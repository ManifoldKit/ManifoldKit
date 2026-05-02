#if CloudSaaS
import Testing
import Foundation
@testable import BaseChatBackends
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport

// MARK: - Helpers

/// Creates a `URLSession` whose traffic is intercepted by `MockURLProtocol`.
private func makeMockSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [MockURLProtocol.self]
    return URLSession(configuration: config)
}

/// Formats a single SSE data line from a JSON string.
private func sseData(_ json: String) -> Data {
    Data("data: \(json)\n\n".utf8)
}

/// Formats the SSE `[DONE]` sentinel.
private let sseDone = Data("data: [DONE]\n\n".utf8)

/// Creates an OpenAIBackend configured for a unique test URL.
///
/// Each call uses a UUID-based hostname, so stubs from different tests
/// never collide. Tests must call `MockURLProtocol.unstub(url:)` in a
/// `defer` block rather than `MockURLProtocol.reset()`, which would clear
/// stubs registered by other suites running concurrently.
private func makeOllamaBackend() -> (OpenAIBackend, URL) {
    let session = makeMockSession()
    let backend = OpenAIBackend(urlSession: session)
    let baseURL = URL(string: "http://ollama-\(UUID().uuidString).test")!
    backend.configure(baseURL: baseURL, apiKey: nil, modelName: "llama3")
    return (backend, baseURL.appendingPathComponent("v1/chat/completions"))
}

private func makeCompatBackend(modelName: String) -> (OpenAIBackend, URL) {
    let session = makeMockSession()
    let backend = OpenAIBackend(urlSession: session)
    let baseURL = URL(string: "http://compat-\(UUID().uuidString).test")!
    backend.configure(baseURL: baseURL, apiKey: nil, modelName: modelName)
    return (backend, baseURL.appendingPathComponent("v1/chat/completions"))
}

private func loadBackend(_ backend: OpenAIBackend) async throws {
    try await backend.loadModel(from: URL(string: "unused:")!, plan: .cloud())
}

/// Extracts the HTTP body from a captured request, handling both httpBody and httpBodyStream.
private func extractBody(from request: URLRequest?) throws -> Data {
    guard let request else {
        Issue.record("No captured request")
        return Data()
    }
    if let body = request.httpBody { return body }
    if let stream = request.httpBodyStream {
        var data = Data()
        stream.open()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            if read > 0 { data.append(buffer, count: read) }
        }
        stream.close()
        return data
    }
    Issue.record("Request has neither httpBody nor httpBodyStream")
    return Data()
}

// MARK: - OpenAI-Compatible Endpoint Tests
//
// All E2E tests that use MockURLProtocol must run serialized to avoid
// cross-test stub interference (MockURLProtocol uses global shared state).

@Suite("OpenAI-compat endpoints (Ollama)", .serialized)
struct OpenAICompatEndpointTests {

    // =========================================================================
    // MARK: - Ollama Streaming
    // =========================================================================

