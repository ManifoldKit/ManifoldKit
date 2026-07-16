#if Server
@testable import ManifoldServer
import ManifoldInference
import ManifoldTestSupport
import Foundation

final class FakeServerBackendProvider: ServerBackendProvider, @unchecked Sendable {
    enum ProviderError: Error, Equatable {
        case unavailable
    }

    var models: [String]
    var backendResult: Result<any InferenceBackend, Error>
    private(set) var listModelsCallCount = 0
    private(set) var backendRequests: [ServerBackendRequest] = []

    init(
        models: [String] = ["fake-model"],
        backend: any InferenceBackend = MockInferenceBackend()
    ) {
        self.models = models
        self.backendResult = .success(backend)
    }

    init(models: [String] = [], backendError: Error = ProviderError.unavailable) {
        self.models = models
        self.backendResult = .failure(backendError)
    }

    func listModels() async throws -> [String] {
        listModelsCallCount += 1
        return models
    }

    func backend(for request: ServerBackendRequest) async throws -> any InferenceBackend {
        backendRequests.append(request)
        return try backendResult.get()
    }
}

final class FakeChatCompletionsAdapter: ChatCompletionsAdapter, @unchecked Sendable {
    var result: Result<ChatCompletionResponse, Error>
    var chunkResult: Result<[ChatCompletionChunk], Error>
    private(set) var requests: [ChatCompletionRequest] = []

    /// When set, `response(for:using:)` never returns and never observes
    /// cancellation — a `withCheckedContinuation` whose continuation is never
    /// resumed. Simulates a genuinely stuck backend call (a wedged network
    /// request), the case `ServerGenerationTimeout`'s unstructured-task race
    /// (rather than `withThrowingTaskGroup`) exists to bound: see
    /// `ServerGenerationTimeoutTests`.
    var hangsForever = false

    /// When set, `chunks(for:using:)` yields one chunk and then hangs forever
    /// (same never-resumed-continuation shape as `hangsForever`) instead of
    /// finishing. Used to prove the streaming idle timeout actually fires on
    /// a stalled backend.
    var hangsAfterFirstChunk = false

    /// When set, `chunks(for:using:)` paces each yielded chunk by this delay
    /// instead of emitting them all synchronously. Used to prove the idle
    /// timeout resets per-chunk rather than applying a wall-clock cap over
    /// the whole stream (#2265).
    var chunkPacing: Duration?

    init(response: ChatCompletionResponse = ChatCompletionResponse(model: "fake-model", content: "fake response")) {
        self.result = .success(response)
        self.chunkResult = .success([
            ChatCompletionChunk(
                id: response.id,
                created: response.created,
                model: response.model,
                choices: [ChatCompletionChunkChoice(index: 0, delta: ChatCompletionDelta(content: response.content))]
            )
        ])
    }

    /// Convenience for streaming-pacing tests that want several distinct
    /// chunks (rather than the single-chunk default) spread across the pace.
    init(chunkedResponse response: ChatCompletionResponse, tokens: [String]) {
        self.result = .success(response)
        self.chunkResult = .success(tokens.map { token in
            ChatCompletionChunk(
                id: response.id,
                created: response.created,
                model: response.model,
                choices: [ChatCompletionChunkChoice(index: 0, delta: ChatCompletionDelta(content: token))]
            )
        })
    }

    init(error: Error) {
        self.result = .failure(error)
        self.chunkResult = .failure(error)
    }

    func generationConfig(for request: ChatCompletionRequest) throws -> GenerationConfig {
        GenerationConfig()
    }

    func response(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) async throws -> ChatCompletionResponse {
        requests.append(request)
        if hangsForever {
            // Never resumes — not even on cancellation — so a caller can only
            // observe completion via an external race (ServerGenerationTimeout),
            // never by awaiting this call to return.
            return try await withCheckedThrowingContinuation { _ in }
        }
        return try result.get()
    }

    func chunks(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) throws -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        requests.append(request)
        let chunkResult = self.chunkResult
        let hangsAfterFirstChunk = self.hangsAfterFirstChunk
        let chunkPacing = self.chunkPacing
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch chunkResult {
                case .success(let chunks):
                    for chunk in chunks {
                        if let chunkPacing {
                            do {
                                try await Task.sleep(for: chunkPacing)
                            } catch {
                                return
                            }
                        }
                        continuation.yield(chunk)
                    }
                    if hangsAfterFirstChunk {
                        // Suspend forever without finishing — the terminal
                        // ManifoldServer-side idle timeout is the only thing
                        // that can end this stream.
                        try? await Task.sleep(for: .seconds(3600))
                        return
                    }
                    continuation.finish()
                case .failure(let error):
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

enum ServerTestBackendFactory {
    static func loadedMock(tokens: [String] = ["Hello", " world"]) -> MockInferenceBackend {
        let backend = MockInferenceBackend()
        backend.isModelLoaded = true
        backend.tokensToYield = tokens
        return backend
    }
}

#endif
