@testable import BaseChatServerCore
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

    func testBearerAuthProtectsAPIButExemptsHealthAndMetrics() async throws {
        let server = ServerApp(
            configuration: ServerConfiguration(apiKey: "secret", metricsEnabled: true),
            backendProvider: FakeBackendProvider(models: ["tiny"]),
            adapter: FixedChatAdapter()
        )
        let app = server.makeApplication()

        try await app.test(.router) { client in
            try await client.execute(uri: "/health", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
            }

            try await client.execute(uri: "/metrics", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
            }

            try await client.execute(uri: "/v1/models", method: .get) { response in
                XCTAssertEqual(response.status, .unauthorized)
                XCTAssertTrue(String(buffer: response.body).contains("invalid_api_key"))
            }

            var headers = HTTPFields()
            headers[.authorization] = "Bearer secret"
            try await client.execute(uri: "/v1/models", method: .get, headers: headers) { response in
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
                XCTAssertEqual(response.headers[.contentType], "text/event-stream")
                XCTAssertEqual(response.headers[.cacheControl], "no-cache")
                XCTAssertEqual(response.headers[.connection], "keep-alive")
                XCTAssertEqual(response.headers[HTTPField.Name("X-Accel-Buffering")!], "no")
                let text = String(buffer: response.body)
                XCTAssertTrue(text.contains("stream"))
                XCTAssertTrue(text.contains("data: [DONE]"))
            }
        }
    }
}

private func requestBody(_ request: ChatCompletionRequest) throws -> ByteBuffer {
    ByteBuffer(bytes: try JSONEncoder().encode(request))
}

private struct FakeBackendProvider: ServerBackendProvider {
    let models: [String]
    let backend = MockInferenceBackend()

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
            continuation.yield(ChatCompletionChunk(
                id: "chatcmpl-test",
                created: 0,
                model: request.model,
                choices: [ChatCompletionChunkChoice(index: 0, delta: ChatCompletionDelta(content: "stream"))]
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
