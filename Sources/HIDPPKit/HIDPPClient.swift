import Foundation
import Diagnostics

// 프로토콜 근거는 모두 Solaar master e7304c4 (lib/logitech_receiver/*.py) 기준.

public enum HIDPPError: Error, Equatable {
    case ioError(Int32)
    case timeout
    /// HID++ 2.0 기능 에러 코드 (hidpp20_constants.ErrorCode)
    case featureError(UInt8)
    /// HID++ 1.0 에러 코드 (hidpp10_constants.ErrorCode). 리시버 자신과 빈/절전 슬롯이 이 형식으로 답한다.
    case hidpp10Error(UInt8)
}

public enum HIDPP {
    // base.py: HIDPP_LONG_MESSAGE_ID / _LONG_MESSAGE_SIZE / HIDPP_SHORT_MESSAGE_ID / SHORT_MESSAGE_SIZE
    public static let longReportID: UInt8 = 0x11
    public static let longReportSize = 20
    public static let shortReportID: UInt8 = 0x10
    public static let shortReportSize = 7

    // base.py SOLAAR_SOFTWARE_ID 주석: 0x07 OpenRGB, 0x0A LGSTrayEx, 0x0B Solaar, 0x0D G HUB, 0x0F 펌웨어가 사용 중.
    // 0은 장치 발신 알림용. 그 외 비어 있는 값 중 하나를 고정 사용.
    public static let softwareID: UInt8 = 0x09

    // base.py request(): 2.0 기능 에러는 [0xFF, featureIdx, funcSW, code], 1.0 에러는 숏 리포트 [0x8F, featureIdx, funcSW, code]
    static let hidpp20ErrorMarker: UInt8 = 0xFF
    static let hidpp10ErrorMarker: UInt8 = 0x8F

    // hidpp20_constants.ErrorCode.BUSY, hidpp10_constants.ErrorCode.BUSY
    static let hidpp20Busy: UInt8 = 0x08
    static let hidpp10Busy: UInt8 = 0x07

    /// base.py write(): [reportID, devnumber, featureIdx, (function<<4)|swID, params...]를 20바이트로 0 패딩.
    static func frame(deviceIndex: UInt8, feature: UInt8, function: UInt8, params: [UInt8]) -> [UInt8] {
        var report = [UInt8](repeating: 0, count: longReportSize)
        report[0] = longReportID
        report[1] = deviceIndex
        report[2] = feature
        report[3] = (function << 4) | softwareID
        for (i, p) in params.prefix(longReportSize - 4).enumerated() { report[4 + i] = p }
        return report
    }
}

/// 장치나 리시버가 스스로 보낸 리포트. base.py make_notification(): sub_id(byte 2)의 최상위 비트가 0이고,
/// HID++ 2.0 기능 이벤트면 funcSW(byte 3)의 swID 니블이 0, HID++ 1.0 리시버 알림이면 sub_id가 0x40~0x7F.
/// sub_id 0 + address 하위 니블 0은 no-op라 버린다. 구형 1.0 커스텀 배터리 이벤트(0x07/0x0D/0x17)는 받지 않는다.
public struct HIDPPNotification: Sendable, Equatable {
    public let reportID: UInt8
    public let deviceIndex: UInt8
    /// 2.0: 기능 인덱스, 1.0: sub id
    public let subID: UInt8
    /// 2.0: (function << 4) | 0, 1.0: address
    public let address: UInt8
    public let data: [UInt8]

    init?(report r: [UInt8]) {
        guard Self.isNotification(r) else { return nil }
        reportID = r[0]
        deviceIndex = r[1]
        subID = r[2]
        address = r[3]
        data = Array(r[4...])
    }

    /// 할당 없이 바이트만 보고 판정한다. 휠·버튼 이벤트가 쏟아질 때 HID 큐에서 싸게 버리기 위한 것.
    static func isNotification(_ r: [UInt8]) -> Bool {
        guard r.count >= 4, r[2] & 0x80 == 0 else { return false }
        let subID = r[2], address = r[3]
        if subID == 0, address & 0x0F == 0 { return false }
        return subID >= 0x40 || address & 0x0F == 0
    }

    /// HID++ 1.0 리시버 알림(sub id 0x40~0x7F). 2.0 기능 인덱스는 그보다 작다.
    public var isReceiverNotification: Bool { subID >= 0x40 }

    /// 2.0 기능 이벤트의 function 번호. 1.0 알림에는 의미 없다.
    public var function: UInt8 { address >> 4 }

    /// HID++ 1.0 리시버 알림 0x41(common.Notification.DJ_PAIRING, 장치 연결/해제)이면 링크 수립 여부.
    /// notifications.py: data[0] & 0x40이 서면 끊김, address 0x02(27MHz 구형)는 항상 연결.
    /// Phase 4 실측(Bolt, MX Master 3S): 전원 끔 `42 34 b0`, 켬 `02 34 b0`.
    public var linkEstablished: Bool? {
        guard subID == 0x41, let flags = data.first else { return nil }
        return address == 0x02 || flags & 0x40 == 0
    }

    static func watchKey(slot: UInt8, featureIndex: UInt8) -> UInt16 { UInt16(slot) << 8 | UInt16(featureIndex) }
}

