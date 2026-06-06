@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

@MainActor
final class ViewModelEdgeCaseTests: XCTestCase {

    // MARK: - Helpers

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    private nonisolated(unsafe) var harnesses: [TestChatViewModelHarness] = []

    private func makeViewModel(ramGB: UInt64 = 16) -> ChatViewModel {
        let harness = try! makeTestChatViewModel(ramGB: ramGB)
        harnesses.append(harness)
        return harness.vm
    }

    private func makeViewModelWithMock(
        ramGB: UInt64 = 16,
        mock: MockInferenceBackend = MockInferenceBackend()
    ) -> (ChatViewModel, MockInferenceBackend) {
        let harness = try! makeTestChatViewModel(mock: mock, ramGB: ramGB)
        harnesses.append(harness)
        return (harness.vm, harness.mock!)
    }

    /// Retains the persistence stack across the test's lifetime. Without this,
    /// the `ModelContainer` from a harness built inside a helper function would
    /// be deallocated when the helper returns, invalidating the `ModelContext`
    /// the provider holds and causing SwiftData to trap on next access.
    private var persistenceStack: InMemoryPersistenceHarness.Stack?

    override func tearDown() async throws {
        for harness in harnesses { harness.cleanup() }
        harnesses.removeAll()
        persistenceStack = nil
        try await super.tearDown()
    }

