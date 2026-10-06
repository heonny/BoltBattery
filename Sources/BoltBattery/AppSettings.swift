import Foundation
import Combine

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
    @Published var displayMode: DisplayMode {
        didSet { defaults.set(displayMode.rawValue, forKey: "displayMode") }
    }
    @Published var fileLogging: Bool {
        didSet { defaults.set(fileLogging, forKey: "fileLogging") }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        displayMode = DisplayMode(rawValue: defaults.string(forKey: "displayMode") ?? "") ?? .iconAndPercent
        fileLogging = defaults.object(forKey: "fileLogging") as? Bool ?? true
    }
}
