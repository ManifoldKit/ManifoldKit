#if Server
@testable import BaseChatServer
import BaseChatInference
import BaseChatTestSupport
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
        return try result.get()
    }

    func chunks(
        for request: ChatCompletionRequest,
        using backend: any InferenceBackend
    ) throws -> AsyncThrowingStream<ChatCompletionChunk, Error> {
        requests.append(request)
        let chunkResult = self.chunkResult
        return AsyncThrowingStream { continuation in
            switch chunkResult {
            case .success(let chunks):
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            case .failure(let error):
                continuation.finish(throwing: error)
            }
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
