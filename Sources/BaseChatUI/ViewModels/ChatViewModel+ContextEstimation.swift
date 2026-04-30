import Foundation
import BaseChatRuntime
import BaseChatInference

// MARK: - ChatViewModel + Context Estimation

extension ChatViewModel {

    /// Recalculates the context usage estimate based on current messages.
    ///
    /// Uses a per-message token count cache to avoid re-estimating unchanged messages.
    func updateContextEstimate() {
        let estimator = ContextEstimator()
        let inputs = ContextEstimator.Inputs(
            messages: messages,
            systemPrompt: systemPrompt,
            modelContextLength: selectedModel?.detectedContextLength,
            contextSizeOverride: activeSession?.contextSizeOverride,
            backendMaxContextTokens: backendCapabilities.map { Int($0.maxContextTokens) },
            tokenizer: inferenceService.tokenizer,
            cache: tokenCountCache
        )
        let result = estimator.estimate(inputs)
        contextMaxTokens = result.maxTokens
        tokenCountCache = result.updatedCache
        contextUsedTokens = result.usedTokens
    }
}
