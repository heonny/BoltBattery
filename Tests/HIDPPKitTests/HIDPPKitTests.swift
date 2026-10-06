import Testing
@testable import HIDPPKit

/// 쓰인 프레임을 보고 응답 리포트를 즉시 되돌려주는 가짜 채널.
final class FakeChannel: HIDReportChannel, @unchecked Sendable {
    var written: [[UInt8]] = []
    private var onReport: (@Sendable ([UInt8]) -> Void)?
    private let reply: ([UInt8]) -> [[UInt8]]

    init(reply: @escaping ([UInt8]) -> [[UInt8]]) { self.reply = reply }

    func start(onReport: @escaping @Sendable ([UInt8]) -> Void) throws { self.onReport = onReport }

    func write(_ report: [UInt8]) throws {
        written.append(report)
        for r in reply(report) { onReport?(r) }
    }
}

func longReply(to frame: [UInt8], _ payload: [UInt8]) -> [UInt8] {
    var r: [UInt8] = [HIDPP.longReportID, frame[1], frame[2], frame[3]] + payload
    r += [UInt8](repeating: 0, count: HIDPP.longReportSize - r.count)
    return r
}

func hidpp20Error(to frame: [UInt8], code: UInt8) -> [UInt8] {
    var r: [UInt8] = [HIDPP.longReportID, frame[1], 0xFF, frame[2], frame[3], code]
    r += [UInt8](repeating: 0, count: HIDPP.longReportSize - r.count)
    return r
}

func hidpp10Error(to frame: [UInt8], code: UInt8) -> [UInt8] {
    [HIDPP.shortReportID, frame[1], 0x8F, frame[2], frame[3], code, 0]
}

// MARK: - HIDPPClient

@Test func frameLayoutMatchesSolaarWrite() throws {
    let frame = HIDPP.frame(deviceIndex: 2, feature: 0x00, function: 1, params: [0, 0, 0xAB])
    #expect(frame.count == 20)
    #expect(Array(frame[0..<7]) == [0x11, 2, 0x00, (1 << 4) | HIDPP.softwareID, 0, 0, 0xAB])
    #expect(frame[7...].allSatisfy { $0 == 0 })
}

@Test func matchingReplyReturnsPayloadAndIgnoresOthers() async throws {
    let channel = FakeChannel { frame in
        [
            [0x11, frame[1], frame[2], frame[3] & 0xF0, 1, 2, 3] + [UInt8](repeating: 0, count: 13),  // swID 0 알림
            longReply(to: [0x11, frame[1] + 1, frame[2], frame[3]], [9, 9, 9]),                     // 다른 장치
            longReply(to: frame, [4, 5, 0xAB]),
        ]
    }
    let client = try HIDPPClient(channel: channel)
    let r = try await client.request(deviceIndex: 2, feature: 0, function: 1, params: [0, 0, 0xAB])
    #expect(Array(r.prefix(3)) == [4, 5, 0xAB])
    #expect(r.count == 16)
}

@Test func featureErrorAndHidpp10ErrorAreSurfaced() async throws {
    let featureErr = try HIDPPClient(channel: FakeChannel { [hidpp20Error(to: $0, code: 0x07)] })
    await #expect(throws: HIDPPError.featureError(0x07)) {
        try await featureErr.request(deviceIndex: 1, feature: 3, function: 2)
    }
    let legacyErr = try HIDPPClient(channel: FakeChannel { [hidpp10Error(to: $0, code: 0x09)] })
    await #expect(throws: HIDPPError.hidpp10Error(0x09)) {
        try await legacyErr.request(deviceIndex: 1, feature: 0, function: 1, attempts: 1)
    }
}

@Test func noReplyTimesOut() async throws {
    let channel = FakeChannel { _ in [] }
    let client = try HIDPPClient(channel: channel, timeout: 0.05)
    await #expect(throws: HIDPPError.timeout) {
        try await client.request(deviceIndex: 1, feature: 0, function: 1, attempts: 1)
    }
    #expect(channel.written.count == 1)
}

@Test func retryPolicyRetriesOnlyBusyAndTimeoutUpToAttempts() async throws {
    let busy = FakeChannel { [hidpp20Error(to: $0, code: 0x08)] }
    let busyClient = try HIDPPClient(channel: busy)
    await #expect(throws: HIDPPError.featureError(0x08)) { try await busyClient.request(deviceIndex: 1, feature: 5, function: 0) }
    #expect(busy.written.count == 3)

    let invalid = FakeChannel { [hidpp20Error(to: $0, code: 0x07)] }
    let invalidClient = try HIDPPClient(channel: invalid)
    await #expect(throws: HIDPPError.featureError(0x07)) { try await invalidClient.request(deviceIndex: 1, feature: 5, function: 0) }
    #expect(invalid.written.count == 1)

    let silent = FakeChannel { _ in [] }
    let silentClient = try HIDPPClient(channel: silent, timeout: 0.02)
    await #expect(throws: HIDPPError.timeout) { try await silentClient.request(deviceIndex: 1, feature: 5, function: 0, attempts: 2) }
    #expect(silent.written.count == 2)
}

