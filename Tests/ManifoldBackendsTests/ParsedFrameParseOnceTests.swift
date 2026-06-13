import XCTest
import Foundation
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore
@testable import ManifoldInference

/// Proves the parse-once migration (`ParsedFrame` / `JSONValue`) produces
/// **provably unchanged** output versus the legacy per-field re-parse path.
///
/// Coverage:
/// - `JSONValue` reproduces `NSNumber`'s Int-vs-Double-vs-Bool casts exactly
///   (the #1 risk: a coercion regression would silently drop usage counts).
/// - Differential: every fixture through both `consume(payload:)` and
///   `consume(frame:)` yields identical event arrays per frame.
/// - Finalizer equivalence: `finalize(frame: ParsedFrame)` ==
///   `finalize(frame: Data)` on terminal + non-terminal frames.
/// - Non-JSON frames (`[DONE]`, keepalive, malformed, empty) → `json == nil`
///   and zero events.
final class ParsedFrameParseOnceTests: XCTestCase {

    // MARK: - JSONValue number coercion fidelity (the #1 risk)

    func test_jsonValue_reproducesNSNumberIntDoubleBoolCasts() {
        // Mirrors the legacy `as? Int` / `as? Double` / `as? Bool` semantics
        // on a JSONSerialization NSNumber tree.
        let json = """
        {"intVal":25,"wholeFloat":100.0,"frac":3.5,"boolTrue":true,"boolFalse":false,"one":1}
        """
        guard let v = JSONValue.parse(string: json) else {
            return XCTFail("parse failed")
        }

        // Plain integers.
        XCTAssertEqual(v["intVal"]?.intValue, 25)
        XCTAssertEqual(v["intVal"]?.doubleValue, 25.0)
        XCTAssertNil(v["intVal"]?.boolValue, "a numeric int is not a bool")

        // Whole float decodes as .number but still recovers as Int (100.0 → 100),
        // exactly matching `100.0 as? Int == 100`.
        XCTAssertEqual(v["wholeFloat"]?.intValue, 100)
        XCTAssertEqual(v["wholeFloat"]?.doubleValue, 100.0)

        // Fractional float: Int recovery fails (3.5 as? Int == nil).
        XCTAssertNil(v["frac"]?.intValue)
        XCTAssertEqual(v["frac"]?.doubleValue, 3.5)

        // Booleans: boolValue succeeds; intValue mirrors `true as? Int == 1`.
        XCTAssertEqual(v["boolTrue"]?.boolValue, true)
        XCTAssertEqual(v["boolTrue"]?.intValue, 1)
        XCTAssertEqual(v["boolFalse"]?.boolValue, false)
        XCTAssertEqual(v["boolFalse"]?.intValue, 0)

        // A numeric 1 must NOT read as a bool (1 as? Bool == nil).
        XCTAssertNil(v["one"]?.boolValue)
        XCTAssertEqual(v["one"]?.intValue, 1)
    }

    func test_jsonValue_usageCounts_survive_wholeFloatEncoding() {
        // A compat server that emits usage as floats (25.0 / 100.0) must not
        // drop the counts — this is the exact silent-drop failure mode.
        let payload = """
        {"choices":[],"usage":{"prompt_tokens":25.0,"completion_tokens":100.0}}
        """
        let usage = OpenAIChatCompletionsPayloadParsing.parseUsage(from: payload)
        XCTAssertEqual(usage?.promptTokens, 25)
        XCTAssertEqual(usage?.completionTokens, 100)
    }

    // MARK: - Non-JSON frames

    func test_parsedFrame_nonJSONFrames_haveNilJSON() {
        for payload in ["[DONE]", "", ": keepalive", "{not json", "  "] {
            let frame = ParsedFrame.make(from: payload)
            XCTAssertNil(frame.json, "non-JSON frame \"\(payload)\" must have json == nil")
            XCTAssertNil(frame.namedEvent)
            XCTAssertEqual(frame.raw, payload)
        }
    }

    func test_extractors_nonJSONFrames_emitZeroEvents() {
        let openAI = OpenAIStreamEventExtractor()
        let claude = ClaudeStreamEventExtractor()
        let responses = OpenAIResponsesStreamEventExtractor()
        for payload in ["[DONE]", "", ": keepalive", "{not json"] {
            let frame = ParsedFrame.make(from: payload)
            XCTAssertTrue(openAI.consume(frame: frame).isEmpty)
            XCTAssertTrue(claude.consume(frame: frame).isEmpty)
            XCTAssertTrue(responses.consume(frame: frame).isEmpty)
        }
    }

    // MARK: - Differential: consume(payload:) == consume(frame:)

    private func assertDifferential(
        _ payloads: [String],
        makeConsumerA: () -> any CloudStreamEventConsumer,
        makeConsumerB: () -> any CloudStreamEventConsumer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // Two fresh consumers (each carries per-stream state) so the string
        // path and the frame path see identical history.
        let a = makeConsumerA()
        let b = makeConsumerB()
        for payload in payloads {
            let viaString = a.consume(payload: payload)
            let viaFrame = b.consume(frame: ParsedFrame.make(from: payload))
            XCTAssertEqual(
                viaString, viaFrame,
                "differential drift on frame: \(payload)",
                file: file, line: line
            )
        }
        XCTAssertEqual(a.finish(cancelled: false), b.finish(cancelled: false),
                       "finish() drift", file: file, line: line)
    }

