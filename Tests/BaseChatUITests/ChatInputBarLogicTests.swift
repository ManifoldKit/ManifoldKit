@preconcurrency import XCTest
@testable import BaseChatUI
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference
@testable import BaseChatTestSupport

/// Tests for the logic that drives ChatInputBar's enabled/disabled states.
///
/// ChatInputBar computes `canSend` and `showRegenerateButton` from ChatViewModel
/// properties. These tests verify those conditions via the view model directly,
/// since the SwiftUI view is a thin projection of this state.
@MainActor
final class ChatInputBarLogicTests: XCTestCase {

    private nonisolated(unsafe) var harnesses: [TestChatViewModelHarness] = []

    override func tearDown() async throws {
        for harness in harnesses { harness.cleanup() }
        harnesses.removeAll()
        try await super.tearDown()
    }

    private func makeViewModel() -> ChatViewModel {
        let harness = try! makeTestChatViewModel()
        harnesses.append(harness)
        return harness.vm
    }

    private func makeViewModelWithMock(
        mock: MockInferenceBackend = MockInferenceBackend()
    ) -> (ChatViewModel, MockInferenceBackend) {
        let harness = try! makeTestChatViewModel(mock: mock, activateSession: true)
        harnesses.append(harness)
        return (harness.vm, harness.mock!)
    }

    // MARK: - canSend conditions

    /// canSend requires: activeSession != nil, isModelLoaded, !isGenerating, !isLoading, non-empty trimmed input.
    /// Mirror the view's logic: ChatInputBar.canSend
    private func canSend(_ vm: ChatViewModel) -> Bool {
        vm.activeSession != nil
        && vm.isModelLoaded
        && !vm.isGenerating
        && !vm.isLoading
        && (
            !vm.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !vm.draftAttachments.isEmpty
        )
    }

    func test_canSend_falseWhenNoActiveSession() async {
        let vm = await makeViewModel()
        vm.inputText = "Hello"
        // No session, no model
        XCTAssertFalse(canSend(vm), "canSend should be false without an active session")
    }

    func test_canSend_falseWhenNoModelLoaded() async {
        let vm = await makeViewModel()
        vm.activeSession = ChatSessionRecord(title: "Test")
        vm.inputText = "Hello"
        XCTAssertFalse(vm.isModelLoaded, "Precondition: no model loaded")
        XCTAssertFalse(canSend(vm), "canSend should be false without a loaded model")
    }

    func test_canSend_falseWhenInputEmpty() {
        let (vm, _) = makeViewModelWithMock()
        vm.inputText = ""
        XCTAssertFalse(canSend(vm), "canSend should be false when input is empty")
    }

    func test_canSend_falseWhenInputWhitespaceOnly() {
        let (vm, _) = makeViewModelWithMock()
        vm.inputText = "   \n\t  "
        XCTAssertFalse(canSend(vm), "canSend should be false when input is only whitespace")
    }

    func test_canSend_trueWhenAllConditionsMet() {
        let (vm, _) = makeViewModelWithMock()
        vm.inputText = "Hello"
        XCTAssertTrue(canSend(vm), "canSend should be true when session exists, model loaded, and input non-empty")
    }

    func test_canSend_trueWhenAttachmentOnlyDraftPresent() {
        let mock = MockInferenceBackend(capabilities: BackendCapabilities(supportsVision: true))
        let (vm, _) = makeViewModelWithMock(mock: mock)
        vm.stageDraftAttachment(.image(data: Data([0x89, 0x50, 0x4E, 0x47]), mimeType: "image/png"))
        XCTAssertTrue(canSend(vm), "canSend should allow attachment-only drafts on vision-capable backends")
    }

    func test_canSend_falseWhileLoading() {
        let (vm, _) = makeViewModelWithMock()
        vm.inputText = "Hello"
        vm.transitionPhase(to: .modelLoading(progress: nil))
        XCTAssertTrue(vm.isLoading, "Precondition: isLoading should be true")
        XCTAssertFalse(canSend(vm), "canSend should be false while model is loading")
    }

