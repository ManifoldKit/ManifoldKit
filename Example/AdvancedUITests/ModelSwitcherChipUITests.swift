import XCTest

/// Regression coverage for #2307: on compact width (iPhone), the toolbar
/// used to render the model-switcher chip at `.principal` placement, which
/// SwiftUI silently drops under space pressure — the chip vanished from
/// both the visible nav bar *and* the "More" overflow menu. Toolbar
/// placements proved unfixable on iOS 26 (`.principal` dropped;
/// `.topBarTrailing`/`.automatic` collapse into an overflow row that
/// renders but does not activate), so the fix mounts the chip in content
/// chrome on compact width — a `safeAreaInset` band under the nav bar
/// (`ChatView.showsModelChipInToolbar(horizontalSizeClass:)`), which is
/// deterministic: always visible, always tappable.
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
    ///
    /// The overflow menu's buttons are synthesized by the system from each
    /// collapsed toolbar item's label/image — confirmed by inspection, this
    /// synthesis drops custom `.accessibilityIdentifier`s entirely (even
    /// `ChatToolbarContent`'s existing `chat-settings-button` identifier
    /// disappears once its button collapses into "More"). So once inside
    /// the overflow menu we anchor on the chip's `cpu` system-image icon
    /// (`ChatView.modelChipButton`'s `Label(_, systemImage: "cpu")`) instead
    /// of the identifier, since the label text itself is the dynamic model
    /// name and isn't a stable match target.
    private func locateSwitcherChip() -> XCUIElement? {
        let directChip = app.descendants(matching: .any)["chat-model-switcher-chip"]
        if directChip.waitForExistence(timeout: 3), directChip.isHittable {
            return directChip
        }

        let more = app.buttons["OverflowBarButtonItem"]
        guard more.waitForExistence(timeout: 3), more.isHittable else { return nil }
        more.tap()

        let menuChip = app.buttons.containing(.image, identifier: "cpu").firstMatch
        if menuChip.waitForExistence(timeout: 3), menuChip.isHittable {
            return menuChip
        }
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
        saveScreenshot(name: "22-switcher-chip-compact")
        // Coordinate-tap, not element-tap: XCUITest's element tap on rows
        // inside a SwiftUI toolbar overflow menu can resolve to a frame the
        // hit-test misses (the menu stays open and the action never fires)
        // even when `isHittable` reports true. Center-coordinate taps land.
        chip.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        // iOS presents the switcher as a sheet with `.presentationDetents`
        // (see `ChatView.modelChipButton`). Tapping through the "More" menu
        // chains two system animations back to back (the menu dismissing,
        // then the sheet presenting), so give the transition a moment to
        // start before polling, and use a generous timeout rather than
        // racing a tight deadline.
        Thread.sleep(forTimeInterval: 0.5)
        // `app.sheets` NEVER matches SwiftUI sheet presentations on iOS (it
        // matches alerts/action sheets) — every earlier red on this assert
        // was partly this matcher bug. Wait for the switcher CONTENT instead,
        // which is also the stronger assertion (rows actually rendered).
        let sheetAppeared = app.descendants(matching: .any)["model-switcher-list"].waitForExistence(timeout: 10)

        captureScreenshot(name: "23-switcher-sheet-open")
        saveScreenshot(name: "23-switcher-sheet-open")
        XCTAssertTrue(sheetAppeared, "Tapping the model-switcher chip should present the switcher sheet")

        dismissSheet(app: app)
    }

    /// Writes a screenshot directly to disk (in addition to the
    /// `XCTAttachment` `captureScreenshot(name:)` keeps in the xcresult
    /// bundle) so the evidence survives as durable PNGs outside the
    /// ephemeral result bundle, matching the #2307 walkthrough's convention.
    private func saveScreenshot(name: String) {
        let dir = URL(
            fileURLWithPath: "/private/tmp/claude-501/-Users-roryford-Repos-ManifoldKit-ManifoldKit/f376d9f6-c188-4c16-be8b-a39b0cac9f78/scratchpad/walkthrough",
            isDirectory: true
        )
        let url = dir.appendingPathComponent(name).appendingPathExtension("png")
        do {
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: url)
        } catch {
            XCTFail("Failed to write screenshot \(name) to disk: \(error)")
        }
    }
}
