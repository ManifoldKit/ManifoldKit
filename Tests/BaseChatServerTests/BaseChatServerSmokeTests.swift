#if Server
@testable import BaseChatServer
import BaseChatInference
import BaseChatTestSupport
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import XCTest

final class BaseChatServerSmokeTests: XCTestCase {
    func testServerAppConstructsHealthPlaceholder() {
        let configuration = ServerConfiguration(host: "localhost", port: 9090)
        let app = ServerApp(configuration: configuration)

        XCTAssertEqual(app.configuration.host, "localhost")
        XCTAssertEqual(app.configuration.port, 9090)
        XCTAssertEqual(app.health(), ServerHealth(status: "ok"))
        XCTAssertEqual(app.metrics.snapshot(), ServerMetricsSnapshot())
    }

    func testRoutesReturnHealthModelsAndChatCompletion() async throws {
        let app = ServerApp(
            backendProvider: FakeBackendProvider(models: ["tiny"]),
            adapter: FixedChatAdapter(content: "hello world")
        ).makeApplication()

        try await app.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let health = try JSONDecoder().decode(ServerHealth.self, from: Data(buffer: response.body))
                XCTAssertEqual(health, ServerHealth())
            }

            try await client.execute(uri: "/v1/models", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                let models = try JSONDecoder().decode(ModelsListResponse.self, from: Data(buffer: response.body))
                XCTAssertEqual(models.data.map(\.id), ["tiny"])
            }

