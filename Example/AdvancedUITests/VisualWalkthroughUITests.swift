import XCTest

/// Visual walkthrough of the 2026 UI refresh (#2307): drives the Advanced demo
/// through the surfaces the refresh restyled — empty state, model switcher,
/// tool-invocation cards, scroll-under-glass, composer, and the classic-theme
/// restore path — asserting each one is reachable and writing a numbered
/// screenshot story for a human visual pass against the Rev 7 mockups
/// (`docs/design/ui-refresh-2026.html`).
///
/// **Why this is a committed suite and not a scratch script.** Its first run
/// found the model-switcher chip unreachable on compact-width toolbars — three
/// compounding bugs, fixed in #2325. `ModelSwitcherChipUITests` is the narrow
/// regression guard that came out of that; this suite is the wide net that
/// caught it, and the tool that produces the evidence for the next visual pass.
///
/// **Not in CI.** `example-ui-smoke.yml` runs two named tests via
/// `-only-testing:`; this suite is run by hand when the chat surface changes:
///
/// ```
/// scripts/example-ui-tests.sh test -only-testing:AdvancedUITests/VisualWalkthroughUITests
/// ```
///
/// Screenshots land in ``walkthroughOutputDirectory`` (printed at the start of
/// each test) *and* as `XCTAttachment`s in the result bundle.
final class VisualWalkthroughUITests: XCTestCase {

    /// Sentinel enabling the live-Ollama finale. See
    /// ``testDefineRealOllamaEndpointAndSendLiveMessage()``.
    private static let liveSentinelName = ".manifoldkit_ui_walkthrough_live"

    /// A missed capture point must not abort the story — partial evidence for
    /// the remaining surfaces beats stopping at the first gap. Failures are
    /// still recorded (and still fail the test), they just don't halt it.
    override func setUpWithError() throws {
        continueAfterFailure = true
        try FileManager.default.createDirectory(
            at: walkthroughOutputDirectory,
            withIntermediateDirectories: true
        )
        // The runner's stdout is where a human looks for "so where are the PNGs".
        print("[walkthrough] screenshots → \(walkthroughOutputDirectory.path)")
    }

    /// Resolution order: `MANIFOLD_WALKTHROUGH_DIR`, then the same name with
    /// Xcode's `TEST_RUNNER_` prefix (the only way to reach the runner process
    /// on a simulator destination — plain shell env vars are not propagated,
    /// see `ModelManagementUITests.skipUnlessRealModelE2EEnabled()`), then a
    /// fixed temp path.
    ///
    /// The default is deliberately absolute rather than `HOME`-relative: under
    /// a simulator destination `HOME` is the simulator's container, while an
    /// absolute path resolves on the host where the human can open it. It is
    /// also under `/private/tmp`, which the system reaper clears after a few
    /// days — copy out anything worth keeping, or point
    /// `MANIFOLD_WALKTHROUGH_DIR` somewhere durable.
    private var walkthroughOutputDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        for key in ["MANIFOLD_WALKTHROUGH_DIR", "TEST_RUNNER_MANIFOLD_WALKTHROUGH_DIR"] {
            if let path = env[key], !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        return URL(fileURLWithPath: "/private/tmp/manifoldkit-ui-walkthrough", isDirectory: true)
    }

    /// Settle time after an interaction before capturing. SwiftUI sheet and
    /// toolbar transitions run ~0.3 s; capturing inside one yields a half-drawn
    /// frame that reads as a rendering bug in the visual pass.
    private let settleAfterInteraction: TimeInterval = 0.4

    /// Mirrors `DemoScenarioUITests.launchDemoApp(scenario:)` (private there,
    /// not shared via `UITestHelpers`) so this suite can pick a scripted
    /// scenario without widening shared test infrastructure.
    private func launchDemoApp(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting", "--bck-demo-scenario", scenario]
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

    /// Writes a durable PNG *and* attaches it to the result bundle. The file
    /// write is the point — the bundle is discarded on the next run, and the
    /// whole purpose of this suite is a set of images that outlive it.
    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let url = walkthroughOutputDirectory
            .appendingPathComponent(name)
            .appendingPathExtension("png")
        do {
            try screenshot.pngRepresentation.write(to: url)
        } catch {
            XCTFail("Failed to write screenshot \(name): \(error)")
        }
        captureScreenshot(name: name)
        Thread.sleep(forTimeInterval: settleAfterInteraction)
    }

