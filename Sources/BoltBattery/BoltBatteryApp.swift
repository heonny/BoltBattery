import AppKit
import BatteryHistory
import Charts
import Combine
import Diagnostics
import HIDPPKit
import SwiftUI

@main
@MainActor
enum BoltBatteryApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        // NSApplication keeps a weak delegate; retain it for the entire event loop.
        withExtendedLifetime(delegate) { app.run() }
    }
}

/// 상태 항목 + 시스템 NSMenu. 메뉴 항목 하나에 SwiftUI 뷰를 통째로 넣는다.
/// macOS 26부터 시스템 메뉴가 Liquid Glass로 그려지고 그림자·모서리·바깥 클릭 닫힘을 OS가 맡는다.
/// (MenuBarExtra .window와 NSPopover는 불투명 재질을 깔고, 직접 만든 투명 패널은 창 그림자가 네모로 비쳤다.)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = AppSettings()
    private lazy var model = BatteryModel()
    private lazy var settingsMenu = SettingsMenuController(settings: settings)
    private var statusItem: NSStatusItem?
    private var mainMenu: NSMenu?
    private var hosting: NSHostingView<PopoverView>?
    private var subscription: AnyCancellable?
    private var settingsSubscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticFile.shared.setEnabled(settings.fileLogging)
        DiagnosticLogger(category: "app").info("Application started")
        MouseIcon.dumpPreviewIfRequested()
        let hosting = NSHostingView(rootView: PopoverView(model: model, openSettings: { [weak self] in
            self?.showSettings()
        }))
        hosting.frame.size = hosting.fittingSize
        self.hosting = hosting

        let item = NSMenuItem()
        item.view = hosting
        let menu = NSMenu()
        menu.addItem(item)
        menu.delegate = self
        mainMenu = menu

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.menu = menu
        self.statusItem = statusItem

        // objectWillChange는 값이 바뀌기 직전에 오므로 다음 런루프 턴에 읽는다.
        subscription = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateButton() }
        }
        settings.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateButton() }
        }.store(in: &settingsSubscriptions)
        settings.$fileLogging.dropFirst().sink { enabled in
            DiagnosticFile.shared.setEnabled(enabled)
            DiagnosticLogger(category: "app").info("File logging \(enabled ? "enabled" : "disabled")")
        }.store(in: &settingsSubscriptions)
        updateButton()

        // 스크린샷 확인용: `BoltBattery --debug-panel`로 띄우면 메뉴를 바로 연다.
        if CommandLine.arguments.contains("--debug-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { statusItem.button?.performClick(nil) }
        }
    }

    /// 메뉴가 열릴 때 내용 크기를 다시 잰다. 열린 동안엔 메뉴가 크기를 바꾸지 않으므로 늘어난 문구는 다음에 열 때 반영된다.
    func menuWillOpen(_ menu: NSMenu) {
        guard menu === mainMenu else { return }
        model.refreshNow()
        guard let hosting else { return }
        hosting.frame.size = hosting.fittingSize
    }

    private func updateButton() {
        guard let button = statusItem?.button else { return }
        button.image = settings.displayMode == .percentOnly ? nil : MouseIcon.image(for: model.primary)
        button.title = settings.displayMode == .iconOnly ? "" :
            (settings.displayMode == .iconAndPercent ? " " : "") + MenuBarIcon.title(for: model.primary)
        button.setAccessibilityLabel("Bolt Battery · \(MenuBarIcon.title(for: model.primary))")
    }

    private func showSettings() {
        // End the current menu before asking the status item to open its settings menu.
        statusItem?.menu?.cancelTracking()
        DispatchQueue.main.async { [weak self] in
            guard let self, let statusItem = self.statusItem, let button = statusItem.button else { return }
            let menu = self.settingsMenu.makeMenu(
                launchAtLogin: self.model.launchAtLogin,
                onLaunchAtLogin: { [weak self] in
                    guard let self else { return }
                    self.model.setLaunchAtLogin(!self.model.launchAtLogin)
                },
                onRefresh: self.model.refreshNow,
                onClear: self.model.clearHistory
            )
            menu.delegate = self
            statusItem.menu = menu
            button.performClick(nil)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        if menu !== mainMenu { statusItem?.menu = mainMenu }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DiagnosticLogger(category: "app").info("Application stopped")
        DiagnosticFile.shared.flush()
    }
}

