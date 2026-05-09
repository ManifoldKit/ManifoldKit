import Foundation
import ManifoldInference

/// A mock backend that conforms to both ``TokenizerVendor`` and ``TokenizerProvider``,
/// returning a configurable fixed token count for every string.
///
/// Use this in tests that need to verify a code path uses a real tokenizer rather
/// than the heuristic fallback.
public final class MockTokenizerVendorBackend: InferenceBackend,
                                               TokenizerVendor,
                                               TokenizerProvider,
                                               @unchecked Sendable {

    // MARK: - InferenceBackend

    public var isModelLoaded: Bool = true
    public var isGenerating: Bool = false
    public var capabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )
    public var tokensToYield: [String] = ["Hello", " world"]

    public func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        isModelLoaded = true
    }

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        guard isModelLoaded else { throw InferenceError.inferenceFailure("No model loaded") }
        isGenerating = true
        let tokens = tokensToYield
        let stream = AsyncThrowingStream<GenerationEvent, Error> { [self] continuation in
            Task {
                for token in tokens {
                    if Task.isCancelled { break }
                    continuation.yield(.token(token))
                }
                self.isGenerating = false
                continuation.finish()
            }
        }
        return GenerationStream(stream)
    }

    public func stopGeneration() { isGenerating = false }
    public func unloadModel() { isModelLoaded = false; isGenerating = false }

    // MARK: - TokenizerVendor + TokenizerProvider

    /// Fixed token count returned for every string. Set before the test runs.
    public var stubbedTokenCount: Int = 1

    public var tokenizer: any TokenizerProvider { self }

    public func tokenCount(_ text: String) -> Int { stubbedTokenCount }

    // MARK: - Init

    public init() {}
}
