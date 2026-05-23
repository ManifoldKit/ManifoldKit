import Foundation
import ManifoldInference

/// Declarative description of a tap-to-try demonstration in ManifoldDemo.
///
/// Each scenario is consumed three ways:
/// 1. As a card on the empty-state surface in `ChatEmptyStateView`.
/// 2. As a menu item in the `Demos` toolbar menu.
/// 3. As a launch-arg target — XCUITests pass `--bck-demo-scenario <id>` to
///    boot directly into the scenario with the scripted mock backend.
///
/// Adding a new scenario is intentionally a one-file change here plus a
/// matching scripted-turn entry in `DemoScenarios+Scripts.swift`.
struct DemoScenario: Identifiable, Sendable {

    /// Stable identifier — referenced by tests and the launch arg. Renaming
    /// is a breaking change for any external XCUITest harness that scripts
    /// the demo by ID.
    let id: String

    let title: String

    /// One-line subtitle shown beneath the title on the card.
    let blurb: String

    /// SF Symbol rendered on the scenario card.
    let systemImage: String

    /// Prompt prefilled into the chat composer when the scenario is launched.
    let prompt: String

    /// Scenario-specific system prompt installed before the prompt is sent.
    ///
    /// Keeps the demo cards honest on real backends by steering the model
    /// toward the intended tool and argument shape instead of relying on the
    /// currently-selected model to infer the demo contract on its own.
    let systemPrompt: String

    /// Tool names the scenario is expected to invoke. Asserted loosely by
    /// the Layer 3 E2E suite (a model may pick a near-synonym) and exactly
    /// by the Layer 1 unit suite (where the mock backend is scripted).
    let expectedTools: [String]

    /// When `true`, the runner sends the prompt automatically. When `false`,
    /// the prompt is left in the composer so the user reviews it before
    /// triggering side-effecting tools (e.g. `journal-write`).
    let autoSend: Bool

    /// Accessibility identifier for the scenario card and menu item. Used
    /// by Layer 2 XCUITests.
    let accessibilityID: String

    /// Forward-compatibility hook for scenarios that need variant tool
    /// executors (e.g. a deliberately-slow `sample_repo_search` for the
    /// cancellation scenario, or an oversized `read_file` for the output
    /// policy scenario). The runner snapshots back to the baseline tool set
    /// before each scenario, then invokes this closure to install variants.
    /// `nil` for the four P1 scenarios — they share the global demo tool set.
    let configure: (@MainActor @Sendable (ToolRegistry) -> Void)?

    /// Synthetic `transfer_to_<agent>` tool names the scenario is expected to
    /// emit. Asserted loudly by the W3B scripted UITest harness — the demo
    /// fails clearly when a handoff fails to materialise (per plan §Demo
    /// realism / AI reviewer fix #9). `nil` for scenarios that don't exercise
    /// agent handoffs.
    let expectedHandoffs: [String]?

    /// Minimum model capability tier under which the scenario produces a
    /// reliable demonstration. Used by the empty-state card to surface an
    /// "install a larger model" hint when the active model is below the bar,
    /// preventing the silent-failure anti-pattern where a small local model
    /// produces inconsistent output on a flagship-shaped demo. `nil` means
    /// any tier is fine.
    let minCapableModel: ModelCapabilityTier?

    init(
        id: String,
        title: String,
        blurb: String,
        systemImage: String,
        prompt: String,
        systemPrompt: String,
        expectedTools: [String],
        autoSend: Bool,
        accessibilityID: String,
        configure: (@MainActor @Sendable (ToolRegistry) -> Void)? = nil,
        expectedHandoffs: [String]? = nil,
        minCapableModel: ModelCapabilityTier? = nil
    ) {
        self.id = id
        self.title = title
        self.blurb = blurb
        self.systemImage = systemImage
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.expectedTools = expectedTools
        self.autoSend = autoSend
        self.accessibilityID = accessibilityID
        self.configure = configure
        self.expectedHandoffs = expectedHandoffs
        self.minCapableModel = minCapableModel
    }
}
