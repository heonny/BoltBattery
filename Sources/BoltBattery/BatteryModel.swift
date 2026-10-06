import AppKit
import HIDPPKit
import IOKit.hid
import ServiceManagement

/// UI가 보는 상태. HID 작업은 전부 HIDPPKit의 액터·큐에서 돌고, 여기에는 결과만 메인 액터로 들어온다.
@MainActor
final class BatteryModel: ObservableObject {
    @Published private(set) var devices: [DeviceStatus] = []
    @Published private(set) var receiverState: ReceiverState = .noReceiver
    @Published private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published private(set) var launchAtLoginError: String?

    /// PLAN Phase 4: 10분 폴링, tolerance를 넉넉히 줘서 macOS가 다른 깨어남과 묶게 한다.
    static let pollInterval: Duration = .seconds(600)
    static let pollTolerance: Duration = .seconds(180)

    private let monitor: BatteryMonitor
    private let hotplug = ReceiverMonitor()

    init() {
        let (updates, continuation) = AsyncStream<[DeviceStatus]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        monitor = BatteryMonitor { continuation.yield($0) }
        let monitor = monitor
        let hotplug = hotplug
        Task { for await devices in updates { self.devices = devices } }
        Task { for await state in hotplug.state { self.receiverState = state } }
        Task { await monitor.run(receivers: hotplug.receivers) }
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval, tolerance: Self.pollTolerance)
                await monitor.refresh()
                await self.sync()
            }
        }
    }

    /// `BatteryMonitor`는 값이 그대로면 알리지 않으므로, 폴링 뒤 "마지막 확인" 시각만이라도 메뉴에 반영한다.
    private func sync() async {
        let latest = await monitor.devices
        if latest != devices { devices = latest }
    }

    /// 메뉴바에 보여줄 장치: 배터리 값이 있는 첫 장치.
    var primary: DeviceStatus? {
        devices.first { $0.battery != nil }
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
