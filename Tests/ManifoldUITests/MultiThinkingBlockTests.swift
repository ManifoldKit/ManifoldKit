@preconcurrency import XCTest
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

/// Tests for #482 / #604: two ``GenerationEvent/thinkingCompleted`` events
/// on a single assistant turn must produce two distinct ``MessagePart/thinking``
/// parts (not one concatenated). Per-block signatures must round-trip onto
/// each part independently so the next replay against Anthropic carries the
/// right pairing.
@MainActor
final class MultiThinkingBlockTests: XCTestCase {

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
        vm.activeSession = ChatSession(title: "Test")
        // Force per-token flushes so partial-streaming writes happen on
        // every event and the test sees deterministic ordering.
        vm.thinkingStreamingUpdateInterval = .zero
        vm.thinkingStreamingBatchCharacterLimit = 1
        vm.streamingUpdateInterval = .zero
        vm.streamingBatchCharacterLimit = 1
        return vm
    }

    // MARK: - 1. Two finalize events → two thinking parts

    func test_twoThinkingBlocks_produceTwoSeparateThinkingParts() async {
        let mock = MockInferenceBackend()
        mock.thinkingBlocksToYield = [
            ["first ", "block"],
            ["second ", "block"],
        ]
        mock.signaturesPerThinkingBlock = ["sig_one", "sig_two"]
        mock.tokensToYield = ["done"]
        let vm = await makeVM(backend: mock)

        vm.inputText = "go"
        await vm.sendMessage()

        let assistant = vm.messages.first(where: { $0.role == .assistant })
        let thinkingParts = assistant?.contentParts.filter { $0.thinkingContent != nil } ?? []

        XCTAssertEqual(thinkingParts.count, 2,
            "Two .finalizeThinking events must produce two separate .thinking parts, not one concatenated. " +
            "Saw \(thinkingParts.count) thinking parts: \(thinkingParts)")

        XCTAssertEqual(thinkingParts[0].thinkingContent, "first block")
        XCTAssertEqual(thinkingParts[1].thinkingContent, "second block")

        // Per-block signatures must land on the matching parts — Anthropic
        // requires them paired correctly on multi-turn replay.
        XCTAssertEqual(thinkingParts[0].thinkingSignature, "sig_one",
            "First block's signature must land on the first .thinking part")
        XCTAssertEqual(thinkingParts[1].thinkingSignature, "sig_two",
            "Second block's signature must land on the second .thinking part")

        // Sabotage check: reverting the finalize branch to the old "merge
        // into existing thinking part" behaviour would coalesce both blocks
        // into a single part with text "first block\n\nsecond block" and
        // only one signature — failing both the count and pairing
        // assertions above.
    }
}