    /// Dumps the accessibility hierarchy next to the screenshots when an
    /// element the walkthrough expects isn't there — the difference between
    /// "the chip is missing" and "the chip is present but not hittable" is the
    /// whole diagnosis, and a PNG cannot tell them apart.
    private func dumpHierarchy(_ app: XCUIApplication, named name: String) {
        let url = walkthroughOutputDirectory
            .appendingPathComponent(name)
            .appendingPathExtension("txt")
        do {
            try app.debugDescription.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[walkthrough] hierarchy dump \(name) failed: \(error)")
        }
    }

    // MARK: - Cold launch, empty state, model switcher

    func testColdLaunchEmptyStateAndModelSwitcher() throws {
        // No scenario: the shared helper's plain `--uitesting` launch is what
        // leaves the transcript empty, which is the state being captured.
        let app = launchDemoApp()
        openChatDetailIfNeeded(app: app)
        XCTAssertTrue(waitForChatInputReady(app: app, timeout: 30))

        capture("01-cold-launch-empty-state")

        // No overflow-menu fallback: #2325 proved every compact toolbar
        // placement dead, so the chip is mounted in a content-chrome
        // safeAreaInset band and must be directly hittable.
        let switcherChip = app.descendants(matching: .any)["chat-model-switcher-chip"]
        let switcherReachable = switcherChip.waitForExistence(timeout: 5) && switcherChip.isHittable
        if !switcherReachable {
            dumpHierarchy(app, named: "01-switcher-chip-unreachable-hierarchy")
        }
        XCTAssertTrue(
            switcherReachable,
            "chat-model-switcher-chip must be visible and hittable (#2325)"
        )
        guard switcherReachable else { return }

        switcherChip.tap()
        let switcherOpened = app.descendants(matching: .any)["model-switcher-list"]
            .waitForExistence(timeout: 10)
        capture("02-model-switcher-open")
        XCTAssertTrue(switcherOpened, "Tapping the chip should present the switcher list")

        dismissSwitcher(app: app)
    }

    // MARK: - Populated transcript, tool cards, scroll, composer, classic preset
    //
    // One test rather than five: each stage depends on the transcript state the
    // previous one produced, and re-launching per stage would cost a
    // scripted-scenario replay each time for no added isolation.
    //
    // `invalid-args-recover` is the scripted scenario that renders BOTH a
    // failed and a completed tool-invocation card in one transcript
    // (`DemoScenarioUITests` scenarioExpectations[3]) — the richest single
    // transcript for a card/bubble visual pass.

