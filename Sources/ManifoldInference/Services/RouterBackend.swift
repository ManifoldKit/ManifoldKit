import Foundation

/// Composes a list of child backends and dispatches each `generate(...)` call
/// to the first child whose ``BackendCapabilities`` satisfy the request's
/// ``GenerationConfig/requiredCapabilities``.
///
/// Useful for "small local for classification, larger local or remote for
/// reasoning" wiring without per-app glue. Single child per request — the
/// router does not fan out, retry across children, or load-balance.
///
/// Lifecycle delegation is intentionally narrow:
///
/// - `loadModel(from:plan:)` is **not** routed by capability — picking a
///   model is the host's job. ``RouterBackend`` itself does not load or
///   identify a single model; `isModelLoaded` reflects whether any child is
///   loaded. Use ``InferenceService`` (which holds one backend per model
///   type) for load orchestration; reach for ``RouterBackend`` only when a
///   single conceptual session multiplexes across already-loaded children.
/// - `stopGeneration()` and `unloadModel()` fan out to every child — a
///   request may be in flight on the most recently picked child, but other
///   children may also have state from previous calls.
/// - `resetConversation()` fans out for the same reason.
///
/// `capabilities` is the **union** of every child's capabilities (per-flag
/// OR; numeric maxima taken). This is the correct surface for a UI that
/// asks "can the runtime as a whole do X?" — for a per-request question
/// the right answer comes from `GenerationConfig.requiredCapabilities` and
/// the dispatch performed in `generate(...)`.
public final class RouterBackend: InferenceBackend, @unchecked Sendable {
    /// Children, in priority order. The first child satisfying a request's
    /// requirements is chosen.
    public let children: [any InferenceBackend]

    public init(children: [any InferenceBackend]) {
        // An empty router would produce a `.noBackendSatisfiesRequirements([])`
        // error on every `generate(...)` call — surfacing that at the wiring
        // site (host code that built the router) is far easier to debug than
        // having every request fail later with an empty diagnostic payload.
        precondition(
            !children.isEmpty,
            "RouterBackend requires at least one child backend"
        )
        self.children = children
    }

    public var isModelLoaded: Bool {
        // Any child with a loaded model means the runtime can serve a
        // request that it can satisfy.
        children.contains { $0.isModelLoaded }
    }

    public var isGenerating: Bool {
        children.contains { $0.isGenerating }
    }

    public var capabilities: BackendCapabilities {
        // Union semantics — see type doc-comment for why this surface is the
        // right answer for "can the runtime as a whole do X?". The merge lives
        // in `BackendCapabilities.union(_:)` so RouterBackend and FallbackBackend
        // share one implementation (extracted #1935).
        BackendCapabilities.union(children.map(\.capabilities))
    }

    /// Picks the first child whose capabilities satisfy `requirements`.
    ///
    /// Loaded children are preferred — if any loaded child satisfies, that
    /// one wins. Only when no loaded child can serve does the router fall
    /// back to an unloaded child that satisfies (so the error surfaces as
    /// "no model loaded" from the chosen backend, not as a routing failure).
    /// Public so hosts can do a dry-run check before issuing a request.
    public func selectBackend(
        for requirements: Set<GenerationCapabilityRequirement>
    ) -> (any InferenceBackend)? {
        let predicate: (any InferenceBackend) -> Bool = requirements.isEmpty
            ? { _ in true }
            : { $0.capabilities.satisfies(requirements) }
        if let loaded = children.first(where: { $0.isModelLoaded && predicate($0) }) {
            return loaded
        }
        return children.first(where: predicate)
    }

    public func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        // Loading is not a routing decision — the host owns model selection.
        // Surface as a config error so the wrong call site is obvious in tests.
        throw InferenceError.inferenceFailure(
            "RouterBackend does not load models — load each child backend before composing the router."
        )
    }

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        hints: GenerationRuntimeHints
    ) throws -> GenerationStream {
        let requirements = config.requiredCapabilities
        guard let chosen = selectBackend(for: requirements) else {
            // Compute the union of unsatisfied requirements across all children
            // so the error names exactly which capabilities the wired set lacks.
            // A requirement appears in the result only if no child satisfies it.
            let unmet = requirements.filter { req in
                children.allSatisfy { !$0.capabilities.satisfies(req) }
            }
            // Fall back to the full requirement list when the failure is per-child
            // partial coverage (every child fails some requirement, but no single
            // requirement is unmet by every child) — rare, but guards against
            // returning an empty diagnostic.
            let unsorted = unmet.isEmpty ? Array(requirements) : Array(unmet)
            // Sort for deterministic logs/diffs — `Set` iteration order is unstable.
            let payload = unsorted.sorted { $0.sortKey < $1.sortKey }
            throw InferenceError.noBackendSatisfiesRequirements(payload)
        }
        return try chosen.generate(
            prompt: prompt,
            systemPrompt: systemPrompt,
            config: config,
            hints: hints
        )
    }

    public func stopGeneration() {
        for child in children { child.stopGeneration() }
    }

    public func unloadModel() {
        for child in children { child.unloadModel() }
    }

    public func resetConversation() {
        for child in children { child.resetConversation() }
    }
}
