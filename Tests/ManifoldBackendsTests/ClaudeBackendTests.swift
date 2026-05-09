#if CloudSaaS
import XCTest
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldBackends
@testable import ManifoldCloud

/// Tests for ClaudeBackend configuration, state, and capabilities.
final class ClaudeBackendTests: XCTestCase {

    // MARK: - Init & State

    func test_init_defaultState() {
        let backend = ClaudeBackend()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    // MARK: - Capabilities

    func test_capabilities_supportsTemperatureAndTopP() {
        let backend = ClaudeBackend()
        let caps = backend.capabilities
        XCTAssertTrue(caps.supportedParameters.contains(.temperature))
        XCTAssertTrue(caps.supportedParameters.contains(.topP))
    }

    func test_capabilities_noRepeatPenalty() {
        let backend = ClaudeBackend()
        XCTAssertFalse(backend.capabilities.supportedParameters.contains(.repeatPenalty),
                       "Claude API does not support repeat_penalty")
    }

    func test_capabilities_highContextLimit() {
        let backend = ClaudeBackend()
        XCTAssertEqual(backend.capabilities.maxContextTokens, 200_000,
                       "Claude should support 200K context")
    }

    // MARK: - Model Lifecycle

    func test_loadModel_withoutAPIKey_throws() async {
        let backend = ClaudeBackend()
        backend.configure(
            baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: nil,
            modelName: "claude-sonnet-4-20250514"
        )

        do {
            try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
            XCTFail("Should throw missingAPIKey when no API key is configured")
        } catch {
            guard let error = extractCloudError(error) else { XCTFail("Expected CloudBackendError, got \(error)"); return }
            if case .missingAPIKey = error {
                // Expected
            } else {
                XCTFail("Expected missingAPIKey, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func test_loadModel_withAPIKey_succeeds() async throws {
        let backend = ClaudeBackend()
        backend.configure(
            baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "sk-ant-test-key",
            modelName: "claude-sonnet-4-20250514"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        XCTAssertTrue(backend.isModelLoaded)
    }

    func test_unloadModel_clearsState() async throws {
        let backend = ClaudeBackend()
        backend.configure(
            baseURL: URL(string: "https://api.anthropic.com")!,
            apiKey: "sk-ant-test-key",
            modelName: "claude-sonnet-4-20250514"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        XCTAssertTrue(backend.isModelLoaded)

        backend.unloadModel()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    func test_generate_withoutLoading_throws() {
        let backend = ClaudeBackend()
        XCTAssertThrowsError(
            try backend.generate(prompt: "hello", systemPrompt: nil, config: GenerationConfig())
        )
    }

    // MARK: - Protocol Conformance

    func test_conformsToConversationHistoryReceiver() {
        let backend = ClaudeBackend()
        XCTAssertTrue(backend is ConversationHistoryReceiver,
                      "ClaudeBackend should conform to ConversationHistoryReceiver")
    }

    func test_conformsToTokenUsageProvider() {
        let backend = ClaudeBackend()
        XCTAssertTrue(backend is TokenUsageProvider,
                      "ClaudeBackend should conform to TokenUsageProvider")
    }

    func test_setConversationHistory_storesMessages() {
        let backend = ClaudeBackend()
        let history: [(role: String, content: String)] = [
            (role: "user", content: "Hello"),
            (role: "assistant", content: "Hi there!")
        ]
        backend.setConversationHistory(history)
        XCTAssertEqual(backend.conversationHistory?.count, 2)
        XCTAssertEqual(backend.conversationHistory?[0].role, "user")
        XCTAssertEqual(backend.conversationHistory?[1].content, "Hi there!")
    }

    func test_lastUsage_nilByDefault() {
        let backend = ClaudeBackend()
        XCTAssertNil(backend.lastUsage, "lastUsage should be nil before any generation")
    }

    func test_castAsProtocols_succeeds() {
        let backend: any InferenceBackend = ClaudeBackend()
        XCTAssertNotNil(backend as? ConversationHistoryReceiver,
                        "Casting InferenceBackend to ConversationHistoryReceiver should succeed")
        XCTAssertNotNil(backend as? TokenUsageProvider,
                        "Casting InferenceBackend to TokenUsageProvider should succeed")
    }
}

// MARK: - Multi-turn History Serialisation

extension ClaudeBackendTests {

    func test_conversationHistory_includedInRequestBody() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let backend = ClaudeBackend(urlSession: session)
        let url = URL(string: "https://claude-history-\(UUID().uuidString).test")!
        backend.configure(baseURL: url, apiKey: "sk-ant-test", modelName: "claude-sonnet-4-20250514")
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        backend.setConversationHistory([
            (role: "user", content: "What is 2+2?"),
            (role: "assistant", content: "4"),
        ])

        let chunk = Data("""
            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"}}\n\ndata: {"type":"message_stop"}\n\n
            """.utf8)
        MockURLProtocol.stub(url: url, response: .sse(chunks: [chunk], statusCode: 200))
        defer { MockURLProtocol.unstub(url: url) }

        let stream = try backend.generate(prompt: "And 3+3?", systemPrompt: nil, config: GenerationConfig())
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url?.host == url.host })
        // URLSession may convert httpBody → httpBodyStream during transmission.
        let body: Data
        if let direct = captured?.httpBody {
            body = direct
        } else if let stream = captured?.httpBodyStream {
            var bodyData = Data()
            stream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: 4096)
                if read > 0 { bodyData.append(buffer, count: read) }
            }
            stream.close()
            body = bodyData
        } else {
            XCTFail("Captured request has no body")
            return
        }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])

        // When conversationHistory is set, its messages are used directly as the request body.
        XCTAssertGreaterThanOrEqual(messages.count, 2, "History messages must be included in request")
        XCTAssertEqual(messages[0]["content"] as? String, "What is 2+2?")
        XCTAssertEqual(messages[1]["content"] as? String, "4")
    }
}

