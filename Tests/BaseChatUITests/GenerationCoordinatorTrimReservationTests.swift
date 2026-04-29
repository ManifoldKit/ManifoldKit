@preconcurrency import XCTest
import SwiftData
@testable import BaseChatUI
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport

/// Regression tests for issue #587 — the UI `GenerationCoordinator` previously
/// hardcoded `responseBuffer: 512` when calling `ContextWindowManager.trimMessages`.
/// That value ignored both `ChatViewModel.maxOutputTokens` and
/// `ChatViewModel.maxThinkingTokens`, so thinking-heavy models could silently
/// truncate older prompt history once reasoning output exceeded ~2 KB.
///
/// These tests pin the new behaviour: the reservation is derived from
/// `maxOutputTokens() + (maxThinkingTokens() ?? 0)` and is forwarded to the
/// backend via `InferenceService.enqueue`.
@MainActor
final class GenerationCoordinatorTrimReservationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var sessionManager: SessionManagerViewModel!
    private var mock: MockInferenceBackend!
    private var sessionID: UUID!

    override func setUp() async throws {
        try await super.setUp()

        container = try makeInMemoryContainer()
        context = container.mainContext

        mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["ok"]

        let service = InferenceService(backend: mock, name: "MockTrim")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: SwiftDataPersistenceProvider(modelContext: context), autoLoad: false)

        let session = try await sessionManager.createSession(title: "Trim fixture")
        sessionManager.activeSession = session
        await vm.switchToSession(session)
        sessionID = session.id
    }

    override func tearDown() async throws {
        vm = nil
        sessionManager = nil
        mock = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    /// Black-box: the UI coordinator must forward `ChatViewModel.maxOutputTokens`
    /// to the backend instead of relying on the `InferenceService.enqueue`
    /// default of `2048`. Sabotage-verified by temporarily setting the
    /// hardcode back in the coordinator — `mock.lastConfig?.maxOutputTokens`
    /// then reports `2048` (the enqueue default) and this assertion fails.
    func test_uiGenerationCoordinator_forwardsMaxOutputTokens() async throws {
        vm.maxOutputTokens = 100
        vm.maxThinkingTokens = nil

        vm.inputText = "hi"
        await vm.sendMessage()

        let config = try XCTUnwrap(mock.lastConfig, "Backend should have received a config")
        XCTAssertEqual(config.maxOutputTokens, 100,
                       "ChatViewModel.maxOutputTokens must propagate to the backend, "
                       + "not the 2048 enqueue default.")
    }

    /// Black-box: the UI coordinator must forward `ChatViewModel.maxThinkingTokens`
    /// through `enqueue` into `GenerationConfig.maxThinkingTokens` so downstream
    /// backends (Ollama, Llama, MLX) can honour the cap.
    func test_uiGenerationCoordinator_forwardsMaxThinkingTokens() async throws {
        vm.maxOutputTokens = 256
        vm.maxThinkingTokens = 128

        vm.inputText = "hi"
        await vm.sendMessage()

        let config = try XCTUnwrap(mock.lastConfig)
        XCTAssertEqual(config.maxThinkingTokens, 128,
                       "ChatViewModel.maxThinkingTokens must flow through to GenerationConfig.")
    }

    /// Black-box: the UI coordinator must NOT hardcode `responseBuffer: 512`.
    /// Verified by setting `maxOutputTokens` to a value far above 512 and
    /// asserting that it, not 512, drives the trim decision.
    ///
    /// Scenario: context = 100 tokens, maxOutputTokens = 90, system prompt empty.
    /// - With the fix: `responseBuffer = 90 + 0 = 90` → only 10 tokens for prompt
    ///   → the trimmer keeps at most a couple of short messages.
    /// - Pre-fix (`responseBuffer: 512`): `available = 100 - 0 - 512 = -412 ≤ 0`
    ///   → the trimmer returns just the single last-user message.
    ///
    /// So the PRE-fix branch keeps exactly 1 message; the POST-fix branch keeps
    /// more than 1. Asserting `count >= 2` distinguishes the two.
    ///
    /// Sabotage check: restoring the hardcoded `responseBuffer: 512` in the
    /// UI `GenerationCoordinator` forces `available <= 0`, the trimmer
    /// returns only the latest user message, and this assertion fails.
    func test_uiGenerationCoordinator_noLongerHardcodes512() async throws {
        vm.contextMaxTokens = 100
        vm.maxOutputTokens = 90
        vm.maxThinkingTokens = 0

        // Seed a history of short messages. Each is roughly 5–7 tokens under
        // the heuristic tokenizer (~4 chars / token). With a 10-token budget
        // the trimmer should keep the newest ~1–2 entries — but crucially
        // **more than 0 history entries from the seed** are kept in addition
        // to the new user message. The pre-fix 512 hardcode forces
        // `available <= 0`, which returns just the last user message.
        var msgs: [ChatMessageRecord] = []
        for i in 0..<6 {
            msgs.append(ChatMessageRecord(role: .user, content: "q\(i)pad", sessionID: sessionID))
            msgs.append(ChatMessageRecord(role: .assistant, content: "r\(i)pad", sessionID: sessionID))
        }
        vm.messages = msgs

        mock.lastReceivedHistory = nil
        vm.inputText = "hi"
        await vm.sendMessage()

        let trimmed = try XCTUnwrap(mock.lastReceivedHistory,
                                    "Mock backend should have received a trimmed history")

        XCTAssertGreaterThanOrEqual(
            trimmed.count, 2,
            "With responseBuffer derived from maxOutputTokens=90 (not a 512 hardcode), "
            + "available = 100 - 0 - 90 = 10 tokens is enough to keep more than one message. "
            + "The pre-fix 512 hardcode would force available <= 0, trimming to just the "
            + "single last user message. Count was \(trimmed.count)."
        )
    }
}