    func test_differential_openAI_tokensReasoningToolCallsUsage() {
        let payloads = [
            #"{"choices":[{"delta":{"role":"assistant","content":""}}]}"#,
            #"{"choices":[{"delta":{"reasoning_content":"thinking…"}}]}"#,
            #"{"choices":[{"delta":{"content":"Hello"}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"get_weather","arguments":""}}]}}]}"#,
            #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":\"SF\"}"}}]}}]}"#,
            #"{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":25,"completion_tokens":100}}"#,
        ]
        assertDifferential(payloads,
                           makeConsumerA: { OpenAIStreamEventExtractor() },
                           makeConsumerB: { OpenAIStreamEventExtractor() })
    }

    func test_differential_claude_thinkingTextToolUseUsage() {
        let payloads = [
            #"{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","content":[],"usage":{"input_tokens":12,"output_tokens":0}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig123"}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu_1","name":"lookup"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"q\":1}"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":48}}"#,
            #"{"type":"message_stop"}"#,
        ]
        assertDifferential(payloads,
                           makeConsumerA: { ClaudeStreamEventExtractor() },
                           makeConsumerB: { ClaudeStreamEventExtractor() })
    }

    func test_differential_responses_reasoningTextToolCallUsage() {
        // The Responses extractor consumes NamedSSETransport envelopes.
        let payloads: [String] = [
            envelope("response.reasoning_summary_text.delta", #"{"delta":"think"}"#),
            envelope("response.reasoning_summary_text.done", #"{}"#),
            envelope("response.output_text.delta", #"{"delta":"Hello"}"#),
            envelope("response.output_item.added", #"{"item":{"type":"function_call","id":"item_1","call_id":"call_1","name":"do_thing"}}"#),
            envelope("response.function_call_arguments.delta", #"{"item_id":"item_1","delta":"{\"a\":1}"}"#),
            envelope("response.completed", #"{"response":{"status":"completed","usage":{"input_tokens":12,"output_tokens":8}}}"#),
        ]
        assertDifferential(payloads,
                           makeConsumerA: { OpenAIResponsesStreamEventExtractor() },
                           makeConsumerB: { OpenAIResponsesStreamEventExtractor() })
    }

    // MARK: - Finalizer equivalence (Data vs ParsedFrame)

    private func assertFinalizerEquivalent(
        _ finalizer: any StreamFinalizer,
        _ payloads: [String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for payload in payloads {
            let viaData = finalizer.finalize(frame: Data(payload.utf8))
            let viaFrame = finalizer.finalize(frame: ParsedFrame.make(from: payload))
            XCTAssertEqual(viaData, viaFrame, "finalizer drift on: \(payload)",
                           file: file, line: line)
        }
    }

    func test_finalizer_openAI_terminalAndNonTerminal() {
        assertFinalizerEquivalent(OpenAIDoneSentinelFinalizer(), [
            #"{"choices":[{"delta":{"content":"x"}}]}"#,                    // continue
            #"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#,         // complete (stop)
            #"{"choices":[],"usage":{"prompt_tokens":25,"completion_tokens":100}}"#, // trailing usage
            #"{"choices":[],"usage":{"prompt_tokens":25.0,"completion_tokens":100.0}}"#, // float usage
        ])
    }

    func test_finalizer_claude_messageDeltaContinues_messageStopCompletes() {
        assertFinalizerEquivalent(ClaudeMessageStopFinalizer(), [
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":48}}"#,
            #"{"type":"message_stop","message":{"stop_reason":"end_turn"}}"#,
        ])
    }

    func test_finalizer_ollama_doneFlag() {
        assertFinalizerEquivalent(OllamaDoneFlagFinalizer(), [
            #"{"message":{"content":"x"},"done":false}"#,
            #"{"done":true,"done_reason":"stop","prompt_eval_count":25,"eval_count":100}"#,
        ])
    }

    func test_finalizer_responses_envelopeTerminalAndIntermediate() {
        let finalizer = OpenAIResponsesEventFinalizer()
        // Intermediate event with the wrapper must NOT terminate even if it
        // embeds a response object.
        let intermediate = envelope("response.output_item.added", #"{"response":{"usage":{"input_tokens":1,"output_tokens":2}}}"#)
        let terminal = envelope("response.completed", #"{"response":{"status":"completed","usage":{"input_tokens":12,"output_tokens":8}}}"#)
        assertFinalizerEquivalent(finalizer, [intermediate, terminal])
    }

    // MARK: - Helpers

    /// Encodes a NamedSSETransport envelope the way the transport does at
    /// runtime (`{"__event":..,"__data":"<json string>"}`).
    private func envelope(_ name: String, _ data: String) -> String {
        let obj: [String: Any] = [
            NamedSSETransport.eventNameKey: name,
            NamedSSETransport.eventDataKey: data,
        ]
        let bytes = try! JSONSerialization.data(withJSONObject: obj)
        return String(data: bytes, encoding: .utf8)!
    }
}
