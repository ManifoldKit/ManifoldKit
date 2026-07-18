import XCTest

/// Regression coverage for #2307: on compact width (iPhone), the toolbar
/// used to render the model-switcher chip at `.principal` placement, which
/// SwiftUI silently drops under space pressure — the chip vanished from
/// both the visible nav bar *and* the "More" overflow menu, with no way for
/// the user to reach it. The fix moves the chip to `.topBarTrailing` on
/// compact width (`ChatView.modelChipPlacement(horizontalSizeClass:)`),
/// which still collapses into the overflow menu under a crowded host
/// toolbar (expected — the same trade-off `ChatToolbarContent` already
/// accepts for its own indicators/actions) but never disappears outright.
///
/// This suite runs on the Advanced demo's crowded toolbar (back button,
/// show-sidebar-button, demo-appearance-menu, context indicator, memory
/// indicator) precisely because that crowding is what triggered the bug —
/// a sparser host toolbar wouldn't have exposed it.
final class ModelSwitcherChipUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchDemoApp()
        openChatDetailIfNeeded(app: app)
        XCTAssertTrue(waitForChatInputReady(app: app, timeout: 30), "Chat input should become ready before exercising the toolbar")
    }

    /// Finds the model-switcher chip, opening the "More" overflow menu first
    /// if the chip isn't directly visible in the bar (compact width).
    private func locateSwitcherChip() -> XCUIElement? {
        let directChip = app.descendants(matching: .any)["chat-model-switcher-chip"]
        if directChip.waitForExistence(timeout: 3), directChip.isHittable {
            return directChip
        }

        let more = app.buttons["OverflowBarButtonItem"]
        guard more.waitForExistence(timeout: 3), more.isHittable else { return nil }
        more.tap()

        let menuChip = app.descendants(matching: .any)["chat-model-switcher-chip"]
        if menuChip.waitForExistence(timeout: 3), menuChip.isHittable {
            return menuChip
        }
        let dumpURL = URL(fileURLWithPath: "/private/tmp/claude-501/-Users-roryford-Repos-ManifoldKit-ManifoldKit/f376d9f6-c188-4c16-be8b-a39b0cac9f78/scratchpad/walkthrough/DEBUG-overflow-open-hierarchy.txt")
        try? app.debugDescription.write(to: dumpURL, atomically: true, encoding: .utf8)
        return nil
    }

    func testSwitcherChipReachableAndOpensSwitcherOnCompactWidth() throws {
        let chip = locateSwitcherChip()
        XCTAssertNotNil(
            chip,
            "chat-model-switcher-chip must be reachable (visible in the bar or the \"More\" overflow menu) — it must never be silently dropped from both (#2307)"
        )
        guard let chip else { return }

        captureScreenshot(name: "22-switcher-chip-compact")
        chip.tap()

        // iOS presents the switcher as a sheet with `.presentationDetents`
        // (see `ChatView.modelChipButton`); wait for the sheet surface
        // itself rather than a specific row, since row content depends on
        // the demo's registered models/endpoints.
        let sheetAppeared = app.sheets.firstMatch.waitForExistence(timeout: 5)

        captureScreenshot(name: "23-switcher-sheet-open")
        XCTAssertTrue(sheetAppeared, "Tapping the model-switcher chip should present the switcher sheet")

        dismissSheet(app: app)
    }
}