enum MenuBarIcon {
    static func title(for device: DeviceStatus?) -> String {
        guard let battery = device?.battery else { return "--" }
        return "\(battery.percent)%"
    }
}

struct PopoverView: View {
    @ObservedObject var model: BatteryModel
    let openSettings: () -> Void
    @State private var range: HistoryRange = .day

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                DeviceSection(model: model)
                Button(action: openSettings) {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 14))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("설정")
            }
            Divider()
            Picker("범위", selection: $range) {
                ForEach(HistoryRange.allCases) { Text(Self.title(for: $0)).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // 차트는 유리 위에서 격자와 뒤 배경이 겹쳐 읽기 어려워 불투명 카드에 올린다.
            HistoryChart(points: model.chartPoints(range), range: range)
                .frame(height: 150)
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            if let error = model.launchAtLoginError {
                Text(error).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    static func title(for range: HistoryRange) -> String {
        switch range {
        case .day: "시간별"
        case .week: "일간"
        case .quarter: "주간"
        }
    }
}

struct DeviceSection: View {
    @ObservedObject var model: BatteryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch model.receiverState {
            case .noReceiver:
                Text("Bolt 리시버가 연결되지 않았습니다").foregroundStyle(.secondary)
            case .openFailed(let reason, let needsInputMonitoring):
                Text("리시버를 열 수 없습니다 (\(reason))").foregroundStyle(.secondary)
                HStack {
                    if needsInputMonitoring {
                        Button("입력 모니터링 권한 허용…") { model.requestInputMonitoring() }
                    }
                    Button("다시 시도") { model.retryReceivers() }
                }
            case .ready:
                if model.displayDevices.isEmpty {
                    Text("장치를 찾는 중입니다. 마우스를 움직여 주세요.").foregroundStyle(.secondary)
                }
            }
            ForEach(model.displayDevices) { device in
                HStack(alignment: .firstTextBaseline) {
                    Text(device.name).font(.headline)
                    Spacer()
                    Text(Self.percent(for: device)).font(.title3.monospacedDigit())
                }
                Text(Self.detail(for: device)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func percent(for device: DeviceStatus) -> String {
        guard let battery = device.battery else { return "--" }
        return "\(battery.isApproximate ? "약 " : "")\(battery.percent)%\(battery.isCharging ? " ⚡︎" : "")"
    }

    static func detail(for device: DeviceStatus) -> String {
        let seen = device.lastUpdated.map { $0.formatted(date: .omitted, time: .shortened) } ?? "없음"
        return device.isReachable ? "마지막 확인 \(seen)" : "응답 없음, 마지막 확인 \(seen)"
    }
}

struct HistoryChart: View {
    let points: [ChartPoint]
    let range: HistoryRange

    var body: some View {
        if points.count < 2 {
            Text("아직 기록이 충분하지 않습니다")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Chart(points) { point in
                AreaMark(x: .value("시각", point.time), y: .value("배터리", point.percent))
                    .foregroundStyle(.linearGradient(colors: [Color.accentColor.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("시각", point.time), y: .value("배터리", point.percent))
                    .foregroundStyle(Color.accentColor)
                    .interpolationMethod(.monotone)
                if point.isCharging {
                    PointMark(x: .value("시각", point.time), y: .value("배터리", point.percent))
                        .foregroundStyle(.green)
                        .symbolSize(20)
                }
            }
            .chartXScale(domain: Date().addingTimeInterval(-range.window)...Date())
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks(values: [0, 50, 100]) }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: Self.axisFormat(for: range))
                }
            }
        }
    }

    static func axisFormat(for range: HistoryRange) -> Date.FormatStyle {
        switch range {
        case .day: .dateTime.hour()
        case .week: .dateTime.weekday(.abbreviated)
        case .quarter: .dateTime.month(.abbreviated).day()
        }
    }
}
