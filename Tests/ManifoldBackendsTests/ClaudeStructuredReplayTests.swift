#if CloudSaaS
import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldBackends
@testable import ManifoldCloud

/// Tests for #604: structured multi-turn replay against the Anthropic
/// Messages API. ``ClaudeBackend`` must:
///
/// 1. Read the structured history when one is supplied
///    (``StructuredHistoryReceiver``), prefer it over the flattened
///    `(role, content)` form.
/// 2. Serialize prior assistant turns as a `content[]` array with thinking
///    blocks **before** text blocks, signature carried verbatim.
/// 3. Drop signature-less thinking blocks from the replay payload (sending
///    a blank signature would 400 the request).
final class ClaudeStructuredReplayTests: XCTestCase {

    // MARK: - Helpers

    private func makeBackend() async throws -> (ClaudeBackend, URL) {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let backend = ClaudeBackend(urlSession: session)
        let url = URL(string: "https://claude-structured-\(UUID().uuidString).test")!
        backend.configure(baseURL: url, apiKey: "sk-ant-test", modelName: "claude-sonnet-4-5")
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        return (backend, url)
    }

    private func extractRequestJSON(host: String?) throws -> [String: Any] {
        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url?.host == host })
        let body: Data
        if let direct = captured?.httpBody {
            body = direct
        } else if let stream = captured?.httpBodyStream {
            var data = Data()
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 4096)
                if read > 0 { data.append(buffer, count: read) }
            }
            stream.close()
            body = data
        } else {
            throw NSError(domain: "test", code: 0, userInfo: [NSLocalizedDescriptionKey: "no body"])
        }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func sseStub(url: URL) {
        let chunk = Data("""
            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"}}\n\ndata: {"type":"message_stop"}\n\n
            """.utf8)
        MockURLProtocol.stub(url: url, response: .sse(chunks: [chunk], statusCode: 200))
    }

    // MARK: - 1. Structured history with thinking + signature

    /// Multi-turn conversation where the prior assistant turn has a
    /// thinking block with a signature plus visible text. The request body
    /// must serialize that turn as a structured `content[]` with thinking
    /// **before** text and the signature preserved verbatim.
    func test_buildRequest_priorAssistantTurnWithThinking_emitsStructuredContent() async throws {
        let (backend, url) = try await makeBackend()
        sseStub(url: url)
        defer { MockURLProtocol.unstub(url: url) }

        let signature = "sig_abc123_xyz_load_bearing"
        backend.setStructuredHistory([
            StructuredMessage(role: "user", content: "What is 2+2?"),
            StructuredMessage(role: "assistant", parts: [
                .thinking("The user is asking simple arithmetic.", signature: signature),
                .text("The answer is 4."),
            ]),
            StructuredMessage(role: "user", content: "Now what is 5+5?"),
        ])

        let stream = try backend.generate(prompt: "Now what is 5+5?", systemPrompt: nil, config: GenerationConfig())
        for try await _ in stream.events { }

        let json = try extractRequestJSON(host: url.host)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3, "All three turns must be replayed")

        // Assistant turn: structured content array, thinking first, text second.
        let assistantContent = try XCTUnwrap(messages[1]["content"] as? [[String: Any]],
            "Assistant turn with a thinking block must serialize as a structured `content[]` array, not a string")
        XCTAssertEqual(assistantContent.count, 2,
            "Expect exactly two blocks: thinking + text (no extra wrapping)")

        XCTAssertEqual(assistantContent[0]["type"] as? String, "thinking",
            "Thinking block must come first — Anthropic rejects text-then-thinking ordering")
        XCTAssertEqual(assistantContent[0]["thinking"] as? String, "The user is asking simple arithmetic.")
        XCTAssertEqual(assistantContent[0]["signature"] as? String, signature,
            "Signature must round-trip verbatim — Anthropic rejects mismatched signatures with HTTP 400")

        XCTAssertEqual(assistantContent[1]["type"] as? String, "text")
        XCTAssertEqual(assistantContent[1]["text"] as? String, "The answer is 4.")

        // Sabotage check: if `encodeMessageContent` flattened the assistant
        // turn back to a string, `messages[1]["content"]` would decode as
        // `String` and the `[[String: Any]]` cast above would fail.
    }

    // MARK: - 2. User turn flattens to string content

    func test_buildRequest_userTurn_flattensToStringContent() async throws {
        let (backend, url) = try await makeBackend()
        sseStub(url: url)
        defer { MockURLProtocol.unstub(url: url) }

        backend.setStructuredHistory([
            StructuredMessage(role: "user", content: "Hello"),
        ])
        let stream = try backend.generate(prompt: "Hello", systemPrompt: nil, config: GenerationConfig())
        for try await _ in stream.events { }

        let json = try extractRequestJSON(host: url.host)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["content"] as? String, "Hello",
            "User turns flatten to a plain string body — only assistant turns need the structured array form")
    }

    // MARK: - 3. Signature-less thinking is dropped

    /// A `.thinking` part without a signature can't be replayed verbatim
    /// (Anthropic checks the signature server-side). Rather than send a
    /// blank signature and 400 the request, the encoder drops the block.
    /// This is the path for cross-backend persistence: a thinking part
    /// captured from MLX or Llama (which don't issue signatures) round-trips
    /// the conversation without breaking the next Claude turn.
    func test_buildRequest_priorAssistantTurnWithUnsignedThinking_dropsThinkingBlock() async throws {
        let (backend, url) = try await makeBackend()
        sseStub(url: url)
        defer { MockURLProtocol.unstub(url: url) }

        backend.setStructuredHistory([
            StructuredMessage(role: "user", content: "Q1"),
            StructuredMessage(role: "assistant", parts: [
                .thinking("local-only reasoning, no signature", signature: nil),
                .text("Visible answer."),
            ]),
            StructuredMessage(role: "user", content: "Q2"),
        ])

        let stream = try backend.generate(prompt: "Q2", systemPrompt: nil, config: GenerationConfig())
        for try await _ in stream.events { }

        let json = try extractRequestJSON(host: url.host)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        let assistantContent = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantContent.count, 1,
            "Unsigned thinking blocks are dropped from the replay payload — only text remains")
        XCTAssertEqual(assistantContent[0]["type"] as? String, "text")
        XCTAssertEqual(assistantContent[0]["text"] as? String, "Visible answer.")
    }

    // MARK: - 4. Structured history takes precedence over flattened history

    func test_buildRequest_prefersStructuredHistory_overConversationHistory() async throws {
        let (backend, url) = try await makeBackend()
        sseStub(url: url)
        defer { MockURLProtocol.unstub(url: url) }

        // Set both — coordinator sets the flattened form too, but the
        // structured form must win when present.
        backend.setConversationHistory([
            (role: "user", content: "OLD"),
            (role: "assistant", content: "OLD-ANSWER"),
        ])
        backend.setStructuredHistory([
            StructuredMessage(role: "user", content: "NEW"),
            StructuredMessage(role: "assistant", content: "NEW-ANSWER"),
        ])

        let stream = try backend.generate(prompt: "ignored", systemPrompt: nil, config: GenerationConfig())
        for try await _ in stream.events { }

        let json = try extractRequestJSON(host: url.host)
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["content"] as? String, "NEW",
            "Structured history must override the legacy conversationHistory when both are set")
    }

    // MARK: - 5. Signature parsed from signature_delta SSE

    func test_parseSignatureDelta_extractsSignatureFromDelta() {
        let payload = #"{"type":"content_block_delta","delta":{"type":"signature_delta","signature":"sig_xyz"}}"#
        XCTAssertEqual(ClaudePayloadParser.parseSignatureDelta(from: payload), "sig_xyz")

        // Sabotage check: removing the type==signature_delta guard would
        // make this return non-nil for thinking_delta payloads.
        let thinkingPayload = #"{"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"...","signature":"oops"}}"#
        XCTAssertNil(ClaudePayloadParser.parseSignatureDelta(from: thinkingPayload),
            "thinking_delta is not a signature_delta — must not match")
    }

    func test_parseThinkingBlockStartSignature_extractsFromStart() {
        let payload = #"{"type":"content_block_start","content_block":{"type":"thinking","signature":"sig_start"}}"#
        XCTAssertEqual(ClaudePayloadParser.parseThinkingBlockStartSignature(from: payload), "sig_start")

        let textStart = #"{"type":"content_block_start","content_block":{"type":"text"}}"#
        XCTAssertNil(ClaudePayloadParser.parseThinkingBlockStartSignature(from: textStart))
    }

    // MARK: - 6. End-to-end: signature flows from SSE → emit ordering

    /// A thinking block's `signature_delta` event must surface as a
    /// ``GenerationEvent/thinkingSignature`` event in the parsed stream,
    /// emitted before the matching ``thinkingComplete``.
    func test_streamParse_emitsThinkingSignatureEvent() async throws {
        let (backend, url) = try await makeBackend()
        let chunks: [Data] = [
            Data(#"data: {"type":"content_block_start","content_block":{"type":"thinking"}}"#.utf8) + Data("\n\n".utf8),
            Data(#"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"reasoning"}}"#.utf8) + Data("\n\n".utf8),
            Data(#"data: {"type":"content_block_delta","delta":{"type":"signature_delta","signature":"abc"}}"#.utf8) + Data("\n\n".utf8),
            Data(#"data: {"type":"content_block_stop"}"#.utf8) + Data("\n\n".utf8),
            Data(#"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"answer"}}"#.utf8) + Data("\n\n".utf8),
            Data(#"data: {"type":"message_stop"}"#.utf8) + Data("\n\n".utf8),
        ]
        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: url) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
        var observed: [String] = []
        for try await event in stream.events {
            switch event {
            case .thinkingToken(let t): observed.append("thinkingToken:\(t)")
            case .thinkingSignature(let s): observed.append("signature:\(s)")
            case .thinkingComplete: observed.append("thinkingComplete")
            case .token(let t): observed.append("token:\(t)")
            default: break
            }
        }
        XCTAssertTrue(observed.contains("signature:abc"),
            "Stream must surface signature_delta as `.thinkingSignature` so the UI can attach it to the persisted thinking part. Observed: \(observed)")
        // Order check: the signature must arrive before thinkingComplete.
        let sigIdx = observed.firstIndex(of: "signature:abc") ?? -1
        let completeIdx = observed.firstIndex(of: "thinkingComplete") ?? -2
        XCTAssertLessThan(sigIdx, completeIdx,
            "Signature must precede thinkingComplete so the consumer has it before applying the finalize")
    }
}
#endif
