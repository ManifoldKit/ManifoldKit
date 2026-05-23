import Foundation
import ManifoldInference
import ManifoldRuntime
import ManifoldUI

/// Composition seam shared by every entry point that launches a scenario:
/// empty-state cards, the toolbar `Demos` menu, and the `--bck-demo-scenario`
/// launch-arg path on cold launch.
@MainActor
enum DemoScenarioRunner {

    /// Executes `scenario` against the supplied view models.
    ///
    /// Sequence:
    /// 1. Bail when generation is in flight — avoids racing the new session
    ///    against an active stream.
    /// 2. Reset the registry to the baseline tool set, then invoke the
    ///    scenario's optional `configure` closure to install variants.
    /// 3. Build a fresh ``DemoScenarioRuntimeContext`` and invoke the
    ///    optional ``DemoScenario/configureContext`` so the scenario can
    ///    attach agents, session tool sources, or a hook registry.
    /// 4. Create a new session, activate it on `sessionManager`, and then
    ///    call `chat.switchToSession(session)` directly. `DemoContentView`'s
    ///    `onChange(of: sessionManager.activeSession)` also calls
    ///    `switchToSession` — but onChange runs on the next view-update
    ///    cycle, so `chat.activeSessionID` could still hold the previous
    ///    value when `sendMessage()` runs below. Doing the switch here
    ///    makes the sequencing deterministic; the onChange path stays in
    ///    place for sidebar-driven switches.
    /// 5. If `sessionStore` is supplied AND the scenario populated
    ///    `agents`/`activeAgentID`, persist them onto the session record
    ///    before the first prompt is sent.
    /// 6. Prefill the composer and, when `autoSend` is true, send.
    static func run(
        _ scenario: DemoScenario,
        chat: ChatViewModel,
        sessions: SessionManagerViewModel,
        registry: ToolRegistry,
        sandboxRoot: URL,
        sessionStore: (any SessionStore)? = nil
    ) async {
        guard !chat.isGenerating else { return }

        DemoTools.resetToDefaults(on: registry, root: sandboxRoot)
        scenario.configure?(registry)

        var context = DemoScenarioRuntimeContext(toolRegistry: registry)
        scenario.configureContext?(&context)

        do {
            let session = try await sessions.createSession(title: scenario.title)
            sessions.activeSession = session
            // Deterministic switch — don't wait on the onChange propagation
            // cycle in DemoContentView. See the sequence doc above.
            await chat.switchToSession(session)

            // Persist agents/activeAgentID if the scenario populated them.
            // The scenario authored these values inside `configureContext`;
            // we apply them via SessionStore so the runtime sees them on
            // the next turn.
            if let sessionStore, !context.agents.isEmpty || context.activeAgentID != nil {
                var record = session
                record.agents = context.agents
                // Guard against a dangling activeAgentID pointer rather
                // than persisting it.
                if let active = context.activeAgentID,
                   context.agents.contains(where: { $0.id == active }) {
                    record.activeAgentID = active
                } else if context.activeAgentID != nil {
                    Log.ui.warning("DemoScenarioRunner: scenario \(scenario.id, privacy: .public) set activeAgentID that doesn't match any agent — clearing")
                    record.activeAgentID = nil
                }
                do {
                    try await sessionStore.updateSession(record)
                } catch {
                    Log.ui.warning("DemoScenarioRunner: failed to persist agents for \(scenario.id, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
        } catch {
            chat.errorMessage = "Failed to start scenario: \(error.localizedDescription)"
            return
        }

        chat.systemPrompt = scenario.systemPrompt
        chat.inputText = scenario.prompt
        if scenario.autoSend || CommandLine.arguments.contains("--bck-demo-autosend-scenario") {
            do {
                _ = try await chat.sendMessage(scenario.prompt)
            } catch {
                chat.errorMessage = "Failed to run scenario: \(error.localizedDescription)"
            }
        }
    }
}