    func test_canSend_falseWhileGenerating() {
        let (vm, _) = makeViewModelWithMock()
        vm.inputText = "Hello"
        vm.transitionPhase(to: .waitingForFirstToken)
        vm.transitionPhase(to: .streaming)
        XCTAssertTrue(vm.isGenerating, "Precondition: isGenerating should be true")
        XCTAssertFalse(canSend(vm), "canSend should be false while generating")
    }

    // MARK: - Input text field disabled state

    /// The text field is disabled when: activeSession == nil || !isModelLoaded || isLoading
    private func isTextFieldDisabled(_ vm: ChatViewModel) -> Bool {
        vm.activeSession == nil || !vm.isModelLoaded || vm.isLoading
    }

    func test_textFieldDisabled_whenNoSession() async {
        let vm = await makeViewModel()
        XCTAssertTrue(isTextFieldDisabled(vm), "Text field should be disabled without a session")
    }

    func test_textFieldDisabled_whenNoModel() async {
        let vm = await makeViewModel()
        vm.activeSession = ChatSessionRecord(title: "Test")
        XCTAssertTrue(isTextFieldDisabled(vm), "Text field should be disabled without a loaded model")
    }

    func test_textFieldEnabled_whenSessionAndModelReady() {
        let (vm, _) = makeViewModelWithMock()
        XCTAssertFalse(isTextFieldDisabled(vm), "Text field should be enabled with session and model")
    }

    func test_textFieldDisabled_whileLoading() {
        let (vm, _) = makeViewModelWithMock()
        vm.transitionPhase(to: .modelLoading(progress: nil))
        XCTAssertTrue(isTextFieldDisabled(vm), "Text field should be disabled while model is loading")
    }

    // MARK: - showRegenerateButton conditions

    /// showRegenerateButton: !isGenerating && !messages.isEmpty && messages.last?.role == .assistant
    private func showRegenerateButton(_ vm: ChatViewModel) -> Bool {
        !vm.isGenerating
        && !vm.messages.isEmpty
        && vm.messages.last?.role == .assistant
    }

    func test_showRegenerateButton_falseWhenNoMessages() {
        let (vm, _) = makeViewModelWithMock()
        XCTAssertFalse(showRegenerateButton(vm), "Regenerate should be hidden when there are no messages")
    }

    func test_showRegenerateButton_trueAfterAssistantResponse() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Response"]
        let (vm, _) = makeViewModelWithMock(mock: mock)
        vm.inputText = "Hello"

        await vm.sendMessage()

