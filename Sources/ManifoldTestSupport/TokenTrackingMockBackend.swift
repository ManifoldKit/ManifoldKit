import Foundation
import ManifoldInference

/// A mock backend that adopts ``TokenUsageProvider`` so that
/// ``InferenceService/lastTokenUsage`` returns non-nil after generation.
///
/// Supports both a single fixed usage value (``usageToReport``) and an ordered
/// sequence (``usageSequence``) so each successive generation can report distinct
/// token counts — useful for testing that usage is not cross-contaminated across
/// multiple messages.
///
/// Shared across test targets via ManifoldTestSupport.
public final class TokenTrackingMockBackend: InferenceBackend, TokenUsageProvider, @unchecked Sendable {
    public var isModelLoaded = true
    public var isGenerating = false
    public var capabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    public var tokensToYield: [String] = []
    public var lastUsage: (promptTokens: Int, completionTokens: Int)?

    /// Set before generation; the usage is recorded after the token stream finishes.
    public var usageToReport: (promptTokens: Int, completionTokens: Int)?

    /// When non-empty, successive calls draw from this queue in order.
    /// Each element is consumed once; the last element is reused once exhausted.
    public var usageSequence: [(promptTokens: Int, completionTokens: Int)] = []
    private var usageSequenceIndex = 0

    public init() {}

    public func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        isModelLoaded = true
    }

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        hints: GenerationRuntimeHints
    ) throws -> GenerationStream {
        isGenerating = true
        let tokens = tokensToYield

        // Draw from usageSequence if populated, otherwise fall back to usageToReport.
        let usage: (promptTokens: Int, completionTokens: Int)?
        if !usageSequence.isEmpty {
            let idx = min(usageSequenceIndex, usageSequence.count - 1)
            usage = usageSequence[idx]
            usageSequenceIndex += 1
        } else {
            usage = usageToReport
        }

        let stream = AsyncThrowingStream<GenerationEvent, Error> { [self] continuation in
            Task {
                for token in tokens {
                    if Task.isCancelled { break }
                    continuation.yield(.token(token))
                }
                self.lastUsage = usage
                self.isGenerating = false
                continuation.finish()
            }
        }
        return GenerationStream(stream)
    }

    public func stopGeneration() { isGenerating = false }
    public func unloadModel() { isModelLoaded = false; isGenerating = false }
}
