#if CloudSaaS
import XCTest
import BaseChatTestSupport
@testable import BaseChatBackends
@testable import BaseChatCloud
@testable import BaseChatInference

/// Asserts that ``OpenAIResponsesBackend/OpenAIResponsesPayloadHandler`` and the
/// per-event-name helpers preserve the `reasoning_content` event surface the
/// migration is supposed to keep intact.
///
/// Closes the per-handler half of #605 (OpenAI Responses reasoning event
/// preservation).
final class OpenAIResponsesPayloadHandlerTests: XCTestCase {

    // MARK: - eventsForReasoningDelta

    func test_eventsForReasoningDelta_emitsThinkingToken() {
        let data = #"{"delta":"Let me think..."}"#
        let events = OpenAIResponsesBackend.eventsForReasoningDelta(data: data)
        XCTAssertEqual(events.count, 1)
        guard case .thinkingToken(let text) = events.first else {
            return XCTFail("Expected .thinkingToken; got \(String(describing: events.first))")
        }
        XCTAssertEqual(text, "Let me think...")
    }

    func test_eventsForReasoningDelta_emptyDelta_returnsEmpty() {
        let data = #"{"delta":""}"#
        XCTAssertTrue(OpenAIResponsesBackend.eventsForReasoningDelta(data: data).isEmpty)
    }

    func test_eventsForReasoningDelta_missingDelta_returnsEmpty() {
        let data = #"{"item_id":"x"}"#
        XCTAssertTrue(OpenAIResponsesBackend.eventsForReasoningDelta(data: data).isEmpty)
    }

    // MARK: - eventsForOutputTextDelta

    func test_eventsForOutputTextDelta_emitsToken() {
        let data = #"{"delta":"42"}"#
        let events = OpenAIResponsesBackend.eventsForOutputTextDelta(data: data)
        XCTAssertEqual(events.count, 1)
        guard case .token(let text) = events.first else {
            return XCTFail("Expected .token; got \(String(describing: events.first))")
        }
        XCTAssertEqual(text, "42")
    }

    // MARK: - Default handler `extractEvents`

    func test_handler_extractEvents_defaultsToToken() {
        // The handler's default classification surfaces `.token` for any
        // payload carrying a `delta`. The named-event dispatcher overrides
        // this for reasoning events via the helpers above; this asserts the
        // base behaviour (e.g. for an isolated-payload unit test or a
        // future SSE consumer that doesn't dispatch on `event:` names).
        let handler = OpenAIResponsesBackend.OpenAIResponsesPayloadHandler()
        let events = handler.extractEvents(from: #"{"delta":"x"}"#)
        XCTAssertEqual(events.count, 1)
        guard case .token = events.first else {
            return XCTFail("Expected .token; got \(String(describing: events.first))")
        }
    }

    func test_handler_extractEvents_missingDelta_returnsEmpty() {
        let handler = OpenAIResponsesBackend.OpenAIResponsesPayloadHandler()
        XCTAssertTrue(handler.extractEvents(from: #"{"foo":"bar"}"#).isEmpty)
    }

    // MARK: - Realistic captured-stream sequence

    /// Synthesised from OpenAI's documented Responses-API named-event SSE
    /// shape. Includes a reasoning summary block followed by a visible
    /// output_text delta and a `response.completed` event with usage.
    private static let openaiResponsesSSE = #"""
    event: response.output_item.added
    data: {"type":"response.output_item.added","item":{"type":"reasoning"}}

    event: response.reasoning_summary_text.delta
    data: {"delta":"Considering "}

    event: response.reasoning_summary_text.delta
    data: {"delta":"the question"}

    event: response.reasoning_summary_text.done
    data: {}

    event: response.output_text.delta
    data: {"delta":"42"}

    event: response.completed
    data: {"response":{"usage":{"input_tokens":10,"output_tokens":3}}}

    """#

    func test_realFixture_namedDispatch_emitsThinkingThenTokenInOrder() async throws {
        let bytes = ByteSequenceForOpenAITests(data: Data(Self.openaiResponsesSSE.utf8))
        let parsed = SSEStreamParser.parseNamed(bytes: bytes)

        var collected: [GenerationEvent] = []
        for try await event in parsed {
            switch event.name {
            case "response.reasoning_summary_text.delta":
                collected.append(contentsOf: OpenAIResponsesBackend.eventsForReasoningDelta(data: event.data))
            case "response.output_text.delta":
                collected.append(contentsOf: OpenAIResponsesBackend.eventsForOutputTextDelta(data: event.data))
            default:
                break
            }
        }

        XCTAssertEqual(collected.count, 3, "events: \(collected)")
        guard case .thinkingToken(let t1) = collected[0],
              case .thinkingToken(let t2) = collected[1],
              case .token(let visible) = collected[2] else {
            return XCTFail("Unexpected event sequence: \(collected)")
        }
        XCTAssertEqual(t1, "Considering ")
        XCTAssertEqual(t2, "the question")
        XCTAssertEqual(visible, "42")
    }

    // MARK: - Malformed-frame defence

    func test_eventsForReasoningDelta_truncatedJSON_returnsEmpty() {
        let data = #"{"delta":"part"#
        XCTAssertTrue(OpenAIResponsesBackend.eventsForReasoningDelta(data: data).isEmpty)
    }

    func test_eventsForOutputTextDelta_nonStringDelta_returnsEmpty() {
        // `delta` is documented as a string. An int or null is malformed
        // upstream output; the handler must skip rather than crash.
        let data = #"{"delta":42}"#
        XCTAssertTrue(OpenAIResponsesBackend.eventsForOutputTextDelta(data: data).isEmpty)
    }
}

struct ByteSequenceForOpenAITests: AsyncSequence {
    typealias Element = UInt8
    let data: Data
    struct AsyncIterator: AsyncIteratorProtocol {
        var index: Data.Index
        let data: Data
        mutating func next() async -> UInt8? {
            guard index < data.endIndex else { return nil }
            defer { index = data.index(after: index) }
            return data[index]
        }
    }
    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(index: data.startIndex, data: data)
    }
}
#endif
