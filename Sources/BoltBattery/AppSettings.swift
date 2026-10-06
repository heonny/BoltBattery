import Foundation
import Combine
import AppKit

enum AppTheme: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "시스템"
        case .light: "라이트"
        case .dark: "다크"
        }
    }

    var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum DisplayMode: String, CaseIterable {
    case iconAndPercent, percentOnly, iconOnly

    var title: String {
        switch self {
        case .iconAndPercent: "아이콘과 퍼센트"
        case .percentOnly: "퍼센트만"
        case .iconOnly: "아이콘만"
        }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let lowBatteryThresholds = [0, 10, 20, 30]
    @Published var lowBatteryThreshold: Int {
        didSet { defaults.set(lowBatteryThreshold, forKey: "lowBatteryThreshold") }
    }
    @Published var theme: AppTheme {
        didSet { defaults.set(theme.rawValue, forKey: "theme") }
    }
    @Published var displayMode: DisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: "displayMode") }
    }
    @Published var fileLogging: Bool {
        didSet { defaults.set(fileLogging, forKey: "fileLogging") }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let threshold = defaults.integer(forKey: "lowBatteryThreshold")
        lowBatteryThreshold = Self.lowBatteryThresholds.contains(threshold) ? threshold : 0
        theme = AppTheme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .iconAndPercent
        fileLogging = defaults.object(forKey: "fileLogging") as? Bool ?? false
    }
}
