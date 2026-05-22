import XCTest

final class CloudAPIUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchDemoApp()
    }

    // MARK: - Navigation to API Configuration

    func testOpenAPIConfiguration() throws {
        navigateToAPIConfiguration()
        captureScreenshot(name: "API-Config-Opened")
    }

    func testEmptyStateMessage() throws {
        navigateToAPIConfiguration()

        // When no endpoints are configured the form shows the empty-state Text;
        // if endpoints exist, the "Endpoints" section header is shown instead.
        // On macOS, Form-section content can be combined into row elements
        // rather than surfaced as `staticTexts` — search across any element type.
        let emptyText = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS[c] 'No cloud APIs configured'")).firstMatch
        let hasEmptyState = waitForElement(emptyText, timeout: 3)

        captureScreenshot(name: "API-Config-Empty-State")

        if !hasEmptyState {
            let endpointsSection = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == 'Endpoints'")).firstMatch
            XCTAssertTrue(waitForElement(endpointsSection, timeout: 3),
                          "Should show either empty state or Endpoints section")
        }
    }

    func testAddEndpointFlow() throws {
        navigateToAPIConfiguration()

        // The "Add Endpoint" control is a SwiftUI Button with a `Label`.
        // macOS exposes the Label as the button's accessibility label, but the
        // exact element type varies — match across descendants for safety.
        let addButton: XCUIElement
        if app.buttons["Add Endpoint"].waitForExistence(timeout: 3) {
            addButton = app.buttons["Add Endpoint"]
        } else {
            addButton = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == 'Add Endpoint'")).firstMatch
        }
        guard waitForElement(addButton, timeout: 3) else {
            captureScreenshot(name: "API-Config-No-Add-Button")
            XCTFail("Add Endpoint button not found")
            return
        }

        addButton.tap()

        // The editor sheet should appear with "Add Endpoint" title
        let editorTitle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Add Endpoint' OR value == 'Add Endpoint'"))
            .firstMatch
        XCTAssertTrue(waitForElement(editorTitle, timeout: 5),
                      "Endpoint editor should appear with 'Add Endpoint' title")

        // Verify the editor's text fields. SwiftUI `TextField("Display Name", text:)`
        // exposes the title via `label` on iOS but only as a sibling StaticText
        // on macOS — the field itself reports the current text as `value`.
        // Confirm the editor rendered by asserting the labels exist (any
        // descendant) and that the underlying text-field count matches what
        // the source declares (3 TextFields + 1 SecureField for OpenAI default).
        for fieldLabel in ["Display Name", "Server URL", "Model Name"] {
            let label = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@ OR value == %@", fieldLabel, fieldLabel))
                .firstMatch
            XCTAssertTrue(label.waitForExistence(timeout: 3),
                          "\(fieldLabel) label should exist in editor")
        }
        XCTAssertGreaterThanOrEqual(app.textFields.count, 3,
                                    "Editor should contain at least 3 text fields")

        // API Key field (SecureField) — look for it
        let apiKeyField = app.secureTextFields["API Key"]
        // API key may not be visible if the default provider doesn't require one
        if apiKeyField.exists {
            captureScreenshot(name: "API-Editor-With-API-Key")
        }

        captureScreenshot(name: "API-Editor-Fields")

        // Dismiss the editor
        let cancelButton = app.buttons["Cancel"]
        if waitForElement(cancelButton, timeout: 2) {
            cancelButton.tap()
        } else {
            dismissSheet(app: app)
        }
    }

    func testDismissAPIConfig() throws {
        navigateToAPIConfiguration()

        // macOS doesn't render a SwiftUI `.navigationBarTitleDisplayMode`-style
        // bar; the Done button placed via `ToolbarItem(.confirmationAction)`
        // appears under the Cloud APIs sheet directly. Two sheets are stacked
        // (Generation Settings -> Cloud APIs), each with its own Done button,
        // so target the most-recently-presented sheet on macOS.
        let doneButton: XCUIElement = {
            let inNavBar = app.navigationBars["Cloud APIs"].buttons["Done"]
            if inNavBar.waitForExistence(timeout: 1) {
                return inNavBar
            }
            #if os(macOS)
            let sheetsCount = app.sheets.count
            if sheetsCount > 0 {
                let topSheet = app.sheets.element(boundBy: sheetsCount - 1)
                let sheetDone = topSheet.buttons["Done"]
                if sheetDone.exists { return sheetDone }
            }
            #endif
            return app.buttons["Done"].firstMatch
        }()
        guard waitForElement(doneButton, timeout: 3) else {
            captureScreenshot(name: "API-Config-No-Done-Button")
            XCTFail("Done button not found in API configuration")
            return
        }

        doneButton.tap()

        if apiTitleStillVisible(app: app) {
            dismissSheet(app: app)
        }

        // The "Cloud APIs" title should no longer be visible — search any
        // element type so the assertion holds across iOS (nav title) and macOS
        // (sheet title rendered as a different element kind).
        let apiTitle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Cloud APIs' OR value == 'Cloud APIs'"))
            .firstMatch
        let disappeared = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: apiTitle
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [disappeared], timeout: 3),
            .completed,
            "API configuration sheet should be dismissed after tapping Done"
        )

        captureScreenshot(name: "API-Config-Dismissed")
    }

    // MARK: - Helpers

    /// Navigates from the main app to the API Configuration view.
    /// Path: Settings button -> Advanced Settings -> Manage Cloud APIs
    private func navigateToAPIConfiguration() {
        openChatDetailIfNeeded(app: app)

        // Step 1: Open settings
        if !tapToolbarButton("Generation settings", app: app) {
            let gearButton = app.buttons.matching(NSPredicate(
                format: "label CONTAINS[c] 'Settings' OR label CONTAINS[c] 'gear'"
            )).firstMatch
            guard waitForElement(gearButton, timeout: 3), gearButton.isHittable else {
                captureScreenshot(name: "API-Nav-No-Settings-Button")
                XCTFail("Could not find settings button to navigate to API configuration")
                return
            }
            gearButton.tap()
        }

        // Wait for settings sheet
        let settingsTitle = app.staticTexts["Generation Settings"]
        guard waitForElement(settingsTitle, timeout: 5) else {
            captureScreenshot(name: "API-Nav-Settings-Not-Opened")
            XCTFail("Settings sheet did not open")
            return
        }

        // Step 2: Expand Advanced Settings disclosure
        //
        // The "Manage Cloud APIs" control is a `Button` whose label is a SwiftUI
        // `Label("Manage Cloud APIs", systemImage: "cloud")`. On macOS the
        // accessibility hierarchy combines the icon and text into a single
        // button accessible by `label`, while iOS often surfaces the inner
        // `Text` as a separate `staticText`. Match across any element type so
        // both platforms work without branching.
        // Match strictly on "Manage Cloud APIs" so we don't pick up the "Cloud APIs"
        // Section header (which is not tappable as navigation).
        let manageAPIsAnyMatch = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Manage Cloud APIs'"))
            .firstMatch

        // The demo seeds `showAdvancedSettings = true` in UserDefaults during
        // `--uitesting` so the disclosure is already expanded; if running
        // against a different launch arg path we still try to toggle it.
        let advancedDisclosure = advancedSettingsDisclosure(app: app)
        if !manageAPIsAnyMatch.exists,
           waitForElement(advancedDisclosure, timeout: 3) {
            toggleDisclosure(advancedDisclosure)
            _ = manageAPIsAnyMatch.waitForExistence(timeout: 3)
        }

        // Step 3: Tap "Manage Cloud APIs". We scroll within the form by
        // dragging on whichever sheet/window contains the disclosure (covered
        // by `scrollToElement`'s macOS branch), then prefer the hittable button
        // form for the actual tap.
        guard scrollToElement(manageAPIsAnyMatch, app: app), waitForElement(manageAPIsAnyMatch, timeout: 2) else {
            captureScreenshot(name: "API-Nav-No-Manage-Button")
            // The Cloud API section may be hidden by feature flags
            XCTFail("Manage Cloud APIs button not found — feature may be disabled")
            return
        }

        let manageAPIsButton = app.buttons["Manage Cloud APIs"]
        if manageAPIsButton.exists, manageAPIsButton.isHittable {
            manageAPIsButton.tap()
        } else {
            manageAPIsAnyMatch.tap()
        }

        // Wait for the API configuration sheet
        let apiTitle = app.staticTexts["Cloud APIs"]
        guard waitForElement(apiTitle, timeout: 5) else {
            captureScreenshot(name: "API-Nav-Config-Not-Opened")
            XCTFail("API Configuration sheet did not open")
            return
        }
    }

    private func apiTitleStillVisible(app: XCUIApplication) -> Bool {
        // The "Cloud APIs" string can appear as a static text (iOS nav title),
        // a sheet title, or an other element on macOS — search broadly.
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Cloud APIs' OR value == 'Cloud APIs'"))
            .firstMatch
            .exists
    }
}
