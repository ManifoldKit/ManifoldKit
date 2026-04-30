import XCTest
@testable import BaseChatPersistenceSwiftData
@testable import BaseChatRuntime
import BaseChatInference

/// Unit tests for ``JSONLExportFormat``.
final class JSONLExportFormatTests: XCTestCase {

    private let sessionID = UUID()

    private func makeRecord() -> ChatSessionRecord {
        ChatSessionRecord(id: sessionID, title: "JSONL Session")
    }

    private func makeMessage(role: MessageRole, content: String, offset: TimeInterval = 0) -> ChatMessageRecord {
        ChatMessageRecord(
            role: role,
            content: content,
            timestamp: Date(timeIntervalSinceReferenceDate: 0).addingTimeInterval(offset),
            sessionID: sessionID
        )
    }

    /// Splits JSONL output into trimmed non-empty lines.
    private func lines(of data: Data) throws -> [String] {
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    func test_export_emitsOneJSONObjectPerMessage() throws {
        let format = JSONLExportFormat()
        let data = try format.export(
            session: makeRecord(),
            messages: [
                makeMessage(role: .user, content: "a", offset: 0),
                makeMessage(role: .assistant, content: "b", offset: 1),
                makeMessage(role: .user, content: "c", offset: 2)
            ]
        )

        let lines = try self.lines(of: data)
        XCTAssertEqual(lines.count, 3)
    }

    func test_export_eachLineIsValidJSON() throws {
        let format = JSONLExportFormat()
        let data = try format.export(
            session: makeRecord(),
            messages: [
                makeMessage(role: .user, content: "hello"),
                makeMessage(role: .assistant, content: "world", offset: 1)
            ]
        )

        for line in try lines(of: data) {
            let lineData = try XCTUnwrap(line.data(using: .utf8))
            // Throws if the line is not valid JSON — captured by XCTest as a failure.
            let object = try JSONSerialization.jsonObject(with: lineData)
            let dict = try XCTUnwrap(object as? [String: Any])
            XCTAssertNotNil(dict["role"])
            XCTAssertNotNil(dict["content"])
            XCTAssertNotNil(dict["timestamp"])
        }
    }

    func test_export_preservesRoleAndContentExactly() throws {
        let format = JSONLExportFormat()
        let data = try format.export(
            session: makeRecord(),
            messages: [makeMessage(role: .assistant, content: "the answer is 42")]
        )

        let lineData = try XCTUnwrap(try lines(of: data).first?.data(using: .utf8))
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: lineData) as? [String: Any])
        XCTAssertEqual(dict["role"] as? String, "assistant")
        XCTAssertEqual(dict["content"] as? String, "the answer is 42")
    }

    func test_export_includesSystemMessages() throws {
        // JSONL is a training-data format — system prompts must round-trip.
        let format = JSONLExportFormat()
        let data = try format.export(
            session: makeRecord(),
            messages: [
                makeMessage(role: .system, content: "be concise"),
                makeMessage(role: .user, content: "hi", offset: 1)
            ]
        )

        let lines = try self.lines(of: data)
        XCTAssertEqual(lines.count, 2)
        let first = try XCTUnwrap(JSONSerialization.jsonObject(with: lines[0].data(using: .utf8)!) as? [String: Any])
        XCTAssertEqual(first["role"] as? String, "system")
    }

    func test_export_handlesUnicodeContent() throws {
        let format = JSONLExportFormat()
        let payload = "café 漢字 🦊 \"quoted\" \\backslash newline\nin-content"
        let data = try format.export(
            session: makeRecord(),
            messages: [makeMessage(role: .user, content: payload)]
        )

        let lines = try self.lines(of: data)
        XCTAssertEqual(lines.count, 1, "An embedded \\n in content must remain escaped, not split the line")

        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: lines[0].data(using: .utf8)!) as? [String: Any])
        XCTAssertEqual(dict["content"] as? String, payload)
    }

    func test_export_emptyMessagesProducesEmptyData() throws {
        let format = JSONLExportFormat()
        let data = try format.export(session: makeRecord(), messages: [])
        XCTAssertEqual(data.count, 0)
    }

    func test_export_endsWithNewline() throws {
        let format = JSONLExportFormat()
        let data = try format.export(
            session: makeRecord(),
            messages: [makeMessage(role: .user, content: "hi")]
        )
        XCTAssertEqual(data.last, 0x0A, "JSONL convention: every record (including the last) ends with \\n")
    }

    func test_export_skipsMessagesWithoutVisibleContent() throws {
        // A thinking-only or tool-only message has empty `.content`. Emitting
        // `"content":""` would mislead training-data pipelines, so the JSONL
        // export must drop these rows entirely.
        let format = JSONLExportFormat()
        let thinkingOnly = ChatMessageRecord(
            role: .assistant,
            contentParts: [.thinking("internal monologue")],
            timestamp: Date(timeIntervalSinceReferenceDate: 0),
            sessionID: sessionID
        )
        let visible = makeMessage(role: .user, content: "hi", offset: 1)

        let data = try format.export(session: makeRecord(), messages: [thinkingOnly, visible])
        let lines = try self.lines(of: data)
        XCTAssertEqual(lines.count, 1, "Empty-content rows must be skipped, not encoded as content:\"\"")

        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: lines[0].data(using: .utf8)!) as? [String: Any])
        XCTAssertEqual(dict["role"] as? String, "user")
        XCTAssertEqual(dict["content"] as? String, "hi")
    }

    func test_format_metadata() {
        let format = JSONLExportFormat()
        XCTAssertEqual(format.fileExtension, "jsonl")
        XCTAssertEqual(format.contentType.identifier, "public.json")
    }
}
