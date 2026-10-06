import Foundation

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

/// HID++ 요청/응답 매칭 계층. 요청은 전용 직렬 큐에서 한 번에 하나씩 처리된다.
/// 응답은 (deviceIndex, featureIndex, function|swID)가 모두 일치할 때만 받아들이고 나머지(알림, 타 클라이언트 응답)는 무시한다.
public final class HIDPPClient: @unchecked Sendable {
    public let timeout: TimeInterval
    private let channel: HIDReportChannel
    private let requestQueue = DispatchQueue(label: "bolt-battery.hidpp.request")
    private let lock = NSLock()
    private var waiter: (([UInt8]) -> Bool)?

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
            } catch let error as HIDPPError where attempt < attempts && Self.isRetryable(error) {
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

    private func handle(_ report: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        if let waiter, waiter(report) { self.waiter = nil }
    }
}