@Test func errorForAnotherRequestIsIgnored() async throws {
    let channel = FakeChannel { frame in
        [hidpp20Error(to: [frame[0], frame[1], frame[2] + 1, frame[3]], code: 0x07),  // 다른 기능 인덱스
         hidpp20Error(to: [frame[0], frame[1], frame[2], frame[3] & 0xF0 | 0x0B], code: 0x07)]  // 다른 swID (Solaar)
    }
    let client = try HIDPPClient(channel: channel, timeout: 0.02)
    await #expect(throws: HIDPPError.timeout) { try await client.request(deviceIndex: 1, feature: 5, function: 0, attempts: 1) }
}

@Test func busyIsRetriedThenSucceeds() async throws {
    var calls = 0
    let channel = FakeChannel { frame in
        calls += 1
        return calls == 1 ? [hidpp20Error(to: frame, code: 0x08)] : [longReply(to: frame, [42])]
    }
    let client = try HIDPPClient(channel: channel)
    let r = try await client.request(deviceIndex: 1, feature: 5, function: 0)
    #expect(r[0] == 42)
    #expect(channel.written.count == 2)
}

// MARK: - BatteryReading

@Test func unifiedBatteryDecodesSocAndLevelFlags() {
    #expect(BatteryReading(unifiedBatteryReply: [90, 4, 0, 0]) == BatteryReading(percent: 90, isCharging: false, isApproximate: false))
    #expect(BatteryReading(unifiedBatteryReply: [0, 2, 1, 0]) == BatteryReading(percent: 20, isCharging: true, isApproximate: true))
    #expect(BatteryReading(unifiedBatteryReply: [0, 8, 3, 0]) == BatteryReading(percent: 90, isCharging: true, isApproximate: true))
    #expect(BatteryReading(unifiedBatteryReply: [50, 0]) == nil)
}

@Test func batteryStatusIsAlwaysApproximate() {
    #expect(BatteryReading(batteryStatusReply: [50, 30, 0]) == BatteryReading(percent: 50, isCharging: false, isApproximate: true))
    #expect(BatteryReading(batteryStatusReply: [70, 90, 4]) == BatteryReading(percent: 70, isCharging: true, isApproximate: true))
}

// MARK: - Receiver

/// 슬롯 2에 HID++ 4.5 마우스가 하나 있는 리시버를 흉내낸다. 나머지 슬롯은 Bolt 실측처럼 0x8F/0x09.
func simulatedReceiver(name: String, nameIndex: UInt8 = 2, batteryIndex: UInt8 = 3) -> ([UInt8]) -> [[UInt8]] {
    { frame in
        let (slot, feature, function) = (frame[1], frame[2], frame[3] >> 4)
        guard slot == 2 else { return [hidpp10Error(to: frame, code: 0x09)] }
        switch (feature, function) {
        case (0, 1):
            return [longReply(to: frame, [4, 5, frame[6]])]
        case (0, 0):
            let id = UInt16(frame[4]) << 8 | UInt16(frame[5])
            let index: UInt8 = id == FeatureID.deviceName.rawValue ? nameIndex : id == FeatureID.unifiedBattery.rawValue ? batteryIndex : 0
            return [longReply(to: frame, [index, 0, 1])]
        case (nameIndex, 0):
            return [longReply(to: frame, [UInt8(name.utf8.count)])]
        case (nameIndex, 1):
            return [longReply(to: frame, Array(name.utf8.dropFirst(Int(frame[4])).prefix(16)))]
        case (batteryIndex, 1):
            return [longReply(to: frame, [90, 4, 1, 0])]
        default:
            return [hidpp20Error(to: frame, code: 0x07)]
        }
    }
}

@Test func receiverEnumeratesDevicesAndReadsBattery() async throws {
    let channel = FakeChannel(reply: simulatedReceiver(name: "Logitech MX Master 3S For Mac"))
    let receiver = try Receiver(channel: channel)

    let devices = try await receiver.pairedDevices()
    #expect(devices == [PairedDevice(slot: 2, name: "Logitech MX Master 3S For Mac", protocolMajor: 4, protocolMinor: 5)])

    let battery = try await receiver.battery(slot: 2)
    #expect(battery == BatteryReading(percent: 90, isCharging: true, isApproximate: false))

    // 이름(2조각)과 배터리 모두 Root 조회는 한 번씩만: 기능 인덱스가 캐시된다.
    let rootLookups = channel.written.filter { $0[1] == 2 && $0[2] == 0 && $0[3] >> 4 == 0 }
    #expect(rootLookups.count == 2)
    _ = try await receiver.battery(slot: 2)
    #expect(channel.written.filter { $0[1] == 2 && $0[2] == 0 && $0[3] >> 4 == 0 }.count == 2)
}
