#if CloudSaaS
import XCTest
import ManifoldTestSupport
@testable import ManifoldBackends
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

/// Asserts that ``ClaudePayloadHandler/extractEvents(from:)``
/// preserves the `thinking_delta` and `text_delta` event surface that the
/// migration from individual `parseToken` / `parseThinkingDelta` calls is
/// supposed to keep intact.
///
/// Closes the per-handler half of #604 (Claude reasoning event preservation).
final class ClaudePayloadHandlerTests: XCTestCase {

    private let handler: CloudPayloadHandler = .claude

    // MARK: - thinking_delta classification

    func test_extractEvents_thinkingDelta_emitsThinkingToken() {
        let payload = """
        {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Let me think..."}}
        """

        let events = handler.extractEvents(from: payload)

        XCTAssertEqual(events.count, 1)
        guard case .thinkingToken(let text) = events.first else {
            return XCTFail("Expected .thinkingToken; got \(String(describing: events.first))")
        }
        XCTAssertEqual(text, "Let me think...")
    }

    func test_extractEvents_textDelta_emitsToken() {
        let payload = """
        {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hello"}}
        """

        let events = handler.extractEvents(from: payload)

        XCTAssertEqual(events.count, 1)
        guard case .token(let text) = events.first else {
            return XCTFail("Expected .token; got \(String(describing: events.first))")
        }
        XCTAssertEqual(text, "Hello")
    }

    // MARK: - Realistic captured-stream sequence

    /// Synthesised from Anthropic's documented extended-thinking shape.
    /// Preserves the order: thinking_delta(s) → text_delta(s) → message_stop.
    private static let claudeThinkingSSE = #"""
    data: {"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","content":[],"model":"claude-sonnet-4-20250514","usage":{"input_tokens":10,"output_tokens":0}}}

    data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking"}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Considering "}}

    data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"the question"}}

    data: {"type":"content_block_stop","index":0}

    data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

    data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"42"}}

    data: {"type":"content_block_stop","index":1}

    data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":3}}

    data: {"type":"message_stop"}

    """#

    func test_realFixture_emitsThinkingThenTokenInOrder() async throws {
        let bytes = ByteSequenceForClaudeTests(data: Data(Self.claudeThinkingSSE.utf8))
        let parsed = SSEStreamParser.parse(bytes: bytes)

        var collected: [GenerationEvent] = []
        for try await payload in parsed {
            collected.append(contentsOf: handler.extractEvents(from: payload))
        }

        // Expect: 2 thinking tokens, then 1 visible token.
        // Anthropic's `content_block_start`/`stop` and message_* shapes return
        // [] from the handler; that's expected — they're handled inline by
        // the backend's stateful parser.
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

    func test_extractEvents_missingType_returnsEmpty() {
        // Missing the `type` field that the classifier keys on.
        let payload = #"{"index":0,"delta":{"type":"text_delta","text":"x"}}"#
        XCTAssertTrue(handler.extractEvents(from: payload).isEmpty)
    }

    func test_extractEvents_truncatedJSON_returnsEmpty() {
        // The byte loop hands us a truncated `data:` line on a malformed
        // upstream. The handler must silently degrade — not throw, not
        // produce a partial token.
        let payload = #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text"#
        XCTAssertTrue(handler.extractEvents(from: payload).isEmpty)
    }

    func test_extractEvents_signatureDelta_returnsEmpty() {
        // Signature deltas are routed inline by the backend (they need a
        // separate `.thinkingSignature` event), so the handler ignores them.
        let payload = #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#
        XCTAssertTrue(handler.extractEvents(from: payload).isEmpty)
    }
}

// Local AsyncSequence helper (mirrors `ByteSequence` in
// SSEPayloadReplayTests) so this test file stays self-contained — XCTest
// doesn't share helper structs across files in the same target without
// import gymnastics.
struct ByteSequenceForClaudeTests: AsyncSequence {
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
