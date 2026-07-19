import XCTest

/// Regression coverage for #2307: on compact width (iPhone), the model-switcher
/// chip must stay visible and tappable. Toolbar placements fail on iOS 26
/// (`.principal` dropped; `.topBarTrailing`/`.automatic` collapse into an
/// overflow row that renders but does not activate), so compact width mounts
/// the chip in a `safeAreaInset` content-chrome band
/// (`ChatView.showsModelChipInToolbar(horizontalSizeClass:)`).
///
/// Runs on the Advanced demo's crowded toolbar because that crowding is what
/// originally dropped the chip — a sparser host would not have exposed it.
///
/// Dispatch logic is unit-tested in `ManifoldUITests` (CI gate). This XCUITest
/// is the end-to-end guard and runs via `example-ui-smoke.yml` (weekly/advisory).
final class ModelSwitcherChipUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchDemoApp()
        openChatDetailIfNeeded(app: app)
        XCTAssertTrue(waitForChatInputReady(app: app, timeout: 30), "Chat input should become ready before exercising the toolbar")
    }

    func testSwitcherChipReachableAndOpensSwitcherOnCompactWidth() throws {
        // Content-chrome placement keeps the identifier on the live button —
        // no overflow-menu fallback (that path is what #2307 proved dead).
        let chip = app.descendants(matching: .any)["chat-model-switcher-chip"]
        XCTAssertTrue(
            chip.waitForExistence(timeout: 5) && chip.isHittable,
            "chat-model-switcher-chip must be directly visible and tappable on compact width (#2307)"
        )

        captureScreenshot(name: "22-switcher-chip-compact")
        chip.tap()

        // `app.sheets` never matches SwiftUI sheet presentations on iOS —
        // wait for the switcher content itself (rows actually rendered).
        let sheetAppeared = app.descendants(matching: .any)["model-switcher-list"]
            .waitForExistence(timeout: 10)
        captureScreenshot(name: "23-switcher-sheet-open")
        XCTAssertTrue(sheetAppeared, "Tapping the model-switcher chip should present the switcher sheet")

        dismissSheet(app: app)
    }
}
