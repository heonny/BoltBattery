import Foundation
import Diagnostics

// hidpp20_constants.SupportedFeature
public enum FeatureID: UInt16, Sendable, CaseIterable {
    case root = 0x0000
    case deviceName = 0x0005
    case batteryStatus = 0x1000
    case unifiedBattery = 0x1004
    case reprogControlsV4 = 0x1B04
    case wirelessDeviceStatus = 0x1D4B
    case smartShift = 0x2110
    case hiresWheel = 0x2121
    case thumbWheel = 0x2150
}

public struct PairedDevice: Equatable, Sendable {
    public let slot: UInt8
    public let name: String
    public let protocolMajor: UInt8
    public let protocolMinor: UInt8
}

/// 리시버 하나와 그 슬롯에 페어링된 장치들. 읽기 전용 HID++ 호출만 보낸다.
public actor Receiver {
    /// receiver.py: Bolt/Unifying 리시버는 최대 6 슬롯.
    public static let slots: ClosedRange<UInt8> = 1...6

    /// 리시버 식별자. 실제 장치는 IORegistry 엔트리 ID.
    public nonisolated let id: UInt64
    public nonisolated let productID: Int
    public nonisolated let productName: String
    /// 배터리 기능 이벤트와 리시버의 연결/해제 알림. 소비자는 하나여야 한다.
    public nonisolated let notifications: AsyncStream<HIDPPNotification>
    /// 이벤트를 받아볼 기능. 인덱스를 알게 되는 즉시 클라이언트 필터에 등록한다.
    private static let notifiedFeatures: Set<FeatureID> = [.unifiedBattery, .batteryStatus]
    private let client: HIDPPClient
    private let log = DiagnosticLogger(category: "receiver")
    private var featureIndexCache: [UInt8: [FeatureID: UInt8]] = [:]

    /// 연결된 Bolt/Unifying 리시버를 모두 열어 반환한다.
    public static func discover() throws -> [Receiver] {
        try IOHIDReportChannel.discoverReceivers().map { try Receiver(channel: $0) }
    }

    init(channel: IOHIDReportChannel) throws {
        try self.init(channel: channel, id: channel.registryID, productID: channel.productID, productName: channel.productName)
    }

    public init(
        channel: HIDReportChannel, id: UInt64 = 0, productID: Int = 0, productName: String = "", timeout: TimeInterval = 1.0
    ) throws {
        self.id = id
        self.productID = productID
        self.productName = productName
        client = try HIDPPClient(channel: channel, timeout: timeout)
        let (stream, continuation) = AsyncStream<HIDPPNotification>.makeStream(bufferingPolicy: .bufferingNewest(16))
        notifications = stream
        client.setNotificationHandler { continuation.yield($0) }
    }

    /// 슬롯 1~6을 핑해서 응답한 장치만 반환한다.
    public func pairedDevices() async throws -> [PairedDevice] {
        var devices: [PairedDevice] = []
        for slot in Self.slots {
            guard let (major, minor) = try await ping(slot: slot) else { continue }
            // 핑과 이름 조회 사이에 절전에 들어가면 타임아웃. 이름 없이라도 목록에는 올린다.
            let name: String
            do { name = try await deviceName(slot: slot) ?? "slot \(slot)" } catch HIDPPError.timeout { name = "slot \(slot)" }
            devices.append(PairedDevice(slot: slot, name: name, protocolMajor: major, protocolMinor: minor))
        }
        return devices
    }

    /// base.py ping(): ROOT fn1 + [0, 0, mark] -> [major, minor, mark]. 빈 슬롯·무응답이면 nil.
    /// 사용 중에도 BUSY나 일시적인 응답 누락이 생기므로 다른 조회와 같은 제한된 재시도를 적용한다.
    /// HID++ 1.0 에러는 모두 nil: base.py ping()은 0x08을 빈 슬롯, 0x04/0x09를 응답 불가, 0x01을 HID++ 1.0 장치로 보는데
    /// 이 앱은 2.0 배터리 기능만 읽으므로 셋 다 "읽을 장치 없음"이다. Phase 0 실측: Bolt는 빈 슬롯에도 0x09를 준다.
    public func ping(slot: UInt8) async throws -> (major: UInt8, minor: UInt8)? {
        let mark = UInt8.random(in: 0...255)
        do {
            let r = try await client.request(deviceIndex: slot, feature: 0x00, function: 1, params: [0, 0, mark])
            guard r.count >= 3, r[2] == mark else {
                log.info("slot \(slot) ping reply marker mismatch")
                return nil
            }
            return (r[0], r[1])
        } catch HIDPPError.timeout {
            return nil
        } catch HIDPPError.hidpp10Error(let code) {
            log.info("slot \(slot) ping unavailable: HID++ 1.0 error \(code)")
            return nil
        }
    }

    /// hidpp20.py get_name: DEVICE_NAME fn0 -> [length]; fn1 + [offset] -> 최대 16바이트 조각.
    public func deviceName(slot: UInt8) async throws -> String? {
        guard let idx = try await featureIndex(slot: slot, .deviceName) else { return nil }
        let length = Int(try await client.request(deviceIndex: slot, feature: idx, function: 0)[0])
        var bytes: [UInt8] = []
        while bytes.count < length {
            let fragment = try await client.request(deviceIndex: slot, feature: idx, function: 1, params: [UInt8(bytes.count)])
            guard !fragment.isEmpty else { break }
            bytes += fragment.prefix(length - bytes.count)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// `0x1004` 우선, 없으면 `0x1000`. 둘 다 없으면 nil.
    public func battery(slot: UInt8) async throws -> BatteryReading? {
        if let idx = try await featureIndex(slot: slot, .unifiedBattery) {
            // hidpp20.py get_battery_unified: UNIFIED_BATTERY fn1
            return BatteryReading(unifiedBatteryReply: try await client.request(deviceIndex: slot, feature: idx, function: 1))
        }
        if let idx = try await featureIndex(slot: slot, .batteryStatus) {
            // hidpp20.py get_battery_status: BATTERY_STATUS fn0
            return BatteryReading(batteryStatusReply: try await client.request(deviceIndex: slot, feature: idx, function: 0))
        }
        return nil
    }

    /// hidpp20.py FeaturesArray: ROOT fn0 + featureId(BE16) -> [index, flags, version]. index 0이면 미지원.
    /// 슬롯별로 캐시한다. 슬롯에 다른 장치가 페어링되면 `forgetFeatures(slot:)`로 비워야 한다.
    public func featureIndex(slot: UInt8, _ feature: FeatureID) async throws -> UInt8? {
        if let cached = featureIndexCache[slot]?[feature] { return cached == 0 ? nil : cached }
        let id = feature.rawValue
        let r = try await client.request(deviceIndex: slot, feature: 0x00, function: 0, params: [UInt8(id >> 8), UInt8(id & 0xFF)])
        featureIndexCache[slot, default: [:]][feature] = r[0]
        if r[0] != 0, Self.notifiedFeatures.contains(feature) { client.watchNotifications(slot: slot, featureIndex: r[0]) }
        return r[0] == 0 ? nil : r[0]
    }

    /// 알림의 기능 인덱스를 캐시로 역조회한다. 아직 조회한 적 없는 기능이면 nil.
    public func cachedFeature(slot: UInt8, index: UInt8) -> FeatureID? {
        featureIndexCache[slot]?.first { $0.value == index }?.key
    }

    public func forgetFeatures(slot: UInt8) {
        featureIndexCache[slot] = nil
        client.unwatchNotifications(slot: slot)
    }
}
