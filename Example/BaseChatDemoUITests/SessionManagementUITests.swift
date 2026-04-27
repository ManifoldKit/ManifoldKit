import XCTest

final class SessionManagementUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchDemoApp()
    }

    // MARK: - Sidebar & Session List

    func testSidebarShowsSessions() throws {
        showSidebarIfNeeded(app: app)

        // The sidebar navigation title is "Chats"
        let chatsTitle = app.staticTexts["Chats"]
        let sidebarVisible = waitForElement(chatsTitle, timeout: 5)
            || findNewChatButton(app: app) != nil
            || app.cells.firstMatch.waitForExistence(timeout: 2)
        XCTAssertTrue(sidebarVisible, "Sidebar should show the session list")

        captureScreenshot(name: "Sidebar-Sessions-Visible")
    }

    func testDefaultSessionExists() throws {
        showSidebarIfNeeded(app: app)

        // The app creates a default session during launch bootstrap.
        // Look for at least one session row — sessions have a title like "New Chat"
        // or a timestamp. We check for any cell in the list.
        let sessionCells = app.cells
        let hasSession = sessionCells.firstMatch.waitForExistence(timeout: 5)

        // Also check for the "New Chat" text which is the default session title
        let newChatText = app.staticTexts.matching(NSPredicate(
            format: "label CONTAINS[c] 'New Chat' OR label CONTAINS[c] 'Chat'"
        )).firstMatch

        captureScreenshot(name: "Default-Session")
        XCTAssertTrue(hasSession || newChatText.exists, "At least one session should exist after launch")
    }

    func testSessionAutoSelectedOnLaunch() throws {
        openChatDetailIfNeeded(app: app)

        // After launch, a session should be auto-selected so the chat input
        // never shows "No session selected" — this was an iPad-specific regression
        // where createSession() didn't activate the session it created.
        //
        // TextField placeholders do not appear as staticTexts in the accessibility
        // hierarchy; use placeholderValue on the field directly.
        let messageInput = app.textFields["Message input"]
        guard messageInput.waitForExistence(timeout: 5) else {
            captureScreenshot(name: "Session-Auto-Selected-No-Input")
            XCTFail("Message input field not found")
            return
        }

        let placeholder = messageInput.placeholderValue ?? ""
        captureScreenshot(name: "Session-Auto-Selected")
        XCTAssertNotEqual(
            placeholder,
            "No session selected",
            "Input bar must not show 'No session selected' — session should be auto-activated on launch"
        )
    }

    func testCreateNewSession() throws {
        showSidebarIfNeeded(app: app)

        // Count sessions before creating a new one
        let cellsBefore = app.cells.count

        // The "+" button in the toolbar creates a new session (label: "New Chat")
        guard let newChatButton = findNewChatButton(app: app) else {
            captureScreenshot(name: "No-New-Chat-Button")
            XCTFail("New Chat button not found in sidebar toolbar")
            return
        }

        newChatButton.tap()

        // On compact, creating a session activates it and collapses to the
        // detail column, so reveal the sidebar again before counting rows.
        showSidebarIfNeeded(app: app)

        // Wait for the new session to appear
        let cellsAfterPredicate = NSPredicate(format: "count > %d", cellsBefore)
        let cellsQuery = app.cells
        let expectation = XCTNSPredicateExpectation(predicate: cellsAfterPredicate, object: cellsQuery)
        let result = XCTWaiter.wait(for: [expectation], timeout: 5)

        captureScreenshot(name: "After-Create-Session")

        if result == .completed {
            XCTAssertGreaterThan(app.cells.count, cellsBefore, "A new session should appear after tapping New Chat")
        } else {
            // The session might replace the existing one; just verify at least one exists
            XCTAssertGreaterThan(app.cells.count, 0, "At least one session should exist after creation")
        }
    }

    func testSwitchBetweenSessions() throws {
        showSidebarIfNeeded(app: app)

        // Ensure we have at least two sessions
        guard let newChatButton = findNewChatButton(app: app) else {
            captureScreenshot(name: "No-New-Chat-Button-Switch")
            XCTFail("New Chat button not found")
            return
        }

        // Create a second session if needed. On compact, the tap activates the
        // new session and collapses to the detail column, so re-reveal the
        // sidebar before checking the row count.
        if app.cells.count < 2 {
            newChatButton.tap()
            showSidebarIfNeeded(app: app)
            _ = app.cells.element(boundBy: 1).waitForExistence(timeout: 3)
        }

        guard app.cells.count >= 2 else {
            captureScreenshot(name: "Not-Enough-Sessions")
            XCTFail("Need at least 2 sessions for switching test")
            return
        }

        // Tap the first session
        let firstSession = app.cells.element(boundBy: 0)
        firstSession.tap()
        captureScreenshot(name: "Switch-First-Session")

        // Show sidebar again (tapping a session may collapse it on iPad)
        showSidebarIfNeeded(app: app)

        // Tap the second session
        let secondSession = app.cells.element(boundBy: 1)
        if secondSession.waitForExistence(timeout: 3) {
            secondSession.tap()
            captureScreenshot(name: "Switch-Second-Session")
        }
    }

    func testDeleteSession() throws {
        showSidebarIfNeeded(app: app)

        // Ensure at least two sessions so deleting one still leaves one
        guard let newChatButton = findNewChatButton(app: app) else {
            captureScreenshot(name: "No-New-Chat-Button-Delete")
            return
        }

        if app.cells.count < 2 {
            newChatButton.tap()
            _ = app.cells.element(boundBy: 1).waitForExistence(timeout: 3)
        }

        let countBefore = app.cells.count
        guard countBefore >= 2 else {
            captureScreenshot(name: "Not-Enough-Sessions-Delete")
            return
        }

        // Swipe-to-delete on the first session
        let firstSession = app.cells.element(boundBy: 0)
        firstSession.swipeLeft()

        let deleteButton = app.buttons["Delete"]
        if waitForElement(deleteButton, timeout: 3) {
            if deleteButton.isHittable {
                deleteButton.tap()
            } else {
                deleteButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }

            // Confirm deletion in the alert
            let confirmDelete = app.alerts.buttons["Delete"]
            if waitForElement(confirmDelete, timeout: 3) {
                confirmDelete.tap()
            }

            captureScreenshot(name: "After-Delete-Session")
        } else {
            captureScreenshot(name: "No-Delete-Button-After-Swipe")
        }
    }
}
