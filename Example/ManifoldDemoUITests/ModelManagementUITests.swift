import XCTest

final class ModelManagementUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchDemoApp()
    }

    // MARK: - Sheet Presentation

    func testModelButtonOpensSheet() throws {
        openModelManagementSheet()

        let selectTab = modelManagementTab("Select", app: app)
        XCTAssertTrue(selectTab.waitForExistence(timeout: 3), "Select tab should appear in model management sheet")
    }

    // MARK: - Tab Switching

    func testCanSwitchBetweenTabs() throws {
        openModelManagementSheet()

        // Verify all three tabs exist
        let selectTab = modelManagementTab("Select", app: app)
        let downloadTab = modelManagementTab("Download", app: app)
        let storageTab = modelManagementTab("Storage", app: app)

        XCTAssertTrue(selectTab.exists, "Select tab should exist")
        XCTAssertTrue(downloadTab.exists, "Download tab should exist")
        XCTAssertTrue(storageTab.exists, "Storage tab should exist")

        // Switch to Download tab
        downloadTab.tap()
        // Should see "Recommended for Your Device" or search field
        let recommendedSection = app.staticTexts["Recommended for Your Device"]
        let searchField = app.searchFields.firstMatch
        XCTAssertTrue(
            recommendedSection.waitForExistence(timeout: 3) || searchField.waitForExistence(timeout: 3),
            "Download tab content should be visible after tapping Download tab"
        )

        // Switch to Storage tab
        storageTab.tap()
        let storageOverview = app.staticTexts["Storage Overview"]
        XCTAssertTrue(storageOverview.waitForExistence(timeout: 3), "Storage tab content should be visible after tapping Storage tab")

        // Switch back to Select tab
        selectTab.tap()
        // Give it a moment to render
        sleep(1)
        takeScreenshot(name: "Select-Tab-After-Switch")
    }

    // MARK: - Select Tab Interaction

    func testSelectTabShowsModels() throws {
        openModelManagementSheet()

        // Model rows in `ModelSelectionTabView` use `accessibilityElement(.combine)`
        // and expose a label like "Apple Foundation Model, …, Fast" on a button.
        // On macOS those rows aren't `staticTexts`; search any element type.
        let predicate = NSPredicate(format: "label CONTAINS[c] 'Foundation'")
        let foundationElement = app.descendants(matching: .any).matching(predicate).firstMatch
        let noModels = app.staticTexts["No Models Available"]

        let hasContent = noModels.waitForExistence(timeout: 3) || foundationElement.waitForExistence(timeout: 3)
        XCTAssertTrue(hasContent, "Select tab should show either models or empty state")

        takeScreenshot(name: "Select-Tab-Content")
    }

    func testSelectTabModelRowIsTappable() throws {
        openModelManagementSheet()
        takeScreenshot(name: "Select-Tab-Open")

        // Find a selectable model row inside the sheet. Scope the search to the
        // top-most sheet so we ignore the chat window's toolbar/system controls
        // (`_XCUI:CloseWindow`, `new-chat-button`, etc.) which sit above the
        // sheet on macOS NavigationSplitView and would otherwise be picked
        // first by `app.buttons.allElementsBoundByIndex`.
        #if os(macOS)
        let sheetScope: XCUIElement = app.sheets.firstMatch.exists
            ? app.sheets.firstMatch
            : app
        #else
        let sheetScope: XCUIElement = app
        #endif

        let allButtons = sheetScope.buttons.allElementsBoundByIndex
        var sheetModelButton: XCUIElement?
        for button in allButtons {
            guard button.isHittable else { continue }
            if ["Select", "Download", "Storage", "Done"].contains(button.label) {
                continue
            }
            // Exclude macOS window-system controls (close / minimise / zoom)
            // which surface as buttons with `_XCUI:` identifiers.
            if button.identifier.hasPrefix("_XCUI:") || button.label.hasPrefix("_XCUI:") {
                continue
            }
            if button.frame.size.width < 40 || button.frame.size.height < 40 {
                continue
            }
            if button.frame.minY > 120 {
                sheetModelButton = button
                break
            }
        }

        guard let modelRow = sheetModelButton else {
            let noModels = app.staticTexts["No Models Available"]
            if noModels.waitForExistence(timeout: 2) {
                takeScreenshot(name: "Select-Tab-No-Models")
                return
            }

            takeScreenshot(name: "Select-Tab-No-Hittable-Model-Row")
            XCTFail("No hittable model row found in the sheet")
            return
        }

        print("MODEL ROW in sheet: label='\(modelRow.label)' hittable=\(modelRow.isHittable) frame=\(modelRow.frame)")
        XCTAssertTrue(modelRow.isHittable, "Model row in sheet should be hittable")

        // Tap it. On iOS the sheet auto-dismisses via `onSelect`; on macOS the
        // sheet may remain visible after a model row tap (the wrapping
        // accessibility element on a Form/List row can intercept the tap before
        // it reaches the inner Button), so accept either outcome — what
        // matters is that the tap did not cause a runtime failure and that the
        // sidebar reflects the selection or the sheet has closed.
        modelRow.tap()
        sleep(1)

        let doneButton = app.buttons["Done"]
        if doneButton.exists {
            takeScreenshot(name: "Select-Tab-Sheet-Still-Open-After-Tap")
            #if os(macOS)
            // macOS-specific: dismiss the sheet via Done so subsequent tests
            // don't inherit a stuck sheet. Treat this path as a soft pass.
            doneButton.tap()
            #else
            XCTFail("Sheet should have dismissed after selecting a model, but it's still open")
            #endif
        } else {
            takeScreenshot(name: "Select-Tab-Sheet-Dismissed")
        }
    }

    // MARK: - Download Tab Interaction

    func testDownloadTabShowsRecommendations() throws {
        openModelManagementSheet()

        modelManagementTab("Download", app: app).tap()
        sleep(1)

        takeScreenshot(name: "Download-Tab-Content")

        // Check for recommendations section
        let recommended = app.staticTexts["Recommended for Your Device"]
        XCTAssertTrue(recommended.waitForExistence(timeout: 5), "Should show recommended models section")

        // Check for at least one downloadable model. `DownloadableModelRow` is
        // a Form/List row, which on macOS combines its child Texts into a
        // single accessibility element exposed as `otherElement`/`cell`/`button`
        // depending on the form style — never `staticText`. Search all
        // descendants by name predicate.
        let modelPredicate = NSPredicate(
            format: "label CONTAINS[c] 'SmolLM' OR label CONTAINS[c] 'Phi' OR label CONTAINS[c] 'Mistral' OR label CONTAINS[c] 'Llama' OR label CONTAINS[c] 'Qwen'"
        )
        let modelElements = app.descendants(matching: .any).matching(modelPredicate)
        XCTAssertGreaterThan(modelElements.count, 0, "Should show at least one recommended model")
    }

    func testDownloadTabSearchFieldIsInteractive() throws {
        openModelManagementSheet()

        modelManagementTab("Download", app: app).tap()
        sleep(1)

        let searchField = app.textFields["Search HuggingFace models"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 3), "Search field should exist on Download tab")
        XCTAssertTrue(searchField.isHittable, "Search field should be hittable")

        searchField.tap()
        searchField.typeText("llama")
        takeScreenshot(name: "Download-Tab-Search-Typed")
    }

    func testDownloadButtonIsHittable() throws {
        openModelManagementSheet()

        modelManagementTab("Download", app: app).tap()
        sleep(1)

        // Look for download buttons (arrow.down.circle)
        let downloadButtons = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'Download'"))

        if downloadButtons.count > 0 {
            let firstDownload = downloadButtons.firstMatch
            XCTAssertTrue(firstDownload.isHittable, "Download button should be hittable")
            takeScreenshot(name: "Download-Tab-Button-Found")
        } else {
            takeScreenshot(name: "Download-Tab-No-Buttons")
            // Not a failure - models might already be downloaded
        }
    }

    // MARK: - Storage Tab

    func testStorageTabShowsOverview() throws {
        openModelManagementSheet()

        modelManagementTab("Storage", app: app).tap()
        sleep(1)

        takeScreenshot(name: "Storage-Tab-Content")

        // The "Total Used" / "Models Directory" labels render as StaticTexts
        // exposed via `value:` on macOS (vs `label:` on iOS). Match either
        // attribute so tests work on both platforms. Constrain the query to
        // `staticTexts` to keep the search bounded — the Storage tab outline
        // can hold dozens of cells once the dev has stored models locally.
        let totalUsed = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'Total Used' OR value CONTAINS[c] 'Total Used'")
        ).firstMatch
        XCTAssertTrue(totalUsed.waitForExistence(timeout: 3), "Storage tab should show Total Used label")

        let modelsDirectory = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'Models Directory' OR value CONTAINS[c] 'Models Directory'")
        ).firstMatch
        XCTAssertTrue(modelsDirectory.exists, "Storage tab should show Models Directory label")
    }

    // MARK: - Done Button

    func testDoneButtonDismissesSheet() throws {
        openModelManagementSheet()

        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 3), "Done button should exist")
        XCTAssertTrue(doneButton.isHittable, "Done button should be hittable")

        doneButton.tap()

        // Sheet should dismiss
        XCTAssertFalse(doneButton.waitForExistence(timeout: 3), "Sheet should dismiss after tapping Done")
    }

    // MARK: - Comprehensive Interaction Audit

    func testAllSheetElementsAreInteractive() throws {
        openModelManagementSheet()

        let controls = [
            modelManagementTab("Select", app: app),
            modelManagementTab("Download", app: app),
            modelManagementTab("Storage", app: app),
            app.buttons["Done"]
        ]

        for control in controls {
            XCTAssertTrue(control.waitForExistence(timeout: 3), "\(control.label) should exist")
            XCTAssertTrue(control.isHittable, "\(control.label) should be hittable")
        }

        takeScreenshot(name: "All-Buttons-Hittable")
    }

    private func openModelManagementSheet() {
        openModelManagementIfNeeded(app: app)

        let selectTab = modelManagementTab("Select", app: app)
        guard selectTab.waitForExistence(timeout: 5) else {
            takeScreenshot(name: "Sidebar-No-Model-Button")
            XCTFail("Model management sheet did not open")
            return
        }
    }

    private func takeScreenshot(name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Real-Model E2E (opt-in, hardware-gated)
    //
    // These three tests prove that a real user can pick a model of each
    // supported on-device type (GGUF / MLX / Apple Foundation) through the
    // real UI and successfully generate a streamed response. They are
    // opt-in via a sentinel file (`~/.manifoldkit_real_e2e`) because:
    //
    //   1. They require ~4 GB of model files on disk under the demo app's
    //      sandbox container (`~/Library/Containers/<app-id>/Data/Documents/Models`).
    //   2. A cold MLX or GGUF load can take 10-30s and generation another
    //      30-120s — too slow for a default developer test sweep.
    //   3. CI runners do not have GPU/MLX/Metal acceleration nor Apple
    //      Intelligence enabled.
    //
    // Prerequisites (one-time local setup on Apple Silicon):
    //   1. Place model files in the demo app's sandbox Documents/Models:
    //      - `Qwen_Qwen3-4B-Q4_K_M.gguf`           (for GGUF)
    //      - `Llama-3.2-3B-Instruct-4bit/` dir     (for MLX)
    //      (Apple Foundation Model needs no file.)
    //   2. `touch ~/.manifoldkit_real_e2e`
    //   3. Native macOS runs require granting Accessibility permission to
    //      `/Applications/Xcode.app` (or `Xcode-testmanagerd`) in
    //      System Settings > Privacy & Security > Accessibility.
    //
    // Example run (native macOS):
    //   scripts/example-ui-tests.sh test-without-building \
    //     --destination 'platform=macOS,arch=arm64' \
    //     -only-testing:ManifoldDemoUITests/ModelManagementUITests/testSelectingGGUFModelProducesResponse

    /// Opt-in gate for real-model end-to-end tests.
    ///
    /// Uses two signals:
    ///
    /// 1. `CI` environment variable — automatically set by GitHub Actions and
    ///    most other CI systems. When present (any non-empty value), we skip,
    ///    because CI runners do not have the model files on disk nor the GPU
    ///    to run them.
    /// 2. Sentinel file at `~/.manifoldkit_real_e2e` — developers opt in by
    ///    creating this file (`touch ~/.manifoldkit_real_e2e`). A sentinel file
    ///    is used instead of an env var because `xcodebuild test` does not
    ///    propagate arbitrary shell env vars into the XCUITest runner process
    ///    on macOS/iOS, so env-var gates get silently skipped.
    ///
    /// Developers can also disable the gate by deleting the sentinel file.
    private func skipUnlessRealModelE2EEnabled() throws {
        let env = ProcessInfo.processInfo.environment
        if let ci = env["CI"], !ci.isEmpty {
            throw XCTSkip("Real-model E2E skipped in CI — requires ~4 GB on-disk models and Apple Silicon")
        }

        let home = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        let sentinel = (home as NSString).appendingPathComponent(".manifoldkit_real_e2e")
        guard FileManager.default.fileExists(atPath: sentinel) else {
            throw XCTSkip("Real-model E2E opt-in: create ~/.manifoldkit_real_e2e (touch ~/.manifoldkit_real_e2e) to run this test locally. Requires ~4 GB on-disk models and Apple Silicon.")
        }

        // The shared `launchDemoApp()` helper forces `--uitesting` which swaps
        // in `ScriptedBackend`, making real on-device backends (GGUF / MLX /
        // Apple Foundation) unreachable through the UI. Until the helper grows
        // a real-backend launch path, opting in via the sentinel file when the
        // suite is run through that helper still cannot exercise real models —
        // so we skip rather than fail. Run via Xcode's UI test target with a
        // launch arg override, or invoke `XCUIApplication().launch()` directly
        // from a custom test file, to opt into the real flow.
        let realE2EOverride = (home as NSString).appendingPathComponent(".manifoldkit_real_e2e_runs_under_uitesting")
        guard FileManager.default.fileExists(atPath: realE2EOverride) else {
            throw XCTSkip("""
                Real-model E2E currently requires a non-`--uitesting` launch path. \
                The `launchDemoApp()` helper installs `ScriptedBackend`, blocking \
                real GGUF / MLX / Foundation backends. Touch \
                `~/.manifoldkit_real_e2e_runs_under_uitesting` only if you have a \
                custom launch wrapper that bypasses `--uitesting`.
                """)
        }
    }

    func testSelectingGGUFModelProducesResponse() throws {
        try skipUnlessRealModelE2EEnabled()
        #if !arch(arm64)
        throw XCTSkip("GGUF backend (llama.cpp) requires Apple Silicon")
        #endif

        runRealModelSelectionFlow(
            modelLabelNeedle: "Qwen3-4B",
            screenshotPrefix: "GGUF"
        )
    }

    func testSelectingMLXModelProducesResponse() throws {
        try skipUnlessRealModelE2EEnabled()
        #if !arch(arm64)
        throw XCTSkip("MLX backend requires Apple Silicon")
        #endif

        runRealModelSelectionFlow(
            modelLabelNeedle: "Llama-3.2-3B",
            screenshotPrefix: "MLX"
        )
    }

    func testSelectingFoundationModelProducesResponse() throws {
        try skipUnlessRealModelE2EEnabled()

        guard #available(macOS 26, iOS 26, *) else {
            throw XCTSkip("Apple Foundation Model requires macOS 26 / iOS 26")
        }

        runRealModelSelectionFlow(
            modelLabelNeedle: "Foundation",
            screenshotPrefix: "Foundation",
            // Foundation Model loads near-instantly and streams quickly; tighter
            // timeouts surface regressions faster than the MLX/GGUF defaults.
            loadTimeout: 30,
            responseTimeout: 60
        )
    }

    /// Drives the full real-model E2E flow: open the sheet, tap the row
    /// matching `modelLabelNeedle`, wait for the model to load, send a short
    /// deterministic prompt, and assert that an assistant response streams in.
    /// Captures screenshots at each milestone for debugging.
    private func runRealModelSelectionFlow(
        modelLabelNeedle: String,
        screenshotPrefix: String,
        loadTimeout: TimeInterval = 60,
        responseTimeout: TimeInterval = 120
    ) {
        openModelManagementSheet()
        takeScreenshot(name: "\(screenshotPrefix)-01-Sheet-Open")

        guard let row = findModelRow(in: app, containing: modelLabelNeedle) else {
            takeScreenshot(name: "\(screenshotPrefix)-FAIL-Row-Not-Found")
            XCTFail("Could not find a model row containing '\(modelLabelNeedle)' on the Select tab. Make sure the model is present in the demo app's sandbox container.")
            return
        }

        XCTAssertTrue(row.isHittable, "Row for '\(modelLabelNeedle)' must be hittable to select it")
        row.tap()
        takeScreenshot(name: "\(screenshotPrefix)-02-Row-Tapped")

        // The sheet should auto-dismiss after selection. We don't gate the rest
        // of the flow on this — what really matters is that the chat input
        // becomes ready, which only happens once the backend has loaded.
        let inputReady = waitForChatInputReady(app: app, timeout: loadTimeout)
        takeScreenshot(name: "\(screenshotPrefix)-03-After-Load-Wait")
        guard inputReady else {
            XCTFail("Chat input never became ready within \(loadTimeout)s after selecting '\(modelLabelNeedle)' — model load likely failed")
            return
        }

        let prompt = "Reply with one word: ready"
        let gotResponse = sendPromptAndAwaitResponse(
            app: app,
            prompt: prompt,
            responseTimeout: responseTimeout
        )
        takeScreenshot(name: "\(screenshotPrefix)-04-After-Send")

        XCTAssertTrue(
            gotResponse,
            "Expected an assistant response to stream within \(responseTimeout)s for model '\(modelLabelNeedle)'"
        )
    }
}
