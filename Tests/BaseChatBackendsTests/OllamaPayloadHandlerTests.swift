#if Ollama
import XCTest
import BaseChatTestSupport
@testable import BaseChatBackends
@testable import BaseChatCloud
@testable import BaseChatInference

/// Asserts that ``OllamaBackend/OllamaPayloadHandler/extractEvents(from:)``
/// classifies the per-line NDJSON `thinking` and `content` fields into the
/// matching ``GenerationEvent`` cases. The byte-loop in
/// ``OllamaBackend/parseResponseStream(bytes:config:continuation:)`` keeps
/// the per-stream state (caps, fallback `<think>` parser, tool accumulator);
/// this handler is the per-payload classifier the migration centralises.
///
/// Closes the per-handler half of #606 (Ollama thinking event preservation).
final class OllamaPayloadHandlerTests: XCTestCase {

    private let handler = OllamaBackend.OllamaPayloadHandler()

    // MARK: - Single-field classification

    func test_extractEvents_contentOnly_emitsToken() {
        let line = #"{"model":"llama3.2","message":{"role":"assistant","content":"Hello"},"done":false}"#
        let events = handler.extractEvents(from: line)
        XCTAssertEqual(events.count, 1)
        guard case .token(let text) = events.first else {
            return XCTFail("Expected .token; got \(String(describing: events.first))")
        }
        XCTAssertEqual(text, "Hello")
    }

    func test_extractEvents_thinkingOnly_emitsThinkingToken() {
        let line = #"{"model":"qwen3:4b","message":{"role":"assistant","thinking":"reasoning..."},"done":false}"#
        let events = handler.extractEvents(from: line)
        XCTAssertEqual(events.count, 1)
        guard case .thinkingToken(let text) = events.first else {
            return XCTFail("Expected .thinkingToken; got \(String(describing: events.first))")
        }
        XCTAssertEqual(text, "reasoning...")
    }

    func test_extractEvents_thinkingThenContent_emitsBothInOrder() {
        // Some Ollama servers ship a single line that carries both fields
        // (e.g. an end-of-thinking line where reasoning closes and the first
        // visible token starts on the same record). The handler must surface
        // both in wire order: thinking first, then content.
        let line = #"{"message":{"role":"assistant","thinking":"done.","content":"42"},"done":false}"#
        let events = handler.extractEvents(from: line)
        XCTAssertEqual(events.count, 2)
        guard case .thinkingToken(let t) = events[0],
              case .token(let c) = events[1] else {
            return XCTFail("Unexpected event sequence: \(events)")
        }
        XCTAssertEqual(t, "done.")
        XCTAssertEqual(c, "42")
    }

    func test_extractEvents_topLevelGenerateShape_emitsToken() {
        // `/api/generate` (non-chat) shape: top-level `response` and
        // top-level `thinking`. Same handler must normalise both.
        let line = #"{"model":"qwen3:4b","response":"hi","thinking":"think","done":false}"#
        let events = handler.extractEvents(from: line)
        XCTAssertEqual(events.count, 2)
        guard case .thinkingToken = events[0],
              case .token = events[1] else {
            return XCTFail("Unexpected event sequence: \(events)")
        }
    }

    // MARK: - Done-line and usage

    func test_extractEvents_doneLineWithEmptyContent_returnsEmpty() {
        let line = #"{"done":true,"eval_count":12,"prompt_eval_count":10}"#
        XCTAssertTrue(handler.extractEvents(from: line).isEmpty)
    }

    func test_extractUsage_doneLine_returnsCounts() {
        let line = #"{"done":true,"eval_count":12,"prompt_eval_count":10}"#
        let usage = handler.extractUsage(from: line)
        XCTAssertEqual(usage?.promptTokens, 10)
        XCTAssertEqual(usage?.completionTokens, 12)
    }

    func test_extractUsage_runningLine_returnsNil() {
        // Running content lines must not pollute the consumer's "final
        // usage only" expectation.
        let line = #"{"message":{"content":"hello"},"done":false}"#
        XCTAssertNil(handler.extractUsage(from: line))
    }

    // MARK: - Realistic captured-stream sequence

    private static let ollamaThinkingNDJSON = """
    {"model":"qwen3:4b","message":{"role":"assistant","thinking":"Let me "},"done":false}
    {"model":"qwen3:4b","message":{"role":"assistant","thinking":"think"},"done":false}
    {"model":"qwen3:4b","message":{"role":"assistant","content":"42"},"done":false}
    {"model":"qwen3:4b","message":{"role":"assistant","content":""},"done":true,"eval_count":3,"prompt_eval_count":10}
    """

    func test_realFixture_emitsThinkingThenTokenInOrder() {
        let lines = Self.ollamaThinkingNDJSON.split(separator: "\n", omittingEmptySubsequences: true)

        var collected: [GenerationEvent] = []
        var usages: [(promptTokens: Int?, completionTokens: Int?)] = []
        for line in lines {
            collected.append(contentsOf: handler.extractEvents(from: String(line)))
            if let u = handler.extractUsage(from: String(line)) {
                usages.append(u)
            }
        }

        XCTAssertEqual(collected.count, 3, "events: \(collected)")
        guard case .thinkingToken(let t1) = collected[0],
              case .thinkingToken(let t2) = collected[1],
              case .token(let visible) = collected[2] else {
            return XCTFail("Unexpected event sequence: \(collected)")
        }
        XCTAssertEqual(t1, "Let me ")
        XCTAssertEqual(t2, "think")
        XCTAssertEqual(visible, "42")

        XCTAssertEqual(usages.count, 1)
        XCTAssertEqual(usages.first?.promptTokens, 10)
        XCTAssertEqual(usages.first?.completionTokens, 3)
    }

    // MARK: - Malformed-frame defence

    func test_extractEvents_invalidJSON_returnsEmpty() {
        // The deleted byte-loop swallowed unparseable JSON lines silently;
        // the new path must do the same.
        XCTAssertTrue(handler.extractEvents(from: "not json").isEmpty)
        XCTAssertTrue(handler.extractEvents(from: "").isEmpty)
        XCTAssertTrue(handler.extractEvents(from: "{").isEmpty)
    }

    func test_extractEvents_invalidUTF8MidLine_returnsEmpty() {
        // UTF-8 round-trip happens at the byte-loop boundary, but a
        // payload containing a lone `` (valid UTF-8 but malformed
        // JSON when not escaped) must still degrade gracefully.
        let data = Data([0x7B, 0x80, 0x7D]) // `{` <invalid> `}`
        guard let payload = String(data: data, encoding: .isoLatin1) else {
            return // unreachable — Latin-1 is total
        }
        XCTAssertTrue(handler.extractEvents(from: payload).isEmpty)
    }
}
#endif
