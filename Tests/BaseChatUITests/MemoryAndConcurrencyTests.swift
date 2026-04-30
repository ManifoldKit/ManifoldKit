@preconcurrency import XCTest
@testable import BaseChatUI
import BaseChatRuntime
import BaseChatPersistenceSwiftData
@testable import BaseChatInference
import BaseChatTestSupport

/// Tests for memory pressure transitions and concurrency edge cases in ChatViewModel.
@MainActor
final class MemoryAndConcurrencyTests: XCTestCase {

    // MARK: - Helpers

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    /// Creates a ChatViewModel with the given memory pressure handler and mock backend.
    /// Returns the view model, mock backend, and pressure handler for test control.
    private func makeViewModel(
        handler: MemoryPressureHandler = MemoryPressureHandler(),
        mock: MockInferenceBackend = MockInferenceBackend()
    ) -> (ChatViewModel, MockInferenceBackend, MemoryPressureHandler) {
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "Mock")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: handler
        )
        vm.activeSession = ChatSessionRecord(title: "Test Session")
        return (vm, mock, handler)
    }

    /// Creates a ChatViewModel backed by a SlowMockBackend for timing-sensitive tests.
    private func makeSlowViewModel(
        tokenCount: Int = 20,
        delayMilliseconds: Int = 50
    ) -> (ChatViewModel, SlowMockBackend) {
        let slow = SlowMockBackend()
        slow.tokensToYield = (0..<tokenCount).map { "tok\($0) " }
        slow.delayPerToken = .milliseconds(delayMilliseconds)

        let service = InferenceService(backend: slow, name: "SlowMock")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
        vm.activeSession = ChatSessionRecord(title: "Slow Test Session")
        return (vm, slow)
    }

    // MARK: - Test 1: Memory Pressure Warning Level

    /// Setting memory pressure to .warning should set an error message but NOT unload the model.
    func test_handleMemoryPressure_warning_setsErrorButDoesNotUnload() async {
        let handler = MemoryPressureHandler()
        let (vm, mock, _) = await makeViewModel(handler: handler)

        // Precondition: no error, model is loaded.
        XCTAssertNil(vm.errorMessage)
        XCTAssertTrue(mock.isModelLoaded)
        XCTAssertEqual(mock.unloadCallCount, 0)

        // Simulate OS memory pressure going to .warning.
        handler.pressureLevel = .warning
        vm.handleMemoryPressure()

        // Error message should warn about elevated memory pressure.
        XCTAssertNotNil(vm.errorMessage, "errorMessage should be set at warning level")
        XCTAssertTrue(
            vm.errorMessage?.contains("Memory pressure") == true,
            "Error should mention memory pressure, got: \(vm.errorMessage ?? "nil")"
        )

        // Model should NOT be unloaded at warning level.
        XCTAssertEqual(mock.unloadCallCount, 0,
            "Model should not be unloaded at warning level")
        XCTAssertTrue(mock.isModelLoaded,
            "Mock backend should still report model loaded")
    }

    // MARK: - Test 2: Memory Pressure Critical Level

    /// Setting memory pressure to .critical should unload the model and set an error message.
    func test_handleMemoryPressure_critical_unloadsModelAndSetsError() async {
        let handler = MemoryPressureHandler()
        let (vm, mock, _) = await makeViewModel(handler: handler)

        // Precondition: model is loaded.
        XCTAssertTrue(mock.isModelLoaded)
        XCTAssertEqual(mock.unloadCallCount, 0)

        // Simulate critical memory pressure.
        handler.pressureLevel = .critical
        vm.handleMemoryPressure()

        // Model should be unloaded via InferenceService.unloadModel(),
        // which calls through to the backend.
        XCTAssertEqual(mock.unloadCallCount, 1,
            "unloadModel should be called exactly once at critical level")

        // Error message should explain the unload.
        XCTAssertNotNil(vm.errorMessage, "errorMessage should be set at critical level")
        XCTAssertTrue(
            vm.errorMessage?.contains("critical") == true,
            "Error should mention critical pressure, got: \(vm.errorMessage ?? "nil")"
        )
    }

    // MARK: - Test 3: Memory Pressure Nominal After Critical

    /// After critical pressure clears back to nominal, the error message should be cleared.
    func test_handleMemoryPressure_nominalAfterCritical_clearsError() async {
        let handler = MemoryPressureHandler()
        let (vm, mock, _) = await makeViewModel(handler: handler)

        // Transition to critical.
        handler.pressureLevel = .critical
        vm.handleMemoryPressure()
        XCTAssertNotNil(vm.errorMessage, "Precondition: error should be set after critical")
        XCTAssertEqual(mock.unloadCallCount, 1)

        // Transition back to nominal.
        handler.pressureLevel = .nominal
        vm.handleMemoryPressure()

        // The error message should be cleared because it contained "Memory pressure".
        XCTAssertNil(vm.errorMessage,
            "errorMessage should be cleared when pressure returns to nominal")
    }

    // MARK: - Test 4: Memory Pressure Level Change Detection

    /// handleMemoryPressure should only act when the level actually changes.
    /// Calling it twice with the same level should produce side effects only once.
    func test_handleMemoryPressure_sameLevelTwice_onlyActsOnce() async {
        let handler = MemoryPressureHandler()
        let (vm, mock, _) = await makeViewModel(handler: handler)

        // Transition to critical (first call).
        handler.pressureLevel = .critical
        vm.handleMemoryPressure()
        XCTAssertEqual(mock.unloadCallCount, 1, "First call should unload")

        // Call handleMemoryPressure again with the same .critical level.
        // The guard (level != lastPressureLevel) should prevent any action.
        vm.handleMemoryPressure()
        XCTAssertEqual(mock.unloadCallCount, 1,
            "Second call with same level should NOT unload again")

        // Similarly test with warning: transition to warning, call twice.
        handler.pressureLevel = .warning
        vm.handleMemoryPressure()
        let errorAfterFirst = vm.errorMessage

        vm.handleMemoryPressure()
        XCTAssertEqual(vm.errorMessage, errorAfterFirst,
            "Second call with same warning level should not change error message")
    }

    // MARK: - Test 5: Rapid Sequential Sends

    /// Send 3 messages in rapid succession without awaiting individually.
    /// Verify no crash, all messages eventually appear, and final state is consistent.
    func test_rapidSequentialSends_doesNotCrash() async throws {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Reply"]

        let service = InferenceService(backend: mock, name: "Mock")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
        vm.activeSession = ChatSessionRecord(title: "Rapid Test")

        // Fire 3 sends in rapid succession as separate tasks.
        var tasks: [Task<Void, Never>] = []
        for i in 0..<3 {
            vm.inputText = "Rapid message \(i)"
            let task = Task { @MainActor in
                await vm.sendMessage()
            }
            tasks.append(task)
        }

        // Wait for all tasks to complete.
        for task in tasks {
            await task.value
        }

        // Verify: no crash (we got here), messages are present, generation is done.
        XCTAssertFalse(vm.messages.isEmpty,
            "Messages should be non-empty after rapid sends")
        XCTAssertFalse(vm.isGenerating,
            "isGenerating should be false after all sends complete")

        // All messages should have non-empty content.
        for message in vm.messages {
            XCTAssertFalse(message.content.isEmpty,
                "Every message should have non-empty content, found empty \(message.role) message")
        }
    }

    // MARK: - Test 6: Edit During Generation

    /// editMessage guards against isGenerating, so calling it during generation should
    /// be a no-op. After stopping generation, edit should work and trigger a new generation.
    func test_editDuringGeneration_isGuardedThenWorksAfterStop() async throws {
        let (vm, slow) = makeSlowViewModel(tokenCount: 20, delayMilliseconds: 50)

        // Send an initial message to get a user + assistant pair.
        slow.tokensToYield = ["initial", " reply"]
        slow.delayPerToken = .milliseconds(0)
        vm.inputText = "Original question"
        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 2, "Should have user + assistant")
        let originalUserMessage = vm.messages[0]

        // Now start a slow generation for a second message.
        slow.tokensToYield = (0..<20).map { "slow\($0) " }
        slow.delayPerToken = .milliseconds(50)
        vm.inputText = "Second question"

        let genTask = Task { @MainActor in
            await vm.sendMessage()
        }

        // Wait for generation to start.
        await vm.awaitGenerating(true)

        // Attempt to edit the first user message while generating -- should be guarded.
        let messageCountBefore = vm.messages.count
        await vm.editMessage(originalUserMessage.id, newContent: "Edited question")

        XCTAssertEqual(vm.messages.count, messageCountBefore,
            "editMessage should be a no-op while isGenerating is true")
        XCTAssertEqual(vm.messages[0].content, "Original question",
            "Original message content should be unchanged during generation")

        // Stop generation and wait for task to finish.
        vm.stopGeneration()
        await genTask.value

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after stop")

        // Now edit should work. Set up fast tokens for the regeneration.
        slow.tokensToYield = ["edited", " reply"]
        slow.delayPerToken = .milliseconds(0)
        await vm.editMessage(originalUserMessage.id, newContent: "Edited question")

        XCTAssertEqual(vm.messages[0].content, "Edited question",
            "User message should be updated after edit")

        // The edit removes everything after the edited message and regenerates.
        let lastAssistant = vm.messages.last { $0.role == .assistant }
        XCTAssertNotNil(lastAssistant, "Should have an assistant response after edit")
        XCTAssertEqual(lastAssistant?.content, "edited reply",
            "Assistant should have regenerated content after edit")
    }

    // MARK: - Test 7: clearChat During Generation

    /// Start generation with SlowMockBackend, then call clearChat().
    /// Verify generation stops and messages are empty.
    func test_clearChatDuringGeneration_stopsAndClears() async throws {
        let (vm, _) = makeSlowViewModel(tokenCount: 20, delayMilliseconds: 50)

        vm.inputText = "Tell me a long story"
        let genTask = Task { @MainActor in
            await vm.sendMessage()
        }

        // Wait for generation to start streaming.
        await vm.awaitGenerating(true)
        XCTAssertFalse(vm.messages.isEmpty, "Should have messages during generation")

        // Clear chat while generating.
        await vm.clearChat()

        XCTAssertFalse(vm.isGenerating,
            "isGenerating should be false after clearChat")
        XCTAssertTrue(vm.messages.isEmpty,
            "Messages should be empty after clearChat")

        // Wait for the background generation task to finish gracefully.
        await genTask.value

        // Final state should still be clean.
        XCTAssertTrue(vm.messages.isEmpty,
            "Messages should remain empty after generation task completes")
    }

    // MARK: - Test 8: stopGeneration Is Idempotent
    // MARK: - Memory Pressure Transition Tests (named variants)

    /// Critical pressure should unload the model; `inferenceService.isModelLoaded` becomes false.
    func test_handleMemoryPressure_critical_unloadsModel() async {
        let handler = MemoryPressureHandler()
        let (vm, mock, _) = await makeViewModel(handler: handler)

        // Precondition: model is loaded.
        XCTAssertTrue(vm.inferenceService.isModelLoaded,
            "Precondition: model should be loaded before critical pressure")

        handler.pressureLevel = .critical
        vm.handleMemoryPressure()

        XCTAssertFalse(vm.inferenceService.isModelLoaded,
            "Model should be unloaded after critical memory pressure")
        XCTAssertEqual(mock.unloadCallCount, 1,
            "unloadModel should be called once at critical level")
        let error = vm.errorMessage ?? ""
        XCTAssertTrue(
            error.lowercased().contains("critical") || error.lowercased().contains("unload"),
            "errorMessage should mention critical pressure or unloading, got: \(error)"
        )
    }

    /// Warning pressure should set an error message but leave the model loaded.
    func test_handleMemoryPressure_warning_setsErrorMessage() async {
        let handler = MemoryPressureHandler()
        let (vm, mock, _) = await makeViewModel(handler: handler)

        handler.pressureLevel = .warning
        vm.handleMemoryPressure()

        XCTAssertNotNil(vm.errorMessage,
            "errorMessage should be set at warning level")
        XCTAssertTrue(vm.inferenceService.isModelLoaded,
            "Model should NOT be unloaded at warning level")
        XCTAssertEqual(mock.unloadCallCount, 0,
            "unloadModel should not be called at warning level")
    }

    /// Calling `handleMemoryPressure()` twice with the same non-nominal level should
    /// only produce side effects on the first call; the second call is a no-op.
    func test_handleMemoryPressure_sameLevel_doesNothing() async {
        let handler = MemoryPressureHandler()
        let (vm, _, _) = await makeViewModel(handler: handler)

        // Transition to warning — first call sets the error.
        handler.pressureLevel = .warning
        vm.handleMemoryPressure()
        let errorAfterFirstCall = vm.errorMessage

        XCTAssertNotNil(errorAfterFirstCall,
            "Precondition: error should be set after first warning call")

        // Second call with the same level — guarded by `lastPressureLevel`, should be a no-op.
        vm.handleMemoryPressure()

        XCTAssertEqual(vm.errorMessage, errorAfterFirstCall,
            "errorMessage should not change on second call with same pressure level")
    }

    /// After warning sets an error, returning to nominal should clear the memory error.
    func test_handleMemoryPressure_returnsToNominal_clearsMemoryError() async {
        let handler = MemoryPressureHandler()
        let (vm, _, _) = await makeViewModel(handler: handler)

        // Step 1: transition to warning to set an error.
        handler.pressureLevel = .warning
        vm.handleMemoryPressure()
        XCTAssertNotNil(vm.errorMessage,
            "Precondition: error should be set after warning")
        XCTAssertTrue(
            vm.errorMessage?.contains("Memory pressure") == true,
            "Precondition: error should mention Memory pressure"
        )

        // Step 2: return to nominal — the memory error should be cleared.
        handler.pressureLevel = .nominal
        vm.handleMemoryPressure()

        XCTAssertNil(vm.errorMessage,
            "Memory pressure error should be cleared when pressure returns to nominal")
    }



    /// Calling stopGeneration() twice should not crash and isGenerating should be false.
    func test_stopGeneration_calledTwice_isIdempotent() {
        let mock = MockInferenceBackend()
        mock.isModelLoaded = true
        let service = InferenceService(backend: mock, name: "Mock")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )

        // Call stopGeneration twice with no generation in progress.
        vm.stopGeneration()
        vm.stopGeneration()

        XCTAssertFalse(vm.isGenerating,
            "isGenerating should be false after double stopGeneration")
        XCTAssertEqual(mock.stopCallCount, 2,
            "stopGeneration should forward to backend both times without crashing")
    }
}
