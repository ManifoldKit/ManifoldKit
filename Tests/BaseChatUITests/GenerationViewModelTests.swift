@preconcurrency import XCTest
@testable import BaseChatUI
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference
import BaseChatTestSupport

@MainActor
final class ChatViewModelTests: XCTestCase {

    // MARK: - Helpers

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    /// Per-test isolated Models directory. Every ViewModel built inside a
    /// test shares the same directory so `refreshModels()` sees fixtures
    /// the test wrote. The directory is nuked in `tearDown` so nothing
    /// leaks into the user's real `<Documents>/Models` path (see #379).
    private nonisolated(unsafe) var scratchModelsDirectory: URL!

    /// Per-instance UserDefaults suite — prevents parallel test runs from racing
    /// on the global `hasCompletedFirstLaunch` key in `UserDefaults.standard`.
    /// Shared across every harness in this test class so tests that seed the
    /// suite directly (e.g. set `hasCompletedFirstLaunch`) see the value
    /// when the VM reads it on init.
    private nonisolated(unsafe) var suiteName: String!
    private nonisolated(unsafe) var testDefaults: UserDefaults!

    /// Per-test harnesses — released in `tearDown`.
    private nonisolated(unsafe) var harnesses: [TestChatViewModelHarness] = []

    /// Convenience to build a view model with controllable device memory.
    /// Uses a default InferenceService (no backend loaded).
    private func makeViewModel(ramGB: UInt64 = 16) -> ChatViewModel {
        let harness = try! makeTestChatViewModel(
            ramGB: ramGB,
            modelsDirectory: scratchModelsDirectory,
            userDefaults: testDefaults
        )
        harnesses.append(harness)
        return harness.vm
    }

    /// Convenience to build a view model with a mock backend pre-loaded.
    private func makeViewModelWithMock(
        ramGB: UInt64 = 16,
        mock: MockInferenceBackend = MockInferenceBackend()
    ) -> (ChatViewModel, MockInferenceBackend) {
        let harness = try! makeTestChatViewModel(
            mock: mock,
            ramGB: ramGB,
            activateSession: true,
            modelsDirectory: scratchModelsDirectory,
            userDefaults: testDefaults
        )
        harnesses.append(harness)
        return (harness.vm, harness.mock!)
    }

    /// The scratch directory backing every `ModelStorageService` built in
    /// this test — exposed here so `createFakeGGUF` writes the fixture to
    /// the same place the ViewModel scans.
    private var modelsDirectory: URL {
        scratchModelsDirectory
    }

    /// Creates a fake .gguf file in the scratch models directory and returns its URL.
    ///
    /// The first 4 bytes are the GGUF magic header (`0x47 0x47 0x55 0x46`) so the
    /// fixture passes `ModelInfo(ggufURL:)`'s magic-bytes gate during discovery.
    @discardableResult
    private func createFakeGGUF(named fileName: String, sizeBytes: Int = 1024) throws -> URL {
        precondition(sizeBytes >= 4, "GGUF fixture must be at least 4 bytes for the magic header")
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        let fileURL = modelsDirectory.appendingPathComponent(fileName)
        var data = Data([0x47, 0x47, 0x55, 0x46])
        data.append(Data(repeating: 0, count: sizeBytes - 4))
        try data.write(to: fileURL)
        return fileURL
    }

