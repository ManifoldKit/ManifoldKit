import Foundation
import ManifoldInference
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
    /// 3. Create a new session, activate it on `sessionManager`, and then
    ///    call `chat.switchToSession(session)` directly. `DemoContentView`'s
    ///    `onChange(of: sessionManager.activeSession)` also calls
    ///    `switchToSession` — but onChange runs on the next view-update
    ///    cycle, so `chat.activeSessionID` could still hold the previous
    ///    value when `sendMessage()` runs below. Doing the switch here
    ///    makes the sequencing deterministic; the onChange path stays in
    ///    place for sidebar-driven switches.
    /// 4. Prefill the composer and, when `autoSend` is true, send.
    static func run(
        _ scenario: DemoScenario,
        chat: ChatViewModel,
        sessions: SessionManagerViewModel,
        registry: ToolRegistry,
        sandboxRoot: URL
    ) async {
        guard !chat.isGenerating else { return }

        DemoTools.resetToDefaults(on: registry, root: sandboxRoot)
        scenario.configure?(registry)

        do {
            let session = try await sessions.createSession(title: scenario.title)
            sessions.activeSession = session
            // Deterministic switch — don't wait on the onChange propagation
            // cycle in DemoContentView. See the sequence doc above.
            await chat.switchToSession(session)
        } catch {
            chat.errorMessage = "Failed to start scenario: \(error.localizedDescription)"
            return
        }

        chat.systemPrompt = scenario.systemPrompt
        chat.inputText = scenario.prompt
        if scenario.autoSend {
            await chat.sendMessage()
        }
    }
}
