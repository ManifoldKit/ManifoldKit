import XCTest

/// Deterministic UI tests for the tool-approval flow surfaces.
///
/// Runs against the demo app launched with `--uitesting`, which swaps in a
/// ``ScriptedBackend`` emitting a canned `.toolCall` for `sample_repo_search`.
/// No live Ollama / MLX / cloud traffic.
///
/// Scope: assert that the empty-state demo-scenario card renders
/// (existence-only — hittability is platform-dependent, since SwiftUI
/// renders the card as a button on iOS and a different element type on
/// macOS). The downstream approval sheet + completed-bubble rendering is
/// covered deterministically by ``UIToolApprovalGateTests`` and
/// ``ToolInvocationViewTests`` at the XCTest level, where we can observe
/// `@Observable` state changes directly. XCUITest's sheet-presentation
/// timing is flaky under simulator in the `--uitesting` pathway and would
/// add noise without adding information.
final class ToolApprovalUITests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func test_workspaceSearchScenarioCard_rendersInEmptyState() {
        let app = launchDemoApp()
        openChatDetailIfNeeded(app: app)

        XCTAssertTrue(
            waitForChatInputReady(app: app, timeout: 20),
            "Chat input should become hittable under --uitesting"
        )

        // Workspace-search is the closest analogue to the legacy
        // flagship-summarise-the-READMEs button — exercises the
        // `sample_repo_search` scripted tool path. We assert existence via
        // `descendants(matching: .any)` because SwiftUI may render the card
        // as a button on iOS and a different element on macOS; a
        // hittability assertion would be fragile across that platform
        // split, so we deliberately stop at existence.
        let card = app.descendants(matching: .any)["demo-card-workspace-search"]
        XCTAssertTrue(
            card.waitForExistence(timeout: 5),
            "workspace-search scenario card should render in the chat empty state"
        )
    }

    func test_sidebarToolPolicyButton_isReachable() {
        let app = launchDemoApp()

        showSidebarIfNeeded(app: app)
        let policyButton = app.buttons["sidebar-tool-policy-button"]
        XCTAssertTrue(
            policyButton.waitForExistence(timeout: 10),
            "Tool-policy picker button should be reachable from the sidebar"
        )
    }
}
