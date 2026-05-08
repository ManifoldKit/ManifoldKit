#if Server
@testable import BaseChatServer
import BaseChatInference
import BaseChatTestSupport
import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import XCTest

/// SSE streaming response structure and cancellation-path tests for
/// ``BaseChatServer``'s `/v1/chat/completions` endpoint.
///
/// ## Cancellation coverage note
///
/// ``testCancellingDefaultAdapterStreamStopsBackendWithin500Milliseconds()``
/// asserts the default adapter stream termination path calls
/// ``InferenceBackend/stopGeneration()``. In the Hummingbird in-process test
/// client the connection is fully consumed before `execute` returns, so the
/// endpoint-level tests continue to assert the SSE framing delivered to clients.
///
/// These assertions are load-bearing: they fail if the SSE framing regresses.
///
/// Sabotage-evidence:
///   M1: Remove `text/event-stream` header assertion → test passes even when
///       the server sends plain JSON (wrong content-type hides SSE breakage).
///   M2: Drop the `[DONE]` assertion → test passes even when the done sentinel
///       is omitted (client would hang waiting for the stream end).
///   M3: Remove the multi-token length assertion → a single-token adapter
///       accidentally satisfies "at least one chunk", hiding regressions where
///       batching collapses all output.
final class SSECancellationTests: XCTestCase {

    // MARK: - SSE structure

    /// A streaming response must carry the four mandatory SSE headers.
    func testStreamingEndpointSetsRequiredSSEHeaders() async throws {
        let app = ServerApp(
            backendProvider: FixedStreamableProvider(),
            adapter: MultiTokenStreamingAdapter(tokenCount: 3)
        ).makeApplication()

        try await app.test(.router) { client in
            let body = try streamingRequestBody(model: "stream-model")
            try await client.execute(
                uri: "/v1/chat/completions",
                method: .post,
                body: body
            ) { response in
                XCTAssertEqual(response.status, .ok)
                // SABOTAGE M1: change to "text/plain" to verify this assertion catches regressions
                XCTAssertEqual(response.headers[.contentType], "text/event-stream")
                XCTAssertEqual(response.headers[.cacheControl], "no-cache")
                XCTAssertEqual(response.headers[.connection], "keep-alive")
                XCTAssertEqual(
                    response.headers[HTTPField.Name("X-Accel-Buffering")!],
                    "no",
                    "X-Accel-Buffering: no disables nginx's response buffering for SSE"
                )
            }
        }
    }

    /// Every SSE data line (except `[DONE]`) must decode as
    /// ``ChatCompletionChunk`` — malformed JSON in the stream is a client
    /// breakage, not just a server inconvenience.
    func testStreamingChunksAreDecodableChatCompletionChunks() async throws {
        let tokenCount = 4
        let app = ServerApp(
            backendProvider: FixedStreamableProvider(),
            adapter: MultiTokenStreamingAdapter(tokenCount: tokenCount)
        ).makeApplication()

        try await app.test(.router) { client in
            let body = try streamingRequestBody(model: "stream-model")
            try await client.execute(
                uri: "/v1/chat/completions",
                method: .post,
                body: body
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let text = String(buffer: response.body)

                let decoder = JSONDecoder()
                let chunks = sseDataLines(in: text).compactMap { line -> ChatCompletionChunk? in
                    guard let data = line.data(using: .utf8) else { return nil }
                    return try? decoder.decode(ChatCompletionChunk.self, from: data)
                }

                // SABOTAGE M3: change 1 to tokenCount to verify the test catches
                //              a regressed single-chunk adapter
                XCTAssertGreaterThanOrEqual(
                    chunks.count, 1,
                    "At least one decodable ChatCompletionChunk expected; got 0"
                )
            }
        }
    }

    /// The stream must end with `data: [DONE]`.
    func testStreamingResponseEndsWithDoneSentinel() async throws {
        let app = ServerApp(
            backendProvider: FixedStreamableProvider(),
            adapter: MultiTokenStreamingAdapter(tokenCount: 2)
        ).makeApplication()

        try await app.test(.router) { client in
            let body = try streamingRequestBody(model: "stream-model")
            try await client.execute(
                uri: "/v1/chat/completions",
                method: .post,
                body: body
            ) { response in
                let text = String(buffer: response.body)
                // SABOTAGE M2: remove this assertion to verify tests detect missing [DONE]
                XCTAssertTrue(
                    text.contains("data: [DONE]"),
                    "SSE stream must terminate with 'data: [DONE]' sentinel. Got: \(text)"
                )
            }
        }
    }

