import Foundation

/// Performs exact tokenizer preflight and context-window trimming before a
/// prompt reaches a backend decode path.
struct GenerationPreflightTrimmer {
    struct Result {
        let prompt: String
        let trimmedMessages: [StructuredMessage]
    }

    let promptTemplate: PromptTemplate
    let maxTrimAttempts: Int

    init(promptTemplate: PromptTemplate, maxTrimAttempts: Int = 20) {
        self.promptTemplate = promptTemplate
        self.maxTrimAttempts = maxTrimAttempts
    }

    /// Counts tokens on the assembled prompt and trims the oldest non-system
    /// messages until the prompt fits inside the context window.
    ///
    /// Up to `maxTrimAttempts` trimming rounds are performed. Each round drops
    /// one non-system message from the front of the history. If the budget is
    /// still exceeded after all attempts, throws
    /// ``InferenceError/contextExhausted(promptTokens:maxOutputTokens:contextSize:)``.
    func exactPreflightAndTrim(
        counter: TokenCountingBackend,
        backend: InferenceBackend,
        messages: [StructuredMessage],
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> Result {
        let contextSize = Int(backend.capabilities.maxContextTokens)
        // Reserve context for both visible output and (optionally) thinking output.
        //
        // Rationale for `?? 0` on the thinking side (not `?? 2048`): the public
        // semantics of `maxThinkingTokens` today are "cap reasoning output; nil
        // means no client-side cap." Reserving a fixed slice of the context
        // window for thinking by default would silently eat that many tokens
        // from every prompt — including on non-thinking models where it has no
        // effect on runtime behaviour. Principle of least surprise: only
        // reserve what the caller explicitly asked for. Callers who know they
        // are driving a reasoning model can opt in by setting
        // `maxThinkingTokens: N`, which then becomes the trim reservation.
        let visibleReserve = config.maxOutputTokens ?? 2048
        let thinkingReserve = config.maxThinkingTokens ?? 0
        let maxOutput = visibleReserve + thinkingReserve

        var workingMessages = messages
        var attempt = 0

        while true {
            let prompt = promptTemplate.format(
                messages: GenerationHistoryInstaller.flatten(workingMessages),
                systemPrompt: systemPrompt
            )
            let promptTokens = try counter.countTokens(prompt)

            if promptTokens + maxOutput <= contextSize {
                return Result(prompt: prompt, trimmedMessages: workingMessages)
            }

            guard attempt < maxTrimAttempts else {
                throw InferenceError.contextExhausted(
                    promptTokens: promptTokens,
                    maxOutputTokens: maxOutput,
                    contextSize: contextSize
                )
            }

            guard let dropIndex = workingMessages.firstIndex(where: { $0.role != "system" }) else {
                throw InferenceError.contextExhausted(
                    promptTokens: promptTokens,
                    maxOutputTokens: maxOutput,
                    contextSize: contextSize
                )
            }

            let userCount = workingMessages.filter { $0.role == "user" }.count
            if userCount <= 1 && workingMessages[dropIndex].role == "user" {
                throw InferenceError.contextExhausted(
                    promptTokens: promptTokens,
                    maxOutputTokens: maxOutput,
                    contextSize: contextSize
                )
            }

            Log.inference.warning(
                "GenerationQueue: prompt over budget — trimming oldest non-system message (attempt \(attempt + 1)/\(maxTrimAttempts))"
            )
            workingMessages.remove(at: dropIndex)
            attempt += 1
        }
    }
}
