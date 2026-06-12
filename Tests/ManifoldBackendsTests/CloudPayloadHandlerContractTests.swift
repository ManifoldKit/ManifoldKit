#if CloudSaaS || Ollama
import XCTest
import ManifoldBackendTestKit
@testable import ManifoldCloud
// v0.48 product split: internal symbols moved into the family targets and
// ManifoldCloudCore; the ManifoldCloud shim only re-exports public surface.
#if Ollama
@testable import ManifoldOllama
#endif
#if CloudSaaS
@testable import ManifoldCloudSaaS
#endif
@testable import ManifoldCloudCore
@testable import ManifoldInference

/// Phase 1b contract tests for ``CloudPayloadHandler``.
///
/// Parameterised over the four enum cases. Each case asserts the
/// observable surface of `SSEPayloadHandler` — token extraction, event
/// extraction, usage extraction (including AI engineering item 5 timing
/// differences), stream-end detection, and error sanitisation — using
/// inline payloads representative of the on-the-wire shape each provider
/// ships. Captured-stream replay through `FixtureComparator` lives in the
/// existing `SSEPayloadReplayTests`; this suite focuses on per-payload
/// classification, which is what `CloudPayloadHandler` directly answers.
final class CloudPayloadHandlerContractTests: XCTestCase {

    // MARK: - OpenAI Chat Completions

    func test_openAI_extractToken_chatCompletionsContentDelta() {
        let payload = #"{"choices":[{"delta":{"content":"Hello"}}]}"#
        XCTAssertEqual(CloudPayloadHandler.openAI.extractToken(from: payload), "Hello")
    }

    func test_openAI_extractEvents_emitsTokenForContentDelta() {
        let payload = #"{"choices":[{"delta":{"content":"world"}}]}"#
        let events = CloudPayloadHandler.openAI.extractEvents(from: payload)
        XCTAssertEqual(events.count, 1)
        if case .token(let text) = events.first { XCTAssertEqual(text, "world") }
        else { XCTFail("expected .token, got \(String(describing: events.first))") }
    }

    func test_openAI_extractUsage_readsTrailingUsageChunk() {
        // OpenAI streams emit a final chunk with `usage` only when
        // `stream_options.include_usage` was sent. Timing-wise this lands
        // AFTER `finish_reason`, so the protocol surface MUST treat
        // usage and finish as independent inputs (AI engineering item 5).
        let payload = #"{"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":48,"total_tokens":60}}"#
        let usage = CloudPayloadHandler.openAI.extractUsage(from: payload)
        XCTAssertEqual(usage?.promptTokens, 12)
        XCTAssertEqual(usage?.completionTokens, 48)
    }