            let body = try requestBody(ChatCompletionRequest(model: "tiny", messages: [.init(role: "user", content: "hi")]))
            try await client.execute(uri: "/v1/chat/completions", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .ok)
                let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: Data(buffer: response.body))
                XCTAssertEqual(completion.content, "hello world")
            }
        }
    }

    func testBearerAuthProtectsAPIButExemptsHealthOnly() async throws {
        let server = ServerApp(
            configuration: ServerConfiguration(apiKey: "secret", metricsEnabled: true),
            backendProvider: FakeBackendProvider(models: ["tiny"]),
            adapter: FixedChatAdapter()
        )
        let app = server.makeApplication()

        try await app.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                // SABOTAGE: change 401 → 200 assertion below to verify auth is enforced
            }

            // /metrics now requires auth (P0-3 fix)
            try await client.execute(uri: "/metrics", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
                XCTAssertTrue(
                    response.headers[.contentType]?.contains("application/json") == true,
                    "Error responses must carry application/json content type"
                )
            }

            try await client.execute(uri: "/v1/models", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
                XCTAssertTrue(String(buffer: response.body).contains("invalid_api_key"))
                XCTAssertTrue(
                    response.headers[.contentType]?.contains("application/json") == true,
                    "Error responses must carry application/json content type"
                )
            }

            var headers = HTTPFields()
            headers[.authorization] = "Bearer secret"
            try await client.execute(uri: "/v1/models", method: .get, headers: headers) { response in
                XCTAssertEqual(response.status, .ok)
            }

            // Unauthenticated POST to /v1/chat/completions must be rejected
            let chatBody = try requestBody(ChatCompletionRequest(model: "tiny", messages: [.init(role: "user", content: "hi")]))
            try await client.execute(uri: "/v1/chat/completions", method: .post, body: chatBody) { response in
                XCTAssertEqual(response.status, .unauthorized)
                XCTAssertTrue(
                    response.headers[.contentType]?.contains("application/json") == true,
                    "Error responses must carry application/json content type"
                )
            }

            // Wrong token must also be rejected
            var wrongHeaders = HTTPFields()
            wrongHeaders[.authorization] = "Bearer wrong"
            try await client.execute(uri: "/v1/chat/completions", method: .post, headers: wrongHeaders, body: chatBody) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }
        }
    }

    func testAuthMiddlewareInjectionRejectsMissingAndAcceptsValid() async throws {
        // Wires BearerTokenMiddleware via the explicit `authMiddleware:`
        // injection (issue #976) rather than the legacy `apiKey` field.
        let server = ServerApp(
            backendProvider: FakeBackendProvider(models: ["tiny"]),
            adapter: FixedChatAdapter(),
            authMiddleware: BearerTokenMiddleware(token: "via-middleware")
        )
        let app = server.makeApplication()

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }

            var malformed = HTTPFields()
            malformed[.authorization] = "Basic dXNlcjpwYXNz"
            try await client.execute(uri: "/v1/models", method: .get, headers: malformed) { response in
                XCTAssertEqual(response.status, .unauthorized)
            }

            var headers = HTTPFields()
            headers[.authorization] = "Bearer via-middleware"
            try await client.execute(uri: "/v1/models", method: .get, headers: headers) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    func testAnonymousMiddlewareDefaultPreservesUnauthenticatedAccess() async throws {
        // No apiKey, no middleware → AnonymousAuthMiddleware default → today's behavior.
        let server = ServerApp(
            backendProvider: FakeBackendProvider(models: ["tiny"]),
            adapter: FixedChatAdapter()
        )
        let app = server.makeApplication()

        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/models", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }

    func testCORSDefaultsConfiguredOriginUnsafeWildcardAndPreflight() async throws {
        try await ServerApp(
            configuration: ServerConfiguration(corsOrigin: "https://example.com")
        ).makeApplication().test(.router) { client in
            var headers = HTTPFields()
            headers[.origin] = "https://client.example"
            try await client.execute(uri: "/health", method: .get, headers: headers) { response in
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], "https://example.com")
            }

            try await client.execute(uri: "/health", method: .options, headers: headers) { response in
                XCTAssertEqual(response.status, .noContent)
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], "https://example.com")
            }
        }

        try await ServerApp().makeApplication().test(.router) { client in
            var headers = HTTPFields()
            headers[.origin] = "https://client.example"
            try await client.execute(uri: "/health", method: .get, headers: headers) { response in
                XCTAssertNil(response.headers[.accessControlAllowOrigin])
            }
        }

        try await ServerApp(
            configuration: ServerConfiguration(unsafeCORS: true)
        ).makeApplication().test(.router) { client in
            var headers = HTTPFields()
            headers[.origin] = "https://client.example"
            try await client.execute(uri: "/health", method: .get, headers: headers) { response in
                XCTAssertEqual(response.headers[.accessControlAllowOrigin], "*")
            }
        }
    }

    func testMetricsEndpointIsConditionalAndTracksCounters() async throws {
        try await ServerApp().makeApplication().test(.router) { client in
            try await client.execute(uri: "/metrics", method: .get) { response in
                XCTAssertEqual(response.status, .notFound)
            }
        }

        let server = ServerApp(
            configuration: ServerConfiguration(metricsEnabled: true),
            backendProvider: FakeBackendProvider(models: ["tiny"]),
            adapter: FixedChatAdapter(content: "one two")
        )
        try await server.makeApplication().test(.router) { client in
            let body = try requestBody(ChatCompletionRequest(model: "tiny", messages: []))
            try await client.execute(uri: "/v1/chat/completions", method: .post, body: body)
            try await client.execute(uri: "/metrics", method: .get) { response in
                let text = String(buffer: response.body)
                XCTAssertTrue(text.contains("basechat_requests_total 1"))
                XCTAssertTrue(text.contains("basechat_completions_total 1"))
                XCTAssertTrue(text.contains("basechat_tokens_total 2"))
            }
        }
    }

    func testSemaphoreLimitsConcurrentChatCompletions() async throws {
        let recorder = ConcurrencyRecorder()
        let server = ServerApp(
            configuration: ServerConfiguration(parallelSlots: 1),
            backendProvider: FakeBackendProvider(models: ["tiny"]),
            adapter: DelayedChatAdapter(recorder: recorder)
        )
        let app = server.makeApplication()

        try await app.test(.router) { client in
            let firstBody = try requestBody(ChatCompletionRequest(model: "tiny", messages: []))
            let secondBody = try requestBody(ChatCompletionRequest(model: "tiny", messages: []))
            async let first: Void = client.execute(uri: "/v1/chat/completions", method: .post, body: firstBody) { _ in () }
            async let second: Void = client.execute(uri: "/v1/chat/completions", method: .post, body: secondBody) { _ in () }
            _ = try await (first, second)
        }

        let maxObserved = await recorder.maxObserved
        XCTAssertEqual(maxObserved, 1)
        // SABOTAGE: bump semaphore limit to 10 to verify gate is active
    }

    func testSemaphoreLimitsConcurrentStreamingChatCompletions() async throws {
        let recorder = ConcurrencyRecorder()
        let server = ServerApp(
            configuration: ServerConfiguration(parallelSlots: 1),
            backendProvider: FakeBackendProvider(models: ["tiny"]),
            adapter: DelayedStreamingChatAdapter(recorder: recorder)
        )
        let app = server.makeApplication()

        try await app.test(.router) { client in
            let firstBody = try requestBody(ChatCompletionRequest(model: "tiny", messages: [], stream: true))
            let secondBody = try requestBody(ChatCompletionRequest(model: "tiny", messages: [], stream: true))
            async let first: Void = client.execute(uri: "/v1/chat/completions", method: .post, body: firstBody) { _ in () }
            async let second: Void = client.execute(uri: "/v1/chat/completions", method: .post, body: secondBody) { _ in () }
            _ = try await (first, second)
        }

        let maxObserved = await recorder.maxObserved
        XCTAssertEqual(maxObserved, 1)
    }

    func testSSEHeadersAndDoneFrame() async throws {
        let server = ServerApp(
            backendProvider: FakeBackendProvider(models: ["tiny"]),
            adapter: FixedStreamingChatAdapter()
        )
        let app = server.makeApplication()

        try await app.test(.router) { client in
            let body = try requestBody(ChatCompletionRequest(model: "tiny", messages: [], stream: true))
            try await client.execute(uri: "/v1/chat/completions", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .ok)
                // SABOTAGE: change Content-Type assertion to "text/plain" to verify SSE type is set
                XCTAssertEqual(response.headers[.contentType], "text/event-stream")
                XCTAssertEqual(response.headers[.cacheControl], "no-cache")
                XCTAssertEqual(response.headers[.connection], "keep-alive")
                XCTAssertEqual(response.headers[HTTPField.Name("X-Accel-Buffering")!], "no")

                let text = String(buffer: response.body)
                XCTAssertTrue(text.contains("data: [DONE]"))

                // Decode each non-DONE SSE data line as ChatCompletionChunk
                let decoder = JSONDecoder()
                let events = text.components(separatedBy: "\n\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.hasPrefix("data: ") && $0 != "data: [DONE]" }
                    .compactMap { line -> ChatCompletionChunk? in
                        let payload = line.dropFirst("data: ".count)
                        return try? decoder.decode(ChatCompletionChunk.self, from: Data(payload.utf8))
                    }

                XCTAssertFalse(events.isEmpty, "Expected at least one decodable SSE chunk")
                let contentTokens = events.compactMap { $0.choices.first?.delta.content }.joined()
                XCTAssertTrue(contentTokens.contains("stream"), "Expected chunk content to contain the test token")

                // The final non-DONE chunk must carry a finish_reason
                XCTAssertEqual(events.last?.choices.first?.finishReason, .stop)
            }
        }
    }

    func testBackendFailureReturns500WithErrorEnvelope() async throws {
        let server = ServerApp(
            backendProvider: FakeBackendProvider(models: ["tiny"]),
            adapter: FailingChatAdapter()
        )
        let app = server.makeApplication()

        try await app.test(.router) { client in
            let body = try requestBody(ChatCompletionRequest(model: "tiny", messages: [.init(role: "user", content: "hi")]))
            try await client.execute(uri: "/v1/chat/completions", method: .post, body: body) { response in
                // SABOTAGE: change status assertion to .ok to verify this test catches regressions
                XCTAssertEqual(response.status, .internalServerError)
                XCTAssertTrue(
                    response.headers[.contentType]?.contains("application/json") == true,
                    "Error responses must be JSON"
                )
                let envelope = try JSONDecoder().decode(
                    ChatCompletionErrorEnvelope.self,
                    from: Data(buffer: response.body)
                )
                XCTAssertFalse(envelope.error.message.isEmpty, "Error envelope must carry a non-empty message")
            }
        }
    }

    func testUnsupportedToolRequestReturnsClearInvalidRequestError() async throws {
        let server = ServerApp(
            backendProvider: FakeBackendProvider(models: ["tiny"]),
            adapter: FixedChatAdapter()
        )
        let app = server.makeApplication()

        try await app.test(.router) { client in
            let request = ChatCompletionRequest(
                model: "tiny",
                messages: [.init(role: "user", content: "hi")],
                tools: [ChatCompletionTool(function: ChatCompletionFunctionDefinition(name: "lookup"))]
            )
            let body = try requestBody(request)

            try await client.execute(uri: "/v1/chat/completions", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .badRequest)
                XCTAssertTrue(
                    response.headers[.contentType]?.contains("application/json") == true,
                    "Capability errors must be JSON"
                )
                let envelope = try JSONDecoder().decode(
                    ChatCompletionErrorEnvelope.self,
                    from: Data(buffer: response.body)
                )
                XCTAssertEqual(envelope.error.type, "invalid_request_error")
                XCTAssertEqual(envelope.error.param, "tools")
                XCTAssertEqual(envelope.error.code, "unsupported_capability")
                XCTAssertTrue(envelope.error.message.contains("tool calling"))
            }
        }
    }

    func testUnsupportedStreamingResponseFormatReturnsJSONErrorBeforeSSE() async throws {
        let server = ServerApp(
            backendProvider: FakeBackendProvider(models: ["tiny"]),
            adapter: FixedStreamingChatAdapter()
        )
        let app = server.makeApplication()

        try await app.test(.router) { client in
            let request = ChatCompletionRequest(
                model: "tiny",
                messages: [.init(role: "user", content: "hi")],
                stream: true,
                responseFormat: ChatCompletionResponseFormat(type: .jsonObject)
            )
            let body = try requestBody(request)

            try await client.execute(uri: "/v1/chat/completions", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .badRequest)
                XCTAssertTrue(
                    response.headers[.contentType]?.contains("application/json") == true,
                    "Pre-stream capability errors must be JSON"
                )
                XCTAssertNotEqual(response.headers[.contentType], "text/event-stream")
                let envelope = try JSONDecoder().decode(
                    ChatCompletionErrorEnvelope.self,
                    from: Data(buffer: response.body)
                )
                XCTAssertEqual(envelope.error.type, "invalid_request_error")
                XCTAssertEqual(envelope.error.param, "response_format")
                XCTAssertTrue(envelope.error.message.contains("native JSON mode"))
            }
        }
    }

    func testToolRequestSucceedsWhenBackendAdvertisesToolCalling() async throws {
        let backend = MockInferenceBackend(capabilities: BackendCapabilities(supportsToolCalling: true))
        let server = ServerApp(
            backendProvider: FakeBackendProvider(models: ["tiny"], backend: backend),
            adapter: FixedChatAdapter(content: "tool ready")
        )
        let app = server.makeApplication()

        try await app.test(.router) { client in
            let request = ChatCompletionRequest(
                model: "tiny",
                messages: [.init(role: "user", content: "hi")],
                tools: [ChatCompletionTool(function: ChatCompletionFunctionDefinition(name: "lookup"))],
                toolChoice: .function(name: "lookup")
            )
            let body = try requestBody(request)

            try await client.execute(uri: "/v1/chat/completions", method: .post, body: body) { response in
                XCTAssertEqual(response.status, .ok)
                let completion = try JSONDecoder().decode(ChatCompletionResponse.self, from: Data(buffer: response.body))
                XCTAssertEqual(completion.content, "tool ready")
            }
        }
    }

    func testMalformedRequestBodyReturnsError() async throws {
        let server = ServerApp(
            backendProvider: FakeBackendProvider(models: ["tiny"]),
            adapter: FixedChatAdapter()
        )
        let app = server.makeApplication()

        try await app.test(.router) { client in
            var headers = HTTPFields()
            headers[.contentType] = "application/json"
            let malformedBody = ByteBuffer(string: "not json")
            try await client.execute(
                uri: "/v1/chat/completions",
                method: .post,
                headers: headers,
                body: malformedBody
            ) { response in
                XCTAssertNotEqual(response.status, .ok)
                XCTAssertTrue(
                    response.headers[.contentType]?.contains("application/json") == true,
                    "Error responses must be JSON"
                )
                XCTAssertNoThrow(
                    try JSONDecoder().decode(
                        ChatCompletionErrorEnvelope.self,
                        from: Data(buffer: response.body)
                    ),
                    "Malformed-body error must decode as ChatCompletionErrorEnvelope"
                )
            }
        }
    }
}

