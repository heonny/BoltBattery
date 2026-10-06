import Foundation
import AppKit
import Testing
@testable import BoltBattery

@Test @MainActor func settingsPersistAndInvalidDisplayFallsBack() {
    let suite = UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    #expect(settings.displayMode == .iconAndPercent)
    #expect(settings.fileLogging)
    settings.displayMode = .percentOnly
    settings.fileLogging = false
    let restored = AppSettings(defaults: defaults)
    #expect(restored.displayMode == .percentOnly)
    #expect(!restored.fileLogging)
    defaults.set("unknown-mode", forKey: "displayMode")
    #expect(AppSettings(defaults: defaults).displayMode == .iconAndPercent)
}

@Test(arguments: [false, true]) @MainActor func historyResetRequiresConfirmationAndRefreshDoesNot(confirmed: Bool) {
    _ = NSApplication.shared
    var resets = 0
    var refreshes = 0
    let controller = SettingsMenuController(settings: AppSettings(), confirmClear: { confirmed })
    defer { withExtendedLifetime(controller) {} }
    let menu = controller.makeMenu(launchAtLogin: false, onLaunchAtLogin: {},
                                   onRefresh: { refreshes += 1 }, onClear: { resets += 1 })
    let clear = menu.items.firstIndex { $0.title == "배터리 기록 초기화…" }!
    menu.performActionForItem(at: clear)
    #expect(resets == (confirmed ? 1 : 0))
    menu.performActionForItem(at: menu.items.firstIndex { $0.title == "지금 갱신" }!)
    #expect(refreshes == 1)
}

@Test @MainActor func settingsMenuActionsChangePreferencesAndKeepOneDisplaySelection() {
    _ = NSApplication.shared
    let suite = UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AppSettings(defaults: defaults)
    let controller = SettingsMenuController(settings: settings)
    defer { withExtendedLifetime(controller) {} }
    let menu = controller.makeMenu(launchAtLogin: false, onLaunchAtLogin: {})
    let percent = menu.items.firstIndex { $0.title == "퍼센트만" }!
    menu.performActionForItem(at: percent)
    #expect(settings.displayMode == .percentOnly)
    #expect(menu.items.filter { $0.representedObject is String && $0.state == .on }.count == 1)
    #expect(menu.items[percent].state == .on)
    let logging = menu.items.firstIndex { $0.title == "파일 로그 쓰기" }!
    menu.performActionForItem(at: logging)
    #expect(!settings.fileLogging)
    #expect(menu.items[logging].state == .off)
    #expect(AppSettings(defaults: defaults).displayMode == .percentOnly)
}
