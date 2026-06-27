@preconcurrency import XCTest
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport
// BackendInternals SPI: seam published for the companion split (#1749).
@_spi(BackendInternals) import ManifoldHardware
@_spi(BackendInternals) import ManifoldUI

// MARK: - Tests

@MainActor
final class GenerationExtensionTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    // MARK: - Helpers

    /// Build a view model with an arbitrary mock backend pre-loaded.
    private func makeVM(
        backend: MockInferenceBackend,
        name: String = "Mock"
    ) -> ChatViewModel {
        backend.isModelLoaded = true
        let service = InferenceService(backend: backend, name: name)
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
        vm.activeSession = ManifoldInference.ChatSession(title: "Test")
        return vm
    }

    /// Build a view model with a non-MockInferenceBackend.
    private func makeVM(
        rawBackend: any InferenceBackend,
        name: String = "Mock"
    ) -> ChatViewModel {
        let service = InferenceService(backend: rawBackend, name: name)
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
        vm.activeSession = ManifoldInference.ChatSession(title: "Test")
        return vm
    }

    // MARK: - 1. Token Usage Capture

    func test_tokenUsage_capturedOnAssistantMessage() async {
        let mock = TokenTrackingMockBackend()
        mock.tokensToYield = ["Hello", " there"]
        mock.usageToReport = (promptTokens: 10, completionTokens: 5)
        let vm = await makeVM(rawBackend: mock)

        vm.inputText = "Hi"
        await vm.sendMessage()

        let assistant = vm.messages.first(where: { $0.role == .assistant })
        XCTAssertNotNil(assistant, "Should have an assistant message")
        XCTAssertEqual(assistant?.promptTokens, 10, "promptTokens should be captured from backend usage")
        XCTAssertEqual(assistant?.completionTokens, 5, "completionTokens should be captured from backend usage")
    }

    func test_tokenUsage_capturedPerGeneration_notCrossContaminated() async {
        // The risk: if the backend overwrites `lastUsage` before the first message
        // captures it, the wrong token counts get attached to a ManifoldInference.ChatMessage.
        // This test sends two sequential messages and asserts that each assistant
        // message receives the token counts from *its own* generation, not the other.
        let mock = TokenTrackingMockBackend()
        mock.tokensToYield = ["reply"]
        mock.usageSequence = [
            (promptTokens: 10, completionTokens: 5),   // first generation
            (promptTokens: 20, completionTokens: 8),   // second generation
        ]
        let vm = await makeVM(rawBackend: mock)

        // First generation
        vm.inputText = "First question"
        await vm.sendMessage()

        // Second generation
        vm.inputText = "Second question"
        await vm.sendMessage()

        let assistants = vm.messages.filter { $0.role == .assistant }
        XCTAssertEqual(assistants.count, 2, "Should have two assistant messages")

        let first = assistants[0]
        XCTAssertEqual(first.promptTokens, 10,
            "First message should have promptTokens=10, got \(String(describing: first.promptTokens))")
        XCTAssertEqual(first.completionTokens, 5,
            "First message should have completionTokens=5, got \(String(describing: first.completionTokens))")

        let second = assistants[1]
        XCTAssertEqual(second.promptTokens, 20,
            "Second message should have promptTokens=20, got \(String(describing: second.promptTokens))")
        XCTAssertEqual(second.completionTokens, 8,
            "Second message should have completionTokens=8, got \(String(describing: second.completionTokens))")
    }

    func test_tokenUsage_nilWhenBackendDoesNotProvide() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Reply"]
        let vm = await makeVM(backend: mock)

        vm.inputText = "Hi"
        await vm.sendMessage()

        let assistant = vm.messages.first(where: { $0.role == .assistant })
        XCTAssertNotNil(assistant)
        XCTAssertNil(assistant?.promptTokens, "promptTokens should be nil when backend is not a TokenUsageProvider")
        XCTAssertNil(assistant?.completionTokens, "completionTokens should be nil when backend is not a TokenUsageProvider")
    }

    // MARK: - 2. Upgrade Hint Logic

    func test_upgradeHint_doesNotTriggerOnNormalStop() async {
        // A normal (.stop) generation must NOT show the hint — only context exhaustion
        // (.length) should, so the banner doesn't fire on every successful reply.
        let originalConfig = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfig }

        ManifoldConfiguration.shared.features = ManifoldConfiguration.Features(showUpgradeHint: true)

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Hello"]
        let vm = await makeVM(backend: mock, name: BackendName.foundation.rawValue)

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertFalse(vm.showUpgradeHint, "showUpgradeHint must stay false after a normal .stop reply")
    }

    func test_upgradeHint_doesNotTriggerWhenFeatureFlagDisabled() async {
        let originalConfig = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfig }

        ManifoldConfiguration.shared.features = ManifoldConfiguration.Features(showUpgradeHint: false)

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Hello"]
        let vm = await makeVM(backend: mock, name: BackendName.foundation.rawValue)

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertFalse(vm.showUpgradeHint, "showUpgradeHint should remain false when feature flag is disabled")
    }

    func test_upgradeHint_doesNotTriggerForNonAppleBackend() async {
        let originalConfig = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfig }

        ManifoldConfiguration.shared.features = ManifoldConfiguration.Features(showUpgradeHint: true)

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Hello"]
        let vm = await makeVM(backend: mock, name: BackendName.mlx.rawValue)

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertFalse(vm.showUpgradeHint, "showUpgradeHint should remain false for non-Apple backends")
    }

    func test_upgradeHint_doesNotTriggerAgainOnceFired() async {
        // Once showUpgradeHint is true the guard `!showUpgradeHint` prevents
        // onUpgradeHintTriggered from firing a second time, even after another turn.
        let originalConfig = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfig }

        ManifoldConfiguration.shared.features = ManifoldConfiguration.Features(showUpgradeHint: true)

        let mock = MockInferenceBackend()
        mock.tokensToYield = ["First"]
        let vm = await makeVM(backend: mock, name: BackendName.foundation.rawValue)

        // Simulate the hint having already fired (e.g. via a prior .length turn).
        vm.showUpgradeHint = true

        var secondCallback = false
        vm.onUpgradeHintTriggered = { secondCallback = true }

        mock.tokensToYield = ["Second"]
        vm.inputText = "Another"
        await vm.sendMessage()

        XCTAssertFalse(secondCallback, "onUpgradeHintTriggered should not fire again once hint is already shown")
    }

    func test_upgradeHint_doesNotTriggerWhenResponseEmpty() async {
        let originalConfig = ManifoldConfiguration.shared
        defer { ManifoldConfiguration.shared = originalConfig }

        ManifoldConfiguration.shared.features = ManifoldConfiguration.Features(showUpgradeHint: true)

        let mock = MockInferenceBackend()
        mock.tokensToYield = []  // Empty response
        let vm = await makeVM(backend: mock, name: BackendName.foundation.rawValue)

        vm.inputText = "Hi"
        await vm.sendMessage()

        XCTAssertFalse(vm.showUpgradeHint, "showUpgradeHint should remain false when response is empty")
    }

    // MARK: - 3. Context Trimming During Generation

    func test_contextTrimming_reducesPromptForLowContextWindow() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["OK"]
        // Use requiresPromptTemplate so the full formatted prompt is captured.
        mock.capabilities = BackendCapabilities(
            supportedParameters: [.temperature, .topP, .repeatPenalty],
            maxContextTokens: 100,
            requiresPromptTemplate: true,
            supportsSystemPrompt: false
        )
        let vm = await makeVM(backend: mock)
        // Set a very small context window.
        vm.contextMaxTokens = 100

        // Add many long messages directly to the messages array.
        let sessionID = vm.activeSession!.id
        let longContent = String(repeating: "word ", count: 200) // ~1000 chars = ~250 tokens
        for i in 0..<10 {
            let role: MessageRole = i.isMultiple(of: 2) ? .user : .assistant
            let msg = ManifoldInference.ChatMessage(role: role, content: longContent, sessionID: sessionID)
            vm.messages.append(msg)
        }

        // Now send a new message.
        vm.inputText = "Short question"
        await vm.sendMessage()

        // The prompt passed to the backend should be shorter than if all messages
        // had been included. With 10 prior messages of ~250 tokens each plus the
        // new user message, the full conversation is ~2500 tokens. With a 100 token
        // context window, trimming should drop most of them.
        let capturedPrompt = mock.lastPrompt ?? ""
        let fullConversationLength = longContent.count * 10 + "Short question".count
        XCTAssertLessThan(
            capturedPrompt.count, fullConversationLength,
            "Prompt should be trimmed to fit within context window (prompt length: \(capturedPrompt.count), full: \(fullConversationLength))"
        )
    }

    // MARK: - 4. Empty Response Cleanup

    func test_emptyResponse_removesAssistantPlaceholder() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = []  // Zero tokens
        let vm = await makeVM(backend: mock)

        vm.inputText = "Hello"
        await vm.sendMessage()

        // The user message should remain; the empty assistant message should be removed.
        XCTAssertEqual(vm.messages.count, 1, "Only the user message should remain when assistant produces no tokens")
        XCTAssertEqual(vm.messages.first?.role, .user, "Remaining message should be the user message")
    }

    func test_nonEmptyResponse_persistsAssistantMessage() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Hi"]
        let vm = await makeVM(backend: mock)

        vm.inputText = "Hello"
        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 2, "Both user and assistant messages should be present")
        XCTAssertEqual(vm.messages[1].role, .assistant)
        XCTAssertEqual(vm.messages[1].content, "Hi")
    }

    func test_streamingBatching_preservesAllTokensWhenFlushAtCompletion() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["A", "B", "C", "D", "E"]
        let vm = await makeVM(backend: mock)
        vm.streamingUpdateInterval = .seconds(60)
        vm.streamingBatchCharacterLimit = 10_000

        vm.inputText = "batch"
        await vm.sendMessage()

        let assistant = vm.messages.first(where: { $0.role == .assistant })
        XCTAssertEqual(assistant?.content, "ABCDE")
    }

    // MARK: - 5. Loop Detection With Batching

    func test_loopDetection_firesWithBatchingEnabled() async {
        let mock = MockInferenceBackend()
        // Build a repeating pattern that triggers RepetitionDetector (50+ chars repeated 2x).
        let chunk = String(repeating: "ABCDEFGHIJ", count: 6) // 60 chars
        // Emit enough single-char tokens to build chunk twice (120 chars total).
        let repeatedText = chunk + chunk
        mock.tokensToYield = repeatedText.map { String($0) }
        let vm = await makeVM(backend: mock)
        vm.loopDetectionEnabled = true
        // Use small batch limit so the batcher flushes frequently and detection runs.
        vm.streamingUpdateInterval = .zero
        vm.streamingBatchCharacterLimit = 1

        vm.inputText = "loop"
        await vm.sendMessage()

        XCTAssertNotNil(vm.errorMessage, "Loop detection should fire and set errorMessage")
        XCTAssertTrue(vm.errorMessage?.contains("repeating itself") == true)
        XCTAssertEqual(mock.stopCallCount, 1, "stopGeneration should be called once")
    }

    // MARK: - 6. isGenerating Flag Transitions

    func test_isGenerating_falseAfterSuccessfulGeneration() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Done"]
        let vm = await makeVM(backend: mock)

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false before generation")

        vm.inputText = "Go"
        await vm.sendMessage()

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after successful generation")
    }

    func test_isGenerating_falseAfterGenerationError() async {
        let mock = MockInferenceBackend()
        mock.shouldThrowOnGenerate = InferenceError.inferenceFailure("Boom")
        let vm = await makeVM(backend: mock)

        vm.inputText = "Go"
        await vm.sendMessage()

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after generation error")
    }

    func test_isGenerating_falseAfterStreamError() async {
        let errorBackend = MidStreamErrorBackend()
        let vm = await makeVM(rawBackend: errorBackend)

        vm.inputText = "Go"
        await vm.sendMessage()

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after stream error")
    }

    // MARK: - 7. Stream Termination Cleans Up Service State

    func test_streamCompletion_setsServiceIsGeneratingFalse() async {
        let mock = MockInferenceBackend()
        mock.tokensToYield = ["Token"]
        let vm = await makeVM(backend: mock)

        vm.inputText = "Test"
        await vm.sendMessage()

        XCTAssertFalse(
            vm.inferenceService.isGenerating,
            "InferenceService.isGenerating should be false after generation completes (queue auto-drains)"
        )
    }

    func test_streamError_clearsIsGenerating() async {
        let mock = MockInferenceBackend()
        mock.shouldThrowOnGenerate = InferenceError.inferenceFailure("fail")
        let vm = await makeVM(backend: mock)

        vm.inputText = "Test"
        await vm.sendMessage()

        XCTAssertFalse(
            vm.inferenceService.isGenerating,
            "InferenceService.isGenerating should be false even after generation error"
        )
    }

    // MARK: - 8. Error During Generation Sets errorMessage

    func test_generationStartError_setsErrorMessage() async {
        let mock = MockInferenceBackend()
        mock.shouldThrowOnGenerate = InferenceError.inferenceFailure("backend exploded")
        let vm = await makeVM(backend: mock)

        vm.inputText = "Hello"
        await vm.sendMessage()

        XCTAssertNotNil(vm.errorMessage, "errorMessage should be set when generation throws")
        XCTAssertNotNil(vm.activeError, "activeError should be set when generation throws")
        XCTAssertEqual(vm.activeError?.kind, .generation, "Error kind should be .generation")
        XCTAssertTrue(
            vm.errorMessage?.contains("backend exploded") == true,
            "Error should contain the underlying error description, got: \(vm.errorMessage ?? "nil")"
        )
    }

    func test_streamError_setsErrorMessage() async {
        let errorBackend = MidStreamErrorBackend()
        let vm = await makeVM(rawBackend: errorBackend)

        vm.inputText = "Hello"
        await vm.sendMessage()

        XCTAssertNotNil(vm.errorMessage, "errorMessage should be set when stream throws")
        XCTAssertTrue(
            vm.errorMessage?.contains("stream boom") == true,
            "Error should contain the stream error description, got: \(vm.errorMessage ?? "nil")"
        )
    }
}
