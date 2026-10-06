import AppKit
import BatteryHistory
import Charts
import Combine
import HIDPPKit
import SwiftUI

@main
struct BoltBatteryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 창을 만들지 않는다. 메뉴바 항목과 팝오버는 AppDelegate가 AppKit으로 띄운다.
        Settings { EmptyView() }
    }
}

/// 상태 항목 + 시스템 NSMenu. 메뉴 항목 하나에 SwiftUI 뷰를 통째로 넣는다.
/// macOS 26부터 시스템 메뉴가 Liquid Glass로 그려지고 그림자·모서리·바깥 클릭 닫힘을 OS가 맡는다.
/// (MenuBarExtra .window와 NSPopover는 불투명 재질을 깔고, 직접 만든 투명 패널은 창 그림자가 네모로 비쳤다.)
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = BatteryModel()
    private var statusItem: NSStatusItem?
    private var hosting: NSHostingView<PopoverView>?
    private var subscription: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MouseIcon.dumpPreviewIfRequested()
        // Info.plist의 LSUIElement와 같은 효과. 번들 없이 swift run으로 띄워도 Dock 아이콘이 생기지 않게 한다.
        NSApplication.shared.setActivationPolicy(.accessory)

        let hosting = NSHostingView(rootView: PopoverView(model: model))
        hosting.frame.size = hosting.fittingSize
        self.hosting = hosting

        let item = NSMenuItem()
        item.view = hosting
        let menu = NSMenu()
        menu.addItem(item)
        menu.delegate = self

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.menu = menu
        self.statusItem = statusItem

        // objectWillChange는 값이 바뀌기 직전에 오므로 다음 런루프 턴에 읽는다.
        subscription = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateButton() }
        }
        updateButton()

        // 스크린샷 확인용: `BoltBattery --debug-panel`로 띄우면 메뉴를 바로 연다.
        if CommandLine.arguments.contains("--debug-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { statusItem.button?.performClick(nil) }
        }
    }

    /// 메뉴가 열릴 때 내용 크기를 다시 잰다. 열린 동안엔 메뉴가 크기를 바꾸지 않으므로 늘어난 문구는 다음에 열 때 반영된다.
    func menuWillOpen(_ menu: NSMenu) {
        guard let hosting else { return }
        hosting.frame.size = hosting.fittingSize
    }

    private func updateButton() {
        guard let button = statusItem?.button else { return }
        button.image = MouseIcon.image(for: model.primary)
        button.title = " " + MenuBarIcon.title(for: model.primary)
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
    @State private var range: HistoryRange = .day
    @State private var confirmingClear = false
    @State private var hoverLabel: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DeviceSection(model: model)
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
            Divider()
            HStack(spacing: 4) {
                IconButton("arrow.clockwise", help: "지금 갱신", hoverLabel: $hoverLabel) { model.refreshNow() }
                if confirmingClear {
                    IconButton("checkmark", help: "6개월치 기록을 지웁니다", role: .destructive, hoverLabel: $hoverLabel) {
                        model.clearHistory()
                        confirmingClear = false
                    }
                    IconButton("xmark", help: "취소", hoverLabel: $hoverLabel) { confirmingClear = false }
                } else {
                    IconButton("eraser", help: "기록 지우기", hoverLabel: $hoverLabel) { confirmingClear = true }
                }
                Spacer()
                // 호버 중인 버튼의 설명. 툴팁 상자 대신 늘 같은 자리에 뜬다.
                Text(hoverLabel ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                IconButton("autostartstop", help: model.launchAtLogin ? "로그인 시 실행: 켜짐" : "로그인 시 실행: 꺼짐",
                           isOn: model.launchAtLogin, hoverLabel: $hoverLabel) {
                    model.setLaunchAtLogin(!model.launchAtLogin)
                }
                IconButton("power", help: "종료", hoverLabel: $hoverLabel) { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            }
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

/// 텍스트 없는 정사각 아이콘 버튼. 평소엔 아이콘만, 마우스를 올리면 옅은 채움이 생기고 설명은 버튼 줄 가운데 `hoverLabel`에 뜬다.
/// 비활성화 패널에서는 시스템 툴팁(.help)이 뜨지 않는다.
struct IconButton: View {
    let symbol: String
    let help: String
    var role: ButtonRole?
    var isOn = false
    @Binding var hoverLabel: String?
    let action: () -> Void

    @State private var hovering = false

    init(_ symbol: String, help: String, role: ButtonRole? = nil, isOn: Bool = false,
         hoverLabel: Binding<String?>, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.role = role
        self.isOn = isOn
        _hoverLabel = hoverLabel
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.primary))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(HoverSquareStyle(hovering: hovering, isOn: isOn))
        .onHover { inside in
            withAnimation(.easeOut(duration: 0.15)) { hovering = inside }
            if inside {
                hoverLabel = help
            } else if hoverLabel == help {
                hoverLabel = nil
            }
        }
        .onAppear {
            // 스크린샷 확인용: BOLT_DEBUG_HOVER=<symbol>이면 그 버튼을 호버 상태로 그린다.
            if ProcessInfo.processInfo.environment["BOLT_DEBUG_HOVER"] == symbol {
                hovering = true
                hoverLabel = help
            }
        }
    }
}

/// macOS 툴바·Finder의 아이콘 버튼처럼 테두리 없이 옅은 채움만으로 호버와 누름을 표현한다.
/// 채움은 항상 같은 색이고 불투명도만 바뀐다. 스타일 자체를 갈아끼우면 보간이 안 돼 한 번 번쩍인다.
/// 켜진 토글은 호버 없이도 상태가 읽히도록 강조색을 옅게 깐다.
struct HoverSquareStyle: ButtonStyle {
    let hovering: Bool
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let level: Double = configuration.isPressed ? 0.16 : hovering ? 0.09 : 0
        configuration.label
            .background(shape.fill(Color.accentColor).opacity(isOn ? 0.14 : 0))
            .background(shape.fill(.primary).opacity(level))
            .contentShape(shape)
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
        return device.isReachable ? "마지막 확인 \(seen)" : "절전 중, 마지막 확인 \(seen)"
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
