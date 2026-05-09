import XCTest

/// XCUITest coverage for the demo-scenario picker surface.
///
/// Layer-2 scope: verify the picker launches the scripted scenario, renders
/// the completed tool call, and shows the canned assistant answer. The app
/// swaps to `ScriptedBackend` under `--uitesting`, so these assertions stay
/// deterministic while still exercising the real UI surfaces.
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

    func test_worldClock_launchArg_rendersCompletedToolCallAndAnswer() {
        let app = launchDemoApp(scenario: "world-clock")
        openChatDetailIfNeeded(app: app)

        XCTAssertTrue(waitForChatInputReady(app: app, timeout: 30))
        XCTAssertTrue(
            app.descendants(matching: .any)["tool-invocation-completed-now"].waitForExistence(timeout: 20),
            "World-clock scenario should complete a now tool call"
        )

        let assistantBubble = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Assistant said: It's currently time in Tokyo.")
        ).firstMatch
        XCTAssertTrue(
            assistantBubble.waitForExistence(timeout: 10),
            "World-clock scenario should render the scripted assistant answer"
        )
    }

    func test_workspaceSearch_launchArg_rendersCompletedToolCallAndAnswer() {
        let app = launchDemoApp(scenario: "workspace-search")
        openChatDetailIfNeeded(app: app)

        XCTAssertTrue(waitForChatInputReady(app: app, timeout: 30))
        XCTAssertTrue(
            app.descendants(matching: .any)["tool-invocation-completed-sample_repo_search"].waitForExistence(timeout: 20),
            "Workspace-search scenario should complete the repo-search tool call"
        )

        let assistantBubble = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Assistant said: I found a match in your workspace mentioning MCP.")
        ).firstMatch
        XCTAssertTrue(
            assistantBubble.waitForExistence(timeout: 10),
            "Workspace-search scenario should render the scripted assistant answer"
        )
    }

    func test_journalWrite_launchArg_approvesToolCallAndWritesFile() {
        let sandboxRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManifoldDemoUITests-\(UUID().uuidString)", isDirectory: true)
        XCTAssertNoThrow(try FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true))
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: sandboxRoot)) }

        let app = launchDemoApp(
            scenario: "journal-write",
            environment: ["BASECHAT_DEMO_SANDBOX_ROOT": sandboxRoot.path]
        )
        openChatDetailIfNeeded(app: app)

        XCTAssertTrue(waitForChatInputReady(app: app, timeout: 30))

        let sendButton = app.buttons["Send message"]
        XCTAssertTrue(sendButton.waitForExistence(timeout: 10), "Journal-write scenario should leave the prompt ready to send")
        XCTAssertTrue(sendButton.isEnabled, "Send button should be enabled for the prefilled journal prompt")
        sendButton.tap()

        let approvalSheet = app.otherElements["approval-sheet"]
        XCTAssertTrue(
            approvalSheet.waitForExistence(timeout: 20),
            "Journal-write scenario should present the approval sheet"
        )
        app.buttons["approval-sheet-approve-button"].tap()

        XCTAssertTrue(
            app.descendants(matching: .any)["tool-invocation-completed-write_file"].waitForExistence(timeout: 20),
            "Approving the journal-write scenario should complete the write_file call"
        )

        let assistantBubble = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Assistant said: Saved today's journal entry.")
        ).firstMatch
        XCTAssertTrue(
            assistantBubble.waitForExistence(timeout: 10),
            "Journal-write scenario should render the scripted confirmation"
        )

        let writtenFile = sandboxRoot.appendingPathComponent("journal/today.md")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: writtenFile.path),
            "Approving the journal-write scenario should write journal/today.md inside the sandbox"
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
    private func launchDemoApp(
        scenario: String?,
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        if let scenario {
            app.launchArguments += ["--bck-demo-scenario", scenario]
        }
        app.launchEnvironment.merge(environment) { _, new in new }
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
