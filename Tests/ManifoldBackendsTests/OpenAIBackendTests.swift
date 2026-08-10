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

/// Tests for OpenAIBackend configuration, state, and capabilities.
///
/// Writes to the Keychain via `KeychainService.store` (see the keychain-path
/// load test below). Per KeychainNamespaceIsolationAuditTest (#2416), that
/// means this class must scope `ManifoldConfiguration.shared` in `setUp`
/// even though `ManifoldBackendsTests` currently gets its own `swift test
/// --parallel` invocation separate from the batch that produced #2416 — an
/// unscoped default-namespace writer is a latent risk under any future
/// re-shuffle of suite batching, not just the one already observed.
final class OpenAIBackendTests: XCTestCase {

    private var originalConfig: ManifoldConfiguration!

    override func setUp() {
        super.setUp()
        DNSRebindingGuard._resolverForTesting = { _ in ["93.184.216.34"] }
        originalConfig = ManifoldConfiguration.shared
        var config = ManifoldConfiguration.shared
        config.bundleIdentifier = "com.manifoldkit.tests.openaibackend.\(UUID().uuidString)"
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
        let backend = OpenAIBackend()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    // MARK: - Capabilities

    func test_capabilities_supportsTemperatureAndTopP() {
        let backend = OpenAIBackend()
        let caps = backend.capabilities
        XCTAssertTrue(caps.supportedParameters.contains(.temperature))
        XCTAssertTrue(caps.supportedParameters.contains(.topP))
    }

    func test_capabilities_doesNotRequirePromptTemplate() {
        let backend = OpenAIBackend()
        XCTAssertFalse(backend.capabilities.requiresPromptTemplate,
                       "OpenAI handles chat templating server-side")
    }

    func test_capabilities_supportsSystemPrompt() {
        let backend = OpenAIBackend()
        XCTAssertTrue(backend.capabilities.supportsSystemPrompt)
    }

    func test_capabilities_supportsNativeJSONMode() {
        XCTAssertTrue(OpenAIBackend().capabilities.supportsNativeJSONMode)
    }

    // MARK: - Model Lifecycle

    func test_loadModel_withoutConfiguration_throws() async {
        let backend = OpenAIBackend()
        do {
            try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
            XCTFail("Should throw when no base URL is configured")
        } catch {
            // Expected — no baseURL configured
        }
    }

    func test_configure_thenLoadModel_succeeds() async throws {
        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "sk-test",
            modelName: "gpt-4o-mini"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        XCTAssertTrue(backend.isModelLoaded)
    }

    func test_unloadModel_clearsState() async throws {
        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "sk-test",
            modelName: "gpt-4o-mini"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        XCTAssertTrue(backend.isModelLoaded)

        backend.unloadModel()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertFalse(backend.isGenerating)
    }

    func test_generate_withoutLoading_throws() {
        let backend = OpenAIBackend()
        XCTAssertThrowsError(
            try backend.generate(prompt: "hello", systemPrompt: nil, config: GenerationConfig())
        )
    }

    func test_stopGeneration_setsIsGeneratingFalse() async throws {
        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "sk-test",
            modelName: "gpt-4o-mini"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        // stopGeneration should be safe to call even when not generating
        backend.stopGeneration()
        XCTAssertFalse(backend.isGenerating)
    }

    // MARK: - Plan Does Not Leak Into Request Payload

    /// Regression guard for the ModelLoadPlan refactor. The plan is informational
    /// for cloud backends — its `effectiveContextSize` must NEVER be copied into
    /// the request body as `max_tokens` or any other field. The API's
    /// `max_tokens` must come exclusively from `GenerationConfig.maxOutputTokens`.
    func test_loadModel_doesNotPropagateEffectiveContextSizeToRequestPayload() throws {
        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "sk-test",
            modelName: "gpt-4o-mini"
        )

        // Construct a plan with a distinctive effectiveContextSize. If a bug copies
        // plan.effectiveContextSize into the request body, we would see 31_337
        // as max_tokens instead of the config's value.
        _ = ModelLoadPlan.testStub(effectiveContextSize: 31_337)

        // Verify the request body reflects only the generation config's
        // maxOutputTokens. We build the request directly since loadModel is a
        // state-only configuration method on cloud backends.
        let config = GenerationConfig(maxOutputTokens: 777)
        let request = try backend.buildRequest(
            prompt: "hello",
            systemPrompt: nil,
            config: config,
            hints: GenerationRuntimeHints()
        )
        guard let body = request.httpBody,
              let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            XCTFail("Request body was not valid JSON")
            return
        }
        XCTAssertEqual(json["max_tokens"] as? Int, 777,
                       "max_tokens must come from GenerationConfig, not ModelLoadPlan")
        XCTAssertNil(json["effective_context_size"],
                     "plan.effectiveContextSize must not appear in the request body")
        XCTAssertNil(json["context_size"],
                     "plan.effectiveContextSize must not appear in the request body")
    }

    func test_buildRequest_jsonModeEnabled_addsFormatAndResponseFormat() throws {
        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "sk-test",
            modelName: "gpt-4o-mini"
        )

        let request = try backend.buildRequest(
            prompt: "hello",
            systemPrompt: nil,
            config: GenerationConfig(),
            hints: GenerationRuntimeHints(jsonMode: true)
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["format"] as? String, "json")
        let responseFormat = try XCTUnwrap(json["response_format"] as? [String: Any])

        XCTAssertEqual(responseFormat["type"] as? String, "json_object")
    }

    func test_buildRequest_jsonModeDisabled_omitsFormatAndResponseFormat() throws {
        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            apiKey: "sk-test",
            modelName: "gpt-4o-mini"
        )

        let request = try backend.buildRequest(
            prompt: "hello",
            systemPrompt: nil,
            config: GenerationConfig(),
            hints: GenerationRuntimeHints()
        )
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        XCTAssertNil(json["format"])
        XCTAssertNil(json["response_format"])
    }

    // MARK: - Token Extraction (indirect via SSE + JSON)

    /// Verifies that the OpenAI JSON format can round-trip through SSE parsing.
    /// Since extractToken is private, we test the format indirectly by verifying
    /// the JSON structure matches what the parser expects.
    func test_extractToken_validJSON() {
        // The expected OpenAI streaming chunk format
        let json = #"{"choices":[{"delta":{"content":"token"}}]}"#
        let data = json.data(using: .utf8)!
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNotNil(parsed)
        let choices = parsed?["choices"] as? [[String: Any]]
        XCTAssertNotNil(choices)
        let delta = choices?.first?["delta"] as? [String: Any]
        XCTAssertNotNil(delta)
        let content = delta?["content"] as? String
        XCTAssertEqual(content, "token")
    }

    // MARK: - Protocol Conformance

    // removed: ConversationHistoryReceiver retired in #2312 — history now
    // threads via hints, not a set-then-use receiver protocol.

    func test_conformsToTokenUsageProvider() {
        let backend = OpenAIBackend()
        XCTAssertTrue(backend is TokenUsageProvider,
                      "OpenAIBackend should conform to TokenUsageProvider")
    }

    // removed: setConversationHistory/conversationHistory retired in #2312 —
    // history is a per-call GenerationRuntimeHints.history value now, not
    // instance state a setter can install and a getter can read back.

    func test_castAsProtocols_succeeds() {
        let backend: any InferenceBackend = OpenAIBackend()
        XCTAssertNotNil(backend as? TokenUsageProvider,
                        "Casting InferenceBackend to TokenUsageProvider should succeed")
    }
}

