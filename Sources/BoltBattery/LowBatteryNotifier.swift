import Foundation
import Diagnostics
import HIDPPKit
import UserNotifications

@MainActor
protocol BatteryNotificationDelivery {
    func authorize() async throws -> Bool
    func send(name: String, percent: Int, identifier: String) async throws
}

@MainActor
struct SystemBatteryNotifications: BatteryNotificationDelivery {
    func authorize() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    func send(name: String, percent: Int, identifier: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = "마우스 배터리가 부족합니다"
        content.body = "\(name)의 배터리가 \(percent)% 남았습니다. 충전해 주세요."
        content.sound = .default
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
    }
}

@MainActor
final class LowBatteryNotifier {
    private let settings: AppSettings
    private let defaults: UserDefaults
    private let delivery: any BatteryNotificationDelivery
    private var notified: Set<String>
    private var pending: Set<String> = []
    private var cycles: [String: Int] = [:]
    private let log = DiagnosticLogger(category: "notifications")
    private static let historyKey = "lowBatteryNotifiedDevices"
    private static let recoveryMargin = 5

    init(settings: AppSettings, defaults: UserDefaults = .standard,
         delivery: any BatteryNotificationDelivery = SystemBatteryNotifications()) {
        self.settings = settings
        self.defaults = defaults
        self.delivery = delivery
        notified = Set(defaults.stringArray(forKey: Self.historyKey) ?? [])
    }

    func configure(_ threshold: Int) async throws -> Bool {
        guard AppSettings.lowBatteryThresholds.contains(threshold) else { return false }
        guard threshold != 0 else {
            settings.lowBatteryThreshold = 0
            return true
        }
        guard try await delivery.authorize() else { return false }
        settings.lowBatteryThreshold = threshold
        return true
    }

    func process(_ devices: [DeviceStatus]) async {
        for device in devices {
            guard device.isReachable, device.lastUpdated != nil, let battery = device.battery else { continue }
            // Receiver registry IDs change across reconnects; retain suppression by paired slot and name.
            let key = "\(device.slot):\(device.name)"
            let threshold = settings.lowBatteryThreshold
            // Recover after charging while the app was closed, without rearming on small fluctuations.
            let hasRecovered = threshold > 0 && battery.percent >= threshold + Self.recoveryMargin
            if battery.isCharging || hasRecovered {
                cycles[key, default: 0] += 1
                if notified.remove(key) != nil { persist() }
                continue
            }
            guard threshold > 0, battery.percent <= threshold,
                  !notified.contains(key), !pending.contains(key) else { continue }
            pending.insert(key)
            let cycle = cycles[key, default: 0]
            do {
                try await delivery.send(name: device.name, percent: battery.percent, identifier: "low-battery-\(key)")
                if cycles[key, default: 0] == cycle {
                    notified.insert(key)
                    persist()
                }
            } catch {
                log.error("Battery notification failed: \(error.localizedDescription)")
            }
            pending.remove(key)
        }
    }

    private func persist() { defaults.set(notified.sorted(), forKey: Self.historyKey) }
}
