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

    /// Convenience factory: wires `AGENTS.md` ambient-instruction discovery
    /// into the prompt-context pipeline via ``AgentInstructionContextProvider``.
    ///
    /// The pipeline is consumed once, at `ConversationRuntime` construction
    /// time (`ManifoldBootstrap.build(...)` / `ManifoldBootstrap.init(...)`),
    /// so this must be set on the options **before** bootstrap runs — there is
    /// no equivalent of `addGenerationToolSources(viewModel:)` for adding a
    /// pipeline after the fact.
    ///
    /// ```swift
    /// let options = ConversationRuntimeOptions.withAgentInstructions(
    ///     currentDirectory: projectRoot
    /// )
    /// let (progress, task) = ManifoldBootstrap.build(
    ///     configuration: configuration,
    ///     runtimeOptions: options
    /// )
    /// ```
    ///
    /// This replaces the more verbose:
    /// ```swift
    /// var options = ConversationRuntimeOptions()
    /// options.pipeline = PromptContextPipeline(providers: [
    ///     AgentInstructionContextProvider(currentDirectory: projectRoot)
    /// ])
    /// ```
    ///
    /// - Parameters:
    ///   - currentDirectory: Starting point for the upward `AGENTS.md` walk;
    ///     typically the session's working directory or git root.
    ///   - stopDirectory: Walk stops here (inclusive). Defaults to the current
    ///     user's home directory — see ``AgentInstructionLoader/discover(from:stoppingAt:)``.
    /// - Note: **Opt-in by design** — calling this is the only way `AGENTS.md`
    ///   loading turns on. `ManifoldKit.quickStart(...)` does not call it, so a
    ///   quickStart bootstrap never loads `AGENTS.md` unless the host builds
    ///   its own `ConversationRuntimeOptions` this way and passes it through
    ///   the manual `ManifoldBootstrap.build(...)` path.
    public static func withAgentInstructions(
        currentDirectory: URL,
        stoppingAt stopDirectory: URL? = nil
    ) -> ConversationRuntimeOptions {
        var options = ConversationRuntimeOptions()
        options.pipeline = PromptContextPipeline(providers: [
            AgentInstructionContextProvider(
                currentDirectory: currentDirectory,
                stoppingAt: stopDirectory
            ),
        ])
        return options
    }
}
