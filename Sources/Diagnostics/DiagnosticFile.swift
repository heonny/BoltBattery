import Foundation
import os

public final class DiagnosticFile: @unchecked Sendable {
    public static let shared = DiagnosticFile(fileURL: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/BoltBattery/bolt-battery.log"))
    public let fileURL: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "bolt-battery.log", qos: .utility)
    private var enabled = false
    private var writeError: String?
    private let failureLog = Logger(subsystem: "bolt-battery", category: "logging")

    public var lastError: String? { queue.sync { writeError } }

    public init(fileURL: URL, maxBytes: Int = 1_048_576) {
        self.fileURL = fileURL
        self.maxBytes = max(64, maxBytes)
    }

    public func setEnabled(_ enabled: Bool) {
        queue.sync { self.enabled = enabled }
    }

    public func append(_ message: String) {
        let timestamp = Date.now.ISO8601Format()
        queue.async { [self] in
            guard enabled else { return }
            do {
                try write("\(timestamp) \(message)")
                writeError = nil
            } catch {
                let description = "\(fileURL.path): \(error.localizedDescription)"
                if writeError != description { failureLog.error("File logging failed: \(description, privacy: .public)") }
                writeError = description
            }
        }
    }

    public func flush() { queue.sync {} }

    private func write(_ line: String) throws {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let escaped = line.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        var data = Data(escaped.utf8.prefix(maxBytes - 1))
        // A truncated line must remain valid UTF-8 for Console and text editors.
        while String(data: data, encoding: .utf8) == nil { data.removeLast() }
        data.append(0x0A)
        if manager.fileExists(atPath: fileURL.path) {
            let size = try fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            if size + data.count > maxBytes {
                let previous = fileURL.appendingPathExtension("1")
                if manager.fileExists(atPath: previous.path) { try manager.removeItem(at: previous) }
                try manager.moveItem(at: fileURL, to: previous)
            }
        }
        if !manager.fileExists(atPath: fileURL.path) {
            try data.write(to: fileURL, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } else {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
    }
}
