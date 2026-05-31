import XCTest
import Foundation
@testable import ManifoldRuntime
import ManifoldInference

// MARK: - ConversationEventTraceTests

/// Unit tests for ``ConversationEventTrace``.
final class ConversationEventTraceTests: XCTestCase {

    // MARK: - Helpers

    private static func message(role: MessageRole = .assistant) -> ChatMessageRecord {
        ChatMessageRecord(
            id: UUID(),
            role: role,
            content: "test",
            sessionID: UUID()
        )
    }

    private static func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString + ".jsonl")
    }

    // MARK: - kinds property

    func test_trace_kinds_property() {
        let messageID = UUID()
        let events: [ConversationEvent] = [
            .streamStarted(messageID: messageID),
            .tokenEmitted(messageID: messageID, delta: "hello"),
            .streamFinished(messageID: messageID, reason: .stop),
        ]
        let trace = ConversationEventTrace(events: events)
        XCTAssertEqual(trace.kinds, [.streamStarted, .tokenEmitted, .streamFinished])
    }

    // MARK: - save(to:) — valid JSONL

    func test_trace_save_writesValidJSONL() throws {
        let messageID = UUID()
        let events: [ConversationEvent] = [
            .streamStarted(messageID: messageID),
            .tokenEmitted(messageID: messageID, delta: "hi"),
            .streamFinished(messageID: messageID, reason: .stop),
        ]
        let trace = ConversationEventTrace(events: events)
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try trace.save(to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        // Each event produces one non-empty line; a trailing newline is expected.
        let lines = content
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }

        XCTAssertEqual(lines.count, 3, "Expected one line per event")

        // Parse each line as JSON and verify the `kind` field.
        let expectedKinds = ["streamStarted", "tokenEmitted", "streamFinished"]
        for (lineText, expectedKind) in zip(lines, expectedKinds) {
            let data = Data(lineText.utf8)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertNotNil(json, "Line should be valid JSON: \(lineText)")
            XCTAssertEqual(json?["kind"] as? String, expectedKind,
                           "Line \(lineText) had wrong kind")
        }
    }

    func test_trace_save_includesIndexField() throws {
        let messageID = UUID()
        let events: [ConversationEvent] = [
            .streamStarted(messageID: messageID),
            .tokenEmitted(messageID: messageID, delta: "world"),
        ]
        let trace = ConversationEventTrace(events: events)
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try trace.save(to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }

        for (expectedIndex, lineText) in lines.enumerated() {
            let data = Data(lineText.utf8)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(json?["index"] as? Int, expectedIndex,
                           "Line \(expectedIndex) should have index field \(expectedIndex)")
        }
    }

    // MARK: - save(to:) — summary fields

    func test_trace_save_includesSummaryFields() throws {
        let messageID = UUID()
        let delta = "Hello, world!"
        let events: [ConversationEvent] = [
            .tokenEmitted(messageID: messageID, delta: delta),
        ]
        let trace = ConversationEventTrace(events: events)
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try trace.save(to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 1)

        let data = Data(lines[0].utf8)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let summary = json?["summary"] as? String
        XCTAssertEqual(summary, delta,
                       "tokenEmitted summary should equal the delta string")
    }

    func test_trace_save_truncatesLongDelta() throws {
        let messageID = UUID()
        // Construct a delta longer than 40 characters.
        let longDelta = String(repeating: "x", count: 80)
        let events: [ConversationEvent] = [
            .tokenEmitted(messageID: messageID, delta: longDelta),
        ]
        let trace = ConversationEventTrace(events: events)
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try trace.save(to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let data = Data(lines[0].utf8)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let summary = json?["summary"] as? String
        XCTAssertEqual(summary?.count, 40,
                       "tokenEmitted summary should be truncated to 40 characters")
    }

    func test_trace_save_emptyTraceWritesSingleNewline() throws {
        let trace = ConversationEventTrace(events: [])
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        try trace.save(to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        // An empty trace produces just the trailing newline (one newline only).
        XCTAssertEqual(content, "\n", "Empty trace should write a single trailing newline")
    }
}