    /// The final non-DONE chunk must carry a `finish_reason` of `.stop` so
    /// clients know the generation completed normally.
    func testStreamingFinalChunkCarriesStopFinishReason() async throws {
        let app = ServerApp(
            backendProvider: FixedStreamableProvider(),
            adapter: MultiTokenStreamingAdapter(tokenCount: 2)
        ).makeApplication()

        try await app.test(.router) { client in
            let body = try streamingRequestBody(model: "stream-model")
            try await client.execute(
                uri: "/v1/chat/completions",
                method: .post,
                body: body
            ) { response in
                let text = String(buffer: response.body)
                let decoder = JSONDecoder()
                let chunks = sseDataLines(in: text).compactMap { line -> ChatCompletionChunk? in
                    guard let data = line.data(using: .utf8) else { return nil }
                    return try? decoder.decode(ChatCompletionChunk.self, from: data)
                }

                let finalChunk = chunks.last
                XCTAssertEqual(
                    finalChunk?.choices.first?.finishReason,
                    .stop,
                    "The final SSE chunk must carry finishReason = .stop"
                )
            }
        }
    }

    /// All delivered tokens must be recoverable from the decoded chunks.
    func testStreamingChunksContainExpectedContent() async throws {
        let testToken = "§STREAM-TOKEN§"
        let app = ServerApp(
            backendProvider: FixedStreamableProvider(),
            adapter: FixedTokenStreamingAdapter(token: testToken, count: 3)
        ).makeApplication()

        try await app.test(.router) { client in
            let body = try streamingRequestBody(model: "stream-model")
            try await client.execute(
                uri: "/v1/chat/completions",
                method: .post,
                body: body
            ) { response in
                let text = String(buffer: response.body)
                let decoder = JSONDecoder()
                let chunks = sseDataLines(in: text).compactMap { line -> ChatCompletionChunk? in
                    guard let data = line.data(using: .utf8) else { return nil }
                    return try? decoder.decode(ChatCompletionChunk.self, from: data)
                }

                let combined = chunks.compactMap { $0.choices.first?.delta.content }.joined()
                XCTAssertTrue(
                    combined.contains(testToken),
                    "Combined chunk content must contain the test token. Got: \(combined)"
                )
            }
        }
    }

    // MARK: - Completion sanity

    /// Verifies a fully consumed stream completes without hanging.
    func testStreamingCompletesWithoutHanging() async throws {
        // Use many tokens to ensure the stream is non-trivial.
        let tokenCount = 20
        let app = ServerApp(
            backendProvider: FixedStreamableProvider(),
            adapter: MultiTokenStreamingAdapter(tokenCount: tokenCount)
        ).makeApplication()

        let startedAt = ContinuousClock.now
        try await app.test(.router) { client in
            let body = try streamingRequestBody(model: "stream-model")
            try await client.execute(
                uri: "/v1/chat/completions",
                method: .post,
                body: body
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let elapsed = ContinuousClock.now - startedAt
                // Stream must complete within a generous timeout (5 seconds).
                // A hang on a 20-token mock stream would surface here.
                XCTAssertLessThan(
                    elapsed,
                    .seconds(5),
                    "Stream must complete in under 5 seconds; suggests a hang in the SSE path"
                )
            }
        }
    }

    func testCancellingDefaultAdapterStreamStopsBackendWithin500Milliseconds() async throws {
        let backend = DisconnectTrackingBackend()
        let adapter = BlockingResponseAdapter()
        let request = ChatCompletionRequest(
            model: "stream-model",
            messages: [.init(role: "user", content: "stream this")],
            stream: true
        )
        let stream = try adapter.chunks(for: request, using: backend)
        let consumer = Task {
            for try await _ in stream {}
        }

        await waitUntil(timeout: .seconds(1)) {
            backend.isGenerating
        }
        XCTAssertTrue(backend.isGenerating, "Backend should be generating before simulating disconnect")

        consumer.cancel()

        await waitUntil(timeout: .milliseconds(500)) {
            !backend.isGenerating
        }
        backend.stopGeneration()
        _ = await consumer.result

        XCTAssertFalse(
            backend.isGenerating,
            "Client disconnect must call stopGeneration() so backend.isGenerating becomes false within 500 ms"
        )
    }
}

// MARK: - Helpers

private func streamingRequestBody(model: String) throws -> ByteBuffer {
    let request = ChatCompletionRequest(
        model: model,
        messages: [.init(role: "user", content: "stream this")],
        stream: true
    )
    return ByteBuffer(bytes: try JSONEncoder().encode(request))
}