private func requestBody(_ request: ChatCompletionRequest) throws -> ByteBuffer {
    ByteBuffer(bytes: try JSONEncoder().encode(request))
}

private struct FakeBackendProvider: ServerBackendProvider {
    let models: [String]
    let backend: any InferenceBackend

    init(models: [String], backend: any InferenceBackend = MockInferenceBackend()) {
        self.models = models
        self.backend = backend
    }

    func listModels() async throws -> [String] {
        models
    }

    func backend(for request: ServerBackendRequest) async throws -> any InferenceBackend {
        backend
    }
}

private struct FixedChatAdapter: ChatCompletionsAdapter {
    var content = "ok"

    func generationConfig(for request: ChatCompletionRequest) throws -> GenerationConfig {
        GenerationConfig()
    }

    func response(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) async throws -> ChatCompletionResponse {
        ChatCompletionResponse(id: "chatcmpl-test", model: request.model, content: content)
    }

    func chunks(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) throws -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(ChatCompletionChunk(
                id: "chatcmpl-test",
                created: 0,
                model: request.model,
                choices: [ChatCompletionChunkChoice(index: 0, delta: ChatCompletionDelta(content: content))]
            ))
            continuation.finish()
        }
    }
}

private struct FixedStreamingChatAdapter: ChatCompletionsAdapter {
    func generationConfig(for request: ChatCompletionRequest) throws -> GenerationConfig {
        GenerationConfig()
    }

