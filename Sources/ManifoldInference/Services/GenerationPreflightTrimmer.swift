import Foundation

/// Performs exact tokenizer preflight and context-window trimming before a
/// prompt reaches a backend decode path.
struct GenerationPreflightTrimmer {
    struct Result {
        let prompt: String
        let trimmedMessages: [StructuredMessage]
    }

    let renderer: PromptRenderer
    let maxTrimAttempts: Int

    init(renderer: PromptRenderer, maxTrimAttempts: Int = 20) {
        self.renderer = renderer
        self.maxTrimAttempts = maxTrimAttempts
    }

    /// Convenience initializer for callers that only have a detected enum
    /// template and no embedded Jinja string (e.g. existing tests). Renders via
    /// the enum path only — no embedded-template preference.
    init(promptTemplate: PromptTemplate, maxTrimAttempts: Int = 20) {
        self.init(
            renderer: PromptRenderer(template: promptTemplate, chatTemplateRaw: nil),
            maxTrimAttempts: maxTrimAttempts
        )
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

        // Forward the live tool definitions on every render so a native tool
        // template emits its `{% if tools %}` block on this path too (#1909).
        // The renderer threads them on whichever branch executes; the caller's
        // `toolAugmentedSystemPrompt` decision (keyed on
        // `PromptRenderer.rendersToolsNatively`) guarantees the preamble is folded
        // only when the rendered prompt will *not* carry tools, so there is no
        // double injection.
        while true {
            // Renders the model's real embedded Jinja when present, else the
            // detected enum (#1811). The same renderer feeds the final prompt
            // sent to the backend, so the token count and the decoded prompt
            // always agree.
            // Suppress the capability-loss diagnostics inside the loop: this can
            // render up to `maxTrimAttempts` times before the prompt fits, and
            // the tool-drop / multimodal-drop warnings are a property of the turn
            // shape, not of any one trim attempt — emitting them per iteration
            // would spam the log. The returned prompt is re-rendered once below
            // with warnings enabled so the loss is reported exactly once.
            let prompt = try renderer.render(
                messages: workingMessages,
                systemPrompt: systemPrompt,
                tools: config.tools,
                documents: config.documents,
                warnOnCapabilityLoss: false
            )
            let promptTokens = try counter.countTokens(prompt)

            if promptTokens + maxOutput <= contextSize {
                // One warning-enabled render on the accepted message set. Cheap
                // (runs only on the success iteration) and uses the renderer's
                // own path detection, so a present-but-unusable embedded template
                // still correctly reports the tool-drop fallback.
                _ = try renderer.render(
                    messages: workingMessages,
                    systemPrompt: systemPrompt,
                    tools: config.tools,
                    documents: config.documents,
                    warnOnCapabilityLoss: true
                )
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
