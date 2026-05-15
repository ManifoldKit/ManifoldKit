#if CloudSaaS
import XCTest
@testable import ManifoldBackends
@testable import ManifoldCloud
@testable import ManifoldInference

/// Focused tests for the helper types extracted during the
/// `SSEPayloadHandler`-cohort consolidation (#964).
///
/// The streaming loops themselves are exercised end-to-end by the existing
/// suites (`OpenAIBackendTests`, `OpenAIResponsesBackendTests`,
/// `OllamaBackendTests`, `CloudThinkingTokenTests`, `CloudBackendSSETests`).
/// This file pins the small new units so a future regression in the lookup
/// table or per-step state surfaces with a tight diagnostic instead of an
/// integration failure deep in the byte loop.
final class SSEStreamParserCohortTests: XCTestCase {

    // MARK: - OpenAIResponsesBackend.ResponsesEventKind

    func test_responsesEventKind_classifiesReasoningDeltaAliases() {
        XCTAssertEqual(
            OpenAIResponsesBackend.ResponsesEventKind(name: "response.reasoning_summary_text.delta"),
            .reasoningDelta
        )
        XCTAssertEqual(
            OpenAIResponsesBackend.ResponsesEventKind(name: "response.reasoning_summary.delta"),
            .reasoningDelta
        )
    }

    func test_responsesEventKind_classifiesReasoningDoneAliases() {
        XCTAssertEqual(
            OpenAIResponsesBackend.ResponsesEventKind(name: "response.reasoning_summary_text.done"),
            .reasoningDone
        )
        XCTAssertEqual(
            OpenAIResponsesBackend.ResponsesEventKind(name: "response.reasoning_summary.done"),
            .reasoningDone
        )
    }

    func test_responsesEventKind_classifiesOutputAndCompletionEvents() {
        XCTAssertEqual(
            OpenAIResponsesBackend.ResponsesEventKind(name: "response.output_text.delta"),
            .outputTextDelta
        )
        XCTAssertEqual(
            OpenAIResponsesBackend.ResponsesEventKind(name: "response.completed"),
            .completed
        )
        XCTAssertEqual(
            OpenAIResponsesBackend.ResponsesEventKind(name: "response.error"),
            .error
        )
    }

    func test_responsesEventKind_classifiesFunctionCallLifecycle() {
        XCTAssertEqual(
            OpenAIResponsesBackend.ResponsesEventKind(name: "response.output_item.added"),
            .outputItemAdded
        )
        XCTAssertEqual(
            OpenAIResponsesBackend.ResponsesEventKind(name: "response.function_call_arguments.delta"),
            .functionCallArgumentsDelta
        )
        XCTAssertEqual(
            OpenAIResponsesBackend.ResponsesEventKind(name: "response.function_call_arguments.done"),
            .functionCallArgumentsDone
        )
    }

    func test_responsesEventKind_unknownNamesFallThrough() {
        XCTAssertEqual(
            OpenAIResponsesBackend.ResponsesEventKind(name: "response.content_part.added"),
            .unknown
        )
        XCTAssertEqual(
            OpenAIResponsesBackend.ResponsesEventKind(name: ""),
            .unknown
        )
        // An exact-match table must not partial-match a typo'd suffix.
        XCTAssertEqual(
            OpenAIResponsesBackend.ResponsesEventKind(name: "response.completed.extra"),
            .unknown
        )
    }

    // MARK: - OpenAIBackend.ChatCompletionsStreamState
    //
    // Removed in Phase 2/B/iii/δ: the inline stream-state struct was deleted
    // along with the `processPayload` cluster. Per-stream state now lives on
    // `OpenAIStreamEventExtractor`, whose initial-state invariants are
    // covered by `OpenAIStreamEventExtractorTests`
    // (`test_extractor_isFreshPerInstance_finalisationGuardDoesNotLeakAcrossStreams`).
}

extension OpenAIResponsesBackend.ResponsesEventKind: Equatable {}
#endif
