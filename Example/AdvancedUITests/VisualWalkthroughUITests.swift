import XCTest

/// Visual walkthrough of the 2026 UI refresh (#2307): drives the Advanced demo
/// through surfaces the refresh restyled — empty state, model switcher,
/// tool-invocation cards, scroll-under-glass, composer, and the demo's
/// bubble-style presets — asserting each one is reachable and writing a
/// numbered screenshot story for a human visual pass against the Rev 7 mockups
/// (`docs/design/ui-refresh-2026.html`).
///
/// Not exhaustive: session rows, the thinking block, and the state screens have
/// no coverage here yet.
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

    /// Where frames are written. See ``resolveOutputDirectory()``.
    private var walkthroughOutputDirectory = URL(
        fileURLWithPath: "/private/tmp/manifoldkit-ui-walkthrough",
        isDirectory: true
    )

    /// A missed capture point must not abort the story — partial evidence for
    /// the remaining surfaces beats stopping at the first gap. Failures are
    /// still recorded (and still fail the test), they just don't halt it.
    override func setUpWithError() throws {
        continueAfterFailure = true
        walkthroughOutputDirectory = resolveOutputDirectory()
        try FileManager.default.createDirectory(
            at: walkthroughOutputDirectory,
            withIntermediateDirectories: true
        )
        // The runner's stdout is where a human looks for "so where are the PNGs".
        print("[walkthrough] screenshots → \(walkthroughOutputDirectory.path)")
    }

    /// Reads an override exported into `xcodebuild`'s **environment** as
    /// `TEST_RUNNER_<name>`:
    ///
    /// ```
    /// TEST_RUNNER_MANIFOLD_WALKTHROUGH_DIR=/tmp/frames scripts/example-ui-tests.sh test …
    /// ```
    ///
    /// That prefix is how a value reaches the XCUITest runner process; an
    /// unprefixed shell variable does not propagate into it, which is why
    /// `ModelManagementUITests.skipUnlessRealModelE2EEnabled()` reaches for a
    /// file instead. It has to be an environment assignment — passing
    /// `TEST_RUNNER_FOO=bar` as a trailing *argument* to `xcodebuild` is taken
    /// as a build setting and never arrives (verified: the frames went to the
    /// default directory).
    ///
    /// Xcode strips the prefix before injecting, so the unprefixed name is what
    /// the runner actually sees; both keys are accepted so a mis-set variable
    /// still lands somewhere visible rather than doing nothing.
    private func runnerOverride(_ name: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        for key in [name, "TEST_RUNNER_\(name)"] {
            if let value = env[key], !value.isEmpty { return value }
        }
        return nil
    }

    /// Overridable with `TEST_RUNNER_MANIFOLD_WALKTHROUGH_DIR=/abs/path`.
    ///
    /// The default is deliberately absolute rather than `HOME`-relative: under
    /// a simulator destination `HOME` is the simulator's container, while an
    /// absolute path resolves on the host where the human can open it. It is
    /// also under `/private/tmp`, which the system reaper clears after a few
    /// days — copy out anything worth keeping, or point the override somewhere
    /// durable.
    ///
    /// A relative override is rejected rather than resolved: a quoted
    /// `"~/Desktop/x"` arrives unexpanded, and quietly creating a `~` directory
    /// inside the runner's container is precisely how a human ends up staring
    /// at an empty folder.
    /// Resolved once per test in `setUpWithError` — the rejection below is a
    /// side effect, and a computed property would re-fire it on every capture.
    private func resolveOutputDirectory() -> URL {
        let fallback = URL(fileURLWithPath: "/private/tmp/manifoldkit-ui-walkthrough", isDirectory: true)
        guard let override = runnerOverride("MANIFOLD_WALKTHROUGH_DIR") else { return fallback }
        guard override.hasPrefix("/") else {
            XCTFail("""
                MANIFOLD_WALKTHROUGH_DIR must be an absolute path; got "\(override)". \
                A quoted ~ is never expanded on its way to the runner — use $HOME/….
                """)
            return fallback
        }
        return URL(fileURLWithPath: override, isDirectory: true)
    }

    /// How long a SwiftUI transition needs to finish. Menus settle in ~0.25 s,
    /// but a modal sheet takes ~0.5 s and `waitForExistence` returns the moment
    /// the element exists — which can be at the *start* of the presentation,
    /// catching the switcher mid-slide. Applied before every capture (a
    /// half-drawn frame reads as a rendering bug in the visual pass) and after a
    /// dismissal, before the next interaction is attempted.
    private let uiSettle: TimeInterval = 0.8

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
        Thread.sleep(forTimeInterval: uiSettle)
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
    }

    /// Scrolls the transcript back through its history.
    ///
    /// `app.swipeDown()` fails on macOS with "Unable to find hit point for
    /// Application" — the app root has no hit-testable area — so the gesture is
    /// driven through a coordinate drag on the frontmost window there, mirroring
    /// `UITestHelpers.scrollToElement(_:app:maxSwipes:)`.
    private func scrollTranscriptBack(app: XCUIApplication) {
        #if os(macOS)
        let target = app.windows.firstMatch.exists ? app.windows.firstMatch : app
        let start = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
        let end = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.05, thenDragTo: end)
        #else
        app.swipeDown()
        app.swipeDown()
        #endif
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

    // MARK: - Populated transcript, tool cards, scroll, composer, bubble presets
    //
    // One test rather than five: each stage depends on the transcript state the
    // previous one produced, and re-launching per stage would cost a
    // scripted-scenario replay each time for no added isolation.
    //
    // `invalid-args-recover` is the scripted scenario that renders BOTH a
    // failed and a completed tool-invocation card in one transcript
    // (`DemoScenarioUITests` scenarioExpectations[3]) — the richest single
    // transcript for a card/bubble visual pass.

    func testTranscriptToolCardsComposerAndBubblePresets() throws {
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
        // Without this the timeout path writes the same broken frame twice,
        // the second time labelled "populated".
        guard bubbleAppeared else { return }

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
        //
        // The scroll-to-bottom control is deliberately NOT exercised here: it
        // shows only while a turn is streaming *and* the user has scrolled away
        // (`ChatHistoryView.showsScrollToBottomControl`), which a replayed
        // scripted transcript is never in. Asserting it on an idle transcript
        // asserts a control the design says must be absent.
        scrollTranscriptBack(app: app)
        capture("05-scrolled-back-under-glass")

        let messageInput = app.textFields["Message input"]
        if messageInput.waitForExistence(timeout: 5), messageInput.isEnabled, messageInput.isHittable {
            messageInput.tap()
            capture("06-composer-focused")

            messageInput.typeText("What was the tip percentage again?")
            capture("07-composer-typed-text")

            let sendButton = app.buttons["Send message"]
            if sendButton.waitForExistence(timeout: 3), sendButton.isEnabled {
                sendButton.tap()
                Thread.sleep(forTimeInterval: 1.5)
                // `invalid-args-recover` scripts exactly three turns, so this
                // fourth send runs off the end of the script and the frame is
                // *expected* to show the turn-ended-without-a-message banner —
                // it is the error-state capture, not a bug in the capture.
                capture("08-after-send-past-scripted-turns")
            } else {
                XCTFail("Send button not enabled after typing")
            }
        } else {
            XCTFail("Message input not enabled/hittable under the scripted backend")
        }

        // A second bubble style over the same transcript is the side-by-side
        // that makes the styling seam legible. Note this is `.iMessage`, a
        // bubble style — the demo has no `.classicManifoldTheme()` option, so
        // the pre-refresh appearance is NOT what these frames show.
        //
        // #2325 moved the appearance menu to `.secondaryAction`, i.e. into the
        // toolbar overflow on compact width, so it must be reached through
        // `tapToolbarButton` (which traverses "More") rather than looked up
        // directly in the bar.
        guard tapToolbarButton("Appearance", app: app) else {
            dumpHierarchy(app, named: "09-appearance-menu-unreachable-hierarchy")
            XCTFail("Appearance menu unreachable, in the toolbar or its overflow")
            return
        }
        capture("09-appearance-menu-open")

        let iMessageOption = app.buttons["iMessage"]
        guard iMessageOption.waitForExistence(timeout: 2), iMessageOption.isHittable else {
            dumpHierarchy(app, named: "10-imessage-option-missing-hierarchy")
            XCTFail("iMessage bubble-style option not found in the appearance menu")
            return
        }
        iMessageOption.tap()
        capture("10-imessage-bubble-style-same-transcript")

        guard tapToolbarButton("Appearance", app: app) else {
            XCTFail("Appearance menu unreachable when restoring the standard style")
            return
        }
        let standardOption = app.buttons["Standard"]
        if standardOption.waitForExistence(timeout: 2), standardOption.isHittable {
            standardOption.tap()
            capture("11-restored-standard-bubble-style")
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
    /// Opt in with an environment assignment on the run command (see
    /// ``runnerOverride(_:)`` — an argument-position `TEST_RUNNER_…=…` does not
    /// reach the runner):
    ///
    /// ```
    /// TEST_RUNNER_MANIFOLD_WALKTHROUGH_LIVE=1 scripts/example-ui-tests.sh test \
    ///   -only-testing:AdvancedUITests/VisualWalkthroughUITests/testDefineRealOllamaEndpointAndSendLiveMessage
    /// ```
    ///
    /// Deliberately *not* the sentinel-file shape
    /// `ModelManagementUITests.skipUnlessRealModelE2EEnabled()` uses: that
    /// suite's documented destination is macOS, where `HOME` is the host's
    /// home. Under this suite's default iPhone-simulator destination `HOME` is
    /// the simulator's data container, so a host-created sentinel is invisible
    /// and the gate could never be opened.
    func testDefineRealOllamaEndpointAndSendLiveMessage() throws {
        try skipUnlessLiveWalkthroughEnabled()

        let app = XCUIApplication()
        // `showAdvancedSettings` is an @AppStorage toggle
        // (`GenerationSettingsView.swift:21`) that `--uitesting` seeds and this
        // launch does not — leaving "Manage Cloud APIs" collapsed inside the
        // disclosure and the endpoint flow unreachable. Seed it through the
        // UserDefaults argument domain instead of tapping a disclosure whose
        // expanded state we would then have to trust.
        app.launchArguments += [
            "-ApplePersistenceIgnoreState", "YES",
            "-showAdvancedSettings", "YES",
        ]
        app.launch()

        openChatDetailIfNeeded(app: app)
        // Without `--uitesting` no model is auto-loaded, so the composer stays
        // disabled until a backend is selected below — and on compact width the
        // settings button lives in the toolbar overflow, so it is not directly
        // present either. The chat navigation bar is the thing that reliably
        // marks "the chat surface is up".
        XCTAssertTrue(
            waitForElement(app.navigationBars["Chat"], timeout: 20),
            "Chat surface should come up in the live (non-scripted) launch"
        )

        guard navigateToAPIConfigurationLive(app: app) else {
            dumpHierarchy(app, named: "12-endpoint-nav-failed-hierarchy")
            capture("12-endpoint-nav-failed")
            XCTFail("Could not reach the Cloud APIs / Add Endpoint flow")
            return
        }

        capture("12-add-endpoint-editor-open")

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
        capture("13-provider-set-to-ollama")

        // Display Name: overwrite the provider-seeded default so the switcher
        // row below is identifiable. Server URL should already be
        // http://localhost:11434 via APIProvider.defaultBaseURL — set it
        // explicitly rather than trusting the seed. Model Name defaults to
        // "llama3.2"; override to the model actually pulled on this host.
        setTextFieldValue(app.textFields["Display Name"], to: "Local Ollama")
        setTextFieldValue(app.textFields["Server URL"], to: "http://localhost:11434")
        setTextFieldValue(app.textFields["Model Name"], to: "llama3.1:8b")
        capture("14-endpoint-fields-filled")

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
                Thread.sleep(forTimeInterval: uiSettle)
            }
        }
        capture("15-back-to-chat-after-save")

        let switcherChip = app.descendants(matching: .any)["chat-model-switcher-chip"]
        guard switcherChip.waitForExistence(timeout: 5), switcherChip.isHittable else {
            dumpHierarchy(app, named: "16-switcher-chip-unreachable-live-hierarchy")
            XCTFail("chat-model-switcher-chip unreachable in the live launch too (#2325 regression)")
            return
        }
        switcherChip.tap()

        let endpointRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'Local Ollama'")).firstMatch
        guard endpointRow.waitForExistence(timeout: 5), endpointRow.isHittable else {
            capture("16-switcher-endpoint-MISSING")
            XCTFail("Local Ollama row not found in the model switcher")
            return
        }
        endpointRow.tap()
        capture("16-switcher-endpoint-selected")
        dismissSwitcher(app: app)

        let replied = sendPromptAndAwaitResponse(
            app: app,
            prompt: "In one sentence, what is a manifold?",
            responseTimeout: 90
        )
        if !replied {
            dumpHierarchy(app, named: "17-no-live-reply-hierarchy")
        }
        capture("17-real-ollama-reply")
        XCTAssertTrue(replied, "Expected a real streamed reply from the local Ollama endpoint")
    }

    // MARK: - Helpers

    /// Opt-in gate for the non-hermetic finale. Uses the runner-env channel
    /// rather than a sentinel file because the sentinel would have to live in
    /// the *simulator's* container to be visible here — see the method's
    /// documentation for why the sibling suite's file-based precedent does not
    /// transplant.
    private func skipUnlessLiveWalkthroughEnabled() throws {
        // No CI guard: an unprefixed `CI` variable cannot reach the runner
        // process (the same fact this gate is built around), so checking it
        // would only look like protection. The flag below is off unless
        // somebody passes it deliberately, which is the real guard.
        guard let flag = runnerOverride("MANIFOLD_WALKTHROUGH_LIVE"), flag != "0" else {
            throw XCTSkip("""
                Live walkthrough opt-in: set TEST_RUNNER_MANIFOLD_WALKTHROUGH_LIVE=1 in the \
                environment BEFORE the run command (in xcodebuild argument position it is read \
                as a build setting and never arrives). Requires Ollama serving llama3.1:8b at \
                localhost:11434, launches without --uitesting, and persists an endpoint into \
                the real demo store.
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
        Thread.sleep(forTimeInterval: uiSettle)
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

        // The launch argument above should have the disclosure open already;
        // this is the fallback for a run that somehow starts collapsed. Scroll
        // first — the row sits at the bottom of the settings form.
        if !manageAPIs.exists {
            let advancedDisclosure = advancedSettingsDisclosure(app: app)
            _ = scrollToElement(advancedDisclosure, app: app)
            if waitForElement(advancedDisclosure, timeout: 3) {
                _ = toggleDisclosure(advancedDisclosure)
                _ = manageAPIs.waitForExistence(timeout: 3)
            }
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