/// HID++ 요청/응답 매칭 계층. 요청은 전용 직렬 큐에서 한 번에 하나씩 처리된다.
/// 응답은 (deviceIndex, featureIndex, function|swID)가 모두 일치할 때만 받아들이고 나머지(알림, 타 클라이언트 응답)는 무시한다.
public final class HIDPPClient: @unchecked Sendable {
    public let timeout: TimeInterval
    private let channel: HIDReportChannel
    private let log = DiagnosticLogger(category: "hidpp")
    private let requestQueue = DispatchQueue(label: "bolt-battery.hidpp.request")
    private let lock = NSLock()
    private var waiter: (([UInt8]) -> Bool)?
    private var onNotification: (@Sendable (HIDPPNotification) -> Void)?
    /// 통과시킬 2.0 기능 이벤트 (slot, featureIndex). Options+가 돌려둔 버튼·휠 이벤트는 초당 수십 개라 HID 큐에서 바로 버린다.
    private var watchedFeatures: Set<UInt16> = []

    /// - Parameter timeout: 요청당 응답 대기. Solaar는 4초(base.py DEFAULT_TIMEOUT)지만 PLAN대로 1초 + 재시도로 간다.
    public init(channel: HIDReportChannel, timeout: TimeInterval = 1.0) throws {
        self.channel = channel
        self.timeout = timeout
        try channel.start { [weak self] report in self?.handle(report) }
    }

    /// BUSY와 타임아웃은 짧은 백오프 후 `attempts`회까지 재시도한다.
    public func request(
        deviceIndex: UInt8, feature: UInt8, function: UInt8, params: [UInt8] = [], attempts: Int = 3
    ) async throws -> [UInt8] {
        var attempt = 1
        while true {
            do {
                return try await requestOnce(deviceIndex: deviceIndex, feature: feature, function: function, params: params)
            } catch let error as HIDPPError where Self.isRetryable(error) {
                log.info("slot \(deviceIndex) feature \(feature) function \(function) attempt \(attempt)/\(attempts): \(error)")
                guard attempt < attempts else { throw error }
                try await Task.sleep(for: .milliseconds(50 * attempt))
                attempt += 1
            }
        }
    }

    static func isRetryable(_ error: HIDPPError) -> Bool {
        switch error {
        case .timeout, .featureError(HIDPP.hidpp20Busy), .hidpp10Error(HIDPP.hidpp10Busy): true
        default: false
        }
    }

    private func requestOnce(deviceIndex: UInt8, feature: UInt8, function: UInt8, params: [UInt8]) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            requestQueue.async {
                continuation.resume(with: Result {
                    try self.requestSync(deviceIndex: deviceIndex, feature: feature, function: function, params: params)
                })
            }
        }
    }

    private func requestSync(deviceIndex: UInt8, feature: UInt8, function: UInt8, params: [UInt8]) throws -> [UInt8] {
        let report = HIDPP.frame(deviceIndex: deviceIndex, feature: feature, function: function, params: params)
        let funcSW = report[3]
        let semaphore = DispatchSemaphore(value: 0)
        var result: Result<[UInt8], HIDPPError>?

        lock.lock()
        waiter = { r in
            guard r.count >= 6, r[1] == deviceIndex else { return false }
            if r[2] == feature, r[3] == funcSW {
                result = .success(Array(r[4...]))
            } else if r[2] == HIDPP.hidpp20ErrorMarker, r[3] == feature, r[4] == funcSW {
                result = .failure(.featureError(r[5]))
            } else if r[0] == HIDPP.shortReportID, r[2] == HIDPP.hidpp10ErrorMarker, r[3] == feature, r[4] == funcSW {
                result = .failure(.hidpp10Error(r[5]))
            } else {
                return false
            }
            semaphore.signal()
            return true
        }
        lock.unlock()
        defer { lock.lock(); waiter = nil; lock.unlock() }

        try channel.write(report)
        guard semaphore.wait(timeout: .now() + timeout) == .success, let result else { throw HIDPPError.timeout }
        return try result.get()
    }

    /// 요청 응답이 아닌 리포트를 받을 콜백. HID 큐에서 불린다.
    /// HID++ 1.0 리시버 알림(sub id 0x40~0x7F)은 항상, 2.0 기능 이벤트는 `watchNotifications`로 등록한 것만 전달한다.
    public func setNotificationHandler(_ handler: @escaping @Sendable (HIDPPNotification) -> Void) {
        lock.lock()
        onNotification = handler
        lock.unlock()
    }

    public func watchNotifications(slot: UInt8, featureIndex: UInt8) {
        lock.lock()
        watchedFeatures.insert(HIDPPNotification.watchKey(slot: slot, featureIndex: featureIndex))
        lock.unlock()
    }

    public func unwatchNotifications(slot: UInt8) {
        lock.lock()
        watchedFeatures = watchedFeatures.filter { $0 >> 8 != UInt16(slot) }
        lock.unlock()
    }

    private func handle(_ report: [UInt8]) {
        lock.lock()
        if let waiter, waiter(report) {
            self.waiter = nil
            lock.unlock()
            return
        }
        guard let handler = onNotification, HIDPPNotification.isNotification(report),
              report[2] >= 0x40 || watchedFeatures.contains(HIDPPNotification.watchKey(slot: report[1], featureIndex: report[2]))
        else {
            lock.unlock()
            return
        }
        lock.unlock()
        if let notification = HIDPPNotification(report: report) { handler(notification) }
    }
}
