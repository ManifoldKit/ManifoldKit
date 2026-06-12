#if CloudSaaS
import XCTest
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
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference

// MARK: - Byte Sequence Helper

/// Converts a raw string into an `AsyncSequence` of `UInt8` for feeding into SSEStreamParser.
struct ByteSequence: AsyncSequence {
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

// MARK: - SSE Payload Replay Tests

final class SSEPayloadReplayTests: XCTestCase {

    // MARK: - Helpers

    /// Collects all payloads from an SSE byte stream via SSEStreamParser.parse.
    private func collectPayloads(from sseText: String) async throws -> [String] {
        let bytes = ByteSequence(data: Data(sseText.utf8))
        let stream = SSEStreamParser.parse(bytes: bytes)
        var payloads: [String] = []
        for try await payload in stream {
            payloads.append(payload)
        }
        return payloads
    }

    // MARK: - Claude API Tests

    func test_claude_realStreamingResponse_extractsTokens() async throws {
        let sseText = """
        data: {"type":"message_start","message":{"id":"msg_123","type":"message","role":"assistant","content":[],"model":"claude-sonnet-4-20250514","usage":{"input_tokens":25,"output_tokens":0}}}

        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" world"}}

        data: {"type":"content_block_stop","index":0}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":12}}

        data: {"type":"message_stop"}

        """

        let payloads = try await collectPayloads(from: sseText)

        // Extract tokens using the Claude payload handler
        let handler: CloudPayloadHandler = .claude
        let tokens = payloads.compactMap { handler.extractToken(from: $0) }
        XCTAssertEqual(tokens, ["Hello", " world"])

        // Verify usage extraction: message_start has input_tokens
        let messageStartPayload = payloads.first {
            $0.contains("\"type\":\"message_start\"")
        }
        XCTAssertNotNil(messageStartPayload)
        let startUsage = handler.extractUsage(from: messageStartPayload!)
        XCTAssertNotNil(startUsage)
        XCTAssertEqual(startUsage?.promptTokens, 25)
        XCTAssertNil(startUsage?.completionTokens)

        // Verify usage extraction: message_delta has output_tokens
        let messageDeltaPayload = payloads.first {
            $0.contains("\"type\":\"message_delta\"")
        }
        XCTAssertNotNil(messageDeltaPayload)
        let deltaUsage = handler.extractUsage(from: messageDeltaPayload!)
        XCTAssertNotNil(deltaUsage)
        XCTAssertNil(deltaUsage?.promptTokens)
        XCTAssertEqual(deltaUsage?.completionTokens, 12)

        // Verify isStreamEnd returns true for message_stop
        let messageStopPayload = payloads.first {
            $0.contains("\"type\":\"message_stop\"")
        }
        XCTAssertNotNil(messageStopPayload)
        XCTAssertTrue(handler.isStreamEnd(messageStopPayload!))

        // Verify isStreamEnd returns false for non-stop events
        XCTAssertFalse(handler.isStreamEnd(messageStartPayload!))
    }

    func test_claude_errorEvent_extractsError() async throws {
        let sseText = """
        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}

        """

        let payloads = try await collectPayloads(from: sseText)
        XCTAssertEqual(payloads.count, 1)

        let handler: CloudPayloadHandler = .claude
        let error = handler.extractStreamError(from: payloads[0])
        XCTAssertNotNil(error)

        // Verify it is a CloudBackendError.parseError with the right message
        if let cloudError = error as? CloudBackendError {
            XCTAssertEqual(
                cloudError.errorDescription,
                CloudBackendError.parseError("Overloaded").errorDescription
            )
        } else {
            XCTFail("Expected CloudBackendError, got \(type(of: error!))")
        }
    }

