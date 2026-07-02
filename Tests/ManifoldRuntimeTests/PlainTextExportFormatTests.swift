import XCTest
@testable import ManifoldRuntime
import ManifoldInference

/// Unit tests for ``PlainTextExportFormat`` — pure serialization, no SwiftData.
/// Mirrors ``MarkdownExportFormatTests`` case-for-case, swapping the Markdown
/// syntax assertions for plain-text equivalents.
final class PlainTextExportFormatTests: XCTestCase {

    private let sessionID = UUID()

    private func makeRecord(title: String = "Round Trip") -> ChatSession {
        ChatSession(id: sessionID, title: title)
    }

    private func makeMessage(role: MessageRole, content: String, offset: TimeInterval = 0) -> ChatMessage {
        ChatMessage(
            role: role,
            content: content,
            timestamp: Date(timeIntervalSinceReferenceDate: 0).addingTimeInterval(offset),
            sessionID: sessionID
        )
    }

    func test_export_includesTitleHeader() throws {
        let format = PlainTextExportFormat()
        let data = try format.export(
            session: makeRecord(title: "My Chat"),
            messages: []
        )

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("My Chat\n"), "Plain text must start with the bare title; got: \(text)")
    }

    func test_export_includesExportTimestampInHeader() throws {
        let format = PlainTextExportFormat()
        let data = try format.export(
            session: makeRecord(),
            messages: []
        )

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("Exported:"), "Header must include export timestamp marker")
        XCTAssertTrue(text.contains("Session created:"), "Header must include session creation timestamp")
    }

    func test_export_rendersUserAndAssistantBlocks() throws {
        let format = PlainTextExportFormat()
        let data = try format.export(
            session: makeRecord(),
            messages: [
                makeMessage(role: .user, content: "Hello"),
                makeMessage(role: .assistant, content: "Hi there!", offset: 1)
            ]
        )

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("User:"))
        XCTAssertTrue(text.contains("Hello"))
        XCTAssertTrue(text.contains("Assistant:"))
        XCTAssertTrue(text.contains("Hi there!"))
    }

    func test_export_omitsSystemMessages() throws {
        let format = PlainTextExportFormat()
        let data = try format.export(
            session: makeRecord(),
            messages: [
                makeMessage(role: .system, content: "You are a helpful assistant"),
                makeMessage(role: .user, content: "Hi", offset: 1)
            ]
        )

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("You are a helpful assistant"), "System content must not leak into plain-text export")
        XCTAssertTrue(text.contains("Hi"))
    }

    func test_export_emptySessionStillProducesValidDocument() throws {
        let format = PlainTextExportFormat()
        let data = try format.export(
            session: makeRecord(title: "Empty"),
            messages: []
        )

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("Empty"))
        XCTAssertTrue(text.contains("---"))
        XCTAssertFalse(text.contains("User:"))
        XCTAssertFalse(text.contains("Assistant:"))
    }

    func test_export_preservesUnicodeContent() throws {
        let format = PlainTextExportFormat()
        let data = try format.export(
            session: makeRecord(),
            messages: [makeMessage(role: .user, content: "café 漢字 🦊")]
        )

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("café 漢字 🦊"))
    }

    func test_export_preservesMessageOrder() throws {
        let format = PlainTextExportFormat()
        let data = try format.export(
            session: makeRecord(),
            messages: [
                makeMessage(role: .user, content: "first", offset: 0),
                makeMessage(role: .assistant, content: "second", offset: 1),
                makeMessage(role: .user, content: "third", offset: 2)
            ]
        )

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        guard
            let firstRange = text.range(of: "first"),
            let secondRange = text.range(of: "second"),
            let thirdRange = text.range(of: "third")
        else {
            XCTFail("All three messages must appear")
            return
        }
        XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound)
        XCTAssertLessThan(secondRange.lowerBound, thirdRange.lowerBound)
    }

    func test_export_skipsMessagesWithoutVisibleContent() throws {
        // Thinking-only / tool-only messages have empty `.content` even
        // though they're not "empty" semantically. The plain-text export must
        // not emit a hollow "Assistant:" block for them.
        let format = PlainTextExportFormat()
        let thinkingOnly = ChatMessage(
            role: .assistant,
            contentParts: [.thinking("internal monologue")],
            timestamp: Date(timeIntervalSinceReferenceDate: 0),
            sessionID: sessionID
        )
        let visible = makeMessage(role: .user, content: "Hi", offset: 1)

        let data = try format.export(session: makeRecord(), messages: [thinkingOnly, visible])
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))

        // Exactly one role block — the user one. No empty assistant block.
        let assistantBlocks = text.components(separatedBy: "Assistant:").count - 1
        XCTAssertEqual(assistantBlocks, 0, "Thinking-only assistant turn must not render an empty block")
        XCTAssertTrue(text.contains("User:"))
        XCTAssertFalse(text.contains("internal monologue"), "Thinking content must not leak into plain-text export")
    }

    func test_export_doesNotLeakMarkdownSyntax() throws {
        let format = PlainTextExportFormat()
        let data = try format.export(
            session: makeRecord(title: "No Markdown"),
            messages: [makeMessage(role: .user, content: "Hello")]
        )

        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(text.contains("**User:**"), "Plain text must not contain Markdown bold syntax")
        XCTAssertFalse(text.contains("# "), "Plain text must not contain a Markdown header")
    }

    func test_format_metadata() {
        let format = PlainTextExportFormat()
        XCTAssertEqual(format.fileExtension, "txt")
        XCTAssertEqual(format.contentType.identifier, "public.plain-text")
    }
}
