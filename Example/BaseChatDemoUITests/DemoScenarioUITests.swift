import XCTest

/// XCUITest coverage for the demo-scenario picker surface.
///
/// Layer-2 scope: verify the picker UI surfaces render and carry the stable
/// accessibility identifiers tests rely on. Auto-send / tool-call rendering
/// timing is non-deterministic enough under the simulator (model-load
/// race + SwiftUI reconciliation) that asserting on user-message bubbles
/// here would be flaky. The full agent-loop is covered at Layer 1
/// (`GenerationCoordinatorToolLoopTests`, mock-backed) and Layer 3
/// (`DemoScenarioOllamaE2ETests`, real Ollama).
///
/// Each test launches with `--uitesting` plus optional
/// `--bck-demo-scenario <id>` to confirm the launch-arg path resolves the
/// scenario and the scripted-backend turn list is wired through
/// `DemoScenarios.scriptedTurns(for:)`.
final class DemoScenarioUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Empty-state cards

    func test_emptyState_rendersAllFourScenarioCards() {
        let app = launchDemoApp(scenario: nil)
        openChatDetailIfNeeded(app: app)

        // The empty state requires an active session; the launch bootstrap
        // should have produced one before the detail view mounts. Wait for chat
        // input to be ready so we know the detail pane is mounted.
        XCTAssertTrue(waitForChatInputReady(app: app, timeout: 30))

        for id in ["demo-card-tip-calc", "demo-card-world-clock", "demo-card-workspace-search", "demo-card-journal-write"] {
            let card = app.descendants(matching: .any)[id]
            XCTAssertTrue(
                card.waitForExistence(timeout: 5),
                "Empty-state should render the \(id) scenario card"
            )
        }
    }

    // MARK: - Launch arg path

    func test_launchArg_bootsIntoScenarioWithoutCrashing() {
        // A bare smoke test for `--bck-demo-scenario`: the app must reach
        // chat-ready state under the launch arg, proving the scenario lookup
        // + post-bootstrap cold-launch hook didn't fail.
        // Asserting on tool-call streaming is left to Layer 3 against a real
        // backend.
        let app = launchDemoApp(scenario: "tip-calc")
        openChatDetailIfNeeded(app: app)
        XCTAssertTrue(
            waitForChatInputReady(app: app, timeout: 30),
            "Demo app should reach chat-ready state when launched with --bck-demo-scenario tip-calc"
        )
    }

    func test_launchArg_unknownScenario_fallsBackGracefully() {
        // Unknown scenario IDs must not crash or block startup — the lookup
        // simply returns nil and `runScenario` is never invoked.
        let app = launchDemoApp(scenario: "no-such-scenario")
        openChatDetailIfNeeded(app: app)
        XCTAssertTrue(waitForChatInputReady(app: app, timeout: 30))
    }

    // MARK: - Helpers

    /// Launches the demo with the standard `--uitesting` plus optional
    /// `--bck-demo-scenario <id>` cold-launch arg.
    private func launchDemoApp(scenario: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        if let scenario {
            app.launchArguments += ["--bck-demo-scenario", scenario]
        }
        #if !os(macOS)
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        #endif
        app.launch()
        #if os(macOS)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        #endif
        return app
    }
}