// MARK: - stopGeneration() Mid-stream Cancellation

extension ClaudeBackendTests {

    func test_stopGeneration_cancelsActiveStream() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let backend = ClaudeBackend(urlSession: session)
        let url = URL(string: "https://claude-cancel-\(UUID().uuidString).test")!
        backend.configure(baseURL: url, apiKey: "sk-ant-test", modelName: "claude-sonnet-4-20250514")
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        var chunks: [Data] = (0..<20).map { i in
            Data("data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"tok\(i)\"}}\n\n".utf8)
        }
        chunks.append(Data("data: {\"type\":\"message_stop\"}\n\n".utf8))

        MockURLProtocol.stub(url: url, response: .asyncSSE(chunks: chunks, statusCode: 200))
        defer { MockURLProtocol.unstub(url: url) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())

        var tokenCount = 0
        do {
            for try await _ in stream.events {
                tokenCount += 1
                if tokenCount == 2 {
                    backend.stopGeneration()
                }
            }
        } catch {
            // Cancellation may throw — that's acceptable
        }

        XCTAssertFalse(backend.isGenerating, "isGenerating must be false after stopGeneration")
        XCTAssertLessThan(tokenCount, 20, "Stream should have been cancelled before all tokens arrived")
    }
}

// MARK: - Keychain-backed configure() path

extension ClaudeBackendTests {

    func test_configure_keychainPath_loadModelSucceeds() async throws {
        let testAccount = "ManifoldKit.test.claude.\(UUID().uuidString)"
        // Claude's loadModel validates the API key, so we must store a real value.
        try KeychainService.store(key: "sk-ant-test-keychain-key", account: testAccount)
        defer { try? KeychainService.delete(account: testAccount) }

        let backend = ClaudeBackend()
        backend.configure(
            baseURL: URL(string: "https://api.anthropic.com")!,
            keychainAccount: testAccount,
            modelName: "claude-sonnet-4-20250514"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        XCTAssertTrue(backend.isModelLoaded)
    }
}

// MARK: - Rate-limit error shape (#531)

extension ClaudeBackendTests {

    /// Pins today's 429 handling: a structured Claude rate-limit body
    /// (`{"type":"error","error":{"type":"rate_limit_error","message":"..."}}`)
    /// plus the documented `anthropic-ratelimit-*` headers surface as
    /// `CloudBackendError.rateLimited(retryAfter: 45)` from the `Retry-After`
    /// header alone.
    ///
    /// FIXME(#531): once `anthropic-ratelimit-tokens-reset` is plumbed through,
    /// flip to assert the structured reset time and the parsed error body message.
    func test_rateLimit_anthropicErrorBody_surfacesRetryAfterOnly() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let backend = ClaudeBackend(urlSession: session)

        // Disable retries so the first 429 propagates immediately, preserving
        // the retryAfter we want to assert on.
        backend.retryStrategy = ExponentialBackoffStrategy(maxRetries: 0)

        let url = URL(string: "https://claude-ratelimit-\(UUID().uuidString).test")!
        backend.configure(baseURL: url, apiKey: "sk-ant-test", modelName: "claude-sonnet-4-20250514")
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        let body = Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"Too many requests"}}"#.utf8)
        let messagesURL = url.appendingPathComponent("v1/messages")
        MockURLProtocol.stub(url: messagesURL, response: .immediate(
            data: body,
            statusCode: 429,
            headers: [
                "Retry-After": "45",
                "anthropic-ratelimit-requests-remaining": "0",
                "anthropic-ratelimit-tokens-remaining": "0",
                "anthropic-ratelimit-tokens-reset": "2026-04-19T12:34:56Z"
            ]
        ))
        defer { MockURLProtocol.unstub(url: messagesURL) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())

        do {
            for try await _ in stream.events { }
            XCTFail("Expected rateLimited error")
        } catch {
            guard let cloud = extractCloudError(error) else {
                XCTFail("Expected CloudBackendError, got \(error)")
                return
            }
            guard case .rateLimited(let retryAfter) = cloud else {
                XCTFail("Expected rateLimited, got \(cloud)")
                return
            }
            // Today: only Retry-After is honoured. The structured body and the
            // anthropic-ratelimit-* headers are discarded. Flipping this test
            // is the signal that richer parsing landed.
            XCTAssertEqual(retryAfter, 45,
                           "Retry-After header must surface as the rateLimited retryAfter value")
        }
    }
}

