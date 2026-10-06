import os

public struct DiagnosticLogger: Sendable {
    private let category: String
    private let system: Logger

    public init(category: String) {
        self.category = category
        system = Logger(subsystem: "bolt-battery", category: category)
    }

    public func info(_ message: String) {
        system.info("\(message, privacy: .public)")
        DiagnosticFile.shared.append("[INFO] [\(category)] \(message)")
    }

    public func error(_ message: String) {
        system.error("\(message, privacy: .public)")
        DiagnosticFile.shared.append("[ERROR] [\(category)] \(message)")
    }
}
