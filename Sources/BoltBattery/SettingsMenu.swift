import AppKit
import Diagnostics

@MainActor
final class SettingsMenuController: NSObject {
    private let settings: AppSettings
    private var onLaunchAtLogin: () -> Void = {}
    private var onRefresh: () -> Void = {}
    private var onClear: () -> Void = {}
    private let confirmClear: @MainActor () -> Bool

    init(settings: AppSettings, confirmClear: @escaping @MainActor () -> Bool = SettingsMenuController.confirmHistoryClear) {
        self.settings = settings
        self.confirmClear = confirmClear
    }

    func makeMenu(launchAtLogin: Bool, onLaunchAtLogin: @escaping () -> Void,
                  onRefresh: @escaping () -> Void = {}, onClear: @escaping () -> Void = {}) -> NSMenu {
        self.onLaunchAtLogin = onLaunchAtLogin
        self.onRefresh = onRefresh
        self.onClear = onClear
        let menu = NSMenu()
        menu.appearance = settings.theme.appearance
        menu.autoenablesItems = false
        add("지금 갱신", action: #selector(refresh), to: menu)
        add("배터리 기록 초기화…", action: #selector(clearHistory), to: menu)
        menu.addItem(.separator())
        for mode in DisplayMode.allCases {
            let item = add(mode.title, action: #selector(selectDisplay(_:)), to: menu)
            item.representedObject = mode.rawValue
            item.state = settings.displayMode == mode ? .on : .off
        }
        menu.addItem(.separator())
        let themeItem = NSMenuItem(title: "테마", action: nil, keyEquivalent: "")
        let themeMenu = NSMenu(title: "테마")
        themeMenu.appearance = settings.theme.appearance
        themeMenu.autoenablesItems = false
        for theme in AppTheme.allCases {
            let item = add(theme.title, action: #selector(selectTheme(_:)), to: themeMenu)
            item.representedObject = theme.rawValue
            item.state = settings.theme == theme ? .on : .off
        }
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)
        add("진단 로그 쓰기", action: #selector(toggleLogging(_:)), to: menu).state = settings.fileLogging ? .on : .off
        add("로그 폴더 열기…", action: #selector(openLogs), to: menu)
        add("로그인 시 실행", action: #selector(toggleLaunchAtLogin), to: menu).state = launchAtLogin ? .on : .off
        menu.addItem(.separator())
        add("Bolt Battery 정보", action: #selector(showAbout), to: menu)
        add("종료", action: #selector(quit), to: menu).keyEquivalent = "q"
        return menu
    }

    @discardableResult
    private func add(_ title: String, action: Selector, to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    @objc private func selectDisplay(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let mode = DisplayMode(rawValue: rawValue) else { return }
        settings.displayMode = mode
        for item in sender.menu?.items ?? [] {
            guard let value = item.representedObject as? String else { continue }
            item.state = value == rawValue ? .on : .off
        }
    }

    @objc private func selectTheme(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String, let theme = AppTheme(rawValue: rawValue) else { return }
        settings.theme = theme
        for item in sender.menu?.items ?? [] {
            item.state = item === sender ? .on : .off
        }
    }

    @objc private func toggleLogging(_ sender: NSMenuItem) {
        settings.fileLogging.toggle()
        sender.state = settings.fileLogging ? .on : .off
    }

    @objc private func toggleLaunchAtLogin() { onLaunchAtLogin() }
    @objc private func refresh() { onRefresh() }
    @objc private func clearHistory() {
        guard confirmClear() else { return }
        onClear()
    }

    static func confirmHistoryClear() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "배터리 기록을 초기화할까요?"
        alert.informativeText = "저장된 배터리 기록과 그래프가 모두 지워집니다. 이 작업은 되돌릴 수 없습니다. 진단 로그 파일과 설정은 유지됩니다."
        alert.addButton(withTitle: "취소")
        alert.addButton(withTitle: "초기화")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Bolt Battery",
            .credits: NSAttributedString(string: "Logitech 마우스 배터리를 위한 작은 메뉴바 앱.\nMIT License")
        ])
    }

    @objc private func openLogs() {
        DiagnosticFile.shared.flush()
        let directory = DiagnosticFile.shared.fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            guard NSWorkspace.shared.open(directory) else {
                showError("로그 폴더를 열 수 없습니다: \(directory.path)")
                return
            }
            if let error = DiagnosticFile.shared.lastError { showError("로그 파일 저장 실패: \(error)") }
        } catch {
            showError("로그 폴더를 만들 수 없습니다: \(error.localizedDescription)")
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "로그 파일 오류"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
