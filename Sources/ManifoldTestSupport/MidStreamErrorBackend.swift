import Foundation
import ManifoldInference

/// A mock backend that yields a configurable list of tokens then throws an error,
/// enabling tests to verify mid-stream error handling.
///
/// Shared across test targets via ManifoldTestSupport.
public final class MidStreamErrorBackend: InferenceBackend, @unchecked Sendable {
    public var isModelLoaded: Bool = true
    public var isGenerating: Bool = false
    public var capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    public var tokensBeforeError: [String]
    public var errorToThrow: Error

    public init(
        tokensBeforeError: [String] = ["partial"],
        errorToThrow: Error = NSError(
            domain: "test",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "stream boom"]
        )
    ) {
        self.tokensBeforeError = tokensBeforeError
        self.errorToThrow = errorToThrow
    }

    public func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        isModelLoaded = true
    }

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        let tokens = tokensBeforeError
        let error = errorToThrow
        isGenerating = true
        let stream = AsyncThrowingStream<GenerationEvent, Error> { [self] continuation in
            Task {
                for token in tokens {
                    if Task.isCancelled { break }
                    continuation.yield(.token(token))
                }
                self.isGenerating = false
                continuation.finish(throwing: error)
            }
        }
        return GenerationStream(stream)
    }

    public func stopGeneration() { isGenerating = false }
    public func unloadModel() { isModelLoaded = false; isGenerating = false }
}
