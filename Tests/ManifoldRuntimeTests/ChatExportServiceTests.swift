import XCTest
@testable import ManifoldRuntime
import ManifoldInference

final class ChatExportServiceTests: XCTestCase {

    private let sessionID = UUID()

    private func makeMessage(role: MessageRole, content: String) -> ChatMessageRecord {
        ChatMessageRecord(role: role, content: content, sessionID: sessionID)
    }

    // MARK: - Plain Text

    func test_exportPlainText_formatsCorrectly() {
        let messages = [
            makeMessage(role: .user, content: "Hello"),
            makeMessage(role: .assistant, content: "Hi there!")
        ]

        let result = ChatExportService.export(
            messages: messages,
            sessionTitle: "Test Chat",
            format: .plainText
        )

        XCTAssertTrue(result.contains("User: Hello"))
        XCTAssertTrue(result.contains("Assistant: Hi there!"))
    }

    func test_exportPlainText_includesSessionTitle() {
        let result = ChatExportService.export(
            messages: [],
            sessionTitle: "My Session",
            format: .plainText
        )

        XCTAssertTrue(result.contains("Chat: My Session"))
    }

    func test_exportPlainText_handlesEmptyMessages() {
        let result = ChatExportService.export(
            messages: [],
            sessionTitle: "Empty",
            format: .plainText
        )

        XCTAssertTrue(result.contains("Chat: Empty"))
        XCTAssertFalse(result.contains("User:"))
        XCTAssertFalse(result.contains("Assistant:"))
    }

    func test_exportPlainText_skipsSystemMessages() {
        let messages = [
            makeMessage(role: .system, content: "You are a bot"),
            makeMessage(role: .user, content: "Hello"),
            makeMessage(role: .assistant, content: "Hi!")
        ]

        let result = ChatExportService.export(
            messages: messages,
            sessionTitle: "Test",
            format: .plainText
        )

        XCTAssertFalse(result.contains("You are a bot"),
                       "System messages should not appear in plain text export")
        XCTAssertTrue(result.contains("User: Hello"))
    }

    // MARK: - Markdown

    func test_exportMarkdown_formatsWithHeaders() {
        let messages = [
            makeMessage(role: .user, content: "Tell me a story"),
            makeMessage(role: .assistant, content: "Once upon a time...")
        ]

        let result = ChatExportService.export(
            messages: messages,
            sessionTitle: "Story",
            format: .markdown
        )

        XCTAssertTrue(result.contains("**User:**"))
        XCTAssertTrue(result.contains("**Assistant:**"))
        XCTAssertTrue(result.contains("Tell me a story"))
        XCTAssertTrue(result.contains("Once upon a time..."))
    }

    func test_exportMarkdown_includesTitleAsH1() {
        let result = ChatExportService.export(
            messages: [],
            sessionTitle: "My Story",
            format: .markdown
        )

        XCTAssertTrue(result.contains("# My Story"))
    }

    func test_exportMarkdown_skipsSystemMessages() {
        let messages = [
            makeMessage(role: .system, content: "System prompt"),
            makeMessage(role: .user, content: "Hello")
        ]

        let result = ChatExportService.export(
            messages: messages,
            sessionTitle: "Test",
            format: .markdown
        )

        XCTAssertFalse(result.contains("System prompt"))
        XCTAssertTrue(result.contains("**User:**"))
    }

    // MARK: - Export Format

    func test_exportFormat_fileExtensions() {
        XCTAssertEqual(ExportFormat.plainText.fileExtension, "txt")
        XCTAssertEqual(ExportFormat.markdown.fileExtension, "md")
    }

    // MARK: - Robustness

    func test_exportMarkdown_specialCharacters_notCorrupted() {
        let specialContent = "*bold* _italic_ # heading `code` **strong** ~~strike~~"
        let messages = [makeMessage(role: .user, content: specialContent)]

        let result = ChatExportService.export(
            messages: messages,
            sessionTitle: "Special Chars",
            format: .markdown
        )

        // User-authored prose should pass through unescaped
        XCTAssertTrue(result.contains("*bold*"), "Asterisk-bold should not be escaped")
        XCTAssertTrue(result.contains("_italic_"), "Underscore-italic should not be escaped")
        XCTAssertTrue(result.contains("# heading"), "Hash heading should not be escaped")
        XCTAssertTrue(result.contains("`code`"), "Backtick code should not be escaped")
        XCTAssertTrue(result.contains("**strong**"), "Double-asterisk bold should not be escaped")
        XCTAssertTrue(result.contains("~~strike~~"), "Strikethrough should not be escaped")
    }

    func test_exportPlainText_unicodeAndEmoji_preserved() {
        let unicodeContent = "Hello 🤖 مرحبا こんにちは"
        let messages = [makeMessage(role: .user, content: unicodeContent)]

        let result = ChatExportService.export(
            messages: messages,
            sessionTitle: "Unicode Test",
            format: .plainText
        )

        XCTAssertTrue(result.contains("🤖"), "Emoji should be preserved in plain text export")
        XCTAssertTrue(result.contains("مرحبا"), "Arabic text should be preserved in plain text export")
        XCTAssertTrue(result.contains("こんにちは"), "Japanese text should be preserved in plain text export")
    }

    func test_exportMarkdown_veryLongMessage_completes() {
        let longContent = String(repeating: "a", count: 100_000)
        let messages = [makeMessage(role: .assistant, content: longContent)]

        let result = ChatExportService.export(
            messages: messages,
            sessionTitle: "Long Message",
            format: .markdown
        )

        XCTAssertGreaterThan(result.count, 100_000,
                             "Export output should be longer than the 100,000-character message itself")
    }

    func test_exportPlainText_nullBytesInContent_handled() {
        let contentWithNull = "before\0after"
        let messages = [makeMessage(role: .user, content: contentWithNull)]

        // Must not crash; result must be non-empty
        let result = ChatExportService.export(
            messages: messages,
            sessionTitle: "Null Byte Test",
            format: .plainText
        )

        XCTAssertFalse(result.isEmpty, "Export should return non-empty output even with null bytes in content")
    }

    func test_export_emptySessionTitle_usesDefault() {
        let result = ChatExportService.export(
            messages: [],
            sessionTitle: "",
            format: .plainText
        )

        // Must not crash; output should contain some recognisable title-area text
        XCTAssertFalse(result.isEmpty, "Export should return non-empty output with an empty session title")
        XCTAssertTrue(result.contains("Chat:"),
                      "Output should contain the 'Chat:' label even when the session title is empty")
    }
}
