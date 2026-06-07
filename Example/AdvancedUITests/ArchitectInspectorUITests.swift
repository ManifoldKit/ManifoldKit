import XCTest

/// XCUITest smoke coverage for the Architect (Glass Box) developer inspector.
///
/// The inspector is presented from `ChatView` behind `#if DEBUG`; the Example
/// app's UI-test build is Debug, so the toolbar entry point is present. These
/// tests exercise the inspector chrome — opening the sheet, switching the three
/// tabs (Timeline / Context / Backend), toggling the record control, the Clear
/// control's empty-log state, and dismissal — without depending on a live model
/// (the demo runs the deterministic `ScriptedBackend` under `--uitesting`).
///
/// Element lookups prefer the `architect-*` accessibility identifiers added to
/// the inspector controls, with text/label fallbacks for cross-platform
/// hierarchy differences (iOS exposes segmented-control segments as buttons;
/// macOS flattens some containers).
final class ArchitectInspectorUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchDemoApp()
        openChatDetailIfNeeded(app: app)
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Open / Dismiss

    func test_architectToolbarButton_opensInspector() throws {
        // This is the headline regression test for the inspector's entry point,
        // so it hard-asserts the DEBUG toolbar button rather than routing through
        // the layout-tolerant `openArchitectInspector()` helper — if the button
        // disappeared, this test must FAIL, not skip.
        let button = app.buttons["architect-toolbar-button"]
        XCTAssertTrue(
            button.waitForExistence(timeout: 5),
            "DEBUG Architect toolbar button should be present in the chat detail"
        )
        XCTAssertTrue(button.isHittable, "Architect toolbar button should be hittable")
        button.tap()

        XCTAssertTrue(
            app.staticTexts["Architect"].waitForExistence(timeout: 3)
                || app.navigationBars["Architect"].waitForExistence(timeout: 1),
            "Tapping the Architect button should present the inspector sheet"
        )

        captureScreenshot(name: "architect-opened")
    }

    func test_doneButton_dismissesInspector() throws {
        try openArchitectInspector()

        let done = app.buttons["architect-done-button"]
        XCTAssertTrue(done.waitForExistence(timeout: 3), "Done button should be present in the inspector")
        guard done.isHittable else {
            throw XCTSkip("Done button is not hittable on this layout")
        }
        done.tap()

        // After dismissal the chat detail toolbar should be reachable again and
        // the inspector navigation title gone.
        XCTAssertTrue(
            isChatDetailVisible(app: app) || app.buttons["architect-toolbar-button"].waitForExistence(timeout: 3),
            "Dismissing the inspector should return to the chat detail"
        )
    }

    // MARK: - Tab switching

    func test_tabSwitching_movesBetweenTimelineContextBackend() throws {
        try openArchitectInspector()

        // Timeline is the default tab.
        XCTAssertTrue(
            tabContentVisible("architect-timeline-tab", emptyStateText: "No Events Captured"),
            "Timeline tab content should be visible on open"
        )

        selectArchitectTab("Context")
        XCTAssertTrue(
            tabContentVisible("architect-context-tab", emptyStateText: "No Context Data"),
            "Context tab content should be visible after selecting Context"
        )

        selectArchitectTab("Backend")
        // Backend content is either the capability matrix or the empty state,
        // depending on whether a model is loaded under the scripted backend.
        XCTAssertTrue(
            tabContentVisible("architect-backend-tab", emptyStateText: "No Backend Loaded"),
            "Backend tab content should be visible after selecting Backend"
        )

        selectArchitectTab("Timeline")
        XCTAssertTrue(
            tabContentVisible("architect-timeline-tab", emptyStateText: "No Events Captured"),
            "Timeline tab content should be visible again after switching back"
        )

        captureScreenshot(name: "architect-tabs")
    }

    // MARK: - Record control

    func test_recordControl_togglesBetweenPauseAndRecord() throws {
        try openArchitectInspector()

        let record = app.buttons["architect-record-button"]
        XCTAssertTrue(record.waitForExistence(timeout: 3), "Record/Pause button should be present")

        // `ArchitectView.onAppear` calls `startRecording()`, so the control
        // deterministically reads "Pause" (recording) when the sheet opens.
        let initialLabel = record.label
        XCTAssertEqual(
            initialLabel, "Pause",
            "Recording auto-starts on appear, so the control should read 'Pause' initially"
        )

        guard record.isHittable else {
            throw XCTSkip("Record button is not hittable on this layout")
        }

        record.tap()
        XCTAssertTrue(
            waitForLabelChange(record, from: initialLabel),
            "Tapping the record control should toggle its title away from '\(initialLabel)'"
        )

        let toggledLabel = record.label
        record.tap()
        XCTAssertTrue(
            waitForLabelChange(record, from: toggledLabel),
            "Tapping the record control again should toggle its title back"
        )
    }

    // MARK: - Clear control

    func test_clearControl_isPresentAndReflectsEmptyLog() throws {
        try openArchitectInspector()

        let clear = app.buttons["architect-clear-button"]
        XCTAssertTrue(clear.waitForExistence(timeout: 3), "Clear button should be present")

        // With no generation performed, the event log is empty and Clear is
        // disabled. If the scripted backend happened to emit events, Clear is
        // enabled and tapping it must return the Timeline to its empty state.
        if clear.isEnabled, clear.isHittable {
            clear.tap()
            XCTAssertTrue(
                tabContentVisible("architect-timeline-tab", emptyStateText: "No Events Captured"),
                "Clearing the log should return the Timeline to its empty state"
            )
        } else {
            XCTAssertFalse(clear.isEnabled, "Clear should be disabled while the event log is empty")
        }
    }

    // MARK: - Helpers

    /// Opens the Architect inspector from the chat toolbar, falling back through
    /// the accessibility label and the toolbar overflow ("More") menu for
    /// compact layouts that collapse trailing toolbar items.
    ///
    /// This is the layout-tolerant path used by the *secondary* tests (tabs,
    /// record, clear, dismiss) and may `XCTSkip` when the entry point is
    /// unreachable. The entry point itself is hard-asserted (no skip) in
    /// `test_architectToolbarButton_opensInspector`.
    private func openArchitectInspector() throws {
        let directCandidates = [
            app.buttons["architect-toolbar-button"],
            app.buttons["Open Architect developer inspector"]
        ]
        for candidate in directCandidates where candidate.waitForExistence(timeout: 3) && candidate.isHittable {
            candidate.tap()
            if architectSheetVisible() { return }
        }

        // Trailing toolbar items can collapse into an overflow menu on compact
        // width. Open it and retry.
        let moreCandidates = [
            app.buttons["More"],
            app.navigationBars.buttons["More"],
            app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'More'")).firstMatch
        ]
        for more in moreCandidates where more.waitForExistence(timeout: 1) && more.isHittable {
            more.tap()
            for candidate in directCandidates where candidate.waitForExistence(timeout: 2) && candidate.isHittable {
                candidate.tap()
                if architectSheetVisible() { return }
            }
        }

        if !architectSheetVisible() {
            throw XCTSkip("Architect toolbar entry point not reachable on this layout/build")
        }
    }

    private func architectSheetVisible() -> Bool {
        app.staticTexts["Architect"].waitForExistence(timeout: 3)
            || app.navigationBars["Architect"].waitForExistence(timeout: 1)
            || app.buttons["architect-record-button"].waitForExistence(timeout: 1)
    }

    /// Selects an Architect tab in the segmented picker. iOS exposes segments as
    /// buttons; macOS may surface them under the picker's descendants.
    private func selectArchitectTab(_ label: String) {
        let picker = app.descendants(matching: .any)
            .matching(identifier: "architect-tab-picker")
            .firstMatch
        let inPicker = picker.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", label))
            .firstMatch
        let candidates = [
            inPicker,
            app.segmentedControls.buttons[label],
            app.buttons[label]
        ]
        for candidate in candidates where candidate.waitForExistence(timeout: 2) && candidate.isHittable {
            candidate.tap()
            return
        }
    }

    /// A tab is considered visible if its content-root identifier resolves, or —
    /// as a hierarchy-flattening fallback — the tab's empty-state text is shown.
    ///
    /// The empty-state fallback holds only because `--uitesting` loads no model,
    /// so every tab renders its "No …" placeholder. If a populated tab is ever
    /// exercised (real model loaded), assert on populated content instead — the
    /// empty-state text would no longer be present.
    private func tabContentVisible(_ identifier: String, emptyStateText: String) -> Bool {
        let root = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if root.waitForExistence(timeout: 3) {
            return true
        }
        return app.staticTexts[emptyStateText].waitForExistence(timeout: 2)
    }

    private func waitForLabelChange(
        _ element: XCUIElement,
        from previous: String,
        timeout: TimeInterval = 3
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.label != previous {
                return true
            }
        }
        return element.label != previous
    }
}
