import Foundation
import BatteryHistory
import HIDPPKit
import Testing
@testable import BoltBattery

@Test func csvExportsUTCAndAllSlotsInOrder() {
    let samples = [
        BatterySample(time: Date(timeIntervalSince1970: 600), slot: 2, percent: 85, isCharging: true),
        BatterySample(time: Date(timeIntervalSince1970: 0), slot: 1, percent: 90, isCharging: false)
    ]
    #expect(SupportReport.csv(samples) == "timestamp_utc,slot,percent,is_charging\n1970-01-01T00:00:00Z,1,90,0\n1970-01-01T00:10:00Z,2,85,1\n")
    #expect(SupportReport.csv([]) == "timestamp_utc,slot,percent,is_charging\n")
}

@Test func diagnosticsExcludeIdentifiersAndRawErrors() {
    let device = DeviceStatus(receiverID: 987654321, slot: 2, name: "Private device name", battery: nil,
                              lastUpdated: nil, isReachable: false)
    let report = SupportReport.diagnostics(devices: [device], receiver: .openFailed(
        reason: "/Users/private/error", needsInputMonitoring: true))
    #expect(report.contains("input monitoring required: true"))
    #expect(report.contains("Battery: unknown"))
    #expect(report.contains("reachable=false"))
    #expect(!report.contains("Private"))
    #expect(!report.contains("987654321"))
    #expect(!report.contains("/Users/"))
    #expect(SupportReport.diagnostics(devices: [], receiver: .noReceiver).contains("not connected"))
    #expect(SupportReport.diagnostics(devices: [], receiver: .ready(count: 1)).contains("ready (1)"))
}
