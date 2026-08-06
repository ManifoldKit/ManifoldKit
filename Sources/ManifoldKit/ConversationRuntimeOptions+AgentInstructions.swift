// ConversationRuntimeOptions+AgentInstructions.swift
//
// Convenience wiring that bridges ManifoldRuntime's PromptContextPipeline seam
// (ConversationRuntimeOptions.pipeline) with ManifoldAgentInstructions'
// AGENTS.md ambient-instruction loader. Lives in the ManifoldKit umbrella —
// the only target that imports both ManifoldRuntime and
// ManifoldAgentInstructions — to avoid a layering violation (mirrors
// ManifoldBootstrap+GenerationToolSources.swift's bridge shape).
//
// ManifoldAgentInstructions itself depends on ManifoldInference ONLY, so it
// stays linkable without pulling in the runtime — this file is where the two
// meet, for hosts that want the one-call recipe instead of composing
// PromptContextPipeline by hand.

import Foundation
import ManifoldAgentInstructions
import ManifoldRuntime

extension ConversationRuntimeOptions {

    /// Wires `AGENTS.md` ambient-instruction discovery into the
    /// prompt-context pipeline via ``AgentInstructionContextProvider``,
    /// adding to any pipeline already configured rather than replacing it —
    /// the same *add* shape as `ManifoldBootstrap.addGenerationToolSources(viewModel:)`.
    ///
    /// Call this **before** bootstrap runs, after configuring any other
    /// `ConversationRuntimeOptions` fields you need — a `mutating func` on
    /// the caller's own options value, not a factory that replaces it:
    ///
    /// ```swift
    /// var options = ConversationRuntimeOptions()
    /// options.generationHooks = [MyHook()]
    /// options.addAgentInstructions(currentDirectory: projectRoot)
    /// let (progress, task) = ManifoldBootstrap.build(
    ///     configuration: configuration,
    ///     runtimeOptions: options
    /// )
    /// ```
    ///
    /// The pipeline is consumed once, at `ConversationRuntime` construction
    /// time, so this must run before `ManifoldBootstrap.build(...)` /
    /// `ManifoldBootstrap.init(...)` — there is no equivalent of
    /// `addGenerationToolSources(viewModel:)` for adding a pipeline after
    /// the fact.
    ///
    /// - Parameters:
    ///   - currentDirectory: Starting point for the upward `AGENTS.md` walk;
    ///     typically the session's working directory or git root.
    ///   - stopDirectory: Walk stops here (inclusive). Defaults to the current
    ///     user's home directory — see ``AgentInstructionLoader/discover(from:stoppingAt:)``.
    ///
    /// - Note: **Security.** `AGENTS.md` files are untrusted on-disk
    ///   content — anything in them is merged verbatim into the model's
    ///   system preamble and treated as an instruction. That is inherent to
    ///   the ambient-instruction format (every major agent tool that reads
    ///   it works the same way), not a defect, but it means a host pointing
    ///   `currentDirectory` at a directory it does not control (an
    ///   unreviewed clone, a user-selected folder) is choosing to trust
    ///   whatever text is there.
    /// - Note: **Platform.** macOS-only in v1 — on iOS this call still
    ///   succeeds and `.pipeline` is non-nil, but
    ///   `AgentInstructionLoader.discover(from:stoppingAt:)` always returns
    ///   zero results (logged once) and the turn loop runs normally with no
    ///   error. There is no signal at the call site that distinguishes "no
    ///   `AGENTS.md` found" from "unsupported platform."
    /// - Note: **Sandboxed apps.** The default `stopDirectory` (the current
    ///   user's home directory) resolves to the app's **container**
    ///   directory in a sandboxed macOS app, not the real `$HOME` a user
    ///   would expect. If `currentDirectory` is a user-selected folder
    ///   outside the container (e.g. via an open panel / security-scoped
    ///   bookmark), the walk's containment guard rejects it and
    ///   `discover(from:stoppingAt:)` returns `[]` with only a log line —
    ///   pass an explicit `stopDirectory` that actually bounds the intended
    ///   tree in that case.
    public mutating func addAgentInstructions(
        currentDirectory: URL,
        stoppingAt stopDirectory: URL? = nil
    ) {
        let agentsProvider = AgentInstructionContextProvider(
            currentDirectory: currentDirectory,
            stoppingAt: stopDirectory
        )
        if let existingPipeline = pipeline {
            // Compose rather than replace: wrap the existing pipeline as a
            // single provider so both it and AGENTS.md contribute slots,
            // instead of silently discarding whatever the host already
            // configured.
            pipeline = PromptContextPipeline(providers: [
                ExistingPipelineProvider(pipeline: existingPipeline),
                agentsProvider,
            ])
        } else {
            pipeline = PromptContextPipeline(providers: [agentsProvider])
        }
    }
}

/// Adapts an already-constructed `PromptContextPipeline` into a single
/// `PromptContextProvider` so `addAgentInstructions(currentDirectory:stoppingAt:)`
/// can compose with a host's existing pipeline instead of replacing it.
/// `PromptContextPipeline` does not expose its registered providers, so
/// wrapping the whole pipeline as one provider is how this composes without
/// widening `ManifoldRuntime`'s public surface.
private struct ExistingPipelineProvider: PromptContextProvider {
    let pipeline: PromptContextPipeline

    func contributeSlots(messageCount: Int) async throws -> [PromptSlot] {
        try await pipeline.assemble(messageCount: messageCount)
    }

    func contributeSlots(budget: ProviderBudget, context: TurnContext) async throws -> [PromptSlot] {
        try await pipeline.assemble(
            totalBudget: budget.allocated,
            contextSize: budget.totalContextSize,
            context: context
        )
    }
}
