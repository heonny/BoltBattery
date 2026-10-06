import AppKit
import HIDPPKit
import SwiftUI

@main
struct BoltBatteryApp: App {
    @StateObject private var model = BatteryModel()

    init() {
        // Info.plist의 LSUIElement와 같은 효과. 번들 없이 swift run으로 띄워도 Dock 아이콘이 생기지 않게 한다.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            BatteryMenu(model: model)
        } label: {
            Image(systemName: MenuBarIcon.symbol(for: model.primary))
            Text(MenuBarIcon.title(for: model.primary))
        }
    }
}

enum MenuBarIcon {
    static func symbol(for device: DeviceStatus?) -> String {
        guard let battery = device?.battery else { return "battery.0" }
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.percent {
        case 88...: return "battery.100"
        case 63...: return "battery.75"
        case 38...: return "battery.50"
        case 13...: return "battery.25"
        default: return "battery.0"
        }
    }

    static func title(for device: DeviceStatus?) -> String {
        guard let battery = device?.battery else { return "--" }
        return "\(battery.percent)%"
    }
}

struct BatteryMenu: View {
    @ObservedObject var model: BatteryModel

    var body: some View {
        if model.devices.isEmpty {
            Text("연결된 장치 없음")
        }
        ForEach(model.devices) { device in
            Text(Self.line(for: device))
            Text(Self.detail(for: device)).font(.caption)
        }
        Divider()
        Button("지금 갱신") { model.refreshNow() }
        Toggle("로그인 시 실행", isOn: Binding(
            get: { model.launchAtLogin },
            set: { model.setLaunchAtLogin($0) }
        ))
        if let error = model.launchAtLoginError {
            Text(error).font(.caption)
        }
        Divider()
        Button("종료") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    static func line(for device: DeviceStatus) -> String {
        guard let battery = device.battery else { return "\(device.name)  배터리 정보 없음" }
        let percent = "\(battery.isApproximate ? "약 " : "")\(battery.percent)%"
        return "\(device.name)  \(percent)\(battery.isCharging ? "  충전 중" : "")"
    }

    static func detail(for device: DeviceStatus) -> String {
        let seen = device.lastUpdated.map { $0.formatted(date: .omitted, time: .shortened) } ?? "없음"
        return device.isReachable ? "마지막 확인 \(seen)" : "절전 중, 마지막 확인 \(seen)"
    }
}