    @Test func ollama_streaming_standardChunks() async throws {
        let (backend, url) = makeOllamaBackend()
        defer { MockURLProtocol.unstub(url: url) }

        // Ollama's streaming format mirrors OpenAI's but includes an "ollama"
        // system_fingerprint and may omit some fields OpenAI includes.
        let chunks: [Data] = [
            sseData("""
            {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"llama3","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}
            """),
            sseData("""
            {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"llama3","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"content":"Once"},"finish_reason":null}]}
            """),
            sseData("""
            {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"llama3","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"content":" upon"},"finish_reason":null}]}
            """),
            sseData("""
            {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"llama3","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"content":" a time"},"finish_reason":null}]}
            """),
            sseData("""
            {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"llama3","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Tell me a story",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let text) = event {
                tokens.append(text)
            }
        }

        // Empty first chunk (role-only) yields empty string; content chunks follow.
        let meaningful = tokens.filter { !$0.isEmpty }
        #expect(meaningful == ["Once", " upon", " a time"])
    }

    @Test func ollama_streaming_withUsage() async throws {
        let (backend, url) = makeOllamaBackend()
        defer { MockURLProtocol.unstub(url: url) }

        // Ollama supports stream_options.include_usage (added in 0.4.0).
        // Usage arrives in the final chunk, same as OpenAI.
        let chunks: [Data] = [
            sseData("""
            {"id":"chatcmpl-456","object":"chat.completion.chunk","created":1234567890,"model":"llama3","choices":[{"index":0,"delta":{"content":"Hi"},"finish_reason":null}]}
            """),
            sseData("""
            {"id":"chatcmpl-456","object":"chat.completion.chunk","created":1234567890,"model":"llama3","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":15,"completion_tokens":1,"total_tokens":16}}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Hello",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        for try await _ in stream.events { }

        // Verify token usage was extracted
        let usage = backend.lastUsage
        #expect(usage?.promptTokens == 15)
        #expect(usage?.completionTokens == 1)
    }

    @Test func compat_prefillProgress_eventsEmitAndPreserveOrdering() async throws {
        let (backend, url) = makeCompatBackend(modelName: "test-model")
        defer { MockURLProtocol.unstub(url: url) }

        let prefill1 = Data("""
        event: prefill_progress
        data: {"n_past":1024,"n_total":4096,"tokens_per_second":280.0}

        """.utf8)
        let prefill2 = Data("""
        event: prefill_progress
        data: {"n_past":3072,"n_total":4096,"tokens_per_second":300.5}

        """.utf8)
        let prefillFinal = Data("""
        event: prefill_progress
        data: {"n_past":4096,"n_total":4096,"tokens_per_second":295.0}

        """.utf8)
        let token = sseData("""
        {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1234567890,"model":"test-model","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}
        """)
        MockURLProtocol.stub(
            url: url,
            response: .sse(chunks: [prefill1, prefill2, prefillFinal, token, sseDone], statusCode: 200)
        )

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Hello",
            systemPrompt: nil,
            config: GenerationConfig(streamPrefillProgress: true)
        )

        var events: [GenerationEvent] = []
        for try await event in stream.events {
            events.append(event)
        }

        #expect(events.count == 4)
        #expect(events[0] == .prefillProgress(nPast: 1024, nTotal: 4096, tokensPerSecond: 280.0))
        #expect(events[1] == .prefillProgress(nPast: 3072, nTotal: 4096, tokensPerSecond: 300.5))
        #expect(events[2] == .prefillProgress(nPast: 4096, nTotal: 4096, tokensPerSecond: 295.0))
        #expect(events[3] == .token("Hello"))
    }