// MARK: - maxThinkingTokens request-body gating (#597)

extension ClaudeBackendTests {

    /// Helper: decodes the captured Claude `/v1/messages` request body into JSON.
    private func capturedMessagesBody(host: String) throws -> [String: Any] {
        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url?.host == host })
        let body: Data
        if let direct = captured?.httpBody {
            body = direct
        } else if let bodyStream = captured?.httpBodyStream {
            var bodyData = Data()
            bodyStream.open()
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            defer { buffer.deallocate() }
            while bodyStream.hasBytesAvailable {
                let read = bodyStream.read(buffer, maxLength: 4096)
                if read > 0 { bodyData.append(buffer, count: read) }
            }
            bodyStream.close()
            body = bodyData
        } else {
            XCTFail("Captured request has no body")
            return [:]
        }
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    /// Executes a one-shot generate() against a MockURLProtocol-backed Claude
    /// endpoint and returns the captured request JSON. The response is a trivial
    /// `message_stop` — we only care about the outbound body.
    private func captureRequestJSON(
        configMutator: (inout GenerationConfig) -> Void
    ) async throws -> [String: Any] {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfig)
        let backend = ClaudeBackend(urlSession: session)
        let url = URL(string: "https://claude-thinking-\(UUID().uuidString).test")!
        backend.configure(baseURL: url, apiKey: "sk-ant-test", modelName: "claude-sonnet-4-20250514")
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        let chunk = Data("data: {\"type\":\"message_stop\"}\n\n".utf8)
        MockURLProtocol.stub(url: url, response: .sse(chunks: [chunk], statusCode: 200))
        defer { MockURLProtocol.unstub(url: url) }

        var cfg = GenerationConfig()
        configMutator(&cfg)

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: cfg)
        for try await _ in stream.events { }

        return try capturedMessagesBody(host: url.host!)
    }

    /// Closes #597 (Anthropic half) — `maxThinkingTokens == 0` must omit the
    /// `thinking` request block entirely. Anthropic's API has no "budget = 0"
    /// equivalent (thinking is either enabled or not), so the only correct
    /// translation of "disable thinking" is to leave the parameter off.
    ///
    /// Sabotage check: change `budget > 0` to `budget >= 0` in
    /// `ClaudeBackend.buildRequest`. The body gains a `"thinking"` key with
    /// `budget_tokens: 0`, Anthropic rejects the request, and this test fails.
    func test_maxThinkingTokens_zero_omitsThinkingBlockFromRequest_regression597() async throws {
        let json = try await captureRequestJSON { cfg in
            cfg.maxThinkingTokens = 0
        }
        XCTAssertNil(json["thinking"],
            "maxThinkingTokens=0 must not send a `thinking` block — "
            + "Anthropic has no budget-zero equivalent and only 'enabled' is valid (#597)")
    }

    /// Companion to the zero-case test: `maxThinkingTokens == nil` must also omit
    /// the thinking block. Together these lock in "thinking is opt-in via N > 0".
    func test_maxThinkingTokens_nil_omitsThinkingBlockFromRequest() async throws {
        let json = try await captureRequestJSON { cfg in
            cfg.maxThinkingTokens = nil
        }
        XCTAssertNil(json["thinking"],
            "maxThinkingTokens=nil must not send a `thinking` block")
    }

    /// Positive control: `maxThinkingTokens = N > 0` must include the `thinking`
    /// block with `type: enabled` and a clamped `budget_tokens`.
    func test_maxThinkingTokens_positive_includesThinkingBlockInRequest() async throws {
        let json = try await captureRequestJSON { cfg in
            cfg.maxThinkingTokens = 4096
        }
        let thinking = try XCTUnwrap(json["thinking"] as? [String: Any],
            "maxThinkingTokens=N>0 must send a `thinking` block")
        XCTAssertEqual(thinking["type"] as? String, "enabled")
        XCTAssertNotNil(thinking["budget_tokens"] as? Int)
    }
}

// MARK: - Backend Contract

extension ClaudeBackendTests {
    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants { ClaudeBackend() }
    }
}

#endif