    func response(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) async throws -> ChatCompletionResponse {
        ChatCompletionResponse(id: "chatcmpl-test", model: request.model, content: "fallback")
    }

    func chunks(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) throws -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        AsyncThrowingStream { continuation in
            // Content token chunk
            continuation.yield(ChatCompletionChunk(
                id: "chatcmpl-test",
                created: 0,
                model: request.model,
                choices: [ChatCompletionChunkChoice(index: 0, delta: ChatCompletionDelta(content: "stream"))]
            ))
            // Final stop chunk (matches the pattern used by ChatCompletionEventMapper)
            continuation.yield(ChatCompletionChunk(
                id: "chatcmpl-test",
                created: 0,
                model: request.model,
                choices: [ChatCompletionChunkChoice(index: 0, delta: ChatCompletionDelta(), finishReason: .stop)]
            ))
            continuation.finish()
        }
    }
}

private actor ConcurrencyRecorder {
    private var current = 0
    private var maxValue = 0

    var maxObserved: Int { maxValue }

    func enter() {
        current += 1
        maxValue = max(maxValue, current)
    }

    func leave() {
        current -= 1
    }
}

private struct DelayedChatAdapter: ChatCompletionsAdapter {
    let recorder: ConcurrencyRecorder

    func generationConfig(for request: ChatCompletionRequest) throws -> GenerationConfig {
        GenerationConfig()
    }

