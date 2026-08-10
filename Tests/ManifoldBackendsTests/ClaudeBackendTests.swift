import XCTest
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldBackendTestKit
import ManifoldTestSupport
@testable import ManifoldFoundation
// v0.48 product split: internal symbols moved into the family targets and
// ManifoldCloudCore; the ManifoldCloud shim only re-exports public surface.
@testable import ManifoldOllama
@testable import ManifoldCloudSaaS
@testable import ManifoldCloudCore

/// Tests for ClaudeBackend configuration, state, and capabilities.
///
/// `test_configure_keychainPath_loadModelSucceeds` writes to the Keychain via
/// `KeychainService.store`. Per KeychainNamespaceIsolationAuditTest (#2416),
/// that means this class must scope `ManifoldConfiguration.shared` in
/// `setUp` even though `ManifoldBackendsTests` currently gets its own
/// `swift test --parallel` invocation separate from the batch that produced
/// #2416 — an unscoped default-namespace writer is a latent risk under any
/// future re-shuffle of suite batching, not just the one already observed.
final class ClaudeBackendTests: XCTestCase {

    private var originalConfig: ManifoldConfiguration!

    override func setUp() {
        super.setUp()
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
        originalConfig = ManifoldConfiguration.shared
        var config = ManifoldConfiguration.shared
        config.bundleIdentifier = "com.manifoldkit.tests.claudebackend.\(UUID().uuidString)"
        ManifoldConfiguration.shared = config
    }

    override func tearDown() {
        DNSRebindingGuard._resolverForTesting = nil
        ManifoldConfiguration.shared = originalConfig
        originalConfig = nil
        super.tearDown()
    }

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

    /// Anthropic's Messages API accepts `top_k`; the backend advertises it so
    /// the UI/gates don't grey out the control. Pairs with the request-encoding
    /// tests below.
    func test_capabilities_supportsTopK() {
        let backend = ClaudeBackend()
        XCTAssertTrue(backend.capabilities.supportedParameters.contains(.topK))
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

    // removed: receiver protocol retired in #2312 — history now threads via hints

    func test_conformsToTokenUsageProvider() {
        let backend = ClaudeBackend()
        XCTAssertTrue(backend is TokenUsageProvider,
                      "ClaudeBackend should conform to TokenUsageProvider")
    }

    // removed: receiver protocol retired in #2312 — history now threads via hints

    func test_lastUsage_nilByDefault() {
        let backend = ClaudeBackend()
        XCTAssertNil(backend.lastUsage, "lastUsage should be nil before any generation")
    }

    func test_castAsProtocols_succeeds() {
        let backend: any InferenceBackend = ClaudeBackend()
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

        let chunk = Data("""
            data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"ok"}}\n\ndata: {"type":"message_stop"}\n\n
            """.utf8)
        MockURLProtocol.stub(url: url, response: .sse(chunks: [chunk], statusCode: 200))
        defer { MockURLProtocol.unstub(url: url) }

        let stream = try backend.generate(
            prompt: "And 3+3?",
            systemPrompt: nil,
            config: GenerationConfig(),
            hints: GenerationRuntimeHints(history: [
                StructuredMessage(role: "user", content: "What is 2+2?"),
                StructuredMessage(role: "assistant", content: "4"),
            ])
        )
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

        // When hints.history is set, its messages are used directly as the request body.
        // Claude's structured encoder gives user turns plain string content and
        // assistant turns a `content[]` block array (so thinking/tool blocks can
        // ride along) — the shape production has always emitted, since the engine
        // always drove Claude through the structured encoder.
        XCTAssertGreaterThanOrEqual(messages.count, 2, "History messages must be included in request")
        XCTAssertEqual(messages[0]["content"] as? String, "What is 2+2?")
        let assistantContent = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantContent.first?["type"] as? String, "text")
        XCTAssertEqual(assistantContent.first?["text"] as? String, "4")
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
    // anthropic-ratelimit-tokens-reset is not plumbed through; only Retry-After is surfaced. Documents the current gap.
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

    /// `top_k` rides on the request body only when the caller set it.
    ///
    /// Sabotage check: remove the `if let topK = config.topK` block in
    /// `ClaudeBackend.buildRequest`; the positive assertion below fails.
    func test_topK_set_includesTopKInRequest() async throws {
        let json = try await captureRequestJSON { cfg in
            cfg.topK = 40
        }
        XCTAssertEqual(json["top_k"] as? Int, 40,
            "config.topK must serialise to Anthropic's `top_k`")
    }

    /// `top_k` is omitted entirely when unset — Anthropic then uses its own
    /// default rather than receiving a bogus 0.
    func test_topK_unset_omitsTopKFromRequest() async throws {
        let json = try await captureRequestJSON { cfg in
            cfg.topK = nil
        }
        XCTAssertNil(json["top_k"],
            "unset config.topK must not send a `top_k` field")
    }
}

// MARK: - Backend Contract

extension ClaudeBackendTests {
    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants { ClaudeBackend() }
    }
}

// MARK: - HTTP 529 providerOverloaded

extension ClaudeBackendTests {

