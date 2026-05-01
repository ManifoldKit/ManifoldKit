import XCTest
@testable import BaseChatRuntime
import BaseChatInference

/// Locks the ``ConversationExportFormat`` protocol contract: the two built-in
/// formats (``MarkdownExportFormat`` and ``JSONLExportFormat``) round-trip a
/// minimal session+messages snapshot to non-empty bytes whose decoded text
/// preserves user content. Format-internal structure is exercised in detail
/// by ``MarkdownExportFormatTests`` and ``JSONLExportFormatTests``; this file
/// only defends the protocol's required surface (`fileExtension`,
/// `contentType`, `export`) so adding a third format does not silently break
/// the contract.
final class ConversationExportFormatContractTests: XCTestCase {

    private let sessionID = UUID()

    private func makeSession() -> ChatSessionRecord {
        ChatSessionRecord(id: sessionID, title: "Contract Session")
    }

    private func makeMessages() -> [ChatMessageRecord] {
        [
            ChatMessageRecord(role: .user, content: "ping", sessionID: sessionID),
            ChatMessageRecord(role: .assistant, content: "pong", sessionID: sessionID),
        ]
    }

    private func assertContract<F: ConversationExportFormat>(
        _ format: F,
        expectedExtension: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertEqual(
            format.fileExtension, expectedExtension,
            "fileExtension must match the format's documented value",
            file: file, line: line
        )
        XCTAssertFalse(
            format.contentType.identifier.isEmpty,
            "contentType must resolve to a non-empty UTI",
            file: file, line: line
        )

        let data = try format.export(session: makeSession(), messages: makeMessages())
        XCTAssertFalse(
            data.isEmpty,
            "export must produce non-empty bytes for a non-empty session",
            file: file, line: line
        )

        let text = try XCTUnwrap(String(data: data, encoding: .utf8), file: file, line: line)
        XCTAssertTrue(
            text.contains("ping") && text.contains("pong"),
            "exported text must preserve user/assistant content verbatim",
            file: file, line: line
        )
    }

    func test_markdownFormat_satisfiesProtocolContract() throws {
        try assertContract(MarkdownExportFormat(), expectedExtension: "md")
    }

    func test_jsonlFormat_satisfiesProtocolContract() throws {
        try assertContract(JSONLExportFormat(), expectedExtension: "jsonl")
    }

    /// Defends the documented "we don't re-sort" rule on the protocol: callers
    /// pass messages already in chronological order, and the format must
    /// preserve that order in its serialized output.
    func test_export_preservesCallerProvidedOrder() throws {
        let format = MarkdownExportFormat()
        let session = makeSession()
        let messages = [
            ChatMessageRecord(role: .user, content: "first", sessionID: sessionID),
            ChatMessageRecord(role: .assistant, content: "second", sessionID: sessionID),
            ChatMessageRecord(role: .user, content: "third", sessionID: sessionID),
        ]

        let data = try format.export(session: session, messages: messages)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        guard let firstIdx = text.range(of: "first")?.lowerBound,
              let secondIdx = text.range(of: "second")?.lowerBound,
              let thirdIdx = text.range(of: "third")?.lowerBound else {
            XCTFail("All three message contents must appear in the export")
            return
        }

        XCTAssertLessThan(firstIdx, secondIdx, "Message order must be preserved")
        XCTAssertLessThan(secondIdx, thirdIdx, "Message order must be preserved")
    }
}