    func test_claude_usageAccumulation_acrossEvents() async throws {
        let sseText = """
        data: {"type":"message_start","message":{"id":"msg_456","type":"message","role":"assistant","content":[],"model":"claude-sonnet-4-20250514","usage":{"input_tokens":42,"output_tokens":0}}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7}}

        data: {"type":"message_stop"}

        """

        let payloads = try await collectPayloads(from: sseText)
        let handler: CloudPayloadHandler = .claude

        // Accumulate usage across events the way the backend does
        var promptTokens: Int?
        var completionTokens: Int?

        for payload in payloads {
            if let usage = handler.extractUsage(from: payload) {
                if let pt = usage.promptTokens { promptTokens = pt }
                if let ct = usage.completionTokens { completionTokens = ct }
            }
        }

        // prompt tokens arrive in message_start, completion tokens in message_delta
        XCTAssertEqual(promptTokens, 42)
        XCTAssertEqual(completionTokens, 7)
    }

    // MARK: - OpenAI API Tests

    func test_openai_realStreamingResponse_parsesTokens() async throws {
        let sseText = """
        data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

        data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}

        data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"content":" world"},"finish_reason":null}]}

        data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}

        data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o-mini","choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5,"total_tokens":15}}

        data: [DONE]

        """

        let payloads = try await collectPayloads(from: sseText)

        // [DONE] should terminate the stream, so it should not appear as a payload
        XCTAssertFalse(payloads.contains("[DONE]"))

        // Manually parse each payload to verify token extraction matches real format
        var tokens: [String] = []
        for payload in payloads {
            guard let data = payload.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = parsed["choices"] as? [[String: Any]],
                  let firstChoice = choices.first,
                  let delta = firstChoice["delta"] as? [String: Any],
                  let content = delta["content"] as? String,
                  !content.isEmpty else {
                continue
            }
            tokens.append(content)
        }
        XCTAssertEqual(tokens, ["Hello", " world"])

        // Verify usage in the final chunk before [DONE]
        let usagePayload = payloads.first { payload in
            guard let data = payload.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let usage = parsed["usage"] as? [String: Any],
                  usage["prompt_tokens"] != nil else {
                return false
            }
            return true
        }
        XCTAssertNotNil(usagePayload)

        // Parse usage values
        let usageData = usagePayload!.data(using: .utf8)!
        let usageParsed = try JSONSerialization.jsonObject(with: usageData) as! [String: Any]
        let usage = usageParsed["usage"] as! [String: Any]
        XCTAssertEqual(usage["prompt_tokens"] as? Int, 10)
        XCTAssertEqual(usage["completion_tokens"] as? Int, 5)
        XCTAssertEqual(usage["total_tokens"] as? Int, 15)
    }

    func test_openai_emptyDelta_skipsGracefully() async throws {
        let sseText = """
        data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}

        data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{},"finish_reason":null}]}

        data: {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"gpt-4o-mini","choices":[{"index":0,"delta":{"content":"OK"},"finish_reason":null}]}

        data: [DONE]

        """

        let payloads = try await collectPayloads(from: sseText)
        let handler = OpenAIBackend.payloadHandler

        let tokens = payloads.compactMap { handler.extractToken(from: $0) }

        // Empty content "" and missing content key should not yield tokens;
        // only "OK" should come through.
        // Note: extractToken returns "" for the first chunk (empty string content),
        // which is still a valid String return. Filter to non-empty for meaningful tokens.
        let meaningfulTokens = tokens.filter { !$0.isEmpty }
        XCTAssertEqual(meaningfulTokens, ["OK"])
    }

    // MARK: - Edge Case Tests

    func test_malformedJSON_doesNotCrash() async throws {
        let sseText = """
        data: {"valid": true}
        data: {invalid json
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}

        """

        let payloads = try await collectPayloads(from: sseText)

        // All three data lines should be yielded by the parser (it doesn't validate JSON)
        XCTAssertEqual(payloads.count, 3)

        // Claude's extractToken should return nil for malformed/irrelevant JSON and
        // a valid token for the content_block_delta
        let handler: CloudPayloadHandler = .claude
        let tokens = payloads.compactMap { handler.extractToken(from: $0) }
        XCTAssertEqual(tokens, ["ok"])

        // extractToken should return nil (not crash) for malformed JSON
        XCTAssertNil(handler.extractToken(from: "{invalid json"))
        XCTAssertNil(handler.extractUsage(from: "{invalid json"))
        XCTAssertFalse(handler.isStreamEnd("{invalid json"))
        XCTAssertNil(handler.extractStreamError(from: "{invalid json"))
    }