    /// Claude returns HTTP 529 when it is temporarily at capacity.
    /// The backend must route this to `.providerOverloaded` — not the
    /// generic `serverError` bucket — so callers can apply purpose-built
    /// backoff rather than treating it as an opaque 5xx.
    func test_529_throwsProviderOverloaded() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let backend = ClaudeBackend(urlSession: session)
        // Disable retries so the error surfaces immediately.
        backend.retryStrategy = ExponentialBackoffStrategy(maxRetries: 0)
        let url = URL(string: "https://claude-529-\(UUID().uuidString).test")!
        backend.configure(baseURL: url, apiKey: "sk-ant-test", modelName: "claude-sonnet-4-20250514")
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        MockURLProtocol.stub(url: url, response: .immediate(data: Data(), statusCode: 529))
        defer { MockURLProtocol.unstub(url: url) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
        do {
            for try await _ in stream.events {}
            XCTFail("Expected providerOverloaded error for HTTP 529")
        } catch {
            guard let cloudError = extractCloudError(error) else {
                XCTFail("Expected CloudBackendError, got \(error)")
                return
            }
            if case .providerOverloaded(let provider, _) = cloudError {
                XCTAssertEqual(provider, "Claude",
                               "529 must surface as providerOverloaded with provider='Claude'")
            } else {
                XCTFail("Expected .providerOverloaded for HTTP 529, got \(cloudError)")
            }
        }
    }

    /// Sabotage check: a 503 must NOT become providerOverloaded — it must remain
    /// the generic serverError so 529 routing stays narrow.
    func test_503_doesNotThrowProviderOverloaded() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let backend = ClaudeBackend(urlSession: session)
        backend.retryStrategy = ExponentialBackoffStrategy(maxRetries: 0)
        let url = URL(string: "https://claude-503-\(UUID().uuidString).test")!
        backend.configure(baseURL: url, apiKey: "sk-ant-test", modelName: "claude-sonnet-4-20250514")
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        MockURLProtocol.stub(url: url, response: .immediate(
            data: Data(#"{"error":{"message":"service unavailable"}}"#.utf8),
            statusCode: 503
        ))
        defer { MockURLProtocol.unstub(url: url) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
        do {
            for try await _ in stream.events {}
            XCTFail("Expected serverError for HTTP 503")
        } catch {
            guard let cloudError = extractCloudError(error) else {
                XCTFail("Expected CloudBackendError, got \(error)")
                return
            }
            if case .providerOverloaded = cloudError {
                XCTFail("503 must not surface as providerOverloaded — that path is reserved for 529")
            } else if case .serverError(let code, _) = cloudError {
                XCTAssertEqual(code, 503)
            }
            // Any non-providerOverloaded error is acceptable — the important
            // thing is that 503 is not mis-classified as providerOverloaded.
        }
    }

    /// A non-ASCII (multi-byte UTF-8) upstream error message must survive the
    /// error-body read intact and reach the surfaced `serverError` message.
    ///
    /// Regression for the per-byte `Character(UnicodeScalar(byte))` read, which
    /// decoded each UTF-8 byte as an independent Latin-1 scalar and turned any
    /// multi-byte sequence into mojibake before sanitization ever saw it.
    ///
    /// Sabotage check: revert `readErrorBody` to the per-byte
    /// `body.append(Character(UnicodeScalar(byte)))` accumulation. The é/中文/🚫
    /// glyphs come back as mojibake and the substring assertions fail.
    func test_serverError_nonASCIIBody_roundTripsAsUTF8() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let backend = ClaudeBackend(urlSession: session)
        backend.retryStrategy = ExponentialBackoffStrategy(maxRetries: 0)
        let url = URL(string: "https://claude-utf8-\(UUID().uuidString).test")!
        backend.configure(baseURL: url, apiKey: "sk-ant-test", modelName: "claude-sonnet-4-20250514")
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        // Mix 2-byte (é), 3-byte (中文), and 4-byte (🚫) UTF-8 sequences.
        let upstreamMessage = "Réseau indisponible 中文 🚫"
        let body = Data(#"{"type":"error","error":{"type":"api_error","message":"\#(upstreamMessage)"}}"#.utf8)
        MockURLProtocol.stub(url: url, response: .immediate(data: body, statusCode: 500))
        defer { MockURLProtocol.unstub(url: url) }

        let stream = try backend.generate(prompt: "hi", systemPrompt: nil, config: GenerationConfig())
        do {
            for try await _ in stream.events {}
            XCTFail("Expected serverError for HTTP 500")
        } catch {
            guard let cloudError = extractCloudError(error) else {
                XCTFail("Expected CloudBackendError, got \(error)")
                return
            }
            guard case .serverError(let code, let message) = cloudError else {
                XCTFail("Expected .serverError, got \(cloudError)")
                return
            }
            XCTAssertEqual(code, 500)
            let surfaced = try XCTUnwrap(message, "serverError must carry the upstream message")
            XCTAssertTrue(surfaced.contains("Réseau"),
                          "2-byte UTF-8 (é) must survive the error-body read; got: \(surfaced)")
            XCTAssertTrue(surfaced.contains("中文"),
                          "3-byte UTF-8 must survive the error-body read; got: \(surfaced)")
            XCTAssertTrue(surfaced.contains("🚫"),
                          "4-byte UTF-8 must survive the error-body read; got: \(surfaced)")
        }
    }
}