    /// Ollama versions before 0.4.0 do not support `stream_options` and silently
    /// ignore it. The final chunk has no `usage` field. OpenAIBackend should handle
    /// this gracefully (lastUsage stays nil).
    @Test func ollama_streaming_withoutUsageSupport() async throws {
        let (backend, url) = makeOllamaBackend()
        defer { MockURLProtocol.unstub(url: url) }

        let chunks: [Data] = [
            sseData("""
            {"id":"chatcmpl-789","object":"chat.completion.chunk","created":1234567890,"model":"llama3","choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}
            """),
            sseData("""
            {"id":"chatcmpl-789","object":"chat.completion.chunk","created":1234567890,"model":"llama3","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Hi",
            systemPrompt: nil,
            config: GenerationConfig()
        )

        var tokens: [String] = []
        for try await event in stream.events {
            if case .token(let text) = event {
                tokens.append(text)
            }
        }

        #expect(tokens == ["Hello"])
        // No usage data when Ollama doesn't support stream_options
        #expect(backend.lastUsage == nil)
    }

    // =========================================================================
    // MARK: - Ollama Errors
    // =========================================================================

    /// Ollama may return an error as a JSON body with a non-200 status,
    /// using OpenAI-compatible error format.
    @Test func ollama_error_modelNotFound() async throws {
        let (backend, url) = makeOllamaBackend()
        defer { MockURLProtocol.unstub(url: url) }

        let body = Data("""
        {"error":{"message":"model 'nonexistent' not found, try pulling it first","type":"not_found","code":"model_not_found"}}
        """.utf8)

        MockURLProtocol.stub(url: url, response: .immediate(data: body, statusCode: 404))

        try await loadBackend(backend)

        do {
            let stream = try backend.generate(
                prompt: "Hi",
                systemPrompt: nil,
                config: GenerationConfig()
            )
            for try await _ in stream.events {}
            Issue.record("Expected server error for missing model")
        } catch {
            guard let error = extractCloudError(error) else { Issue.record("Expected CloudBackendError, got \(error)"); return }
            switch error {
            case .serverError(let statusCode, let message):
                #expect(statusCode == 404)
                #expect(message.contains("not found"))
            default:
                Issue.record("Expected serverError, got \(error)")
            }
        }
    }

    // =========================================================================
    // MARK: - Ollama Auth
    // =========================================================================

    /// Ollama does not require an API key. Verify that OpenAIBackend works
    /// without authentication headers.
    @Test func ollama_noAuth_omitsAuthHeader() async throws {
        let (backend, url) = makeOllamaBackend()
        defer { MockURLProtocol.unstub(url: url) }

        let chunks: [Data] = [
            sseData("""
            {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1234567890,"model":"llama3","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "test",
            systemPrompt: nil,
            config: GenerationConfig()
        )
        for try await _ in stream.events { }

        // Verify no Authorization header was sent (apiKey was nil)
        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == url })
        #expect(captured != nil)
        let authHeader = captured?.value(forHTTPHeaderField: "Authorization")
        #expect(authHeader == nil, "Ollama doesn't need auth -- no Authorization header should be sent")
    }

    // =========================================================================
    // MARK: - Request Format Compatibility
    // =========================================================================

    /// Verifies the request body contains the expected fields for an
    /// OpenAI-compatible endpoint. Ollama accepts this format.
    @Test func requestFormat_containsExpectedFields() async throws {
        let (backend, url) = makeCompatBackend(modelName: "test-model")
        defer { MockURLProtocol.unstub(url: url) }

        let chunks: [Data] = [
            sseData("""
            {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1234567890,"model":"test-model","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Hello",
            systemPrompt: "You are helpful.",
            config: GenerationConfig()
        )
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == url })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        // Required fields that Ollama expects
        #expect(json["model"] as? String == "test-model")
        #expect(json["stream"] as? Bool == true)

        let messages = try #require(json["messages"] as? [[String: Any]])
        #expect(messages.count >= 2, "Should have system + user messages")
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[0]["content"] as? String == "You are helpful.")

        // temperature and top_p should be present
        #expect(json["temperature"] != nil)
        #expect(json["top_p"] != nil)

        // max_tokens should be present
        #expect(json["max_tokens"] != nil)
    }

    @Test func requestHeaders_prefillProgressOptIn_isOffByDefault() async throws {
        let (backend, url) = makeCompatBackend(modelName: "test-model")
        defer { MockURLProtocol.unstub(url: url) }

        let chunks: [Data] = [
            sseData("""
            {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1234567890,"model":"test-model","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Hello",
            systemPrompt: nil,
            config: GenerationConfig()
        )
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == url })
        #expect(captured?.value(forHTTPHeaderField: "X-BaseChat-Prefill-Progress") == nil)
    }

    @Test func requestHeaders_prefillProgressOptIn_setsHeader() async throws {
        let (backend, url) = makeCompatBackend(modelName: "test-model")
        defer { MockURLProtocol.unstub(url: url) }

        let chunks: [Data] = [
            sseData("""
            {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1234567890,"model":"test-model","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Hello",
            systemPrompt: nil,
            config: GenerationConfig(streamPrefillProgress: true)
        )
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == url })
        #expect(captured?.value(forHTTPHeaderField: "X-BaseChat-Prefill-Progress") == "true")
    }

    /// INCOMPATIBILITY DOCUMENTED: OpenAIBackend sends `stream_options`
    /// which is specific to OpenAI's API. Ollama only supports it from
    /// version 0.4.0+. Older Ollama versions ignore it without erroring.
    @Test func requestFormat_containsStreamOptions() async throws {
        let (backend, url) = makeCompatBackend(modelName: "test-model")
        defer { MockURLProtocol.unstub(url: url) }

        let chunks: [Data] = [
            sseData("""
            {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1234567890,"model":"test-model","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)
        let stream = try backend.generate(
            prompt: "Hello",
            systemPrompt: nil,
            config: GenerationConfig()
        )
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == url })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])

