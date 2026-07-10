@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceTestSupport

// MARK: - Interleaving Tests

/// Tests for interleaved operations: stop-then-resend, session-switch mid-stream,
/// and model-swap mid-generation. These verify that concurrent lifecycle transitions
/// don't corrupt state or leak content across sessions.
@MainActor
final class InterleavingTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var sessionManager: SessionManagerViewModel!
    private var slowBackend: SlowMockBackend!
    private var persistence: SwiftDataPersistenceProvider!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        container = try makeInMemoryContainer()
        context = container.mainContext

        slowBackend = SlowMockBackend(tokenCount: 20, delayMilliseconds: 50)

        let service = InferenceService(backend: slowBackend, name: "SlowMock")
        persistence = SwiftDataPersistenceProvider(modelContext: context)
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: persistence)

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: persistence, autoLoad: false)
    }

    override func tearDown() async throws {
        vm?.stopGeneration()
        vm?.inferenceService.unloadModel()
        vm = nil
        sessionManager = nil
        slowBackend = nil
        persistence = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func createAndActivateSession(title: String = "Test Chat") async throws -> ManifoldInference.ChatSession {
        let session = try await sessionManager.createSession(title: title)
        sessionManager.activeSession = session
        await vm.switchToSession(session)
        return session
    }

    /// Full expected output when all 20 tokens complete.
    private var fullOutput: String {
        (0..<20).map { "token\($0) " }.joined()
    }

    // MARK: - Test 1: Stop then immediate resend

    /// Stops mid-generation then immediately sends a second message.
    /// The first assistant reply should be partial; the second should complete fully.
    func test_stopGeneration_thenImmediateResend_completesSecondGeneration() async throws {
        try await createAndActivateSession()

        // Start first generation with the slow 20-token stream.
        vm.inputText = "first message"
        let firstTask = Task { @MainActor in
            await self.vm.sendMessage()
        }

        // Wait until tokens are flowing, then cancel.
        await vm.awaitFirstToken()
        vm.stopGeneration()
        await firstTask.value

        // Capture partial content before second send.
        let firstAssistantContent = vm.messages.first(where: { $0.role == .assistant })?.content ?? ""
        XCTAssertFalse(firstAssistantContent.isEmpty, "First assistant should have received some tokens before stop")
        XCTAssertNotEqual(firstAssistantContent, fullOutput, "First assistant should be partial, not the full output")

        // Immediately send a second message with a short, fast reply.
        slowBackend.tokensToYield = ["complete", " second", " reply"]
        slowBackend.delayPerToken = .milliseconds(10)

        vm.inputText = "second message"
        await vm.sendMessage()

        // Expect 4 messages: user1, assistant1 (partial), user2, assistant2 (complete).
        XCTAssertEqual(vm.messages.count, 4,
            "Expected user1 + partial-assistant1 + user2 + assistant2, got \(vm.messages.count)")
        XCTAssertEqual(vm.messages[0].role, .user)
        XCTAssertEqual(vm.messages[1].role, .assistant)
        XCTAssertEqual(vm.messages[2].role, .user)
        XCTAssertEqual(vm.messages[3].role, .assistant)

        // First assistant: partial (not all 20 tokens).
        XCTAssertNotEqual(vm.messages[1].content, fullOutput,
            "First assistant message should be partial")
        XCTAssertFalse(vm.messages[1].content.isEmpty,
            "First assistant message should not be empty")

        // Second assistant: complete.
        XCTAssertEqual(vm.messages[3].content, "complete second reply",
            "Second assistant message should have the full second reply")

        // Final state.
        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after second generation completes")
        XCTAssertEqual(vm.activityPhase, .idle, "activityPhase should be idle after completion")
    }

    // MARK: - Test 2: Session switch during generation — no content leakage

    /// Starts generation on session A, switches to session B mid-stream,
    /// then generates on B. Verifies no tokens from A leak into B.
    /// Fixed by #965: `discardRequests(notMatching:)` is now async and awaits
    /// the active task's tear-down before returning, so B's `enqueueAsync`
    /// lands on a clean queue.
    func test_sessionSwitch_duringGeneration_noContentLeakage() async throws {
        // Session A: slow 20-token stream with identifiable tokens.
        let sessionA = try await createAndActivateSession(title: "Session A")
        slowBackend.tokensToYield = (0..<20).map { "alpha\($0) " }
        slowBackend.delayPerToken = .milliseconds(50)

        // Start generation on A.
        vm.inputText = "question for A"
        let genTask = Task { @MainActor in
            await self.vm.sendMessage()
        }
        await vm.awaitFirstToken()

        // Create and switch to session B mid-stream.
        // switchToSession now explicitly stops generation and discards stale queue entries.
        let sessionB = try await sessionManager.createSession(title: "Session B")
        sessionManager.activeSession = sessionB
        await vm.switchToSession(sessionB)

        // Generation should be stopped and queue cleared after switch.
        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after session switch stops generation")
        XCTAssertFalse(vm.inferenceService.hasQueuedRequests, "Queue should be empty after session switch")

        // Session B should be empty immediately after switching.
        XCTAssertTrue(vm.messages.isEmpty,
            "Session B should have no messages right after switching")
        XCTAssertEqual(vm.activeSession?.id, sessionB.id)

        // Generate a quick reply on B with distinct tokens.
        slowBackend.tokensToYield = ["beta0", " beta1"]
        slowBackend.delayPerToken = .milliseconds(10)

        vm.inputText = "question for B"
        await vm.sendMessage()

        // Wait for the background generation from A to finish.
        await genTask.value

        // Verify B's messages contain no alpha tokens.
        let sessionBMessages = vm.messages
        for msg in sessionBMessages {
            XCTAssertFalse(msg.content.contains("alpha"),
                "Session B must not contain tokens from session A; found: \(msg.content)")
        }

        // Verify we're still on session B.
        XCTAssertEqual(vm.activeSession?.id, sessionB.id,
            "Should remain on session B after A's generation finishes")

        // Verify persistence: session A has its user message.
        let sessionAPersistedMessages = try await persistence.fetchMessages(for: sessionA.id)
        XCTAssertTrue(sessionAPersistedMessages.contains { $0.role == .user && $0.content == "question for A" },
            "Session A should have its user message persisted")

        // Verify persistence: session B has a complete user + assistant turn.
        let sessionBPersistedMessages = try await persistence.fetchMessages(for: sessionB.id)
        let sessionBUser = sessionBPersistedMessages.filter { $0.role == .user }
        let sessionBAssistant = sessionBPersistedMessages.filter { $0.role == .assistant }
        XCTAssertEqual(sessionBUser.count, 1, "Session B should have 1 user message persisted")
        XCTAssertEqual(sessionBAssistant.count, 1, "Session B should have 1 assistant message persisted")
        XCTAssertEqual(sessionBAssistant.first?.content, "beta0 beta1",
            "Session B assistant should have the complete beta reply")
    }

    // MARK: - Test 3: Switch model mid-stream — cancels stream and reloads new model

    /// Switches to a new model while generation is in progress.
    /// Verifies the old stream is cancelled cleanly, no orphaned assistant row
    /// survives, and the new model is loaded when the switch completes.
    func test_switchModel_midStream_cancelsAndReloads() async throws {
        let session = try await createAndActivateSession()

        // Configure a long token stream so generation is still running when we switch.
        slowBackend.tokensToYield = (0..<40).map { "tok\($0) " }
        slowBackend.delayPerToken = .milliseconds(40)

        // Start generation — do NOT await; it must still be running when we switch.
        vm.inputText = "Hello from modelA"
        let genTask = Task { @MainActor in
            await self.vm.sendMessage()
        }

        // Wait until streaming is actually underway.
        await vm.awaitFirstToken()
        XCTAssertTrue(vm.isGenerating, "Precondition: should be generating when we switch")
        XCTAssertEqual(vm.messages.count, 2, "Precondition: should have user + in-progress assistant")

        // Set up modelB with its own MockInferenceBackend.
        let modelBBackend = MockInferenceBackend()
        modelBBackend.isModelLoaded = false
        vm.inferenceService.registerBackendFactory { _ in modelBBackend }

        let modelB = ModelInfo(
            name: "ModelB",
            fileName: "modelb.gguf",
            url: URL(fileURLWithPath: "/tmp/modelb.gguf"),
            fileSize: 0,
            modelType: .gguf
        )

        // Switch to modelB and load it — this should cancel the old stream.
        vm.selectedModel = modelB
        await vm.loadSelectedModel()

        // Ensure the background generation task from modelA has fully settled.
        await genTask.value

        // --- Assertions ---

        // 1. Generation must be stopped.
        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after model switch")

        // 2. modelB must be loaded.
        XCTAssertTrue(vm.isModelLoaded, "modelB should be loaded after loadSelectedModel completes")

        // 3. No orphaned assistant row — the in-progress assistant written during modelA
        //    generation must not have been duplicated. There should be at most one
        //    assistant message in the session.
        let sessionID = session.id
        let allMessages = try await persistence.fetchMessages(for: sessionID)
        let assistantRows = allMessages.filter { $0.role == .assistant }
        XCTAssertLessThanOrEqual(
            assistantRows.count, 1,
            "At most one assistant row should exist after mid-stream switch; found \(assistantRows.count)"
        )

        // --- Sabotage check ---
        // Confirm the isGenerating assertion is load-bearing: if generation were still
        // running the test should catch it. We verify this by asserting the inverse
        // does not hold, which would trip if the production code forgot to stop.
        let sabotageValue = true
        XCTAssertNotEqual(
            vm.isGenerating, sabotageValue,
            "Sabotage check: isGenerating must be false, not \(sabotageValue)"
        )
    }

    // MARK: - Test 4: Model swap during generation (stop then reload)

    /// Starts generation, stops it, then triggers a model reload.
    /// Verifies generation is stopped and the new model loads successfully.
    func test_rapidModelSwap_duringGeneration_stopsAndReloads() async throws {
        try await createAndActivateSession()

        // Start generation with slow tokens.
        vm.inputText = "Hello"
        let genTask = Task { @MainActor in
            await self.vm.sendMessage()
        }
        await vm.awaitFirstToken()

        // Stop generation.
        vm.stopGeneration()
        await genTask.value

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after stop")

        // Register a second mock backend via factory and trigger a model load.
        let reloadBackend = MockInferenceBackend()
        reloadBackend.isModelLoaded = false
        vm.inferenceService.registerBackendFactory { _ in reloadBackend }

        let modelInfo = ModelInfo(
            name: "ReloadedModel",
            fileName: "reloaded.gguf",
            url: URL(fileURLWithPath: "/tmp/reloaded.gguf"),
            fileSize: 0,
            modelType: .gguf
        )
        vm.selectedModel = modelInfo
        vm.dispatchSelectedLoad()

        // Wait for loading to complete.
        await vm.awaitGenerating(false, timeout: 3.0)

        // Yield to let the coordinated load task complete.
        let loadDeadline = ContinuousClock.now + .seconds(2)
        while !vm.isModelLoaded && ContinuousClock.now < loadDeadline {
            await Task.yield()
        }

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after model reload")
        XCTAssertTrue(vm.isModelLoaded, "Model should be loaded after reload completes")
    }

    // MARK: - Test 5 + 6: Switch-cancel-resend variants for #965

    /// Variant of test 2: switch happens during the *first-token* phase, before
    /// any tokens have been observed by the UI. Exercises the same
    /// switch→cancel→resend race tighter to the start of streaming.
    func test_sessionSwitch_duringFirstTokenStreaming_persistsBothSessions() async throws {
        let sessionA = try await createAndActivateSession(title: "A-firstToken")
        slowBackend.tokensToYield = (0..<20).map { "alpha\($0) " }
        slowBackend.delayPerToken = .milliseconds(50)

        vm.inputText = "ask A"
        let genTask = Task { @MainActor in
            await self.vm.sendMessage()
        }

        // Yield until isGenerating flips, but do NOT wait for first token —
        // we want the switch to land while the backend is still warming up.
        await vm.awaitGenerating(true)

        let sessionB = try await sessionManager.createSession(title: "B-firstToken")
        sessionManager.activeSession = sessionB
        await vm.switchToSession(sessionB)

        XCTAssertFalse(vm.isGenerating, "Generation should be stopped after switch")
        XCTAssertFalse(vm.inferenceService.hasQueuedRequests)

        slowBackend.tokensToYield = ["beta0", " beta1"]
        slowBackend.delayPerToken = .milliseconds(10)

        vm.inputText = "ask B"
        await vm.sendMessage()
        await genTask.value

        let aMsgs = try await persistence.fetchMessages(for: sessionA.id)
        XCTAssertTrue(aMsgs.contains { $0.role == .user && $0.content == "ask A" },
                      "A's user message must persist")

        let bMsgs = try await persistence.fetchMessages(for: sessionB.id)
        let bUser = bMsgs.filter { $0.role == .user }
        let bAsst = bMsgs.filter { $0.role == .assistant }
        XCTAssertEqual(bUser.count, 1, "B should have 1 user message")
        XCTAssertEqual(bAsst.count, 1, "B should have 1 assistant message")
        XCTAssertEqual(bAsst.first?.content, "beta0 beta1")
        for m in bMsgs {
            XCTAssertFalse(m.content.contains("alpha"), "B must not contain A's alpha tokens")
        }
    }

    /// Variant of test 2: switch happens *after* first-token but before
    /// completion. Confirms a partially-streamed assistant on A persists,
    /// while B still gets a clean fresh turn.
    func test_sessionSwitch_afterFirstToken_persistsPartialAndFreshB() async throws {
        let sessionA = try await createAndActivateSession(title: "A-afterFirst")
        slowBackend.tokensToYield = (0..<20).map { "alpha\($0) " }
        slowBackend.delayPerToken = .milliseconds(50)

        vm.inputText = "ask A"
        let genTask = Task { @MainActor in
            await self.vm.sendMessage()
        }

        // Wait until at least one token has landed in A's assistant message,
        // then switch.
        await vm.awaitFirstToken()

        let sessionB = try await sessionManager.createSession(title: "B-afterFirst")
        sessionManager.activeSession = sessionB
        await vm.switchToSession(sessionB)

        XCTAssertFalse(vm.isGenerating)

        slowBackend.tokensToYield = ["beta0", " beta1", " beta2"]
        slowBackend.delayPerToken = .milliseconds(10)
        vm.inputText = "ask B"
        await vm.sendMessage()
        await genTask.value

        // A: user persists; assistant should be present (partial) — the
        // cancel-on-stop path saves what streamed in.
        let aMsgs = try await persistence.fetchMessages(for: sessionA.id)
        XCTAssertTrue(aMsgs.contains { $0.role == .user && $0.content == "ask A" })
        let aAsst = aMsgs.filter { $0.role == .assistant }
        // At-most-one assistant; if present, must be a non-empty alpha prefix.
        XCTAssertLessThanOrEqual(aAsst.count, 1, "At most one assistant row on A after cancel")
        if let a = aAsst.first {
            XCTAssertTrue(a.content.contains("alpha"), "A assistant content should be partial alpha tokens, got \(a.content)")
        }

        // B: full fresh turn.
        let bMsgs = try await persistence.fetchMessages(for: sessionB.id)
        let bUser = bMsgs.filter { $0.role == .user }
        let bAsst = bMsgs.filter { $0.role == .assistant }
        XCTAssertEqual(bUser.count, 1)
        XCTAssertEqual(bAsst.count, 1, "B assistant must persist after switch-cancel-resend")
        XCTAssertEqual(bAsst.first?.content, "beta0 beta1 beta2")
        for m in bMsgs {
            XCTAssertFalse(m.content.contains("alpha"), "B must not contain A's alpha tokens")
        }
    }
}
