import XCTest
import SwiftUI
@testable import BaseChatUI
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference
import BaseChatTestSupport

/// Verifies that user-facing controls in ChatView and ChatInputBar are present
/// in the view hierarchy across different states.
///
/// Uses `Swift.dump()` on a hosted view to capture the hierarchy as text,
/// then asserts expected type names and string literals appear. SF Symbol names
/// and accessibility labels are NOT captured by `Swift.dump()` — those are tested
/// indirectly via type references and state properties. This catches accidental
/// control removal without requiring pixel rendering or XCUITest infrastructure.
@MainActor
final class ChatViewControlTests: XCTestCase {

    // MARK: - Helpers

    private func makeChatViewModel() -> ChatViewModel {
        let oneGB: UInt64 = 1_024 * 1_024 * 1_024
        return ChatViewModel(
            inferenceService: InferenceService(),
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(
                baseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
            )
        )
    }

    private func makeChatViewModelWithMock() -> ChatViewModel {
        let oneGB: UInt64 = 1_024 * 1_024 * 1_024
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "Mock")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(
                baseDirectory: FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
            )
        )
        vm.activeSession = ChatSessionRecord(title: "Test Session")
        return vm
    }

    // MARK: - ChatView — No Model Loaded (Empty)

    private func chatViewDump(viewModel: ChatViewModel? = nil) -> String {
        let vm = viewModel ?? makeChatViewModel()
        return ViewHierarchyDumper.dump(
            NavigationStack {
                ChatView(
                    showModelManagement: .constant(false),
                    apiConfiguration: { EmptyView() }
                )
            }
            .environment(vm)
        )
    }

    func test_chatView_noModel_showsBrowseModelsButton() {
        let dump = chatViewDump()
        XCTAssertTrue(
            dump.contains("Browse Models"),
            "ChatView with no models should show 'Browse Models' button"
        )
    }

    func test_chatView_noModel_showsWelcomeText() {
        let dump = chatViewDump()
        XCTAssertTrue(
            dump.contains("Download a model to get started"),
            "ChatView with no models should show welcome text"
        )
    }

    // MARK: - ChatView — Clear Chat Alert

    func test_chatView_hasClearChatAlert() {
        let dump = chatViewDump()
        XCTAssertTrue(
            dump.contains("Clear Chat"),
            "ChatView should have the 'Clear Chat' alert configured"
        )
    }

    // MARK: - ChatView — Settings and Export Sheets

    func test_chatView_hasGenerationSettingsSheet() {
        let dump = chatViewDump()
        XCTAssertTrue(
            dump.contains("GenerationSettingsView"),
            "ChatView should reference GenerationSettingsView for the settings sheet"
        )
    }

    func test_chatView_hasChatExportSheet() {
        let dump = chatViewDump()
        XCTAssertTrue(
            dump.contains("ChatExportSheet"),
            "ChatView should reference ChatExportSheet for the export sheet"
        )
    }

    // MARK: - ChatInputBar — Text Input Affordance

    private func inputBarDump(viewModel: ChatViewModel? = nil) -> String {
        let vm = viewModel ?? makeChatViewModel()
        return ViewHierarchyDumper.dump(
            ChatInputBar()
                .environment(vm)
        )
    }

    func test_inputBar_hasTextField() {
        let dump = inputBarDump(viewModel: makeChatViewModelWithMock())
        XCTAssertTrue(
            dump.contains("Message…"),
            "ChatInputBar should contain a text field with 'Message…' placeholder when input is available"
        )
    }

    func test_inputBar_containsChatInputBarType() {
        let dump = inputBarDump()
        XCTAssertTrue(
            dump.contains("ChatInputBar"),
            "Dump should contain the ChatInputBar type"
        )
    }

    func test_inputBar_hasFocusState() {
        let dump = inputBarDump()
        XCTAssertTrue(
            dump.contains("FocusState"),
            "ChatInputBar should have a FocusState for input focus management"
        )
    }

    func test_inputBar_hasKeyboardShortcut() {
        let dump = inputBarDump()
        XCTAssertTrue(
            dump.contains("KeyboardShortcut"),
            "ChatInputBar should have a keyboard shortcut for sending"
        )
    }

    // MARK: - ChatView — Navigation Title

    func test_chatView_hasNavigationTitle() {
        let dump = chatViewDump()
        XCTAssertTrue(
            dump.contains("NavigationTitleKey"),
            "ChatView should set a navigation title"
        )
    }

    // MARK: - ChatView — Model Loaded State

    func test_chatView_modelLoaded_showsEmptyPlaceholder() {
        let vm = makeChatViewModelWithMock()
        let dump = chatViewDump(viewModel: vm)
        XCTAssertTrue(
            dump.contains("Send a message to start chatting."),
            "ChatView with model loaded but no messages should show empty placeholder"
        )
    }

    func test_chatView_modelLoaded_doesNotShowBrowseModels() {
        let vm = makeChatViewModelWithMock()
        let dump = chatViewDump(viewModel: vm)
        XCTAssertFalse(
            dump.contains("Browse Models"),
            "ChatView with model loaded should not show 'Browse Models' button"
        )
    }
}
