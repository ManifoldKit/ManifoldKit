#if canImport(FoundationModels)
import XCTest
import FoundationModels
import ManifoldContract
@testable import ManifoldFoundation

@available(iOS 26, macOS 26, *)
final class FoundationConversationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(ProcessInfo.processInfo.isOperatingSystemAtLeast(
            .init(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        ), "FoundationModels requires iOS 26 / macOS 26")
    }

    private func texts(_ request: FoundationConversation) -> [String] {
        request.entries.map { entry in
            let segments: [Transcript.Segment]
            switch entry {
            case .prompt(let value): segments = value.segments
            case .response(let value): segments = value.segments
            default: return "unexpected entry"
            }
            return segments.compactMap { if case .text(let value) = $0 { value.content } else { nil } }.joined()
        }
    }

    func test_fullHistory_restoresRolesAndCurrentPromptExactlyOnce() throws {
        let request = try FoundationConversation(history: [
            .init(role: "user", content: "Remember TANGERINE"),
            .init(role: "assistant", content: "OK"),
            .init(role: "user", parts: [.text("What "), .text("word?")])
        ], fallbackPrompt: "What word?")
        XCTAssertEqual(texts(request), ["Remember TANGERINE", "OK"])
        XCTAssertEqual(request.prompt, "What word?")
        let first = try XCTUnwrap(request.entries.first)
        let last = try XCTUnwrap(request.entries.last)
        guard case .prompt = first, case .response = last else {
            return XCTFail("Historical roles must retain their native transcript roles")
        }
    }

    func test_trimEditAndBranch_onlyContainSuppliedHistory() throws {
        for word in ["EDITED", "BRANCHED"] {
            let request = try FoundationConversation(history: [
                .init(role: "user", content: word), .init(role: "assistant", content: "OK"),
                .init(role: "user", content: "Which word?")
            ], fallbackPrompt: "Which word?")
            XCTAssertEqual(texts(request), [word, "OK"])
            XCTAssertFalse(texts(request).joined().contains("TANGERINE"))
        }
        let trimmed = try FoundationConversation(history: [.init(role: "user", content: "Which word?")], fallbackPrompt: "Which word?")
        XCTAssertTrue(trimmed.entries.isEmpty)
        XCTAssertEqual(trimmed.prompt, "Which word?")
    }

    func test_emptyHistory_isSingleTurn_andSystemHistoryIsInstructions() throws {
        let empty = try FoundationConversation(history: [], fallbackPrompt: "Now")
        XCTAssertTrue(empty.entries.isEmpty)
        XCTAssertEqual(empty.prompt, "Now")
        let system = try FoundationConversation(history: [
            .init(role: "system", content: "Persona"), .init(role: "user", content: "Now")
        ], fallbackPrompt: "Now")
        XCTAssertEqual(system.systemInstructions, "Persona")
        XCTAssertTrue(system.entries.isEmpty)
    }

    func test_toolContinuation_preservesCallsResultsAndDenial_withoutRepeatingUser() throws {
        let call = ToolCall(id: "call-1", toolName: "read_marker", arguments: "{}")
        let denied = ToolResult(callId: call.id, content: "DENIED", errorKind: .permissionDenied)
        let result = ToolResult(callId: "call-2", content: "COBALT_42", errorKind: nil)
        let request = try FoundationConversation(history: [
            .init(role: "user", content: "Read marker"),
            .init(role: "assistant", parts: [.toolCall(call)]),
            .init(role: "tool", parts: [.toolResult(denied)]),
            .init(role: "tool", parts: [.toolResult(result)])
        ], fallbackPrompt: "Read marker")
        XCTAssertEqual(texts(request).first, "Read marker")
        let recordedCall = try XCTUnwrap(texts(request).last)
        XCTAssertTrue(recordedCall.contains("read_marker"))
        XCTAssertTrue(recordedCall.contains("call-1"))
        XCTAssertFalse(request.prompt.contains("Read marker"))
        XCTAssertTrue(request.prompt.contains("permissionDenied"))
        XCTAssertEqual(request.prompt.components(separatedBy: "COBALT_42").count, 2)
        XCTAssertLessThan(try XCTUnwrap(request.prompt.range(of: "DENIED")).lowerBound,
                          try XCTUnwrap(request.prompt.range(of: "COBALT_42")).lowerBound)
    }

    func test_privateReasoningIsExcluded_andUnsupportedInputsFailClosed() throws {
        let request = try FoundationConversation(history: [
            .init(role: "assistant", parts: [.thinking("PRIVATE"), .text("Visible")]),
            .init(role: "user", content: "Now")
        ], fallbackPrompt: "Now")
        XCTAssertEqual(texts(request), ["Visible"])
        XCTAssertThrowsError(try FoundationConversation(history: [.init(role: "user", parts: [.image(data: Data(), mimeType: "image/png")])], fallbackPrompt: "Image"))
        XCTAssertThrowsError(try FoundationConversation(history: [.init(role: "unknown", content: "No")], fallbackPrompt: "No"))
        XCTAssertThrowsError(try FoundationConversation(history: [.init(role: "user", parts: [.toolCall(.init(id: "bad", toolName: "read_marker", arguments: "{}"))])], fallbackPrompt: "No"))
        XCTAssertThrowsError(try FoundationConversation(history: [.init(role: "assistant", parts: [.toolResult(.init(callId: "bad", content: "result", errorKind: nil))])], fallbackPrompt: "No"))
        XCTAssertThrowsError(try FoundationConversation(history: [.init(role: "assistant", content: "Already answered")], fallbackPrompt: "Prior question"))
    }
}
#endif