    func testTranscriptToolCardsComposerAndClassicPreset() throws {
        let app = launchDemoApp(scenario: "invalid-args-recover")
        openChatDetailIfNeeded(app: app)
        XCTAssertTrue(waitForChatInputReady(app: app, timeout: 30))

        let assistantBubble = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS[c] \"Dividing by zero isn't defined\"")
        ).firstMatch
        let bubbleAppeared = assistantBubble.waitForExistence(timeout: 25)
        if !bubbleAppeared {
            dumpHierarchy(app, named: "03-transcript-timeout-hierarchy")
            capture("03-transcript-timeout-state")
        }
        XCTAssertTrue(bubbleAppeared, "Scripted invalid-args-recover answer should render")

        capture("03-populated-transcript-bubbles")

        let failedCard = app.descendants(matching: .any)["tool-invocation-failed-calc"]
        if failedCard.waitForExistence(timeout: 5) {
            capture("04a-tool-card-failed")
        } else {
            capture("04a-tool-card-failed-MISSING")
            XCTFail("tool-invocation-failed-calc not found")
        }

        let completedCard = app.descendants(matching: .any)["tool-invocation-completed-calc"]
        if completedCard.waitForExistence(timeout: 5) {
            capture("04b-tool-card-completed")
        } else {
            capture("04b-tool-card-completed-MISSING")
            XCTFail("tool-invocation-completed-calc not found")
        }

        // Scroll-under-glass: the refresh runs the transcript edge-to-edge
        // beneath the composer, so content must be visibly behind the glass.
        app.swipeDown()
        app.swipeDown()
        capture("05-scrolled-up-under-glass")

        let scrollToBottom = app.buttons["Scroll to latest message"]
        if scrollToBottom.waitForExistence(timeout: 3) {
            capture("06-scroll-to-bottom-control")
            if scrollToBottom.isHittable {
                scrollToBottom.tap()
                capture("07-returned-to-bottom")
            }
        } else {
            XCTFail("Scroll to latest message control not found after scrolling up")
        }

        let messageInput = app.textFields["Message input"]
        if messageInput.waitForExistence(timeout: 5), messageInput.isEnabled, messageInput.isHittable {
            messageInput.tap()
            capture("08-composer-focused")

            messageInput.typeText("What was the tip percentage again?")
            capture("09-composer-typed-text")

            let sendButton = app.buttons["Send message"]
            if sendButton.waitForExistence(timeout: 3), sendButton.isEnabled {
                sendButton.tap()
                Thread.sleep(forTimeInterval: 1.5)
                capture("10-after-send")
            } else {
                XCTFail("Send button not enabled after typing")
            }
        } else {
            XCTFail("Message input not enabled/hittable under the scripted backend")
        }

        // The classic preset over the same transcript is the side-by-side that
        // makes the default-appearance change legible.
        let appearanceMenu = app.descendants(matching: .any)["demo-appearance-menu"]
        guard appearanceMenu.waitForExistence(timeout: 5), appearanceMenu.isHittable else {
            dumpHierarchy(app, named: "11-appearance-menu-missing-hierarchy")
            XCTFail("demo-appearance-menu not found/hittable")
            return
        }

        appearanceMenu.tap()
        capture("11-appearance-menu-open")

        let classicOption = app.buttons["iMessage"]
        guard classicOption.waitForExistence(timeout: 2), classicOption.isHittable else {
            XCTFail("iMessage (classic) appearance option not found")
            return
        }
        classicOption.tap()
        capture("12-classic-theme-same-transcript")

        appearanceMenu.tap()
        let standardOption = app.buttons["Standard"]
        if standardOption.waitForExistence(timeout: 2), standardOption.isHittable {
            standardOption.tap()
            capture("13-restored-standard-theme")
        } else {
            XCTFail("Standard appearance option not found when restoring")
        }
    }

    // MARK: - Live finale (opt-in): define a real endpoint and send a real message

    /// Drives the endpoint-definition flow against a **real** local Ollama and
    /// sends a real message — the one path the scripted backend cannot cover,
    /// and the reason the rest of the walkthrough never sees a live token
    /// stream, a real load state, or a real error.
    ///
    /// **Opt-in, because it is not hermetic**: it launches *without*
    /// `--uitesting` (real `ManifoldBootstrap`, real backends, real SwiftData
    /// store), needs Ollama serving `llama3.1:8b` at `localhost:11434`, and
    /// **persists an endpoint into the real demo store** that outlives the run.
    ///
    /// Enable it the way this target already gates its real-model E2E — a
    /// sentinel file, not an env var, because `xcodebuild test` does not
    /// propagate shell env vars into the XCUITest runner process:
    ///
    /// ```
    /// touch ~/.manifoldkit_ui_walkthrough_live
    /// ```
    func testDefineRealOllamaEndpointAndSendLiveMessage() throws {
        try skipUnlessLiveWalkthroughEnabled()

        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()

        openChatDetailIfNeeded(app: app)
        // Without `--uitesting` no model is auto-loaded, so the input stays
        // disabled until a backend is selected below — gate on the toolbar
        // being up instead.
        XCTAssertTrue(
            waitForElement(app.buttons["chat-settings-button"], timeout: 15)
                || waitForElement(app.staticTexts["No Model Selected"], timeout: 5),
            "Chat surface should come up in the live (non-scripted) launch"
        )

        guard navigateToAPIConfigurationLive(app: app) else {
            dumpHierarchy(app, named: "18-endpoint-nav-failed-hierarchy")
            capture("18-endpoint-nav-failed")
            XCTFail("Could not reach the Cloud APIs / Add Endpoint flow")
            return
        }

        capture("18-add-endpoint-editor-open")

        // `APIEndpointEditorView` uses a default `Picker`, which renders inside
        // a Form as a disclosure row labeled "Provider".
        let providerRow = app.buttons["Provider"].exists
            ? app.buttons["Provider"]
            : app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS[c] 'Provider'")).firstMatch
        guard providerRow.waitForExistence(timeout: 3), providerRow.isHittable else {
            XCTFail("Provider picker row not found/hittable")
            return
        }
        providerRow.tap()

        let ollamaOption = app.buttons["Ollama"].exists
            ? app.buttons["Ollama"]
            : app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == 'Ollama'")).firstMatch
        guard ollamaOption.waitForExistence(timeout: 3), ollamaOption.isHittable else {
            XCTFail("Ollama provider option not found in picker")
            return
        }
        ollamaOption.tap()
        capture("19-provider-set-to-ollama")

        // Display Name: overwrite the provider-seeded default so the switcher
        // row below is identifiable. Server URL should already be
        // http://localhost:11434 via APIProvider.defaultBaseURL — set it
        // explicitly rather than trusting the seed. Model Name defaults to
        // "llama3.2"; override to the model actually pulled on this host.
        setTextFieldValue(app.textFields["Display Name"], to: "Local Ollama")
        setTextFieldValue(app.textFields["Server URL"], to: "http://localhost:11434")
        setTextFieldValue(app.textFields["Model Name"], to: "llama3.1:8b")
        capture("19b-endpoint-fields-filled")

        let saveButton = app.buttons["Save"]
        guard saveButton.waitForExistence(timeout: 3), saveButton.isEnabled else {
            XCTFail("Save button not found/enabled after filling endpoint fields")
            return
        }
        saveButton.tap()

        // The editor sheet dismisses on save; the Cloud APIs and Generation
        // Settings sheets (stacked on iOS) each need an explicit Done.
        for _ in 0..<2 {
            let doneButton = app.buttons["Done"].firstMatch
            if doneButton.waitForExistence(timeout: 2), doneButton.isHittable {
                doneButton.tap()
                Thread.sleep(forTimeInterval: settleAfterInteraction)
            }
        }
        capture("19c-back-to-chat-after-save")

        let switcherChip = app.descendants(matching: .any)["chat-model-switcher-chip"]
        guard switcherChip.waitForExistence(timeout: 5), switcherChip.isHittable else {
            dumpHierarchy(app, named: "21-switcher-chip-unreachable-live-hierarchy")
            XCTFail("chat-model-switcher-chip unreachable in the live launch too (#2325 regression)")
            return
        }
        switcherChip.tap()

        let endpointRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'Local Ollama'")).firstMatch
        guard endpointRow.waitForExistence(timeout: 5), endpointRow.isHittable else {
            capture("21-switcher-endpoint-MISSING")
            XCTFail("Local Ollama row not found in the model switcher")
            return
        }
        endpointRow.tap()
        capture("21-switcher-endpoint-selected")
        dismissSwitcher(app: app)

        let replied = sendPromptAndAwaitResponse(
            app: app,
            prompt: "In one sentence, what is a manifold?",
            responseTimeout: 90
        )
        if !replied {
            dumpHierarchy(app, named: "20-no-live-reply-hierarchy")
        }
        capture("20-real-ollama-reply")
        XCTAssertTrue(replied, "Expected a real streamed reply from the local Ollama endpoint")
    }

    // MARK: - Helpers

    /// Mirrors `ModelManagementUITests.skipUnlessRealModelE2EEnabled()`: a
    /// sentinel file rather than an env var, because `xcodebuild test` does not
    /// propagate shell env vars into the XCUITest runner — an env gate would
    /// silently skip everywhere.
    private func skipUnlessLiveWalkthroughEnabled() throws {
        let env = ProcessInfo.processInfo.environment
        if let ci = env["CI"], !ci.isEmpty {
            throw XCTSkip("Live walkthrough skipped in CI — needs a local Ollama serving llama3.1:8b")
        }

        let home = env["HOME"] ?? NSHomeDirectory()
        let sentinel = (home as NSString).appendingPathComponent(Self.liveSentinelName)
        guard FileManager.default.fileExists(atPath: sentinel) else {
            throw XCTSkip("""
                Live walkthrough opt-in: touch ~/\(Self.liveSentinelName) to run it. \
                Requires Ollama serving llama3.1:8b at localhost:11434, launches without \
                --uitesting, and persists an endpoint into the real demo store.
                """)
        }
    }

    /// The switcher is a sheet on iOS and a popover on macOS; prefer an
    /// explicit dismiss control and fall back to the shared sheet dismissal.
    private func dismissSwitcher(app: XCUIApplication) {
        let candidates = [app.buttons["Cancel"], app.buttons["Done"], app.buttons["Close"]]
        if let button = candidates.first(where: { $0.waitForExistence(timeout: 1) && $0.isHittable }) {
            button.tap()
        } else {
            dismissSheet(app: app)
        }
        Thread.sleep(forTimeInterval: settleAfterInteraction)
    }

    /// Mirrors `CloudAPIUITests.navigateToAPIConfiguration()` but tolerates a
    /// launch without `--uitesting` (Advanced Settings starts collapsed) and
    /// returns `false` instead of hard-failing, so the caller can dump
    /// diagnostics before giving up.
    private func navigateToAPIConfigurationLive(app: XCUIApplication) -> Bool {
        if !tapToolbarButton("Generation settings", app: app) {
            let gearButton = app.buttons.matching(NSPredicate(
                format: "label CONTAINS[c] 'Settings' OR label CONTAINS[c] 'gear'"
            )).firstMatch
            guard waitForElement(gearButton, timeout: 5), gearButton.isHittable else { return false }
            gearButton.tap()
        }

        guard waitForElement(app.staticTexts["Generation Settings"], timeout: 5) else { return false }

        let manageAPIs = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Manage Cloud APIs'")).firstMatch

        let advancedDisclosure = advancedSettingsDisclosure(app: app)
        if !manageAPIs.exists, waitForElement(advancedDisclosure, timeout: 3) {
            _ = toggleDisclosure(advancedDisclosure)
            _ = manageAPIs.waitForExistence(timeout: 3)
        }

        guard scrollToElement(manageAPIs, app: app), waitForElement(manageAPIs, timeout: 2) else {
            return false
        }

        let manageAPIsButton = app.buttons["Manage Cloud APIs"]
        if manageAPIsButton.exists, manageAPIsButton.isHittable {
            manageAPIsButton.tap()
        } else {
            manageAPIs.tap()
        }

        guard waitForElement(app.staticTexts["Cloud APIs"], timeout: 5) else { return false }

        let addButton = app.buttons["Add Endpoint"].exists
            ? app.buttons["Add Endpoint"]
            : app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == 'Add Endpoint'")).firstMatch
        guard waitForElement(addButton, timeout: 3), addButton.isHittable else { return false }
        addButton.tap()

        let editorTitle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Add Endpoint' OR value == 'Add Endpoint'")).firstMatch
        return waitForElement(editorTitle, timeout: 5)
    }

    /// `typeText` appends, so a provider-seeded default has to be deleted
    /// first — select-all affordances differ across iOS/macOS, backspacing the
    /// existing value does not.
    private func setTextFieldValue(_ field: XCUIElement, to value: String) {
        guard field.waitForExistence(timeout: 3) else {
            XCTFail("Text field not found while filling the endpoint editor")
            return
        }
        field.tap()
        if let existing = field.value as? String, !existing.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
        }
        field.typeText(value)
    }
}
