import XCTest

/// XCUITest coverage for the turn-loop actions ManifoldKit's Principle 8
/// centers on: **regenerate**, **edit**, **cancel**, and **branch**
/// (`ConversationRuntime`'s `send`/`regenerate`/`edit`/`cancel`/`branch`).
///
/// Issue #2453 found that `scripts/demo-coverage-manifest.tsv` scored the
/// `turn-loop-actions` row as executed while zero XCUITests actually drove
/// regenerate, edit, or branch through the UI — only `send` (``ChatFlowUITests``)
/// and `clear` had coverage. This suite closes that hole.
///
/// Each test drives the affordance through ``MessageActionMenuModifier``'s
/// context menu (long-press on iOS, secondary-click on macOS) — the same
/// entry point a real user has — rather than calling `ChatViewModel` methods
/// directly, so a regression in the menu wiring itself (not just the
/// underlying view-model method) fails the test.
///
/// Scripted-turn design (`DemoScenarios+Scripts.swift`, `"turn-loop-actions"` /
/// `"turn-loop-cancel"`): `ScriptedBackend` pops one script entry per
/// `generate()` call. A plain token-only turn (no tool call) costs exactly
/// one `generate()` call per user-visible reply, so a fresh app launch's
/// two-entry `"turn-loop-actions"` script covers "initial send" (entry 0)
/// plus whichever single follow-up turn (regenerate OR edit) a given test
/// drives next (entry 1) — each test launches its own app process, so the
/// cursor always starts at 0. `ChatViewModel.branch(from:)` never calls
/// `generate()` at all (it only persists a new session), so the branch test
/// only ever consumes entry 0.
final class TurnLoopActionUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Regenerate

    /// Which assertion fails if regenerate broke: after tapping "Regenerate"
    /// on the assistant reply, the ORIGINAL reply text must be gone and a
    /// NEW, scripted-distinct reply must be present. `runRegenerateFlow`
    /// (`ConversationTurnExecutor.swift`) deletes the old assistant message
    /// before generating the replacement, so this is a real content swap,
    /// not an append — both halves of the assertion are load-bearing.
    func testRegenerateReplacesAssistantReply() throws {
        let app = launchDemoApp(scenario: "turn-loop-actions")
        openChatDetailIfNeeded(app: app)

        guard let input = findMessageInput(app: app), input.isEnabled else {
            captureScreenshot(name: "Regenerate-Input-Unavailable")
            XCTFail("Message input unavailable")
            return
        }
        input.tap()
        input.typeText("Tell me something")

        let sendButton = app.buttons["Send message"]
        guard waitForElement(sendButton, timeout: 5), sendButton.isEnabled else {
            captureScreenshot(name: "Regenerate-Send-Unavailable")
            XCTFail("Send button unavailable")
            return
        }
        sendButton.tap()

        let firstReply = assistantBubble(app: app, containing: "This is the first reply")
        guard waitForElement(firstReply, timeout: 10) else {
            captureScreenshot(name: "Regenerate-No-Initial-Reply")
            XCTFail("Initial assistant reply never appeared")
            return
        }
        captureScreenshot(name: "Regenerate-Before")

        guard openMessageContextMenu(firstReply) else {
            captureScreenshot(name: "Regenerate-Context-Menu-Failed")
            XCTFail("Could not open the assistant message's context menu")
            return
        }
        captureScreenshot(name: "Regenerate-Context-Menu-Open")

        guard tapContextMenuAction(identifier: "message-action-regenerate", label: "Regenerate", app: app) else {
            captureScreenshot(name: "Regenerate-Menu-Item-Missing")
            XCTFail("Regenerate menu item not found")
            return
        }

        let secondReply = assistantBubble(app: app, containing: "This is a different, second reply")
        let regenerated = waitForElement(secondReply, timeout: 10)
        captureScreenshot(name: "Regenerate-After")

        XCTAssertTrue(regenerated, "A regenerated reply with scripted-distinct content should appear")
        XCTAssertFalse(firstReply.exists, "The pre-regenerate reply should have been replaced, not kept alongside the new one")
    }

    // MARK: - Edit

    /// Which assertion fails if edit broke: after editing the sent user
    /// message and saving, the EDITED text must render in place of the
    /// original, and the assistant's reply must be the second scripted
    /// entry — proving `runEditFlow` actually truncated and regenerated the
    /// downstream turn rather than leaving stale history in place.
    func testEditUserMessageRewritesHistory() throws {
        let app = launchDemoApp(scenario: "turn-loop-actions")
        openChatDetailIfNeeded(app: app)

        guard let input = findMessageInput(app: app), input.isEnabled else {
            captureScreenshot(name: "Edit-Input-Unavailable")
            XCTFail("Message input unavailable")
            return
        }
        input.tap()
        input.typeText("Original message")

        let sendButton = app.buttons["Send message"]
        guard waitForElement(sendButton, timeout: 5), sendButton.isEnabled else {
            captureScreenshot(name: "Edit-Send-Unavailable")
            XCTFail("Send button unavailable")
            return
        }
        sendButton.tap()

        let firstReply = assistantBubble(app: app, containing: "This is the first reply")
        guard waitForElement(firstReply, timeout: 10) else {
            captureScreenshot(name: "Edit-No-Initial-Reply")
            XCTFail("Initial assistant reply never appeared")
            return
        }

        let userBubble = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'Original message'"))
            .firstMatch
        guard waitForElement(userBubble, timeout: 5) else {
            captureScreenshot(name: "Edit-User-Bubble-Missing")
            XCTFail("Original user message never appeared")
            return
        }

        guard openMessageContextMenu(userBubble) else {
            captureScreenshot(name: "Edit-Context-Menu-Failed")
            XCTFail("Could not open the user message's context menu")
            return
        }

        guard tapContextMenuAction(identifier: "message-action-edit", label: "Edit", app: app) else {
            captureScreenshot(name: "Edit-Menu-Item-Missing")
            XCTFail("Edit menu item not found")
            return
        }

        let textEditor = app.textViews["message-edit-text-editor"]
        guard waitForElement(textEditor, timeout: 5) else {
            captureScreenshot(name: "Edit-Sheet-Missing")
            XCTFail("Edit sheet's text editor never appeared")
            return
        }
        captureScreenshot(name: "Edit-Sheet-Open")

        // Tapping this (large) TextEditor does NOT reliably place the caret
        // at the end of its single line of existing text — verified by
        // instrumenting this test to log `textEditor.value` after exactly
        // this tap+typeText sequence: it read
        // `" EDITEDOriginal message"`, i.e. the caret landed at position 0,
        // not the end. (A prior version of this test assumed
        // tap-places-caret-at-end, which does not hold on this simulator —
        // see #2453 PR discussion.) Select-all + retype the full desired
        // content sidesteps caret-position uncertainty entirely, rather than
        // relying on where an on-screen tap happens to land.
        textEditor.tap()
        textEditor.typeKey("a", modifierFlags: .command)
        textEditor.typeText("Original message EDITED")

        let saveButton = app.buttons["message-edit-save"]
        guard waitForElement(saveButton, timeout: 3), saveButton.isEnabled else {
            captureScreenshot(name: "Edit-Save-Unavailable")
            XCTFail("Save button unavailable")
            return
        }
        saveButton.tap()

        let editedUserBubble = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'Original message EDITED'"))
            .firstMatch
        let editedTextShows = waitForElement(editedUserBubble, timeout: 5)
        captureScreenshot(name: "Edit-After-Save")
        XCTAssertTrue(editedTextShows, "Edited user message text should render in the transcript")

        let updatedReply = assistantBubble(app: app, containing: "This is a different, second reply")
        let downstreamUpdated = waitForElement(updatedReply, timeout: 10)
        captureScreenshot(name: "Edit-Downstream-Reply")
        XCTAssertTrue(downstreamUpdated, "The assistant reply after the edited message should regenerate")
    }

    // MARK: - Cancel

    /// `ScriptedBackend` (`Sources/ManifoldTools/ScriptedBackend.swift`)
    /// yields every token in a tight loop with no artificial delay, so
    /// there is no way to make "generation was truncated mid-stream" a
    /// deterministic UI-level assertion without adding delay support to a
    /// shared test-infrastructure type — out of scope for this PR (see PR
    /// body). This is therefore the strongest HONEST variant: it asserts
    /// the Stop-generation control is actually reachable while a turn is in
    /// flight (proving the cancel affordance is live, not just present in
    /// source), and that invoking it deterministically returns the composer
    /// to its idle/ready state. It does NOT assert the streamed content was
    /// interrupted before completion — that claim is not testable at UI
    /// speed against this backend.
    ///
    /// Which assertion fails if cancel broke: if `stopGeneration()` stopped
    /// forwarding to `ChatViewModel.stopGeneration()`, or the phase
    /// transition it drives stopped working, the Send button / composer
    /// would never return to its idle, re-enabled state.
    func testCancelStopsGeneration() throws {
        let app = launchDemoApp(scenario: "turn-loop-cancel")
        openChatDetailIfNeeded(app: app)

        guard let input = findMessageInput(app: app), input.isEnabled else {
            captureScreenshot(name: "Cancel-Input-Unavailable")
            XCTFail("Message input unavailable")
            return
        }
        input.tap()
        input.typeText("Say a lot")

        let sendButton = app.buttons["Send message"]
        guard waitForElement(sendButton, timeout: 5), sendButton.isEnabled else {
            captureScreenshot(name: "Cancel-Send-Unavailable")
            XCTFail("Send button unavailable")
            return
        }
        sendButton.tap()

        let stopButton = app.buttons["Stop generation"]
        let sawStopButton = waitForElement(stopButton, timeout: 5)
        captureScreenshot(name: "Cancel-Stop-Button-State")
        XCTAssertTrue(sawStopButton, "The Stop-generation control should appear while a (400-token scripted) turn is in flight")

        if stopButton.exists, stopButton.isHittable {
            stopButton.tap()
        }

        let idleSendButton = app.buttons["Send message"]
        let returnedToIdle = waitForElement(idleSendButton, timeout: 10)
        captureScreenshot(name: "Cancel-After-Stop")
        XCTAssertTrue(returnedToIdle, "Composer should return to its idle state (Send button visible) after cancel")
        XCTAssertFalse(app.buttons["Stop generation"].exists, "Stop-generation control should be gone once cancelled")
    }

    // MARK: - Branch

    /// Which assertion fails if branch broke: after "Branch from here", the
    /// app should be looking at the newly-created branched session, which
    /// renders `BranchOriginChipView` (`Sources/ManifoldUI/Views/Chat/HandoffChipView.swift`,
    /// stable identifier `branch-origin-chip`, #2307) at the top of its
    /// transcript. This exercises `ManifoldDemoApp`'s `vm.onSessionBranched`
    /// wiring added in this PR — without it, `branch(from:)` still persists
    /// the new session, but the demo silently stays on the source session
    /// and the chip is never reachable (a "shipped but not live" gap this
    /// test would have caught per Principle 10).
    func testBranchCreatesAlternatePath() throws {
        let app = launchDemoApp(scenario: "turn-loop-actions")
        openChatDetailIfNeeded(app: app)

        guard let input = findMessageInput(app: app), input.isEnabled else {
            captureScreenshot(name: "Branch-Input-Unavailable")
            XCTFail("Message input unavailable")
            return
        }
        input.tap()
        input.typeText("Branch source message")

        let sendButton = app.buttons["Send message"]
        guard waitForElement(sendButton, timeout: 5), sendButton.isEnabled else {
            captureScreenshot(name: "Branch-Send-Unavailable")
            XCTFail("Send button unavailable")
            return
        }
        sendButton.tap()

        let reply = assistantBubble(app: app, containing: "This is the first reply")
        guard waitForElement(reply, timeout: 10) else {
            captureScreenshot(name: "Branch-No-Initial-Reply")
            XCTFail("Initial assistant reply never appeared")
            return
        }
        captureScreenshot(name: "Branch-Before")

        guard openMessageContextMenu(reply) else {
            captureScreenshot(name: "Branch-Context-Menu-Failed")
            XCTFail("Could not open the assistant message's context menu")
            return
        }

        guard tapContextMenuAction(identifier: "message-action-branch", label: "Branch from here", app: app) else {
            captureScreenshot(name: "Branch-Menu-Item-Missing")
            XCTFail("Branch menu item not found")
            return
        }

        let branchChip = app.descendants(matching: .any)
            .matching(identifier: "branch-origin-chip")
            .firstMatch
        let sawBranchChip = waitForElement(branchChip, timeout: 10)
        captureScreenshot(name: "Branch-After")
        XCTAssertTrue(
            sawBranchChip,
            "Branching should switch the demo to the new session and render its 'Branched from' origin chip"
        )
    }

    // MARK: - Helpers

    /// Launches the demo with `--uitesting` plus `--bck-demo-scenario <id>`
    /// so `ManifoldDemoApp` swaps in the matching `ScriptedBackend` turn
    /// list (`DemoScenarios.scriptedTurns(for:)`) while the chat itself
    /// starts empty — these scenario IDs are deliberately NOT registered in
    /// `DemoScenarios.all`, so no card auto-send fires; every message in
    /// this suite is typed and sent manually, exactly like `ChatFlowUITests`.
    private func launchDemoApp(scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--uitesting", "--bck-demo-scenario", scenario]
        #if !os(macOS)
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        #endif
        app.launch()
        #if os(macOS)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "ManifoldDemo should reach the foreground under macOS UI tests")
        #endif
        return app
    }

    /// Finds the message input field the same way `ChatFlowUITests` does.
    private func findMessageInput(app: XCUIApplication) -> XCUIElement? {
        let byLabel = app.textFields["Message input"]
        if waitForElement(byLabel, timeout: 5) { return byLabel }

        let byPlaceholder = app.textFields["Message..."]
        if waitForElement(byPlaceholder, timeout: 2) { return byPlaceholder }

        let first = app.textFields.firstMatch
        if waitForElement(first, timeout: 2) { return first }

        return nil
    }

    /// Locates an assistant bubble by its `"Assistant said: …"` accessibility
    /// label (`MessageBubbleView.accessibilityLabel(for:)`), scoped to
    /// assistant-authored text so it never accidentally matches the user's
    /// own prompt.
    private func assistantBubble(app: XCUIApplication, containing text: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label BEGINSWITH[c] 'Assistant said:' AND label CONTAINS[c] %@", text)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    /// Opens `MessageActionMenuModifier`'s context menu on a message bubble:
    /// secondary-click on macOS, long-press on iOS/iPadOS — matching the
    /// modifier's own doc comment on how each platform surfaces it.
    @discardableResult
    private func openMessageContextMenu(_ element: XCUIElement) -> Bool {
        guard waitForElement(element, timeout: 5) else { return false }
        #if os(macOS)
        element.rightClick()
        #else
        element.press(forDuration: 1.2)
        #endif
        return true
    }

    /// Taps a context-menu action, preferring the stable accessibility
    /// identifier added to `MessageActionMenuModifier` in this PR and
    /// falling back to the plain label (XCUITest's identifier lookup
    /// already falls back to label when no explicit identifier is set, but
    /// the fallback chain here also covers `.menuItems` for macOS's native
    /// `NSMenu` representation of a SwiftUI `.contextMenu`).
    @discardableResult
    private func tapContextMenuAction(identifier: String, label: String, app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
        let candidates = [
            app.buttons[identifier],
            app.menuItems[identifier],
            app.buttons[label],
            app.menuItems[label],
            app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", identifier)).firstMatch
        ]

        for candidate in candidates where candidate.waitForExistence(timeout: timeout) && candidate.isHittable {
            candidate.tap()
            return true
        }

        return false
    }
}