    func test_openAI_isStreamEnd_alwaysFalse() {
        // Chat Completions stops on `[DONE]` (stripped at framing time) +
        // `finish_reason`; the per-payload handler does not own that.
        XCTAssertFalse(CloudPayloadHandler.openAI.isStreamEnd(#"{"choices":[{"finish_reason":"stop"}]}"#))
    }

    func test_openAI_extractStreamError_alwaysNil() {
        // Chat Completions surfaces in-stream errors as HTTP status codes,
        // not SSE event payloads.
        XCTAssertNil(CloudPayloadHandler.openAI.extractStreamError(from: #"{"error":{"message":"x"}}"#))
    }

    // MARK: - OpenAI Responses

    // `.claude` / `.openAIResponses` are published by ManifoldCloudSaaS;
    // this file also compiles in Ollama-only builds where they don't exist.
#if CloudSaaS
    func test_openAIResponses_extractEvents_outputTextDelta() {
        // Responses API delivers the per-token text under `delta` for
        // both reasoning and visible-text named events. The handler
        // classifies as `.token` by default — the named-event dispatcher
        // upgrades reasoning deltas to `.thinkingToken` upstream.
        let payload = #"{"type":"response.output_text.delta","delta":"Hi"}"#
        let events = CloudPayloadHandler.openAIResponses.extractEvents(from: payload)
        XCTAssertEqual(events.count, 1)
        if case .token(let text) = events.first { XCTAssertEqual(text, "Hi") }
        else { XCTFail("expected .token, got \(String(describing: events.first))") }
    }

    func test_openAIResponses_extractUsage_readsResponseEnvelope() {
        // Responses API places usage on the terminal `response` envelope
        // using `input_tokens` / `output_tokens` keys (NOT
        // `prompt_tokens` / `completion_tokens`). The handler normalises.
        let payload = #"{"type":"response.completed","response":{"usage":{"input_tokens":7,"output_tokens":3}}}"#
        let usage = CloudPayloadHandler.openAIResponses.extractUsage(from: payload)
        XCTAssertEqual(usage?.promptTokens, 7)
        XCTAssertEqual(usage?.completionTokens, 3)
    }

    // MARK: - Claude

    func test_claude_extractEvents_thinkingDelta_emitsThinkingToken() {
        let payload = #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me think..."}}"#
        let events = CloudPayloadHandler.claude.extractEvents(from: payload)
        XCTAssertEqual(events.count, 1)
        if case .thinkingToken(let text) = events.first {
            XCTAssertEqual(text, "Let me think...")
        } else {
            XCTFail("expected .thinkingToken, got \(String(describing: events.first))")
        }
    }

    func test_claude_extractEvents_textDelta_emitsToken() {
        let payload = #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}"#
        let events = CloudPayloadHandler.claude.extractEvents(from: payload)
        XCTAssertEqual(events.count, 1)
        if case .token(let text) = events.first { XCTAssertEqual(text, "Hello") }
        else { XCTFail("expected .token, got \(String(describing: events.first))") }
    }

    func test_claude_extractUsage_messageStart_carriesInputOnly() {
        // Claude splits usage across two events: `message_start` ships
        // `input_tokens` (prompt) only; `message_delta` ships `output_tokens`
        // (completion) only. AI engineering item 5 — the protocol surface
        // returns `(prompt, nil)` and `(nil, completion)` respectively;
        // `SSECloudBackend.handleUsage` reconciles.
        let start = #"{"type":"message_start","message":{"usage":{"input_tokens":42}}}"#
        let u1 = CloudPayloadHandler.claude.extractUsage(from: start)
        XCTAssertEqual(u1?.promptTokens, 42)
        XCTAssertNil(u1?.completionTokens)
    }

    func test_claude_extractUsage_messageDelta_carriesOutputOnly() {
        let delta = #"{"type":"message_delta","usage":{"output_tokens":17}}"#
        let u2 = CloudPayloadHandler.claude.extractUsage(from: delta)
        XCTAssertNil(u2?.promptTokens)
        XCTAssertEqual(u2?.completionTokens, 17)
    }

    func test_claude_isStreamEnd_messageStop() {
        XCTAssertTrue(CloudPayloadHandler.claude.isStreamEnd(#"{"type":"message_stop"}"#))
        XCTAssertFalse(CloudPayloadHandler.claude.isStreamEnd(#"{"type":"content_block_delta"}"#))
    }

    func test_claude_extractStreamError_returnsParseError() {
        let payload = #"{"type":"error","error":{"message":"context length exceeded"}}"#
        let err = CloudPayloadHandler.claude.extractStreamError(from: payload)
        XCTAssertNotNil(err)
        // Error is sanitised through CloudBackendError; the message is
        // surfaced verbatim at this layer (CloudErrorSanitizer runs
        // envelope-level on HTTP errors, not stream events).
    }
#endif

    // MARK: - Ollama

#if Ollama
    func test_ollama_extractEvents_chatMessageContent() {
        // `/api/chat` shape: content under `message.content`.
        let payload = #"{"model":"llama3","message":{"role":"assistant","content":"Hi"},"done":false}"#
        let events = CloudPayloadHandler.ollama.extractEvents(from: payload)
        XCTAssertEqual(events.count, 1)
        if case .token(let text) = events.first { XCTAssertEqual(text, "Hi") }
        else { XCTFail("expected .token, got \(String(describing: events.first))") }
    }

    func test_ollama_extractEvents_thinkingBeforeContent() {
        // Reasoning models put text on `message.thinking` BEFORE
        // `message.content`. Emission order on the line matters because
        // downstream consumers see one event sequence; `.thinkingToken`
        // must come before `.token`.
        let payload = #"{"message":{"thinking":"reasoning","content":"answer"},"done":false}"#
        let events = CloudPayloadHandler.ollama.extractEvents(from: payload)
        XCTAssertEqual(events.count, 2)
        if case .thinkingToken(let t1) = events[0] { XCTAssertEqual(t1, "reasoning") }
        else { XCTFail("expected first event .thinkingToken") }
        if case .token(let t2) = events[1] { XCTAssertEqual(t2, "answer") }
        else { XCTFail("expected second event .token") }
    }

    func test_ollama_extractUsage_doneLineCarriesBothCounts() {
        // Ollama places `eval_count` (completion) and `prompt_eval_count`
        // (prompt) on the terminal `"done":true` line. The handler
        // returns both in one call — unlike Claude's split delivery.
        let payload = #"{"done":true,"eval_count":99,"prompt_eval_count":11}"#
        let usage = CloudPayloadHandler.ollama.extractUsage(from: payload)
        XCTAssertEqual(usage?.promptTokens, 11)
        XCTAssertEqual(usage?.completionTokens, 99)
    }

    func test_ollama_extractUsage_nonDoneLine_returnsNil() {
        let payload = #"{"message":{"content":"streaming"},"done":false}"#
        XCTAssertNil(CloudPayloadHandler.ollama.extractUsage(from: payload))
    }
#endif

    // MARK: - Sabotage-style cross-provider isolation

#if CloudSaaS
    func test_handlerCases_doNotCrossContaminate_eventClassification() {
        // OpenAI shape MUST NOT be parsed as Claude content delta.
        let openAIShape = #"{"choices":[{"delta":{"content":"hello"}}]}"#
        XCTAssertNil(CloudPayloadHandler.claude.extractToken(from: openAIShape))
        XCTAssertTrue(CloudPayloadHandler.claude.extractEvents(from: openAIShape).isEmpty)
    }
#endif
}

// MARK: - StreamFinalizer contract

/// Per-provider `StreamFinalizer` smoke checks. Phase 1b only ships the
/// protocol + 4 concrete impls; Phase 2 wires `SSECloudBackend` to consume
/// them. The smoke tests here lock in the per-frame contract so the Phase 2
/// migration has a green floor to push from.
final class StreamFinalizerContractTests: XCTestCase {

    private func data(_ s: String) -> Data { s.data(using: .utf8)! }

    func test_openAIDoneSentinel_finishReasonTerminates() {
        let f = OpenAIDoneSentinelFinalizer()
        let frame = data(#"{"choices":[{"finish_reason":"stop"}]}"#)
        let outcome = f.finalize(frame: frame)
        guard case .streamComplete(let usage, let reason) = outcome else {
            return XCTFail("expected streamComplete, got \(String(describing: outcome))")
        }
        XCTAssertEqual(reason, "stop")
        XCTAssertNil(usage)
    }

    func test_openAIDoneSentinel_trailingUsageTerminates() {
        let f = OpenAIDoneSentinelFinalizer()
        let frame = data(#"{"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":7}}"#)
        guard case .streamComplete(let usage, _) = f.finalize(frame: frame) else {
            return XCTFail("expected streamComplete")
        }
        XCTAssertEqual(usage?.promptTokens, 5)
        XCTAssertEqual(usage?.completionTokens, 7)
    }

    func test_openAIDoneSentinel_tokenDelta_returnsContinue() {
        let f = OpenAIDoneSentinelFinalizer()
        let frame = data(#"{"choices":[{"delta":{"content":"x"}}]}"#)
        XCTAssertEqual(f.finalize(frame: frame), .streamContinue)
    }

    func test_openAIResponsesEvent_responseCompletedTerminates() {
        let f = OpenAIResponsesEventFinalizer()
        let frame = data(#"{"type":"response.completed","response":{"usage":{"input_tokens":3,"output_tokens":2},"status":"completed"}}"#)
        guard case .streamComplete(let usage, let reason) = f.finalize(frame: frame) else {
            return XCTFail("expected streamComplete")
        }
        XCTAssertEqual(usage?.promptTokens, 3)
        XCTAssertEqual(usage?.completionTokens, 2)
        XCTAssertEqual(reason, "completed")
    }

    func test_claudeMessageStop_terminates() {
        let f = ClaudeMessageStopFinalizer()
        let frame = data(#"{"type":"message_stop"}"#)
        guard case .streamComplete = f.finalize(frame: frame) else {
            return XCTFail("expected streamComplete")
        }
    }

    func test_claudeMessageDelta_doesNotTerminate() {
        let f = ClaudeMessageStopFinalizer()
        let frame = data(#"{"type":"message_delta","usage":{"output_tokens":4}}"#)
        XCTAssertEqual(f.finalize(frame: frame), .streamContinue)
    }

#if Ollama
    func test_ollamaDoneFlag_doneTrueTerminatesWithUsage() {
        let f = OllamaDoneFlagFinalizer()
        let frame = data(#"{"done":true,"eval_count":50,"prompt_eval_count":10}"#)
        guard case .streamComplete(let usage, _) = f.finalize(frame: frame) else {
            return XCTFail("expected streamComplete")
        }
        XCTAssertEqual(usage?.promptTokens, 10)
        XCTAssertEqual(usage?.completionTokens, 50)
    }

    func test_ollamaDoneFlag_doneFalseDoesNotTerminate() {
        let f = OllamaDoneFlagFinalizer()
        let frame = data(#"{"done":false,"message":{"content":"x"}}"#)
        XCTAssertEqual(f.finalize(frame: frame), .streamContinue)
    }
#endif

    func test_anyFinalizer_malformedJSONReturnsNil() {
        let frame = data("not json")
        XCTAssertNil(OpenAIDoneSentinelFinalizer().finalize(frame: frame))
#if CloudSaaS
        XCTAssertNil(ClaudeMessageStopFinalizer().finalize(frame: frame))
        XCTAssertNil(OpenAIResponsesEventFinalizer().finalize(frame: frame))
#endif
#if Ollama
        XCTAssertNil(OllamaDoneFlagFinalizer().finalize(frame: frame))
#endif
    }
}
#endif
