import XCTest
@testable import ManifoldRuntime
import ManifoldInference

/// Exhaustive value-equality and hashable coverage for the small public types
/// declared in `ConversationRuntimeTypes.swift` (``FinishReason``,
/// ``CompressionReason``, ``PromptContextRequest``). These types are part of
/// the runtime's public event surface — locking their case set and equality
/// semantics catches accidental ABI breakage at compile + test time.
final class ConversationRuntimeTypesTests: XCTestCase {

    // MARK: - FinishReason

    func test_finishReason_allCases_haveDistinctEquality() {
        let cases: [FinishReason] = [.stop, .cancelled, .empty, .length]
        for (i, lhs) in cases.enumerated() {
            for (j, rhs) in cases.enumerated() {
                if i == j {
                    XCTAssertEqual(lhs, rhs, "\(lhs) must equal itself")
                } else {
                    XCTAssertNotEqual(lhs, rhs, "\(lhs) must not equal \(rhs)")
                }
            }
        }
    }

    /// Compile-time guard: switching exhaustively on `FinishReason` must
    /// remain exhaustive. Adding a case without updating this switch will
    /// fail to compile, surfacing the new case at review time.
    func test_finishReason_switchExhaustiveness_compilesForAllCases() {
        func describe(_ reason: FinishReason) -> String {
            switch reason {
            case .stop: return "stop"
            case .cancelled: return "cancelled"
            case .empty: return "empty"
            case .length: return "length"
            case .timedOut: return "timedOut"
            }
        }
        XCTAssertEqual(describe(.stop), "stop")
        XCTAssertEqual(describe(.cancelled), "cancelled")
        XCTAssertEqual(describe(.empty), "empty")
        XCTAssertEqual(describe(.length), "length")
        XCTAssertEqual(describe(.timedOut), "timedOut")
    }

    // MARK: - ConversationTurnOutcome.Classification (B.3 item 2)

    private func makeOutcome(
        reason: FinishReason,
        error: ConversationError? = nil,
        finalText: String = "",
        assistantMessage: ChatMessage? = nil
    ) -> ConversationTurnOutcome {
        ConversationTurnOutcome(
            sessionID: UUID(),
            streamHandle: ConversationStreamHandle(),
            assistantMessageID: assistantMessage?.id,
            assistantMessage: assistantMessage,
            reason: reason,
            error: error,
            finalText: finalText,
            promptTokens: nil,
            completionTokens: nil
        )
    }

    func test_classification_reconstructsFiveOutcomes() {
        // completed: normal stop, no error.
        XCTAssertEqual(
            makeOutcome(reason: .stop, finalText: "hi",
                        assistantMessage: ChatMessage(role: .assistant, content: "hi", sessionID: UUID())).classification,
            .completed
        )
        // A dropped-empty turn with no error is still "completed", not failed.
        XCTAssertEqual(makeOutcome(reason: .empty).classification, .completed)
        // length stop, no error → completed.
        XCTAssertEqual(makeOutcome(reason: .length, finalText: "x").classification, .completed)

        // failed: a normal reason carrying an error.
        XCTAssertEqual(
            makeOutcome(reason: .stop, error: .inference(InferenceError.inferenceFailure("boom"))).classification,
            .failed
        )

        // timedOut: the stall reason maps straight through, even though it
        // carries an error.
        XCTAssertEqual(
            makeOutcome(reason: .timedOut, error: .inference(InferenceError.idleTimeout(.seconds(1)))).classification,
            .timedOut
        )

        // cancelled (with content) vs cancelledEmpty (no content) — the two
        // states the old surface could not distinguish.
        XCTAssertEqual(
            makeOutcome(reason: .cancelled, finalText: "partial",
                        assistantMessage: ChatMessage(role: .assistant, content: "partial", sessionID: UUID())).classification,
            .cancelled
        )
        XCTAssertEqual(makeOutcome(reason: .cancelled).classification, .cancelledEmpty)
    }

    func test_classification_cancelledWithToolOnlyContent_isCancelledNotEmpty() {
        // A cancel that captured a tool call but no visible text still counts
        // as "cancelled" (content present via assistantMessage), not
        // cancelled-empty.
        let toolMessage = ChatMessage(role: .assistant, content: "", sessionID: UUID())
        XCTAssertEqual(
            makeOutcome(reason: .cancelled, finalText: "", assistantMessage: toolMessage).classification,
            .cancelled
        )
    }

    // MARK: - CompressionReason

    func test_compressionReason_distinctEquality() {
        XCTAssertEqual(CompressionReason.contextWindowExceeded, .contextWindowExceeded)
        XCTAssertEqual(CompressionReason.manual, .manual)
        XCTAssertNotEqual(CompressionReason.contextWindowExceeded, .manual)
    }

    func test_compressionReason_switchExhaustiveness_compilesForAllCases() {
        func describe(_ reason: CompressionReason) -> String {
            switch reason {
            case .contextWindowExceeded: return "context"
            case .manual: return "manual"
            }
        }
        XCTAssertEqual(describe(.contextWindowExceeded), "context")
        XCTAssertEqual(describe(.manual), "manual")
    }

    // MARK: - PromptContextRequest

    func test_promptContextRequest_storesAllFields() {
        let id = UUID()
        let request = PromptContextRequest(sessionID: id, messageCount: 7, userInput: "hi")
        XCTAssertEqual(request.sessionID, id)
        XCTAssertEqual(request.messageCount, 7)
        XCTAssertEqual(request.userInput, "hi")
    }

    func test_promptContextRequest_equatable_byValue() {
        let id = UUID()
        let a = PromptContextRequest(sessionID: id, messageCount: 3, userInput: nil)
        let b = PromptContextRequest(sessionID: id, messageCount: 3, userInput: nil)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func test_promptContextRequest_inequality_anyFieldDifferent() {
        let id = UUID()
        let base = PromptContextRequest(sessionID: id, messageCount: 3, userInput: "x")

        XCTAssertNotEqual(
            base,
            PromptContextRequest(sessionID: UUID(), messageCount: 3, userInput: "x")
        )
        XCTAssertNotEqual(
            base,
            PromptContextRequest(sessionID: id, messageCount: 4, userInput: "x")
        )
        XCTAssertNotEqual(
            base,
            PromptContextRequest(sessionID: id, messageCount: 3, userInput: "y")
        )
        XCTAssertNotEqual(
            base,
            PromptContextRequest(sessionID: id, messageCount: 3, userInput: nil)
        )
    }

    func test_promptContextRequest_userInputNil_isPreserved() {
        let request = PromptContextRequest(sessionID: UUID(), messageCount: 0, userInput: nil)
        XCTAssertNil(request.userInput)
    }
}
