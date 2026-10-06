import Foundation
import Testing
@testable import Diagnostics

@Test func fileLoggingCanBeDisabledAndResumed() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("app.log")
    let log = DiagnosticFile(fileURL: url)
    log.append("before enabling")
    log.flush()
    #expect(!FileManager.default.fileExists(atPath: url.path))
    log.setEnabled(true)
    log.append("first event")
    log.setEnabled(false)
    log.append("must not appear")
    log.setEnabled(true)
    log.append("second event")
    log.flush()
    let content = try String(contentsOf: url, encoding: .utf8)
    #expect(content.contains("first event"))
    #expect(content.contains("second event"))
    #expect(!content.contains("must not appear"))
    #expect(!content.contains("before enabling"))
}

@Test func rotationKeepsOnlyTwoBoundedFiles() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DiagnosticFile(fileURL: directory.appendingPathComponent("app.log"), maxBytes: 128)
    log.setEnabled(true)
    for index in 0..<20 { log.append("event \(index): " + String(repeating: "x", count: 50)) }
    log.flush()
    let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
    #expect(files.count == 2)
    for file in files { #expect(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize! <= 128) }
    #expect(try String(contentsOf: log.fileURL, encoding: .utf8).contains("event 19"))
}

@Test func writeFailureIsReportedWithoutCrashing() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try Data().write(to: file)
    let log = DiagnosticFile(fileURL: file.appendingPathComponent("app.log"))
    log.setEnabled(true)
    log.append("event")
    log.flush()
    #expect(log.lastError != nil)
}

@Test func longUnicodeMessagesStayBoundedAndReadable() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DiagnosticFile(fileURL: directory.appendingPathComponent("app.log"), maxBytes: 128)
    log.setEnabled(true)
    log.append("first\nsecond\r" + String(repeating: "배터리", count: 100))
    log.flush()
    let data = try Data(contentsOf: log.fileURL)
    #expect(data.count <= 128)
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.contains("first\\nsecond\\r"))
    #expect(text.filter { $0 == "\n" }.count == 1)
}
