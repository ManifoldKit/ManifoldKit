import XCTest

/// XCUITest coverage for the demo-scenario picker surface.
///
/// Layer-2 scope: verify the picker exposes every scripted scenario and that
/// each `--bck-demo-scenario` launch arg reaches the canned assistant answer.
/// Each test launches with `--uitesting` plus optional
/// `--bck-demo-scenario <id>` to confirm the launch-arg path resolves the
/// scenario and the scripted-backend turn list is wired through
/// `DemoScenarios.scriptedTurns(for:)`.
final class DemoScenarioUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Empty-state cards

    private struct ScenarioExpectation {
        let id: String
        let cardID: String
        let completedTools: [String]
        let failedTools: [String]
        let assistantAnswer: String?
    }

    private let scenarioExpectations: [ScenarioExpectation] = [
        ScenarioExpectation(
            id: "tip-calc",
            cardID: "demo-card-tip-calc",
            completedTools: ["calc"],
            failedTools: [],
            assistantAnswer: "An 18% tip on $73.40 is $13.21. Each person's share is about $21.65."
        ),
        ScenarioExpectation(
            id: "world-clock",
            cardID: "demo-card-world-clock",
            completedTools: ["now"],
            failedTools: [],
            assistantAnswer: "It's currently time in Tokyo."
        ),
        ScenarioExpectation(
            id: "workspace-search",
            cardID: "demo-card-workspace-search",
            completedTools: ["sample_repo_search"],
            failedTools: [],
            assistantAnswer: "I found a match in your workspace mentioning MCP."
        ),
        ScenarioExpectation(
            id: "invalid-args-recover",
            cardID: "demo-card-invalid-args-recover",
            completedTools: ["calc"],
            failedTools: ["calc"],
            assistantAnswer: "Dividing by zero isn't defined, but 100 ÷ 4 is 25."
        ),
        ScenarioExpectation(
            id: "rate-limited-retry",
            cardID: "demo-card-rate-limited-retry",
            completedTools: ["fakeRateLimited"],
            failedTools: ["fakeRateLimited"],
            assistantAnswer: "The first call was rate-limited, but the retry succeeded."
        ),
        ScenarioExpectation(
            id: "mcp-tool-failure",
            cardID: "demo-card-mcp-tool-failure",
            completedTools: [],
            failedTools: ["fakeMCPLookup"],
            assistantAnswer: "The MCP lookup failed: the remote server is unreachable."
        ),
        ScenarioExpectation(
            id: "mcp-echo",
            cardID: "demo-card-mcp-echo",
            completedTools: [],
            failedTools: ["everything__echo"],
            assistantAnswer: "The MCP echo server replied: 'Hello from ManifoldKit'."
        ),
        // MARK: W3B scenarios
        // skill-explain: scripted invoke_skill dispatch via bundled SKILL.md.
        // The scripted backend treats unregistered tool names as failed
        // invocations so we assert against tool-invocation-failed-invoke_skill
        // — same shape as `mcp-echo` whose `everything__echo` only exists
        // after the user connects. The scripted answer is what matters here.
        ScenarioExpectation(
            id: "skill-explain",
            cardID: "demo-card-skill-explain",
            completedTools: [],
            failedTools: ["invoke_skill"],
            assistantAnswer: "An actor in Swift is a reference type that protects its mutable state behind an isolation boundary."
        ),
        // handoff-research-write: transfer_to_writer is a genuine handoff
        // (Researcher's session carries a real agent roster via
        // configureContext, so ConversationTurnExecutor's handoffDetector
        // intercepts the call rather than routing it through normal tool
        // dispatch — see HandoffDetector.classify). The turn that emits it
        // persists as a *completed* tool invocation (TurnStreamFinalizer
        // synthesizes a success ToolResult so the UI doesn't show a stuck
        // "running" spinner waiting for a result that will never arrive
        // through normal dispatch); the scripted answer comes from the
        // runner's automatic follow-up turn that plays Writer (#2378).
        ScenarioExpectation(
            id: "handoff-research-write",
            cardID: "demo-card-handoff-research-write",
            completedTools: ["transfer_to_writer"],
            failedTools: [],
            assistantAnswer: "MCP is a JSON-RPC protocol that lets hosts advertise tools and resources to model runtimes."
        ),
        // hook-input-sanitize: scripted backend emits the post-hook
        // sandboxed path. The rendered tool invocation reflects the
        // sanitised target, NOT the user-supplied `../../../etc/passwd`.
        ScenarioExpectation(
            id: "hook-input-sanitize",
            cardID: "demo-card-hook-input-sanitize",
            completedTools: ["read_file"],
            failedTools: [],
            assistantAnswer: "The requested path was rewritten to sandbox/etc/passwd before the tool ran."
        )
    ]

    func test_emptyState_rendersAllScenarioCards() {
        let app = launchDemoApp(scenario: nil)
        openChatDetailIfNeeded(app: app)

        // The empty state requires an active session; the launch bootstrap
        // should have produced one before the detail view mounts. Wait for chat
        // input to be ready so we know the detail pane is mounted.
        XCTAssertTrue(waitForChatInputReady(app: app, timeout: 30))

        let cardIDs = scenarioExpectations.map(\.cardID) + ["demo-card-journal-write"]
        for cardID in cardIDs {
            let card = app.descendants(matching: .any)[cardID]
            XCTAssertTrue(
                card.waitForExistence(timeout: 5),
                "Empty-state should render the \(cardID) scenario card"
            )
        }
    }

    // MARK: - Launch arg path

    func test_tipCalc_launchArg_rendersCompletedToolCallAndAnswer() {
        assertLaunchArgScenario(scenarioExpectations[0])
    }

    func test_worldClock_launchArg_rendersCompletedToolCallAndAnswer() {
        assertLaunchArgScenario(scenarioExpectations[1])
    }

    func test_workspaceSearch_launchArg_rendersCompletedToolCallAndAnswer() {
        assertLaunchArgScenario(scenarioExpectations[2])
    }

    func test_invalidArgsRecover_launchArg_rendersFailedThenCompletedToolCallsAndAnswer() {
        assertLaunchArgScenario(scenarioExpectations[3])
    }

    func test_rateLimitedRetry_launchArg_rendersFailedThenCompletedToolCallsAndAnswer() {
        assertLaunchArgScenario(scenarioExpectations[4])
    }

    func test_mcpToolFailure_launchArg_rendersFailedToolCallAndAnswer() {
        assertLaunchArgScenario(scenarioExpectations[5])
    }

    func test_mcpEcho_launchArg_rendersScriptedFailureAndAnswer() {
        assertLaunchArgScenario(scenarioExpectations[6])
    }

    // MARK: - W3B scenarios

    func test_skillExplain_launchArg_rendersInvokeSkillAndScriptedAnswer() {
        // scenarioExpectations[7] = skill-explain
        assertLaunchArgScenario(scenarioExpectations[7])
    }

    func test_handoffResearchWrite_launchArg_rendersTransferToWriterAndScriptedAnswer() {
        // The loud-failure contract on `expectedHandoffs` is encoded as a
        // completedTools assertion here: if the scripted `transfer_to_writer`
        // tool-call does not render in the bubble, the wait below fails with
        // a clear message. That maps the plan's "demo fails LOUDLY if no
        // handoff fires" requirement onto the XCUITest harness without
        // needing live LLM execution. The answer assertion covers the
        // runner's automatic follow-up turn (see `DemoScenario.handoffFollowUpPrompt`).
        assertLaunchArgScenario(scenarioExpectations[8])
    }

    func test_hookInputSanitize_launchArg_rendersSanitisedPathAndScriptedAnswer() {
        // The scripted backend dispatches read_file against the sanitised
        // path (`sandbox/etc/passwd`), not the user-supplied traversal. The
        // tool-invocation-completed-read_file element confirms the executor
        // saw the post-hook arguments; the assistant bubble describes the
        // rewrite.
        assertLaunchArgScenario(scenarioExpectations[9])
    }

    func test_journalWrite_launchArg_approvesToolCallAndWritesFile() {
        let sandboxRoot = repositoryRoot()
            .appendingPathComponent("DerivedData/ManifoldDemoUITestSandboxes/\(UUID().uuidString)", isDirectory: true)
        XCTAssertNoThrow(try FileManager.default.createDirectory(at: sandboxRoot, withIntermediateDirectories: true))
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: sandboxRoot)) }

        let app = launchDemoApp(
            scenario: "journal-write",
            extraArguments: ["--bck-demo-autosend-scenario"],
            environment: [
                "MANIFOLD_DEMO_SANDBOX_ROOT": sandboxRoot.path,
                "MANIFOLD_DEMO_INLINE_APPROVAL": "1"
            ]
        )
        openChatDetailIfNeeded(app: app)

        XCTAssertTrue(waitForChatInputReady(app: app, timeout: 30))

        let approvalSheet = app.descendants(matching: .any)["approval-sheet"]
        if approvalSheet.waitForExistence(timeout: 8) {
            app.buttons["Approve"].tap()
        } else {
            let inlineApproval = app.descendants(matching: .any)["tool-invocation-pending-write_file"]
            XCTAssertTrue(
                inlineApproval.waitForExistence(timeout: 5),
                "Journal-write scenario should present an approval control"
            )
            app.buttons["approval-approve-button"].tap()
        }

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

    private func assertLaunchArgScenario(
        _ expectation: ScenarioExpectation,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let app = launchDemoApp(scenario: expectation.id)
        openChatDetailIfNeeded(app: app)

        XCTAssertTrue(
            waitForChatInputReady(app: app, timeout: 30),
            "Demo app should reach chat-ready state when launched with --bck-demo-scenario \(expectation.id)",
            file: file,
            line: line
        )

        if let answer = expectation.assistantAnswer {
            assertAssistantAnswer(answer, in: app, file: file, line: line)
        }

        for toolName in expectation.completedTools {
            assertToolInvocation(
                identifier: "tool-invocation-completed-\(toolName)",
                message: "\(expectation.id) should render completed \(toolName) invocation UI",
                app: app,
                file: file,
                line: line
            )
        }

        for toolName in expectation.failedTools {
            assertToolInvocation(
                identifier: "tool-invocation-failed-\(toolName)",
                message: "\(expectation.id) should render failed \(toolName) invocation UI",
                app: app,
                file: file,
                line: line
            )
        }
    }

    private func assertAssistantAnswer(
        _ answer: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let assistantBubble = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "Assistant said: \(answer)")
        ).firstMatch
        XCTAssertTrue(
            assistantBubble.waitForExistence(timeout: 10),
            "Scenario should render the scripted assistant answer: \(answer)",
            file: file,
            line: line
        )
    }

    private func assertToolInvocation(
        identifier: String,
        message: String,
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let element = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(
            element.waitForExistence(timeout: 10),
            message,
            file: file,
            line: line
        )
    }

    private func repositoryRoot(file: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Launches the demo with the standard `--uitesting` plus optional
    /// `--bck-demo-scenario <id>` cold-launch arg.
    private func launchDemoApp(
        scenario: String?,
        extraArguments: [String] = [],
        environment: [String: String] = [:]
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting"]
        if let scenario {
            app.launchArguments += ["--bck-demo-scenario", scenario]
        }
        app.launchArguments += extraArguments
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
