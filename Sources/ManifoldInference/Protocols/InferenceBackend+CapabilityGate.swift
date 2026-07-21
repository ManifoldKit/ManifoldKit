import Foundation

public extension InferenceBackend {

    /// Enforces ``GenerationConfig/requiredCapabilities`` against this backend's
    /// advertised ``InferenceBackend/capabilities`` and then generates.
    ///
    /// The capability gate previously lived **only** in `RouterBackend` — the
    /// footgun audit's class A ("cross-cutting invariant wired into one branch
    /// only"). A host that set `requiredCapabilities` and ran against a single
    /// concrete backend (no router) had the constraint silently ignored: the
    /// backend would generate anyway, downgrading (e.g. dropping tool calls or
    /// thinking) with no error. Routing every non-router dispatch through this
    /// wrapper makes fail-fast the default — the same `noBackendSatisfiesRequirements`
    /// error the router raises, raised at the single-backend boundary too.
    ///
    /// The guard is a no-op when `requiredCapabilities` is empty (the standard
    /// chat path), so it adds nothing to normal generation. When this backend is
    /// itself a `RouterBackend`, its merged capabilities pass the gate whenever
    /// some child can satisfy the request, and the router then performs precise
    /// per-child selection — the double check is benign.
    func generateEnforcingCapabilities(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        hints: GenerationRuntimeHints = GenerationRuntimeHints()
    ) throws -> GenerationStream {
        try enforceRequiredCapabilities(config.requiredCapabilities)
        return try generate(
            prompt: prompt,
            systemPrompt: systemPrompt,
            config: config,
            hints: hints
        )
    }

    /// Throws ``InferenceError/noBackendSatisfiesRequirements(_:)`` listing the
    /// unmet requirements (sorted for deterministic diagnostics) when this
    /// backend cannot satisfy `requirements`. No-op for an empty set.
    func enforceRequiredCapabilities(_ requirements: Set<GenerationCapabilityRequirement>) throws {
        guard !requirements.isEmpty, !capabilities.satisfies(requirements) else { return }
        let unmet = requirements
            .filter { !capabilities.satisfies($0) }
            .sorted { $0.sortKey < $1.sortKey }
        throw InferenceError.noBackendSatisfiesRequirements(unmet)
    }
}
