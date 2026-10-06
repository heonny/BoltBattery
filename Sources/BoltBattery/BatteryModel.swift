import AppKit
import BatteryHistory
import HIDPPKit
import IOKit.hid
import ServiceManagement

/// UI가 보는 상태. HID 작업은 전부 HIDPPKit의 액터·큐에서 돌고, 여기에는 결과만 메인 액터로 들어온다.
@MainActor
final class BatteryModel: ObservableObject {
    @Published private(set) var devices: [DeviceStatus] = []
    @Published private(set) var receiverState: ReceiverState = .noReceiver
    @Published private(set) var samples: [BatterySample] = []
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var launchAtLoginError: String?

    /// PLAN Phase 4: 10분 폴링, tolerance를 넉넉히 줘서 macOS가 다른 깨어남과 묶게 한다.
    static let pollInterval: Duration = .seconds(600)
    static let pollTolerance: Duration = .seconds(180)
    /// 깊은 절전에 든 마우스는 시작 시 핑에 답하지 않아 목록에 오르지 않는다. 장치가 하나도 없는 동안은 30초마다 다시 찾는다.
    /// 빈 슬롯과 절전 슬롯 핑은 리시버가 즉시 에러로 답하므로 비용이 거의 없다.
    static let discoveryInterval: Duration = .seconds(30)

    private let monitor: BatteryMonitor
    private let hotplug = ReceiverMonitor()
    private let history = BatteryHistory(fileURL: BatteryHistory.defaultFileURL())

    init() {
        let (updates, continuation) = AsyncStream<[DeviceStatus]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        monitor = BatteryMonitor { continuation.yield($0) }
        let monitor = monitor
        let hotplug = hotplug
        let history = history
        Task {
            await history.load()
            self.samples = await history.samples
            for await devices in updates {
                self.devices = devices
                await self.recordReadings()
            }
        }
        Task { for await state in hotplug.state { self.receiverState = state } }
        Task { await monitor.run(receivers: hotplug.receivers) }
        Task {
            while !Task.isCancelled {
                // 리시버가 열려 있는데 장치만 없을 때만 빨리 찾는다. 리시버 자체가 없으면 핫플러그 콜백이 깨워 준다.
                if self.devices.isEmpty, case .ready = self.receiverState {
                    try? await Task.sleep(for: Self.discoveryInterval, tolerance: .seconds(5))
                } else {
                    try? await Task.sleep(for: Self.pollInterval, tolerance: Self.pollTolerance)
                }
                await monitor.refresh()
                await self.sync()
            }
        }
    }

    /// `BatteryMonitor`는 값이 그대로면 알리지 않으므로, 폴링 뒤 "마지막 확인" 시각만이라도 메뉴에 반영한다.
    private func sync() async {
        let latest = await monitor.devices
        if latest != devices { devices = latest }
        await recordReadings()
    }

    /// 새 읽기값(lastUpdated가 바뀐 것)만 기록된다. 절전 중인 장치는 새 값이 없으니 기록되지 않는다.
    private func recordReadings() async {
        rememberNames()
        var recorded = false
        for device in devices {
            guard let battery = device.battery, let time = device.lastUpdated else { continue }
            let sample = BatterySample(time: time, slot: device.slot, percent: battery.percent, isCharging: battery.isCharging)
            if await history.record(sample) { recorded = true }
        }
        if recorded { samples = await history.samples }
    }

    /// 표시 중인 장치가 없으면 빈 차트. 슬롯을 합치면 같은 시각의 점이 겹쳐 ID가 충돌한다.
    func chartPoints(_ range: HistoryRange) -> [ChartPoint] {
        guard let slot = primary?.slot else { return [] }
        return BatteryHistory.points(samples, slot: slot, range: range)
    }

    /// UI가 보는 장치 목록. 깊은 절전에 든 마우스는 핑에 답하지 않아 시작 직후 목록이 비는데,
    /// 그때는 기록의 마지막 값을 "절전 중"으로 보여준다. 이름은 CSV에 없으니 UserDefaults에서 가져온다.
    var displayDevices: [DeviceStatus] {
        if !devices.isEmpty { return devices }
        guard case .ready = receiverState else { return [] }
        let names = UserDefaults.standard.dictionary(forKey: Self.deviceNamesKey) as? [String: String] ?? [:]
        var last: [UInt8: BatterySample] = [:]
        for sample in samples { last[sample.slot] = sample }
        return last.keys.sorted().map { slot in
            let sample = last[slot]!
            return DeviceStatus(
                receiverID: 0, slot: slot, name: names[String(slot)] ?? "슬롯 \(slot)",
                battery: BatteryReading(percent: sample.percent, isCharging: sample.isCharging, isApproximate: false),
                lastUpdated: sample.time, isReachable: false
            )
        }
    }

    private static let deviceNamesKey = "deviceNames"

    private func rememberNames() {
        guard !devices.isEmpty else { return }
        var names = UserDefaults.standard.dictionary(forKey: Self.deviceNamesKey) as? [String: String] ?? [:]
        for device in devices { names[String(device.slot)] = device.name }
        UserDefaults.standard.set(names, forKey: Self.deviceNamesKey)
    }

    func clearHistory() {
        Task {
            await history.clear()
            samples = await history.samples
        }
    }

    /// 메뉴바에 보여줄 장치: 배터리 값이 있는 첫 장치. 절전 중이면 마지막 값.
    var primary: DeviceStatus? {
        displayDevices.first { $0.battery != nil }
    }

    func refreshNow() {
        Task {
            await monitor.refresh()
            await sync()
        }
    }

    func retryReceivers() {
        hotplug.retry()
    }

    /// 입력 모니터링은 평소엔 필요 없다(Phase 0 실측). 거부로 열기에 실패한 경우에만 시스템 프롬프트를 띄우고 설정으로 보낸다.
    func requestInputMonitoring() {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginError = nil
        } catch {
            // 번들 없이 swift run으로 띄우면 LaunchServices에 등록할 앱이 없어 실패한다.
            launchAtLoginError = error.localizedDescription
        }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if status == .requiresApproval {
            launchAtLoginError = "시스템 설정 > 일반 > 로그인 항목에서 허용이 필요합니다"
        }
    }
}