    /// Removes a file at the given URL if it exists.
    private nonisolated func removeFile(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Removes all .gguf files from the models directory created during the test.
    private nonisolated(unsafe) var createdFiles: [URL] = []

    override func setUp() {
        super.setUp()
        scratchModelsDirectory = makeIsolatedModelsDirectory()
        suiteName = "com.basechatkit.test.chatvm.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() async throws {
        try await super.tearDown()
        for url in createdFiles {
            removeFile(at: url)
        }
        createdFiles.removeAll()
        for harness in harnesses { harness.cleanup() }
        harnesses.removeAll()
        if let dir = scratchModelsDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
        scratchModelsDirectory = nil
        if let suiteName {
            testDefaults?.removePersistentDomain(forName: suiteName)
        }
        testDefaults = nil
        suiteName = nil
    }

    // MARK: - test_init_defaultState

    func test_init_defaultState() async {
        let vm = await makeViewModel()

        XCTAssertTrue(vm.availableModels.isEmpty, "availableModels should be empty on init")
        XCTAssertNil(vm.selectedModel, "selectedModel should be nil on init")
        XCTAssertEqual(vm.inputText, "", "inputText should be empty on init")
        XCTAssertTrue(vm.messages.isEmpty, "messages should be empty on init")
        XCTAssertFalse(vm.isLoading, "isLoading should be false on init")
        XCTAssertNil(vm.errorMessage, "errorMessage should be nil on init")
        XCTAssertFalse(vm.isGenerating, "isGenerating should be false on init")
        XCTAssertFalse(vm.isModelLoaded, "isModelLoaded should be false on init")
    }

    // MARK: - test_refreshModels_populatesAvailableModels

    func test_refreshModels_populatesAvailableModels() async throws {
        let url = try createFakeGGUF(named: "test-refresh-model.gguf")
        createdFiles.append(url)

        let vm = await makeViewModel()
        vm.refreshModels()

        XCTAssertFalse(vm.availableModels.isEmpty, "availableModels should contain discovered models")
        XCTAssertTrue(
            vm.availableModels.contains(where: { $0.fileName == "test-refresh-model.gguf" }),
            "availableModels should include the test model file"
        )
    }

    // MARK: - test_refreshModels_clearsStaleSelection

    func test_refreshModels_clearsStaleSelection() async throws {
        let url = try createFakeGGUF(named: "test-stale-model.gguf")
        createdFiles.append(url)

        let vm = await makeViewModel()
        vm.refreshModels()

        // Select the discovered model.
        let model = vm.availableModels.first { $0.fileName == "test-stale-model.gguf" }
        XCTAssertNotNil(model, "Should have discovered the test model")
        vm.selectedModel = model

        // Delete the file and refresh.
        removeFile(at: url)
        vm.refreshModels()

        XCTAssertNil(vm.selectedModel, "selectedModel should be cleared when file no longer exists")
    }

    // MARK: - test_loadSelectedModel_noSelection_setsError

    func test_loadSelectedModel_noSelection_setsError() async {
        let vm = await makeViewModel()
        XCTAssertNil(vm.selectedModel)

        await vm.loadSelectedModel()

        XCTAssertNotNil(vm.errorMessage, "errorMessage should be set when no model is selected")
        XCTAssertEqual(vm.errorMessage, "No model selected.")
    }

    // MARK: - test_loadSelectedModel_modelTooLarge_setsError

    func test_loadSelectedModel_modelTooLarge_setsError() async {
        // 4 GB device with a 4 GB model. Stage 2 routes fit checks through
        // `ModelLoadPlan`, which reads `availableMemoryBytes` from an injected
        // environment — pin it low so the plan denies deterministically on any
        // host (the real CI box has far more RAM than the model's weights).
        let vm = await makeViewModel(ramGB: 4)
        vm.loadPlanEnvironment = ModelLoadPlan.Environment(
            availableMemoryBytes: { 512 * 1024 * 1024 },  // 512 MB available
            physicalMemoryBytes: 4 * oneGB
        )

        let largeModel = ModelInfo(
            name: "huge-model",
            fileName: "huge-model.gguf",
            url: URL(fileURLWithPath: "/tmp/huge-model.gguf"),
            fileSize: 4 * oneGB,
            modelType: .gguf
        )
        vm.selectedModel = largeModel

        await vm.loadSelectedModel()

        XCTAssertNotNil(vm.errorMessage, "errorMessage should be set when model is too large")
        XCTAssertTrue(
            vm.errorMessage?.contains("too large") == true,
            "Error should mention the model being too large, got: \(vm.errorMessage ?? "nil")"
        )
    }

    // MARK: - test_sendMessage_emptyInput_doesNothing

    func test_sendMessage_emptyInput_doesNothing() async {
        let vm = await makeViewModel()
        vm.inputText = ""

        await vm.sendMessage()

        XCTAssertTrue(vm.messages.isEmpty, "messages should remain empty when input is empty")
        XCTAssertNil(vm.errorMessage, "No error should be set for empty input")
    }

    // MARK: - test_sendMessage_noModelLoaded_setsError

    func test_sendMessage_noModelLoaded_setsError() async {
        let vm = await makeViewModel()
        vm.activeSession = ChatSessionRecord(title: "Test")
        vm.inputText = "Tell me a story"

        await vm.sendMessage()

        XCTAssertNotNil(vm.errorMessage, "errorMessage should be set when no model is loaded")
        XCTAssertTrue(
            vm.errorMessage?.contains("No model loaded") == true,
            "Error should mention no model loaded, got: \(vm.errorMessage ?? "nil")"
        )
    }

    // MARK: - test_sendMessage_addsUserMessage

    func test_sendMessage_addsUserMessage() async {
        let (vm, _) = makeViewModelWithMock()
        vm.inputText = "Hello, assistant!"

        await vm.sendMessage()

        // Should have a user message and an assistant message.
        let userMessages = vm.messages.filter { $0.role == .user }
        XCTAssertEqual(userMessages.count, 1, "Should have one user message")
        XCTAssertEqual(userMessages.first?.content, "Hello, assistant!", "User message content should match input")

        // Input should be cleared after sending.
        XCTAssertEqual(vm.inputText, "", "inputText should be cleared after sending")
    }

    // MARK: - test_clearChat_removesAllMessages

    func test_clearChat_removesAllMessages() async {
        let (vm, _) = makeViewModelWithMock()

        // Send a message to populate the chat.
        vm.inputText = "First message"
        await vm.sendMessage()

        XCTAssertFalse(vm.messages.isEmpty, "Should have messages after sending")

        await vm.clearChat()

        XCTAssertTrue(vm.messages.isEmpty, "messages should be empty after clearChat")
    }

    // MARK: - test_autoSelectFirstRunModel_selectsFoundation

    func test_autoSelectFirstRunModel_selectsFoundation() async {
        // Per-instance suite starts empty — no need to clear; the flag is unset by construction.
        let vm = await makeViewModel()

        vm.refreshModels()

        let hasFoundation = vm.availableModels.contains(where: { $0.modelType == .foundation })

        vm.autoSelectFirstRunModel()

        if hasFoundation {
            XCTAssertNotNil(vm.selectedModel, "Should have auto-selected a model")
            XCTAssertEqual(vm.selectedModel?.modelType, .foundation,
                          "Should have auto-selected the foundation model")
        } else {
            // Foundation not available on this OS — autoSelect won't find a model but must
            // still set the flag. Assert via vm.firstRunKey so the check is parallel-safe
            // even if another test mutates BaseChatConfiguration.shared.bundleIdentifier.
            XCTAssertTrue(testDefaults.bool(forKey: vm.firstRunKey),
                         "Flag should be set even if no foundation model available")
        }
    }

    // MARK: - test_autoSelectFirstRunModel_doesNotRepeat

    func test_autoSelectFirstRunModel_doesNotRepeat() async {
        // Create the VM first so we can seed the flag using the VM's captured key.
        // Seeding via vm.firstRunKey guarantees the right key is used even if another
        // parallel test mutates BaseChatConfiguration.shared.bundleIdentifier.
        let vm = await makeViewModel()
        testDefaults.set(true, forKey: vm.firstRunKey)

        vm.refreshModels()
        vm.autoSelectFirstRunModel()

        // Should NOT auto-select because the flag is already set.
        XCTAssertNil(vm.selectedModel, "Should not auto-select on subsequent launches")
    }

    // MARK: - test_handleMemoryPressure_nominal_doesNotSetError

    func test_handleMemoryPressure_nominal_doesNotSetError() async {
        let vm = await makeViewModel()

        vm.handleMemoryPressure()

        // On the very first call, lastPressureLevel == .nominal and pressureLevel == .nominal,
        // so the guard (level != lastPressureLevel) prevents any action.
        XCTAssertNil(vm.errorMessage,
                     "handleMemoryPressure at nominal should not set an error")
    }

    // MARK: - test_deviceDescription_returnsNonEmpty

    func test_deviceDescription_returnsNonEmpty() async {
        let vm = await makeViewModel(ramGB: 16)

        XCTAssertFalse(vm.deviceDescription.isEmpty, "deviceDescription should not be empty")
        XCTAssertTrue(
            vm.deviceDescription.contains("16 GB RAM"),
            "deviceDescription should contain RAM info, got: \(vm.deviceDescription)"
        )
    }

    // MARK: - test_recommendedSize_returnsValidRecommendation

    func test_recommendedSize_returnsValidRecommendation() async {
        let vm = await makeViewModel(ramGB: 8)

        let recommendation = vm.recommendedSize
        XCTAssertTrue(
            ModelSizeRecommendation.allCases.contains(recommendation),
            "recommendedSize should return a valid ModelSizeRecommendation"
        )
        // 8 GB should recommend .medium.
        XCTAssertEqual(recommendation, .medium, "8 GB device should recommend medium models")
    }

    // MARK: - test_modelsDirectoryPath_returnsNonEmpty

    func test_modelsDirectoryPath_returnsNonEmpty() async {
        let vm = await makeViewModel()

        XCTAssertFalse(vm.modelsDirectoryPath.isEmpty, "modelsDirectoryPath should not be empty")
        // When a custom `baseDirectory:` is passed to ModelStorageService the
        // path is the exact custom URL (no trailing "Models" segment), so we
        // verify only that it matches the scratch directory the test set up.
        XCTAssertEqual(
            vm.modelsDirectoryPath,
            scratchModelsDirectory.path,
            "modelsDirectoryPath should be the scratch directory, got: \(vm.modelsDirectoryPath)"
        )
    }

    // MARK: - test_backendCapabilities_nilWhenNoModel

    func test_backendCapabilities_nilWhenNoModel() async {
        let vm = await makeViewModel()
        XCTAssertNil(vm.backendCapabilities, "backendCapabilities should be nil when no model loaded")
    }

    // MARK: - test_backendCapabilities_availableWithMock

    func test_backendCapabilities_availableWithMock() {
        let (vm, _) = makeViewModelWithMock()
        XCTAssertNotNil(vm.backendCapabilities, "backendCapabilities should be available when model is loaded")
    }

    // MARK: - Generation Streaming Flow

    func test_sendMessage_streamsTokensIntoAssistantMessage() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Hello", " world"]
        let (vm, _) = makeViewModelWithMock(mock: mock)
        vm.inputText = "Say hello"

        await vm.sendMessage()

        let assistantMessages = vm.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistantMessages.count, 1, "Should have one assistant message")
        XCTAssertEqual(
            assistantMessages.first?.content, "Hello world",
            "Assistant message should contain streamed tokens concatenated"
        )
    }

    func test_sendMessage_createsUserAndAssistantMessages() async {
        let (vm, _) = makeViewModelWithMock()
        vm.inputText = "Tell me a story"

        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 2, "Should have exactly 2 messages (user + assistant)")
        XCTAssertEqual(vm.messages[0].role, .user, "First message should be from user")
        XCTAssertEqual(vm.messages[0].content, "Tell me a story", "User message content should match input")
        XCTAssertEqual(vm.messages[1].role, .assistant, "Second message should be from assistant")
    }

    // MARK: - Regenerate

    func test_regenerateLastResponse_removesAndRecreatesAssistant() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["First", " response"]
        let (vm, _) = makeViewModelWithMock(mock: mock)
        vm.inputText = "Hello"

        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 2, "Should have user + assistant after send")
        XCTAssertEqual(vm.messages[1].content, "First response")

        // Change the mock tokens for the regeneration.
        mock.tokensToYield = ["Regenerated", " response"]

        await vm.regenerateLastResponse()

        XCTAssertEqual(vm.messages.count, 2, "Should still have exactly 2 messages after regenerate")
        XCTAssertEqual(vm.messages[0].role, .user, "First message should still be from user")
        XCTAssertEqual(vm.messages[1].role, .assistant, "Second message should still be from assistant")
        XCTAssertEqual(
            vm.messages[1].content, "Regenerated response",
            "Assistant message should have new regenerated content"
        )
    }

    func test_regenerateLastResponse_noAssistantMessage_doesNothing() async {
        let (vm, _) = makeViewModelWithMock()

        // Messages is empty — regenerate should be a no-op.
        XCTAssertTrue(vm.messages.isEmpty, "Precondition: messages should be empty")

        await vm.regenerateLastResponse()

        XCTAssertTrue(vm.messages.isEmpty, "Messages should remain empty after regenerate with no assistant")
    }

    // MARK: - Stop Generation

    func test_stopGeneration_setsIsGeneratingFalse() async {
        let (vm, _) = makeViewModelWithMock()

        // Verify isGenerating is false before and after stopGeneration.
        XCTAssertFalse(vm.isGenerating, "isGenerating should be false before any generation")

        vm.stopGeneration()

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after stopGeneration")
    }

    func test_stopGeneration_callsInferenceServiceStop() {
        let mock = MockInferenceBackend()
        let (vm, _) = makeViewModelWithMock(mock: mock)

        vm.stopGeneration()

        XCTAssertEqual(mock.stopCallCount, 1, "stopGeneration should call backend's stopGeneration")
    }

    // MARK: - Edit Message

    func test_editMessage_updatesContentAndRegenerates() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Original", " reply"]
        let (vm, _) = makeViewModelWithMock(mock: mock)
        vm.inputText = "Original question"

        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 2, "Should have user + assistant")
        XCTAssertEqual(vm.messages[0].content, "Original question")
        XCTAssertEqual(vm.messages[1].content, "Original reply")

        // Edit the user message with new content.
        mock.tokensToYield = ["New", " reply"]
        let userMessage = vm.messages[0]

        await vm.editMessage(userMessage.id, newContent: "Edited question")

        XCTAssertEqual(vm.messages[0].content, "Edited question", "User message should be updated")
        XCTAssertEqual(vm.messages.count, 2, "Should still have 2 messages after edit + regenerate")
        XCTAssertEqual(vm.messages[1].role, .assistant, "Second message should be assistant")
        XCTAssertEqual(
            vm.messages[1].content, "New reply",
            "Assistant message should be regenerated with new tokens"
        )
    }

    func test_editMessage_nonExistentMessage_doesNothing() async {
        let (vm, _) = makeViewModelWithMock()
        vm.inputText = "Hello"
        await vm.sendMessage()

        let originalCount = vm.messages.count
        let fakeMessage = ChatMessageRecord(role: .user, content: "Fake", sessionID: UUID())

        await vm.editMessage(fakeMessage.id, newContent: "Edited")

        XCTAssertEqual(vm.messages.count, originalCount, "Messages should not change when editing a non-existent message")
    }

    // MARK: - Auto-template Detection on Model Load

    func test_loadSelectedModel_autoDetectsPromptTemplate() async {
        let (vm, _) = makeViewModelWithMock()

        // Create a model with a detected prompt template.
        let model = ModelInfo(
            name: "test-llama",
            fileName: "test-llama.gguf",
            url: URL(fileURLWithPath: "/tmp/test-llama.gguf"),
            fileSize: 1024,
            modelType: .gguf,
            detectedPromptTemplate: .llama3
        )
        vm.selectedModel = model

        // The actual loadModel will fail because the file doesn't exist,
        // but the template should be set before the load attempt.
        await vm.loadSelectedModel()

        XCTAssertEqual(
            vm.selectedPromptTemplate, .llama3,
            "selectedPromptTemplate should be auto-detected from model metadata"
        )
    }

    // MARK: - System Prompt in Generation

    func test_sendMessage_includesSystemPrompt() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Response"]
        let (vm, _) = makeViewModelWithMock(mock: mock)

        vm.systemPrompt = "You are a helpful storytelling assistant."
        vm.inputText = "Tell me a story"

        await vm.sendMessage()

        // The mock backend captures lastSystemPrompt. Since MockInferenceBackend
        // has supportsSystemPrompt: true and requiresPromptTemplate: false,
        // the InferenceService passes the system prompt through to the backend.
        XCTAssertEqual(
            mock.lastSystemPrompt, "You are a helpful storytelling assistant.",
            "Backend should receive the system prompt"
        )
    }

    func test_sendMessage_nilSystemPromptWhenEmpty() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Response"]
        let (vm, _) = makeViewModelWithMock(mock: mock)

        vm.systemPrompt = ""
        vm.inputText = "Hello"

        await vm.sendMessage()

        XCTAssertNil(
            mock.lastSystemPrompt,
            "Backend should receive nil system prompt when systemPrompt is empty"
        )
    }

    // MARK: - Generation Error Handling

    func test_sendMessage_generationError_setsErrorMessage() async {
        let mock = MockInferenceBackend()
        mock.shouldThrowOnGenerate = InferenceError.inferenceFailure("Test error")
        let (vm, _) = makeViewModelWithMock(mock: mock)
        vm.inputText = "Hello"

        await vm.sendMessage()

        XCTAssertNotNil(vm.errorMessage, "errorMessage should be set when generation fails")
        XCTAssertNotNil(vm.activeError, "activeError should be set when generation fails")
        XCTAssertEqual(vm.activeError?.kind, .generation, "Error kind should be .generation")
        XCTAssertTrue(
            vm.errorMessage?.contains("Test error") == true,
            "Error should contain the underlying error description, got: \(vm.errorMessage ?? "nil")"
        )
    }

    func test_sendMessage_clearsInputAfterSending() async {
        let (vm, _) = makeViewModelWithMock()
        vm.inputText = "Hello there"

        await vm.sendMessage()

        XCTAssertEqual(vm.inputText, "", "inputText should be cleared after sending")
    }

    func test_sendMessage_isGeneratingFalseAfterCompletion() async {
        let (vm, _) = makeViewModelWithMock()
        vm.inputText = "Hello"

        await vm.sendMessage()

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after generation completes")
    }

    // MARK: - Multiple Messages

    func test_sendMessage_multipleMessages_accumulatesHistory() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Reply", " 1"]
        let (vm, _) = makeViewModelWithMock(mock: mock)

        vm.inputText = "First message"
        await vm.sendMessage()

        mock.tokensToYield = ["Reply", " 2"]
        vm.inputText = "Second message"
        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 4, "Should have 4 messages (2 user + 2 assistant)")
        XCTAssertEqual(vm.messages[0].role, .user)
        XCTAssertEqual(vm.messages[0].content, "First message")
        XCTAssertEqual(vm.messages[1].role, .assistant)
        XCTAssertEqual(vm.messages[1].content, "Reply 1")
        XCTAssertEqual(vm.messages[2].role, .user)
        XCTAssertEqual(vm.messages[2].content, "Second message")
        XCTAssertEqual(vm.messages[3].role, .assistant)
        XCTAssertEqual(vm.messages[3].content, "Reply 2")
    }

    // MARK: - Clear Chat After Messages

    func test_clearChat_afterMultipleMessages_removesAll() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Reply"]
        let (vm, _) = makeViewModelWithMock(mock: mock)

        vm.inputText = "Msg 1"
        await vm.sendMessage()
        vm.inputText = "Msg 2"
        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 4, "Precondition: should have 4 messages")

        await vm.clearChat()

        XCTAssertTrue(vm.messages.isEmpty, "All messages should be cleared")
    }
}