    /// Creates a view model backed by real in-memory SwiftData persistence,
    /// wrapped in an error-injecting shim so tests can simulate storage
    /// failures without also lying about what storage actually does.
    private func makeViewModelWithPersistence(
        mock: MockInferenceBackend = MockInferenceBackend()
        ) throws -> (ChatViewModel, MockInferenceBackend, ErrorInjectingPersistenceProvider) {
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "Mock")
        let modelsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ViewModelEdgeCaseTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: modelsDirectory) }
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(baseDirectory: modelsDirectory),
            memoryPressure: MemoryPressureHandler()
        )
        let stack = try InMemoryPersistenceHarness.make()
        persistenceStack = stack
        let persistence = ErrorInjectingPersistenceProvider(wrapping: stack.provider)
        vm.configure(persistence: persistence)
        return (vm, mock, persistence)
    }

    // MARK: - saveSettingsToSession

    func test_saveSettingsToSession_updatesSessionProperties() async throws {
        let (vm, _, persistence) = try makeViewModelWithPersistence()

        let session = ManifoldInference.ChatSession(title: "Settings Test")
        try await persistence.insertSession(session)

        vm.activeSession = session
        vm.temperature = 0.3
        vm.topP = 0.8
        vm.repeatPenalty = 1.5
        vm.systemPrompt = "Be concise."
        vm.selectedPromptTemplate = .llama3

        try await vm.saveSettingsToSession()

        let updated = vm.activeSession!
        XCTAssertEqual(updated.temperature!, 0.3, accuracy: 0.001,
                       "Session temperature should match view model value")
        XCTAssertEqual(updated.topP!, 0.8, accuracy: 0.001,
                       "Session topP should match view model value")
        XCTAssertEqual(updated.repeatPenalty!, 1.5, accuracy: 0.001,
                       "Session repeatPenalty should match view model value")
        XCTAssertEqual(updated.systemPrompt, "Be concise.",
                       "Session systemPrompt should match view model value")
        XCTAssertEqual(updated.promptTemplate, .llama3,
                       "Session promptTemplate should match view model value")
    }

    func test_saveSettingsToSession_noActiveSession_isNoop() async throws {
        let (vm, _, _) = try makeViewModelWithPersistence()

        // No active session — should not crash.
        vm.temperature = 0.5
        try await vm.saveSettingsToSession()

        XCTAssertNil(vm.activeSession, "activeSession should remain nil")
    }

    // MARK: - switchToSession

    func test_switchToSession_loadsSessionSettings() async throws {
        let (vm, _, _) = try makeViewModelWithPersistence()

        var sessionA = ManifoldInference.ChatSession(title: "Session A")
        sessionA.temperature = 0.2
        sessionA.topP = 0.5
        sessionA.repeatPenalty = 1.0
        sessionA.systemPrompt = "Prompt A"

        var sessionB = ManifoldInference.ChatSession(title: "Session B")
        sessionB.temperature = 0.9
        sessionB.topP = 0.95
        sessionB.repeatPenalty = 1.3
        sessionB.systemPrompt = "Prompt B"

        await vm.switchToSession(sessionA)
        XCTAssertEqual(vm.temperature, 0.2, accuracy: 0.001)
        XCTAssertEqual(vm.systemPrompt, "Prompt A")

        await vm.switchToSession(sessionB)
        XCTAssertEqual(vm.temperature, 0.9, accuracy: 0.001,
                       "Temperature should reflect session B after switch")
        XCTAssertEqual(vm.topP, 0.95, accuracy: 0.001,
                       "topP should reflect session B after switch")
        XCTAssertEqual(vm.repeatPenalty, 1.3, accuracy: 0.001,
                       "repeatPenalty should reflect session B after switch")
        XCTAssertEqual(vm.systemPrompt, "Prompt B",
                       "systemPrompt should reflect session B after switch")
    }

    func test_switchToSession_clearsMessages() async throws {
        let (vm, _, _) = try makeViewModelWithPersistence(mock: MockInferenceBackend())

        let sessionA = ManifoldInference.ChatSession(title: "Session A")

        vm.activeSession = sessionA
        vm.inputText = "Hello"
        await vm.sendMessage()

        let countBeforeSwitch = vm.messages.count
        XCTAssertGreaterThan(countBeforeSwitch, 0,
                             "Should have messages before switching")

        let sessionB = ManifoldInference.ChatSession(title: "Session B")

        await vm.switchToSession(sessionB)

        // Session B has no persisted messages, so messages should be empty.
        XCTAssertTrue(vm.messages.isEmpty,
                      "Messages should be empty after switching to a session with no messages")
    }

    func test_clearChat_whenPersistenceDeleteFails_reloadsPersistedMessages() async throws {
        let (vm, _, persistence) = try makeViewModelWithPersistence()
        let session = ManifoldInference.ChatSession(title: "Clear Chat Failure")
        try await persistence.insertSession(session)
        vm.activeSession = session

        vm.inputText = "Hello"
        await vm.sendMessage()

        // vm.sendMessage() auto-creates and persists a session if needed; read
        // whichever session id ended up active to get the persisted messages.
        guard let activeID = vm.activeSession?.id else {
            XCTFail("Expected an active session after sendMessage")
            return
        }
        let expectedMessages = try await persistence.fetchMessages(for: activeID)
        XCTAssertEqual(expectedMessages.count, 2, "Precondition: the chat should have persisted user and assistant messages")

        let deleteError = NSError(
            domain: "ViewModelEdgeCaseTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "simulated delete failure"]
        )
        persistence.shouldThrowOnDeleteMessages = deleteError

        await vm.clearChat()

        XCTAssertEqual(vm.messages.map(\.id), expectedMessages.map(\.id),
                       "clearChat should reload persisted messages when deletion fails")
        let stillPersisted = try await persistence.fetchMessages(for: activeID)
        XCTAssertEqual(stillPersisted.map(\.id), expectedMessages.map(\.id),
                       "Persistence should still contain the original messages after a failed clear")
        XCTAssertNotNil(vm.activeError, "activeError should be set when clear chat fails")
        XCTAssertEqual(vm.activeError?.kind, .persistence, "Error kind should be .persistence")
        XCTAssertTrue(
            vm.errorMessage?.contains("simulated delete failure") == true,
            "Error message should contain the underlying error description, got: \(vm.errorMessage ?? "nil")"
        )
    }

    // MARK: - switchToSession model-selection restoration

    func test_switchToSession_restoresSelectedModel_whenModelInList() async throws {
        let (vm, _, _) = try makeViewModelWithPersistence()

        vm.foundationModelProvider = { true }
        vm.refreshModels()
        let foundationModel = ModelInfo.builtInFoundation

        XCTAssertTrue(
            vm.availableModels.contains(where: { $0.id == foundationModel.id }),
            "Foundation model should be in availableModels after refreshModels()"
        )

        var session = ManifoldInference.ChatSession(title: "Model Restore Session")
        session.selectedModelID = foundationModel.id

        await vm.switchToSession(session)

        XCTAssertEqual(vm.selectedModel?.id, foundationModel.id,
            "selectedModel should be restored to the session's saved model when it exists in availableModels")
        XCTAssertEqual(vm.selectedModel?.modelType, .foundation,
            "Restored model should have the expected type")
    }

    func test_switchToSession_clearsSelectedModel_whenModelNotInList() async throws {
        let (vm, _, _) = try makeViewModelWithPersistence()

        vm.foundationModelProvider = { true }
        vm.refreshModels()
        let foundationModel = ModelInfo.builtInFoundation
        vm.selectedModel = foundationModel

        let missingModelID = UUID()
        XCTAssertFalse(
            vm.availableModels.contains(where: { $0.id == missingModelID }),
            "Precondition: missingModelID must not be in availableModels"
        )

        var session = ManifoldInference.ChatSession(title: "Missing Model Session")
        session.selectedModelID = missingModelID

        await vm.switchToSession(session)

        XCTAssertNil(vm.selectedModel,
            "selectedModel should be cleared when session's model is not in availableModels")
    }

    func test_saveSettingsToSession_persistsSelectedModelID() async throws {
        let (vm, _, persistence) = try makeViewModelWithPersistence()

        let model = ModelInfo.builtInFoundation
        let expectedID = model.id

        let session = ManifoldInference.ChatSession(title: "Persist Model Session")
        try await persistence.insertSession(session)

        vm.activeSession = session
        vm.selectedModel = model

        try await vm.saveSettingsToSession()

        XCTAssertEqual(vm.activeSession?.selectedModelID, expectedID,
            "saveSettingsToSession should persist the selected model's UUID to the session")
    }

    func test_selectionMutualExclusion_selectingEndpoint_clearsModel() async {
        let vm = await makeViewModel()
        vm.selectedModel = ModelInfo.builtInFoundation

        let endpoint = APIEndpointRecord(name: "OpenAI", provider: .openAI)
        vm.selectedEndpoint = endpoint

        XCTAssertNil(vm.selectedModel, "Selecting an endpoint should clear selectedModel")
        XCTAssertEqual(vm.selectedEndpoint?.id, endpoint.id)
    }

    func test_selectionMutualExclusion_selectingModel_clearsEndpoint() async {
        let vm = await makeViewModel()
        let endpoint = APIEndpointRecord(name: "OpenAI", provider: .openAI)
        vm.selectedEndpoint = endpoint

        vm.selectedModel = ModelInfo.builtInFoundation

        XCTAssertNil(vm.selectedEndpoint, "Selecting a model should clear selectedEndpoint")
        XCTAssertEqual(vm.selectedModel?.id, ModelInfo.builtInFoundation.id)
    }

    func test_switchToSession_restoresSelectedEndpoint_whenEndpointExists() async throws {
        let (vm, _, _) = try makeViewModelWithPersistence()
        let endpoint = APIEndpointRecord(name: "OpenAI", provider: .openAI)
        vm.setAvailableEndpoints([endpoint])
        vm.selectedModel = ModelInfo.builtInFoundation

        var session = ManifoldInference.ChatSession(title: "Endpoint Session")
        session.selectedEndpointID = endpoint.id
        session.selectedModelID = ModelInfo.builtInFoundation.id

        await vm.switchToSession(session)

        XCTAssertEqual(vm.selectedEndpoint?.id, endpoint.id)
        XCTAssertNil(vm.selectedModel, "Endpoint restore should not leak prior model selection")
    }

    func test_switchToSession_clearsSelectedEndpoint_whenEndpointMissing() async throws {
        let (vm, _, _) = try makeViewModelWithPersistence()
        let oldEndpoint = APIEndpointRecord(name: "Old", provider: .openAI)
        vm.setAvailableEndpoints([oldEndpoint])
        vm.selectedEndpoint = oldEndpoint

        var session = ManifoldInference.ChatSession(title: "Missing Endpoint Session")
        session.selectedEndpointID = UUID()

        await vm.switchToSession(session)

        XCTAssertNil(vm.selectedEndpoint, "Missing endpoint should clear selectedEndpoint")
    }

    func test_switchToSession_clearsSelectedEndpoint_whenSessionHasNoEndpointID() async throws {
        let (vm, _, _) = try makeViewModelWithPersistence()
        let oldEndpoint = APIEndpointRecord(name: "Old", provider: .openAI)
        vm.setAvailableEndpoints([oldEndpoint])
        vm.selectedEndpoint = oldEndpoint

        let session = ManifoldInference.ChatSession(title: "Local Model Session")

        await vm.switchToSession(session)

        XCTAssertNil(vm.selectedEndpoint, "A session without selectedEndpointID should not keep the prior endpoint")
    }

    func test_setAvailableEndpoints_filtersDisabledEndpoints() async {
        let vm = await makeViewModel()
        let enabled = APIEndpointRecord(name: "Enabled", provider: .openAI, isEnabled: true)
        let disabled = APIEndpointRecord(name: "Disabled", provider: .claude, isEnabled: false)

        vm.setAvailableEndpoints([enabled, disabled])

        XCTAssertEqual(vm.availableEndpoints.map(\.id), [enabled.id])
    }

    func test_switchToSession_doesNotPersistNilSelectionWhenEndpointUnavailable() async throws {
        let (vm, _, persistence) = try makeViewModelWithPersistence()

        let endpoint = APIEndpointRecord(name: "Delayed Endpoint", provider: .openAI)
        var session = ManifoldInference.ChatSession(title: "Deferred Endpoint Session")
        session.selectedEndpointID = endpoint.id
        try await persistence.insertSession(session)
        vm.activeSession = session

        vm.setAvailableEndpoints([])
        await vm.switchToSession(session)

        XCTAssertEqual(persistence.updateSessionCallCount, 0,
                       "switchToSession should not auto-persist settings while restoring")
        let stored = try await persistence.fetchSessions().first(where: { $0.id == session.id })
        XCTAssertEqual(stored?.selectedEndpointID, endpoint.id,
                       "Unresolved endpoint ID should remain persisted until user saves settings")
    }

    func test_saveSettingsToSession_persistsSelectedEndpointID() async throws {
        let (vm, _, persistence) = try makeViewModelWithPersistence()
        let endpoint = APIEndpointRecord(name: "Claude", provider: .claude)
        vm.setAvailableEndpoints([endpoint])

        let session = ManifoldInference.ChatSession(title: "Persist Endpoint Session")
        try await persistence.insertSession(session)
        vm.activeSession = session
        vm.selectedEndpoint = endpoint

        try await vm.saveSettingsToSession()

        XCTAssertEqual(vm.activeSession?.selectedEndpointID, endpoint.id)
        XCTAssertNil(vm.activeSession?.selectedModelID, "Endpoint selection should clear model selection")
    }

    func test_switchToSession_usesDefaultsForNilSettings() async throws {
        let (vm, _, _) = try makeViewModelWithPersistence()

        let session = ManifoldInference.ChatSession(title: "Defaults Session")

        vm.temperature = 0.1
        vm.topP = 0.1
        vm.repeatPenalty = 2.0

        await vm.switchToSession(session)

        XCTAssertEqual(vm.temperature, 0.7, accuracy: 0.001,
                       "Should fall back to 0.7 default when session temperature is nil")
        XCTAssertEqual(vm.topP, 0.9, accuracy: 0.001,
                       "Should fall back to 0.9 default when session topP is nil")
        XCTAssertEqual(vm.repeatPenalty, 1.1, accuracy: 0.001,
                       "Should fall back to 1.1 default when session repeatPenalty is nil")
    }

    // MARK: - editMessage on assistant message

    func test_editMessage_assistantMessage_updatesContentButDoesNotRegenerate() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Original", " reply"]
        let (vm, _) = makeViewModelWithMock(mock: mock)
        vm.activeSession = ManifoldInference.ChatSession(title: "Test")
        vm.inputText = "Question"

        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 2)
        let assistantMessage = vm.messages[1]
        XCTAssertEqual(assistantMessage.role, .assistant)

        let generateCountBefore = mock.generateCallCount

        await vm.editMessage(assistantMessage.id, newContent: "Edited assistant text")

        // Editing an assistant message should update its content...
        XCTAssertEqual(vm.messages[1].content, "Edited assistant text",
                       "Assistant message content should be updated")
        // ...but should NOT trigger regeneration (only user edits do that).
        XCTAssertEqual(mock.generateCallCount, generateCountBefore,
                       "Editing an assistant message should not trigger regeneration")
        // Message count should remain the same (no messages after the assistant to remove).
        XCTAssertEqual(vm.messages.count, 2,
                       "Message count should remain unchanged after editing the last assistant message")
    }

    // MARK: - editMessage with empty content

    func test_editMessage_emptyContent_updatesMessageToEmpty() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Reply"]
        let (vm, _) = makeViewModelWithMock(mock: mock)
        vm.activeSession = ManifoldInference.ChatSession(title: "Test")
        vm.inputText = "Hello"

        await vm.sendMessage()

        let userMessage = vm.messages[0]
        XCTAssertEqual(userMessage.role, .user)

        // Edit with empty content — the method does not guard against this.
        mock.tokensToYield = ["New", " reply"]
        await vm.editMessage(userMessage.id, newContent: "")

        XCTAssertEqual(vm.messages[0].content, "",
                       "User message content should be set to empty string")
        // Since it was a user message edit, regeneration should still occur.
        XCTAssertEqual(vm.messages.count, 2,
                       "Should still have user + regenerated assistant message")
    }

    // MARK: - sendMessage whitespace-only input

    func test_sendMessage_whitespaceOnlyInput_isNoop() async {
        let (vm, mock) = makeViewModelWithMock()
        vm.activeSession = ManifoldInference.ChatSession(title: "Test")
        vm.inputText = "   \n  "

        await vm.sendMessage()

        XCTAssertTrue(vm.messages.isEmpty,
                      "Whitespace-only input should not produce any messages")
        XCTAssertEqual(mock.generateCallCount, 0,
                       "No generation should be triggered for whitespace-only input")
    }

    func test_sendMessage_tabAndNewlineInput_isNoop() async {
        let (vm, mock) = makeViewModelWithMock()
        vm.activeSession = ManifoldInference.ChatSession(title: "Test")
        vm.inputText = "\t\n\r\n  \t"

        await vm.sendMessage()

        XCTAssertTrue(vm.messages.isEmpty,
                      "Tab/newline-only input should not produce any messages")
        XCTAssertEqual(mock.generateCallCount, 0,
                       "No generation should be triggered for whitespace input")
    }

    // MARK: - sendMessage clears errorMessage

    func test_sendMessage_clearsExistingErrorMessage() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["OK"]
        let (vm, _) = makeViewModelWithMock(mock: mock)
        vm.activeSession = ManifoldInference.ChatSession(title: "Test")

        vm.errorMessage = "Previous error that should be cleared"
        vm.inputText = "Hello"

        await vm.sendMessage()

        XCTAssertNil(vm.errorMessage,
                     "errorMessage should be cleared after a successful sendMessage")
    }

    func test_sendMessage_noSession_setsErrorMessage() async {
        let (vm, _) = makeViewModelWithMock()
        // No active session
        vm.inputText = "Hello"

        await vm.sendMessage()

        XCTAssertNotNil(vm.errorMessage,
                        "errorMessage should be set when no active session exists")
        XCTAssertTrue(vm.errorMessage?.contains("No active session") == true,
                      "Error should mention no active session, got: \(vm.errorMessage ?? "nil")")
    }

    // MARK: - exportChat formats

    func test_exportChat_markdownFormat_returnsNonEmptyOutput() {
        let (vm, _) = makeViewModelWithMock()
        vm.activeSession = ManifoldInference.ChatSession(title: "Export Test")

        // Manually add messages to test export without triggering generation.
        let sessionID = vm.activeSession!.id
        vm.messages = [
            ManifoldInference.ChatMessage(role: .user, content: "What is 2+2?", sessionID: sessionID),
            ManifoldInference.ChatMessage(role: .assistant, content: "4", sessionID: sessionID)
        ]

        let markdown = vm.exportChat(format: .markdown)

        XCTAssertFalse(markdown.isEmpty, "Markdown export should not be empty")
        XCTAssertTrue(markdown.contains("# Export Test"),
                      "Markdown export should contain session title as heading")
        XCTAssertTrue(markdown.contains("What is 2+2?"),
                      "Markdown export should contain user message content")
        XCTAssertTrue(markdown.contains("4"),
                      "Markdown export should contain assistant message content")
        XCTAssertTrue(markdown.contains("**User:**"),
                      "Markdown export should format user role in bold")
        XCTAssertTrue(markdown.contains("**Assistant:**"),
                      "Markdown export should format assistant role in bold")
    }

    func test_exportChat_plainTextFormat_returnsNonEmptyOutput() {
        let (vm, _) = makeViewModelWithMock()
        vm.activeSession = ManifoldInference.ChatSession(title: "Plain Export")

        let sessionID = vm.activeSession!.id
        vm.messages = [
            ManifoldInference.ChatMessage(role: .user, content: "Hello", sessionID: sessionID),
            ManifoldInference.ChatMessage(role: .assistant, content: "Hi there", sessionID: sessionID)
        ]

        let plainText = vm.exportChat(format: .plainText)

        XCTAssertFalse(plainText.isEmpty, "Plain text export should not be empty")
        XCTAssertTrue(plainText.contains("Plain Export"),
                      "Plain text export should contain session title")
        XCTAssertTrue(plainText.contains("User: Hello"),
                      "Plain text export should contain user message")
        XCTAssertTrue(plainText.contains("Assistant: Hi there"),
                      "Plain text export should contain assistant message")
    }

    func test_exportChat_emptyMessages_returnsHeaderOnly() {
        let (vm, _) = makeViewModelWithMock()
        vm.activeSession = ManifoldInference.ChatSession(title: "Empty Chat")
        vm.messages = []

        let markdown = vm.exportChat(format: .markdown)

        XCTAssertFalse(markdown.isEmpty, "Export of empty chat should still produce a header")
        XCTAssertTrue(markdown.contains("# Empty Chat"),
                      "Export should contain the session title even with no messages")
    }
}
