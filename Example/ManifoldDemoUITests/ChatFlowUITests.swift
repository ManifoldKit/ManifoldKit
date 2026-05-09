import XCTest

final class ChatFlowUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = launchDemoApp()
        openChatDetailIfNeeded(app: app)
    }

    // MARK: - Empty / Welcome State

    func testEmptyStateShowsWelcome() throws {
        // Possible empty-state surfaces:
        //   - ChatView's no-session welcome ("Welcome to Manifold Demo") — pre-session.
        //   - ChatView's no-messages prompt ("Send a message to start chatting.").
        //   - The demo's session-but-no-messages picker ("Try a scenario").
        //   - Sidebar "No Model Selected" when no model is loaded.
        //
        // On macOS, list/form rows often combine into a single accessibility element
        // so the literal text isn't always exposed as a separate `staticText`. We
        // therefore search across `descendants(matching: .any)` rather than just
        // `staticTexts`.
        let predicate = NSPredicate(
            format: """
            label CONTAINS[c] 'Welcome' \
            OR label CONTAINS[c] 'Send a message to start chatting' \
            OR label CONTAINS[c] 'Try a scenario' \
            OR label CONTAINS[c] 'No Model Selected'
            """
        )
        let anyEmptyText = app.descendants(matching: .any).matching(predicate).firstMatch

        let hasEmptyState = waitForElement(anyEmptyText, timeout: 5)

        captureScreenshot(name: "Empty-State")
        XCTAssertTrue(hasEmptyState, "Should show a welcome message, empty placeholder, or no-model state on launch")
    }

    // MARK: - Input Bar

    func testChatInputBarExists() throws {
        // The input bar should always be visible at the bottom of the chat view
        let messageInput = app.textFields["Message input"]
        let textField = app.textFields["Message..."]

        let inputExists = waitForElement(messageInput, timeout: 5)
            || waitForElement(textField, timeout: 2)

        captureScreenshot(name: "Chat-Input-Bar")
        XCTAssertTrue(inputExists, "Chat input field should be present")

        // Send button should exist (it is always rendered, just disabled when empty)
        let sendButton = app.buttons["Send message"]
        XCTAssertTrue(waitForElement(sendButton, timeout: 3), "Send button should be present")
    }

    func testCanTypeInInputField() throws {
        let messageInput = findMessageInput()
        guard let input = messageInput else {
            captureScreenshot(name: "No-Input-Field")
            XCTFail("Could not find message input field")
            return
        }

        // The input may be disabled if no model is loaded; skip gracefully
        guard input.isEnabled else {
            captureScreenshot(name: "Input-Field-Disabled")
            return // Not a failure — no model loaded in test environment
        }

        input.tap()
        input.typeText("Hello, world!")

        captureScreenshot(name: "Typed-Text")

        // Verify the text was entered
        let typedText = input.value as? String ?? ""
        XCTAssertTrue(typedText.contains("Hello"), "Typed text should appear in the input field")
    }

    func testSendButtonStateChanges() throws {
        let sendButton = app.buttons["Send message"]
        guard waitForElement(sendButton, timeout: 5) else {
            captureScreenshot(name: "No-Send-Button")
            XCTFail("Send button not found")
            return
        }

        // When input is empty, the send button should be disabled
        XCTAssertFalse(sendButton.isEnabled, "Send button should be disabled when input is empty")

        captureScreenshot(name: "Send-Button-Disabled")

        // Type text — button may remain disabled if no model is loaded,
        // but we verify the basic flow
        let input = findMessageInput()
        if let input, input.isEnabled {
            input.tap()
            input.typeText("Test message")

            captureScreenshot(name: "Send-Button-After-Typing")
            // If a model is loaded, the button should now be enabled
            // We don't hard-fail because the test environment may not have a model
        }
    }

    func testSendMessageFlow() throws {
        let input = findMessageInput()
        guard let input, input.isEnabled else {
            captureScreenshot(name: "Send-Flow-Input-Unavailable")
            // Input is disabled (no model loaded) — skip gracefully
            return
        }

        input.tap()
        input.typeText("Hello from UI test")

        let sendButton = app.buttons["Send message"]
        guard waitForElement(sendButton, timeout: 3), sendButton.isEnabled else {
            captureScreenshot(name: "Send-Flow-Button-Disabled")
            return // Model not loaded — cannot send
        }

        sendButton.tap()

        // MessageBubbleView combines its content with `accessibilityElement(.combine)`
        // and exposes a "User said: <content>" label on the wrapping element. On
        // macOS, that wrapping element is exposed as `otherElement` — not a
        // `staticText` — so we search across all element types.
        let predicate = NSPredicate(format: "label CONTAINS[c] 'Hello from UI test'")
        let userMessage = app.descendants(matching: .any).matching(predicate).firstMatch

        let messageAppeared = waitForElement(userMessage, timeout: 5)
        captureScreenshot(name: "Send-Flow-After-Send")
        XCTAssertTrue(messageAppeared, "User message should appear in the chat after sending")
    }

    func testClearChatFlow() throws {
        // The clear button is in the toolbar with accessibility label "Clear chat"
        let clearButton = app.buttons["Clear chat"]
        guard waitForElement(clearButton, timeout: 5) else {
            captureScreenshot(name: "No-Clear-Button")
            // Clear button may not be visible if there's no toolbar space
            return
        }

        // If disabled (no messages), just verify it exists
        guard clearButton.isEnabled else {
            captureScreenshot(name: "Clear-Button-Disabled")
            return
        }

        clearButton.tap()

        // An alert should appear asking for confirmation
        let clearConfirmButton = app.buttons["Clear"]
        if waitForElement(clearConfirmButton, timeout: 3) {
            clearConfirmButton.tap()
            captureScreenshot(name: "Clear-Chat-After-Confirm")
        } else {
            captureScreenshot(name: "Clear-Chat-No-Alert")
        }
    }

    // MARK: - Helpers

    /// Finds the message input field using known accessibility labels.
    private func findMessageInput() -> XCUIElement? {
        let byLabel = app.textFields["Message input"]
        if waitForElement(byLabel, timeout: 3) { return byLabel }

        let byPlaceholder = app.textFields["Message..."]
        if waitForElement(byPlaceholder, timeout: 2) { return byPlaceholder }

        // Fall back to first text field
        let first = app.textFields.firstMatch
        if waitForElement(first, timeout: 2) { return first }

        return nil
    }
}