    func test_multilineSSE_handlesCorrectly() async throws {
        // Multiple blank lines between events should not cause issues
        let sseText = """
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"A"}}



        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"B"}}




        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"C"}}

        """

        let payloads = try await collectPayloads(from: sseText)
        let handler: CloudPayloadHandler = .claude
        let tokens = payloads.compactMap { handler.extractToken(from: $0) }
        XCTAssertEqual(tokens, ["A", "B", "C"])
    }

    // MARK: - Claude citations_delta (currently unsupported)

    // Claude citations_delta is not currently surfaced as a GenerationEvent — no
    // citation case exists in the cloud event model. This documents the gap;
    // update if/when citation surfacing lands.
    func test_claude_citationsDelta_currentlyUnsupported() async throws {
        let sseText = """
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Einstein said "}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"citations_delta","citation":{"type":"char_location","cited_text":"E=mc^2","document_index":0,"document_title":"Relativity"}}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"E=mc^2."}}

        """

        let payloads = try await collectPayloads(from: sseText)
        let handler: CloudPayloadHandler = .claude
        let tokens = payloads.compactMap { handler.extractToken(from: $0) }

        // Today: citation delta drops cleanly, text_deltas flow through in order.
        XCTAssertEqual(tokens, ["Einstein said ", "E=mc^2."],
                       "citations_delta must not interleave into the token stream")

        // Citation payload exists but yields nothing.
        let citationPayload = payloads.first { $0.contains("citations_delta") }
        XCTAssertNotNil(citationPayload)
        XCTAssertNil(handler.extractToken(from: citationPayload!),
                     "citations_delta must not leak into the token stream today")
    }

    // MARK: - Claude stop_reason variants (currently parse usage only)

    // GenerationEvent has no stopReason case, so Claude stop_reason variants
    // (refusal/max_tokens/stop_sequence) are not surfaced — only usage is parsed.
    // This documents the current gap.
    func test_claude_stopReasonVariants_currentlyParseUsageOnly() async throws {
        let sseText = """
        data: {"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{"output_tokens":3}}

        data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":8192}}

        data: {"type":"message_delta","delta":{"stop_reason":"stop_sequence","stop_sequence":"\\n\\nHuman:"},"usage":{"output_tokens":14}}

        """

        let payloads = try await collectPayloads(from: sseText)
        let handler: CloudPayloadHandler = .claude

        // No tokens produced from any of the three message_delta events.
        let tokens = payloads.compactMap { handler.extractToken(from: $0) }
        XCTAssertEqual(tokens, [], "stop_reason variants must not leak into the token stream")

        // But usage should extract cleanly for each variant.
        let completionTokens = payloads.compactMap { handler.extractUsage(from: $0)?.completionTokens }
        XCTAssertEqual(completionTokens, [3, 8192, 14],
                       "Every variant must still surface completion token usage")

        // None of these events is a stream terminator (no message_stop here).
        for payload in payloads {
            XCTAssertFalse(handler.isStreamEnd(payload),
                           "message_delta must not be treated as stream end: \(payload)")
        }
    }

    // MARK: - Existing tests

    func test_unicodeInTokens_preservedCorrectly() async throws {
        let sseText = """
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello \\ud83d\\ude00"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" caf\\u00e9"}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" \\u4f60\\u597d"}}

        """

        let payloads = try await collectPayloads(from: sseText)
        let handler: CloudPayloadHandler = .claude
        let tokens = payloads.compactMap { handler.extractToken(from: $0) }

        XCTAssertEqual(tokens.count, 3)
        XCTAssertEqual(tokens[0], "Hello \u{1F600}")  // emoji
        XCTAssertEqual(tokens[1], " caf\u{00E9}")     // accented character
        XCTAssertEqual(tokens[2], " \u{4F60}\u{597D}") // Chinese characters (你好)
    }
}
#endif
