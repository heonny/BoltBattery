import AppKit
import BatteryHistory
import HIDPPKit
import UniformTypeIdentifiers

enum SupportReport {
    static func csv(_ samples: [BatterySample]) -> String {
        let formatter = ISO8601DateFormatter()
        let rows = samples.sorted { ($0.time, $0.slot) < ($1.time, $1.slot) }.map {
            "\(formatter.string(from: $0.time)),\($0.slot),\($0.percent),\($0.isCharging ? 1 : 0)"
        }
        return (["timestamp_utc,slot,percent,is_charging"] + rows).joined(separator: "\n") + "\n"
    }

    static func diagnostics(devices: [DeviceStatus], receiver: ReceiverState) -> String {
        let state: String
        switch receiver {
        case .noReceiver: state = "not connected"
        case .ready(let count): state = "ready (\(count))"
        case .openFailed(_, let needsPermission):
            state = "open failed; input monitoring required: \(needsPermission)"
        }
        let formatter = ISO8601DateFormatter()
        var lines = ["Receiver: \(state)", "Detected devices: \(devices.count)"]
        for device in devices {
            lines.append("Slot \(device.slot): reachable=\(device.isReachable)")
            if let battery = device.battery {
                lines.append("Battery: \(battery.percent)%; charging=\(battery.isCharging); approximate=\(battery.isApproximate)")
            } else {
                lines.append("Battery: unknown")
            }
            lines.append("Last update (UTC): \(device.lastUpdated.map(formatter.string(from:)) ?? "unknown")")
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class SupportExportController {
    private let model: BatteryModel
    private let settings: AppSettings

    init(model: BatteryModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
    }

    func copyDiagnostics() {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let report = """
        Bolt Battery \(version) (\(build))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Captured (UTC): \(ISO8601DateFormatter().string(from: Date()))
        \(SupportReport.diagnostics(devices: model.devices, receiver: model.receiverState))
        History samples: \(model.samples.count)
        Theme: \(settings.theme.rawValue)
        Display: \(settings.displayMode.rawValue)
        Diagnostic logging: \(settings.fileLogging)
        Low battery threshold: \(settings.lowBatteryThreshold)% (0=off)
        Launch at login: \(model.launchAtLogin)
        """
        NSPasteboard.general.clearContents()
        if !NSPasteboard.general.setString(report, forType: .string) {
            showError("진단 정보를 복사할 수 없습니다", message: "클립보드에 쓰지 못했습니다. 다시 시도해 주세요.")
        }
    }

    func exportHistory() {
        let samples = model.samples
        let panel = NSSavePanel()
        panel.title = "배터리 기록 내보내기"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "BoltBattery-history.csv"
        panel.message = "전체 기록을 내보냅니다. 시각은 UTC, 충전 여부는 1(충전 기록 있음) 또는 0입니다."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    try SupportReport.csv(samples).write(to: url, atomically: true, encoding: .utf8)
                }.value
            } catch {
                showError("배터리 기록을 내보낼 수 없습니다", message: error.localizedDescription)
            }
        }
    }

    private func showError(_ title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