/// Extracts JSON payloads from SSE `data:` lines, excluding `[DONE]`.
private func sseDataLines(in text: String) -> [String] {
    text.components(separatedBy: "\n\n")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { $0.hasPrefix("data: ") && $0 != "data: [DONE]" }
        .map { String($0.dropFirst("data: ".count)) }
}

private func waitUntil(
    timeout: Duration,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: @escaping () -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTAssertTrue(condition(), file: file, line: line)
}

// MARK: - Test doubles

/// Minimal ``ServerBackendProvider`` that always returns a fixed backend.
private struct FixedStreamableProvider: ServerBackendProvider {
    func listModels() async throws -> [String] { ["stream-model"] }
    func backend(for request: ServerBackendRequest) async throws -> any InferenceBackend {
        MockInferenceBackend()
    }
}

private final class DisconnectTrackingBackend: InferenceBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var _isGenerating = false
    private var continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation?

    var isModelLoaded: Bool { true }
    var isGenerating: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isGenerating
    }
    var capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true,
        supportsToolCalling: false,
        supportsStructuredOutput: false,
        cancellationStyle: .cooperative,
        supportsTokenCounting: false
    )

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws {}

    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig) throws -> GenerationStream {
        lock.lock()
        _isGenerating = true
        lock.unlock()

        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }
        return GenerationStream(stream)
    }

    func stopGeneration() {
        let continuation: AsyncThrowingStream<GenerationEvent, Error>.Continuation?
        lock.lock()
        _isGenerating = false
        continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }

    func unloadModel() {
        stopGeneration()
    }
}

private struct BlockingResponseAdapter: ChatCompletionsAdapter {
    func generationConfig(for request: ChatCompletionRequest) throws -> GenerationConfig {
        GenerationConfig()
    }

    func response(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) async throws -> ChatCompletionResponse {
        let stream = try backend.generate(
            prompt: "user: stream this",
            systemPrompt: nil,
            config: generationConfig(for: request)
        )
        for try await _ in stream.events {}
        return ChatCompletionResponse(id: "chatcmpl-blocking", model: request.model, content: "")
    }
}

/// Adapter that emits `n` numbered content tokens followed by a stop chunk.
/// All state is captured in value types so it is safe to call from concurrent
/// test runs without shared mutable state.
private struct MultiTokenStreamingAdapter: ChatCompletionsAdapter {
    let tokenCount: Int

    func generationConfig(for request: ChatCompletionRequest) throws -> GenerationConfig {
        GenerationConfig()
    }

    func response(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) async throws -> ChatCompletionResponse {
        ChatCompletionResponse(id: "chatcmpl-mt", model: request.model, content: "fallback")
    }

    func chunks(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) throws -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        let n = tokenCount
        let model = request.model
        return AsyncThrowingStream { continuation in
            for i in 0..<n {
                continuation.yield(ChatCompletionChunk(
                    id: "chatcmpl-mt",
                    created: 0,
                    model: model,
                    choices: [ChatCompletionChunkChoice(
                        index: 0,
                        delta: ChatCompletionDelta(content: "tok\(i) ")
                    )]
                ))
            }
            // Stop chunk — no content, finish_reason = .stop.
            continuation.yield(ChatCompletionChunk(
                id: "chatcmpl-mt",
                created: 0,
                model: model,
                choices: [ChatCompletionChunkChoice(
                    index: 0,
                    delta: ChatCompletionDelta(),
                    finishReason: .stop
                )]
            ))
            continuation.finish()
        }
    }
}

/// Adapter that emits `count` copies of a fixed `token` string, then a stop chunk.
private struct FixedTokenStreamingAdapter: ChatCompletionsAdapter {
    let token: String
    let count: Int

    func generationConfig(for request: ChatCompletionRequest) throws -> GenerationConfig {
        GenerationConfig()
    }

    func response(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) async throws -> ChatCompletionResponse {
        ChatCompletionResponse(id: "chatcmpl-ft", model: request.model, content: "fallback")
    }

    func chunks(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) throws -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        let tok = token
        let n = count
        let model = request.model
        return AsyncThrowingStream { continuation in
            for _ in 0..<n {
                continuation.yield(ChatCompletionChunk(
                    id: "chatcmpl-ft",
                    created: 0,
                    model: model,
                    choices: [ChatCompletionChunkChoice(
                        index: 0,
                        delta: ChatCompletionDelta(content: tok)
                    )]
                ))
            }
            continuation.yield(ChatCompletionChunk(
                id: "chatcmpl-ft",
                created: 0,
                model: model,
                choices: [ChatCompletionChunkChoice(
                    index: 0,
                    delta: ChatCompletionDelta(),
                    finishReason: .stop
                )]
            ))
            continuation.finish()
        }
    }
}

#endif
