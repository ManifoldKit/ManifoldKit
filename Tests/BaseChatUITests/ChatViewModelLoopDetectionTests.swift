@preconcurrency import XCTest
@testable import BaseChatUI
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport

@MainActor
final class ChatViewModelLoopDetectionTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    private func makeVM(backend: MockInferenceBackend) -> ChatViewModel {
        backend.isModelLoaded = true
        let service = InferenceService(backend: backend, name: "Mock")
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
        vm.activeSession = ChatSessionRecord(title: "Test")
        return vm
    }

    // MARK: - Loop detection stops generation

    func test_repetitiveOutput_stopsGeneration() async {
        let mock = MockInferenceBackend()
        // 20-char chunk repeated 30 times = 600 chars, well above thresholds
        let repeatedChunk = "The world ended now. "
        mock.tokensToYield = Array(repeating: repeatedChunk, count: 30)
        let vm = await makeVM(backend: mock)

        vm.inputText = "Hello"
        await vm.sendMessage()

        XCTAssertNotNil(vm.errorMessage, "Should have set an error message")
        XCTAssertTrue(
            vm.errorMessage?.contains("repeating") == true,
            "Error should mention repetition, got: \(vm.errorMessage ?? "nil")"
        )
    }

    // MARK: - Loop detection disabled

    func test_repetitiveOutput_notStopped_whenDisabled() async {
        let mock = MockInferenceBackend()
        let repeatedChunk = "The world ended now. "
        mock.tokensToYield = Array(repeating: repeatedChunk, count: 30)
        let vm = await makeVM(backend: mock)
        vm.loopDetectionEnabled = false

        vm.inputText = "Hello"
        await vm.sendMessage()

        // All tokens should have been accumulated without stopping
        let assistant = vm.messages.first(where: { $0.role == .assistant })
        XCTAssertNotNil(assistant)
        let expectedFull = String(repeating: repeatedChunk, count: 30)
        XCTAssertEqual(assistant?.content, expectedFull, "All tokens should be accumulated when detection is off")
        XCTAssertNil(vm.errorMessage, "No error should be set when loop detection is disabled")
    }

    // MARK: - Thinking buffer loop detection (unit test on consumer)

    /// Verifies that `shouldStopForLoop` fires on `thinkingAccumulator` content,
    /// mirroring the guard that already exists for the visible-text accumulator.
    /// Caught by fuzz finding 748815b0da2e (qwen3.5:4b, looping/thinking-loop).
    func test_thinkingAccumulator_loopDetection_firesOnRepetitiveContent() {
        var consumer = GenerationStreamConsumer(loopDetectionEnabled: true)

        // Build a repetitive thinking accumulator: a 25-char phrase repeated 12 times
        // gives 300 chars, well above the 100-char 2x-detection threshold.
        let chunk = "This is a thinking loop. "
        let thinkingAccumulator = String(repeating: chunk, count: 12)

        // Sabotage check: with loopDetectionEnabled=false the guard must NOT fire.
        consumer.loopDetectionEnabled = false
        XCTAssertFalse(
            consumer.shouldStopForLoop(content: thinkingAccumulator),
            "shouldStopForLoop must return false when loop detection is disabled"
        )

        // Real assertion: with detection enabled the repetitive content must trip the guard.
        consumer.loopDetectionEnabled = true
        XCTAssertTrue(
            consumer.shouldStopForLoop(content: thinkingAccumulator),
            "shouldStopForLoop must return true for repetitive thinking content"
        )
    }

    // MARK: - Normal output not stopped

    func test_normalOutput_completesWithoutStopping() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = [
            "The ", "quick ", "brown ", "fox ", "jumps ", "over ",
            "the ", "lazy ", "dog. ", "A ", "wonderful ", "sentence."
        ]
        let vm = await makeVM(backend: mock)

        vm.inputText = "Hello"
        await vm.sendMessage()

        let assistant = vm.messages.first(where: { $0.role == .assistant })
        XCTAssertNotNil(assistant)
        XCTAssertEqual(assistant?.content, "The quick brown fox jumps over the lazy dog. A wonderful sentence.")
        XCTAssertNil(vm.errorMessage, "Normal output should not trigger loop detection")
    }
}
