public struct BatteryReading: Equatable, Sendable {
    public let percent: Int
    public let isCharging: Bool
    /// `0x1000`의 단계형 값이거나 `0x1004`가 SoC 대신 레벨 플래그만 준 경우.
    public let isApproximate: Bool

    public init(percent: Int, isCharging: Bool, isApproximate: Bool) {
        self.percent = percent
        self.isCharging = isCharging
        self.isApproximate = isApproximate
    }

    // common.BatteryStatus: 0 discharging, 1 recharging, 2 almost full, 3 full, 4 slow recharge, 5 invalid, 6 thermal.
    // common.Battery.charging(): 1~4를 충전 중으로 본다.
    static func isCharging(status: UInt8) -> Bool { (1...4).contains(status) }

    /// hidpp20.py decipher_battery_unified: [soc%, levelFlags, status, _]. soc가 0이면 levelFlags로 근사.
    /// common.BatteryLevelApproximation: FULL(8) 90, GOOD(4) 50, LOW(2) 20, CRITICAL(1) 5, 그 외 EMPTY 0.
    public init?(unifiedBatteryReply r: [UInt8]) {
        guard r.count >= 3 else { return nil }
        if r[0] > 0 {
            percent = Int(r[0])
            isApproximate = false
        } else {
            percent = switch r[1] {
            case 8: 90
            case 4: 50
            case 2: 20
            case 1: 5
            default: 0
            }
            isApproximate = true
        }
        isCharging = Self.isCharging(status: r[2])
    }

    /// hidpp20.py decipher_battery_status: [level%, nextLevel%, status]. 장치가 정한 몇 단계 값만 온다.
    public init?(batteryStatusReply r: [UInt8]) {
        guard r.count >= 3 else { return nil }
        percent = Int(r[0])
        isApproximate = true
        isCharging = Self.isCharging(status: r[2])
    }
}