        XCTAssertEqual(vm.messages.last?.role, .assistant, "Precondition: last message should be assistant")
        XCTAssertTrue(showRegenerateButton(vm), "Regenerate should be visible after assistant responds")
    }

    func test_showRegenerateButton_falseWhenLastMessageIsUser() {
        let (vm, _) = makeViewModelWithMock()
        let sessionID = vm.activeSession!.id
        vm.messages = [
            ChatMessageRecord(role: .user, content: "Hello", sessionID: sessionID)
        ]
        XCTAssertFalse(showRegenerateButton(vm), "Regenerate should be hidden when last message is from user")
    }

    func test_showRegenerateButton_falseWhileGenerating() {
        let (vm, _) = makeViewModelWithMock()
        let sessionID = vm.activeSession!.id
        vm.messages = [
            ChatMessageRecord(role: .user, content: "Hello", sessionID: sessionID),
            ChatMessageRecord(role: .assistant, content: "Hi", sessionID: sessionID)
        ]
        vm.transitionPhase(to: .waitingForFirstToken)
        vm.transitionPhase(to: .streaming)
        XCTAssertFalse(showRegenerateButton(vm), "Regenerate should be hidden while generating")
    }

    // MARK: - Quick action pill disabled state

    /// Quick action pills are disabled when: no session || !isModelLoaded || isGenerating || isLoading
    private func isQuickActionDisabled(_ vm: ChatViewModel) -> Bool {
        vm.activeSession == nil || !vm.isModelLoaded || vm.isGenerating || vm.isLoading
    }

    func test_quickActionDisabled_whenNoSession() async {
        let vm = await makeViewModel()
        XCTAssertTrue(isQuickActionDisabled(vm), "Quick actions should be disabled without a session")
    }

    func test_quickActionEnabled_whenReady() {
        let (vm, _) = makeViewModelWithMock()
        XCTAssertFalse(isQuickActionDisabled(vm), "Quick actions should be enabled when session and model ready")
    }

    func test_quickActionDisabled_whileGenerating() {
        let (vm, _) = makeViewModelWithMock()
        vm.transitionPhase(to: .waitingForFirstToken)
        vm.transitionPhase(to: .streaming)
        XCTAssertTrue(isQuickActionDisabled(vm), "Quick actions should be disabled while generating")
    }

    // MARK: - Send clears input

    func test_sendMessage_clearsInputText() async {
        let (vm, _) = makeViewModelWithMock()
        vm.inputText = "Test message"

        await vm.sendMessage()

        XCTAssertEqual(vm.inputText, "", "Input text should be cleared after sending")
    }

    func test_sendMessage_attachmentOnlyPersistsImagePart() async {
        let mock = MockInferenceBackend(capabilities: BackendCapabilities(supportsVision: true))
        mock.tokensToYield = ["Done"]
        let (vm, backend) = makeViewModelWithMock(mock: mock)
        let image = MessagePart.image(data: ImageFixtures.oneByOnePNGData, mimeType: "image/png")
        let expectedImage = image.generatingImagePlaceholderIfNeeded()
        vm.stageDraftAttachment(image)

        await vm.sendMessage()

        XCTAssertTrue(vm.draftAttachments.isEmpty, "Draft attachments should be cleared after sending")
        let userMessage = vm.messages.first(where: { $0.role == .user })
        XCTAssertEqual(userMessage?.contentParts, [expectedImage])
        XCTAssertEqual(backend.lastReceivedStructuredHistory?.first?.parts, [expectedImage])
    }

    func test_sendMessage_textAndAttachmentPreservesPartOrder() async {
        let mock = MockInferenceBackend(capabilities: BackendCapabilities(supportsVision: true))
        mock.tokensToYield = ["Done"]
        let (vm, backend) = makeViewModelWithMock(mock: mock)
        let image = MessagePart.image(data: ImageFixtures.oneByOnePNGData, mimeType: "image/png")
        let expectedImage = image.generatingImagePlaceholderIfNeeded()
        vm.inputText = "Describe this image"
        vm.stageDraftAttachment(image)

        await vm.sendMessage()

        let expectedParts: [MessagePart] = [.text("Describe this image"), expectedImage]
        let userMessage = vm.messages.first(where: { $0.role == .user })
        XCTAssertEqual(userMessage?.contentParts, expectedParts)
        XCTAssertEqual(backend.lastReceivedStructuredHistory?.first?.parts, expectedParts)
    }

    func test_supportsImageAttachments_reflectsBackendCapability() {
        let mock = MockInferenceBackend(capabilities: BackendCapabilities(supportsVision: true))
        let (vm, _) = makeViewModelWithMock(mock: mock)
        XCTAssertTrue(vm.supportsImageAttachments)
    }

    // MARK: - Edge cases

    func test_canSend_withUnicodeInput() {
        let (vm, _) = makeViewModelWithMock()
        vm.inputText = "Hello! \u{1F600} \u{1F30D}"
        XCTAssertTrue(canSend(vm), "canSend should handle Unicode emoji input")
    }

    func test_canSend_withVeryLongInput() {
        let (vm, _) = makeViewModelWithMock()
        vm.inputText = String(repeating: "A", count: 10_000)
        XCTAssertTrue(canSend(vm), "canSend should handle very long input strings")
    }

    func test_canSend_withNewlinesOnly() {
        let (vm, _) = makeViewModelWithMock()
        vm.inputText = "\n\n\n"
        XCTAssertFalse(canSend(vm), "canSend should be false when input is only newlines")
    }

    func test_canSend_withMixedWhitespaceAndContent() {
        let (vm, _) = makeViewModelWithMock()
        vm.inputText = "  Hello  "
        XCTAssertTrue(canSend(vm), "canSend should be true when trimmed input has content")
    }
}