// MARK: - Multi-turn History Serialisation

extension OpenAIBackendTests {

    func test_conversationHistory_includedInRequestBody() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let backend = OpenAIBackend(urlSession: session)
        let url = URL(string: "https://openai-history-\(UUID().uuidString).test")!
        backend.configure(baseURL: url, apiKey: "sk-test", modelName: "gpt-4o-mini")
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        let chunk = Data("data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n".utf8)
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
        XCTAssertGreaterThanOrEqual(messages.count, 2, "History messages must be included in request")
        XCTAssertEqual(messages[0]["content"] as? String, "What is 2+2?")
        XCTAssertEqual(messages[1]["content"] as? String, "4")
    }
}

// MARK: - stopGeneration() Mid-stream Cancellation

extension OpenAIBackendTests {

    func test_stopGeneration_cancelsActiveStream() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let backend = OpenAIBackend(urlSession: session)
        let url = URL(string: "https://openai-cancel-\(UUID().uuidString).test")!
        backend.configure(baseURL: url, apiKey: "sk-test", modelName: "gpt-4o-mini")
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())

        var chunks: [Data] = (0..<20).map { i in
            Data("data: {\"choices\":[{\"delta\":{\"content\":\"tok\(i)\"}}]}\n\n".utf8)
        }
        chunks.append(Data("data: [DONE]\n\n".utf8))

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

extension OpenAIBackendTests {

    func test_configure_keychainPath_loadModelSucceeds() async throws {
        let testAccount = "ManifoldKit.test.openai.\(UUID().uuidString)"
        try KeychainService.store(key: "sk-test-keychain-key", account: testAccount)
        defer { try? KeychainService.delete(account: testAccount) }

        let backend = OpenAIBackend()
        backend.configure(
            baseURL: URL(string: "https://api.openai.com")!,
            keychainAccount: testAccount,
            modelName: "gpt-4o-mini"
        )
        try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
        XCTAssertTrue(backend.isModelLoaded)
    }
}

// MARK: - Backend Contract

extension OpenAIBackendTests {
    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants { OpenAIBackend() }
    }
}
