import Foundation
import ManifoldInference

// MARK: - ContextEstimator

/// Pure token-budget calculator for the chat context window.
///
/// Extracted from `ChatViewModel` (phase 2 of #329) so estimation is a value-type
/// function of its inputs — the owning view model is still responsible for
/// holding the mutable caches and publishing the results.
struct ContextEstimator {

    struct Inputs {
        let messages: [ChatMessage]
        let systemPrompt: String
        let modelContextLength: Int?
        let contextSizeOverride: Int?
        let backendMaxContextTokens: Int?
        let tokenizer: (any TokenizerProvider)?
        let cache: [UUID: Int]
    }

    struct Result {
        let usedTokens: Int
        let maxTokens: Int
        let updatedCache: [UUID: Int]
    }

    func estimate(_ inputs: Inputs) -> Result {
        let maxTokens = ContextWindowManager.resolveContextSize(
            sessionOverride: inputs.contextSizeOverride,
            modelContextLength: inputs.modelContextLength,
            backendMaxTokens: inputs.backendMaxContextTokens,
            defaultSize: 2048
        )

        let systemTokens = ContextWindowManager.estimateTokenCount(
            inputs.systemPrompt,
            tokenizer: inputs.tokenizer
        )

        var messageTokens = 0
        var newCache: [UUID: Int] = [:]
        for message in inputs.messages {
            let count: Int
            if let cached = inputs.cache[message.id] {
                count = cached
            } else {
                count = ContextWindowManager.estimateTokenCount(
                    message.content,
                    tokenizer: inputs.tokenizer
                )
            }
            newCache[message.id] = count
            messageTokens += count
        }

        return Result(
            usedTokens: systemTokens + messageTokens,
            maxTokens: maxTokens,
            updatedCache: newCache
        )
    }
}
