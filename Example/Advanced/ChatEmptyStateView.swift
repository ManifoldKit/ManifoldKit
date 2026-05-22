import SwiftUI
import ManifoldUI

/// Empty-state shown in the chat detail area when the active session has no
/// messages yet.
///
/// Renders the demo-scenario picker — four tap-to-try cards covering:
/// single tool call (`tip-calc`), non-numeric arg (`world-clock`), text
/// search (`workspace-search`), and the per-call approval flow
/// (`journal-write`). Each tap creates a new session, prefills the composer
/// with the scenario's prompt, and (for auto-send scenarios) sends.
struct ChatEmptyStateView: View {

    @Environment(ChatViewModel.self) private var viewModel

    let runScenario: (DemoScenario) -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 36))
                .foregroundStyle(.tint)

            Text("Try a scenario")
                .font(.headline)

            Text("Each card runs a scripted prompt against a registered tool. Tap to see the full ManifoldKit loop in one go.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            scenarioGrid
                .padding(.horizontal, 24)

            Text("…or type your own question below.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(.vertical, 32)
    }

    @ViewBuilder
    private var scenarioGrid: some View {
        let columns = [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 12)]
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(DemoScenarios.all) { scenario in
                DemoScenarioCard(
                    scenario: scenario,
                    isEnabled: viewModel.isModelLoaded,
                    action: { runScenario(scenario) }
                )
            }
        }
    }
}
