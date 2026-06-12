@preconcurrency import XCTest
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport
// BackendInternals SPI: seam published for the companion split (#1749).
@_spi(BackendInternals) import ManifoldHardware
@_spi(BackendInternals) import ManifoldUI

/// Asserts the live-streaming behavior introduced for issue #481: the
/// reasoning block must mutate multiple times during the streaming phase
/// rather than only being written once on `.finalizeThinking`.
@MainActor
final class ThinkingStreamingTests: XCTestCase {

    private let oneGB: UInt64 = 1_024 * 1_024 * 1_024

    private func makeVM(backend: MockInferenceBackend) async -> ChatViewModel {
        backend.isModelLoaded = true
        let service = InferenceService(backend: backend, name: "Mock")
        // The runtime applies the streaming intervals from `TurnConfig` it
        // receives at `processTurn(...)` time. ChatViewModel forwards the
        // view-model-level overrides into the input, so setting them on the
        // VM still flows through.
        let vm = ChatViewModel(
            inferenceService: service,
            deviceCapability: DeviceCapabilityService(physicalMemory: 16 * oneGB),
            modelStorage: ModelStorageService(),
            memoryPressure: MemoryPressureHandler()
        )
        vm.activeSession = ManifoldInference.ChatSession(title: "Test")
        // Force per-token flushes for both batchers so every thinking fragment
        // and visible token causes its own observable mutation, making the
        // intermediate states visible to the test recorder.
        vm.thinkingStreamingUpdateInterval = .zero
        vm.thinkingStreamingBatchCharacterLimit = 1
        vm.streamingUpdateInterval = .zero
        vm.streamingBatchCharacterLimit = 1
        return vm
    }

    // MARK: - Streaming flag clears on finalize

    func test_streamingThinkingFlag_clearsOnFinalize() async {
        let mock = MockInferenceBackend()
        mock.thinkingTokensToYield = ["a", "b", "c", "d", "e"]
        mock.tokensToYield = ["ok"]
        let vm = await makeVM(backend: mock)

        vm.inputText = "hi"
        await vm.sendMessage()
        await vm.awaitGenerating(false)

        XCTAssertTrue(
            vm.messageIDsWithStreamingThinking.isEmpty,
            "messageIDsWithStreamingThinking must be empty after generation completes"
        )
    }

    // MARK: - Visible-text appends preserve sibling thinking parts
    //
    // Direct unit tests for `appendVisibleText` — the helper that replaces the
    // `msg.content += batch` line whose setter clobbered any non-text parts.
    // These tests pin the contract so a future refactor can't silently regress
    // to wholesale replacement.

    func test_appendVisibleText_preservesLeadingThinkingPart() {
        var msg = ManifoldInference.ChatMessage(role: .assistant, content: "", sessionID: UUID())
        msg.contentParts = [.thinking("reasoning"), .text("Hello")]

        ChatViewModel.appendVisibleText(", world", into: &msg)

        XCTAssertEqual(msg.contentParts.count, 2)
        guard case .thinking(let t, _) = msg.contentParts[0] else {
            return XCTFail("Expected leading .thinking part to survive append")
        }
        XCTAssertEqual(t, "reasoning")
        guard case .text(let s) = msg.contentParts[1] else {
            return XCTFail("Expected trailing .text part")
        }
        XCTAssertEqual(s, "Hello, world")
    }

    func test_appendVisibleText_appendsNewTextPart_whenNoneExists() {
        var msg = ManifoldInference.ChatMessage(role: .assistant, content: "", sessionID: UUID())
        msg.contentParts = [.thinking("only reasoning so far")]

        ChatViewModel.appendVisibleText("first visible", into: &msg)

        XCTAssertEqual(msg.contentParts.count, 2)
        guard case .thinking = msg.contentParts[0] else {
            return XCTFail("Thinking part must remain at index 0")
        }
        guard case .text(let s) = msg.contentParts[1] else {
            return XCTFail("New .text part must be appended after thinking")
        }
        XCTAssertEqual(s, "first visible")
    }

    // MARK: - Partial thinking writes mutate the placeholder in place

    func test_writeThinkingPartialText_replacesExistingPlaceholder() {
        var msg = ManifoldInference.ChatMessage(role: .assistant, content: "", sessionID: UUID())
        msg.contentParts = [.thinking(""), .text("visible")]

        ChatViewModel.writeThinkingPartialText("Let me", into: &msg)
        ChatViewModel.writeThinkingPartialText("Let me think", into: &msg)

        XCTAssertEqual(msg.contentParts.count, 2, "No new parts should be appended on partial flushes")
        guard case .thinking(let t, _) = msg.contentParts[0] else {
            return XCTFail("Index 0 must remain a .thinking part")
        }
        XCTAssertEqual(t, "Let me think")
        guard case .text(let s) = msg.contentParts[1] else {
            return XCTFail("Index 1 must remain the .text part")
        }
        XCTAssertEqual(s, "visible")
    }
}
