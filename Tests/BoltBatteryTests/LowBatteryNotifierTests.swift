import Foundation
import HIDPPKit
import Testing
@testable import BoltBattery

@MainActor
private final class NotificationStub: BatteryNotificationDelivery {
    var authorized = true
    var shouldFail = false
    var authorizations = 0
    var sent = 0
    func authorize() async throws -> Bool {
        authorizations += 1
        return authorized
    }
    func send(name: String, percent: Int, identifier: String) async throws {
        if shouldFail { throw CocoaError(.fileWriteUnknown) }
        sent += 1
    }
}

private func batteryDevice(_ percent: Int, charging: Bool = false, reachable: Bool = true, slot: UInt8 = 2) -> DeviceStatus {
    DeviceStatus(receiverID: 1, slot: slot, name: "Test Mouse", battery: BatteryReading(
        percent: percent, isCharging: charging, isApproximate: false), lastUpdated: Date(), isReachable: reachable)
}

@Test @MainActor func lowBatteryIsOptInAndRequiresPermission() async throws {
    let suite = UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let delivery = NotificationStub()
    let notifier = LowBatteryNotifier(settings: settings, defaults: defaults, delivery: delivery)
    #expect(settings.lowBatteryThreshold == 0)
    await notifier.process([batteryDevice(5)])
    #expect(delivery.sent == 0)
    #expect(delivery.authorizations == 0)
    delivery.authorized = false
    #expect(try await !notifier.configure(20))
    #expect(settings.lowBatteryThreshold == 0)
    delivery.authorized = true
    #expect(try await notifier.configure(20))
    #expect(AppSettings(defaults: defaults).lowBatteryThreshold == 20)
    #expect(try await notifier.configure(0))
    #expect(delivery.authorizations == 2)
    defaults.set(99, forKey: "lowBatteryThreshold")
    #expect(AppSettings(defaults: defaults).lowBatteryThreshold == 0)
}

@Test @MainActor func lowBatteryAlertsOnceUntilChargingEvenAfterRestart() async throws {
    let suite = UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.lowBatteryThreshold = 20
    let delivery = NotificationStub()
    let notifier = LowBatteryNotifier(settings: settings, defaults: defaults, delivery: delivery)
    await notifier.process([batteryDevice(21), batteryDevice(10, reachable: false)])
    #expect(delivery.sent == 0)
    await notifier.process([batteryDevice(20)])
    await notifier.process([batteryDevice(10)])
    #expect(delivery.sent == 1)
    let restarted = LowBatteryNotifier(settings: settings, defaults: defaults, delivery: delivery)
    await restarted.process([batteryDevice(10)])
    #expect(delivery.sent == 1)
    await restarted.process([batteryDevice(10, charging: true)])
    #expect(delivery.sent == 1)
    await restarted.process([batteryDevice(10)])
    #expect(delivery.sent == 2)
    await restarted.process([batteryDevice(10, slot: 3)])
    #expect(delivery.sent == 3)
}

@Test @MainActor func failedNotificationDoesNotSuppressRetry() async {
    let suite = UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.lowBatteryThreshold = 10
    let delivery = NotificationStub()
    let notifier = LowBatteryNotifier(settings: settings, defaults: defaults, delivery: delivery)
    delivery.shouldFail = true
    await notifier.process([batteryDevice(5)])
    delivery.shouldFail = false
    await notifier.process([batteryDevice(5)])
    #expect(delivery.sent == 1)
}

@Test(arguments: [10, 20, 30]) @MainActor
func batteryRecoveryRearmsNotificationsAcrossRestarts(threshold: Int) async {
    let suite = UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    settings.lowBatteryThreshold = threshold
    let delivery = NotificationStub()
    let notifier = LowBatteryNotifier(settings: settings, defaults: defaults, delivery: delivery)
    await notifier.process([batteryDevice(threshold)])
    #expect(delivery.sent == 1)

    let restarted = LowBatteryNotifier(settings: settings, defaults: defaults, delivery: delivery)
    await restarted.process([batteryDevice(threshold + 4)])
    await restarted.process([batteryDevice(threshold)])
    await restarted.process([batteryDevice(100, reachable: false)])
    await restarted.process([batteryDevice(threshold)])
    #expect(delivery.sent == 1)

    await restarted.process([batteryDevice(threshold + 5)])
    #expect(delivery.sent == 1)
    let recovered = LowBatteryNotifier(settings: settings, defaults: defaults, delivery: delivery)
    await recovered.process([batteryDevice(threshold)])
    await recovered.process([batteryDevice(threshold - 1)])
    #expect(delivery.sent == 2)
}