    func response(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) async throws -> ChatCompletionResponse {
        await recorder.enter()
        try await Task.sleep(for: .milliseconds(100))
        await recorder.leave()
        return ChatCompletionResponse(id: "chatcmpl-delayed", model: request.model, content: "done")
    }

    func chunks(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) throws -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}

private struct DelayedStreamingChatAdapter: ChatCompletionsAdapter {
    let recorder: ConcurrencyRecorder

    func generationConfig(for request: ChatCompletionRequest) throws -> GenerationConfig {
        GenerationConfig()
    }

    func response(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) async throws -> ChatCompletionResponse {
        ChatCompletionResponse(id: "chatcmpl-delayed-stream", model: request.model, content: "done")
    }

    func chunks(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) throws -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        let recorder = recorder
        return AsyncThrowingStream { continuation in
            let task = Task {
                await recorder.enter()
                try await Task.sleep(for: .milliseconds(100))
                await recorder.leave()
                continuation.yield(ChatCompletionChunk(
                    id: "chatcmpl-delayed-stream",
                    created: 0,
                    model: request.model,
                    choices: [ChatCompletionChunkChoice(index: 0, delta: ChatCompletionDelta(content: "done"), finishReason: .stop)]
                ))
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

private struct FailingChatAdapter: ChatCompletionsAdapter {
    struct GenerationFailure: Error {}

    func generationConfig(for request: ChatCompletionRequest) throws -> GenerationConfig {
        GenerationConfig()
    }

    func response(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) async throws -> ChatCompletionResponse {
        throw GenerationFailure()
    }

    func chunks(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) throws -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: GenerationFailure())
        }
    }
}

#endif