        // stream_options is sent by OpenAIBackend -- harmless for Ollama
        // (silently ignores unknown fields), but worth documenting.
        let streamOptions = json["stream_options"] as? [String: Any]
        #expect(streamOptions != nil, "stream_options is always sent (harmlessly ignored by old Ollama)")
        #expect(streamOptions?["include_usage"] as? Bool == true)
    }

    /// Verifies that conversation history is included in the request body,
    /// which is essential for multi-turn conversations with Ollama.
    @Test func requestFormat_includesConversationHistory() async throws {
        let (backend, url) = makeCompatBackend(modelName: "llama3")
        defer { MockURLProtocol.unstub(url: url) }

        let chunks: [Data] = [
            sseData("""
            {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1234567890,"model":"llama3","choices":[{"index":0,"delta":{"content":"6"},"finish_reason":null}]}
            """),
            sseDone,
        ]

        MockURLProtocol.stub(url: url, response: .sse(chunks: chunks, statusCode: 200))

        try await loadBackend(backend)

        backend.setConversationHistory([
            (role: "user", content: "What is 2+2?"),
            (role: "assistant", content: "4"),
            (role: "user", content: "And 3+3?"),
        ])

        let stream = try backend.generate(
            prompt: "And 3+3?",
            systemPrompt: "You are a calculator.",
            config: GenerationConfig()
        )
        for try await _ in stream.events { }

        let captured = MockURLProtocol.capturedRequests.last(where: { $0.url == url })
        let body = try extractBody(from: captured)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let messages = try #require(json["messages"] as? [[String: Any]])

        // System prompt + 3 conversation history messages
        #expect(messages.count == 4)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "What is 2+2?")
        #expect(messages[2]["role"] as? String == "assistant")
        #expect(messages[3]["role"] as? String == "user")
    }
}

// MARK: - Payload Handler Unit Tests (no MockURLProtocol needed)

/// Tests edge cases in SSE payload parsing that may differ between providers.
/// These use the payload handler directly (unit-level) and do not need serialization.
@Suite("Provider SSE payload parsing")
struct ProviderSSEPayloadTests {

    // MARK: - Ollama Payload Format

    @Test func ollama_payloadHandler_extractsToken() {
        let handler = OpenAIBackend.payloadHandler

        let chunk = """
        {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"llama3","system_fingerprint":"fp_ollama","choices":[{"index":0,"delta":{"content":"hello"},"finish_reason":null}]}
        """
        #expect(handler.extractToken(from: chunk) == "hello")
    }

    @Test func ollama_payloadHandler_finishChunkReturnsNil() {
        let handler = OpenAIBackend.payloadHandler

        let finishChunk = """
        {"id":"chatcmpl-123","object":"chat.completion.chunk","created":1234567890,"model":"llama3","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}
        """
        #expect(handler.extractToken(from: finishChunk) == nil)
    }

    @Test func ollama_payloadHandler_extractsUsage() {
        let handler = OpenAIBackend.payloadHandler

        let usageChunk = """
        {"id":"chatcmpl-456","object":"chat.completion.chunk","created":1234567890,"model":"llama3","choices":[],"usage":{"prompt_tokens":20,"completion_tokens":50,"total_tokens":70}}
        """
        let usage = handler.extractUsage(from: usageChunk)
        #expect(usage?.promptTokens == 20)
        #expect(usage?.completionTokens == 50)
    }

    /// Ollama may include extra fields in the delta that OpenAI doesn't send.
    @Test func ollama_extraFieldsInDelta_parsesCorrectly() {
        let handler = OpenAIBackend.payloadHandler

        let chunk = """
        {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1234567890,"model":"llama3","choices":[{"index":0,"delta":{"content":"hello","extra_field":true},"finish_reason":null}],"done":false}
        """
        #expect(handler.extractToken(from: chunk) == "hello")
    }

    /// Ollama may send empty string content in early chunks.
    @Test func ollama_emptyContent_yieldsEmptyString() {
        let handler = OpenAIBackend.payloadHandler

        let chunk = """
        {"id":"chatcmpl-1","object":"chat.completion.chunk","created":1234567890,"model":"llama3","choices":[{"index":0,"delta":{"role":"assistant","content":""},"finish_reason":null}]}
        """
        // extractToken returns "" (empty string) which is technically a valid return,
        // not nil. The caller should filter empty tokens if needed.
        let token = handler.extractToken(from: chunk)
        #expect(token == "")
    }

    // MARK: - Unicode

    /// Ollama may stream Unicode content.
    @Test func unicode_parsedCorrectly() {
        let handler = OpenAIBackend.payloadHandler

        let emojiChunk = """
        {"choices":[{"delta":{"content":"Hello \\ud83d\\ude00"}}]}
        """
        #expect(handler.extractToken(from: emojiChunk) == "Hello \u{1F600}")

        let cjkChunk = """
        {"choices":[{"delta":{"content":"\\u4f60\\u597d"}}]}
        """
        #expect(handler.extractToken(from: cjkChunk) == "\u{4F60}\u{597D}")

        let accentChunk = """
        {"choices":[{"delta":{"content":"caf\\u00e9"}}]}
        """
        #expect(handler.extractToken(from: accentChunk) == "caf\u{00E9}")
    }

    // MARK: - Malformed Responses

    /// Ollama may occasionally send malformed SSE payloads.
    @Test func malformedJSON_returnsNil() {
        let handler = OpenAIBackend.payloadHandler

        #expect(handler.extractToken(from: "not json at all") == nil)
        #expect(handler.extractToken(from: "{invalid") == nil)
        #expect(handler.extractToken(from: "") == nil)
        #expect(handler.extractToken(from: "{}") == nil)
        #expect(handler.extractToken(from: "{\"choices\":[]}") == nil)

        // Usage extraction should also be nil for malformed data
        #expect(handler.extractUsage(from: "not json") == nil)
        #expect(handler.extractUsage(from: "") == nil)
    }
}

// MARK: - Documented Incompatibilities
//
// The following notes describe differences between OpenAIBackend and Ollama's
// OpenAI-compatible endpoint. These are NOT bugs to fix in OpenAIBackend --
// they are inherent differences in the provider.
//
// 1. `stream_options` parameter:
//    - OpenAIBackend always sends `"stream_options": {"include_usage": true}`
//    - Ollama < 0.4.0 ignores this; Ollama >= 0.4.0 supports it
//    - Impact: `lastUsage` may be nil when using older Ollama versions.
//      Not a functional problem, just missing telemetry. Ollama silently
//      ignores unknown fields, so this causes no errors.
//
// 2. Error response format:
//    - OpenAI: `{"error": {"message": "...", "type": "...", "code": "..."}}`
//    - Ollama:  `{"error": {"message": "...", "type": "...", "code": "..."}}` (compatible)
//
// 3. Model listing (`/v1/models`):
//    - Not tested here because OpenAIBackend does not call `/v1/models`.
//    - Model selection is done at configuration time, not via discovery.
//    - Ollama: `GET /v1/models` returns `{"object":"list","data":[...]}`
//
// 4. Supported generation parameters:
//    - OpenAIBackend sends `temperature`, `top_p`, `max_tokens`
//    - Ollama accepts these standard parameters
//    - Ollama supports additional `options` field in its native API for
//      `num_ctx`, `top_k`, `repeat_penalty`, etc. -- not available via
//      OpenAI-compatible endpoint.
//
// 5. Authentication:
//    - Ollama does not require API keys by default.
//    - OpenAIBackend correctly omits the Authorization header when apiKey is nil.
#endif
