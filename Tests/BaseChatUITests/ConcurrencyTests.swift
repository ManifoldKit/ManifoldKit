@preconcurrency import XCTest
import SwiftData
@testable import BaseChatUI
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport

// MARK: - Concurrency Tests

/// Tests for concurrent access patterns in ChatViewModel and SessionManagerViewModel.
///
/// Uses a slow mock backend with configurable per-token delay so that concurrent
/// operations (rapid sends, session switches, regeneration) can interleave and
/// expose race conditions or state corruption.
@MainActor
final class ConcurrencyTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var sessionManager: SessionManagerViewModel!
    private var slowBackend: SlowMockBackend!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        container = try makeInMemoryContainer()
        context = container.mainContext

        slowBackend = SlowMockBackend(tokenCount: 4, delayMilliseconds: 50)

        let service = InferenceService(backend: slowBackend, name: "SlowMock")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
    }

    override func tearDown() async throws {
        vm?.stopGeneration()
        vm?.inferenceService.unloadModel()
        vm = nil
        sessionManager = nil
        slowBackend = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func createAndActivateSession(title: String = "Test Chat") async -> ChatSessionRecord {
        let session = try! await sessionManager.createSession(title: title)
        sessionManager.activeSession = session
        await vm.switchToSession(session)
        return session
    }

    private func fetchMessages(for sessionID: UUID) -> [ChatMessage] {
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchSessions() -> [ChatSession] {
        let descriptor = FetchDescriptor<ChatSession>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Test 1: Rapid Send Messages

    /// Fire-and-forget 5 messages rapidly. Verify no crash, messages are non-empty,
    /// and isGenerating eventually becomes false.
    func test_rapidSendMessages_doesNotCrash() async throws {
        await createAndActivateSession()

        // Fire 5 sends as concurrent tasks without awaiting each one.
        var tasks: [Task<Void, Never>] = []
        for i in 0..<5 {
            vm.inputText = "Rapid message \(i)"
            let task = Task { @MainActor in
                await self.vm.sendMessage()
            }
            tasks.append(task)
        }

        // Wait for all tasks to complete.
        for task in tasks {
            await task.value
        }

        // Verify: no crash (we got here), messages are non-empty, generation finished.
        XCTAssertFalse(vm.messages.isEmpty, "Messages should be non-empty after rapid sends")
        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after all tasks complete")

        // Timestamp ordering: messages must be monotonically non-decreasing.
        let timestamps = vm.messages.map(\.timestamp)
        for i in 1..<timestamps.count {
            XCTAssertLessThanOrEqual(
                timestamps[i - 1], timestamps[i],
                "messages[\(i - 1)].timestamp (\(timestamps[i - 1])) should be <= messages[\(i)].timestamp (\(timestamps[i])); vm.messages are out of chronological order"
            )
        }
    }

    // MARK: - Test 1b: Message Chronological Order

    /// Sends two messages sequentially (each fully awaited before the next) and
    /// verifies that the resulting four messages — user₁, assistant₁, user₂,
    /// assistant₂ — have monotonically non-decreasing timestamps.
    func test_messages_maintainChronologicalOrder() async {
        await createAndActivateSession()

        // Use a fast backend so message timestamps are as tight as possible.
        slowBackend.tokensToYield = ["reply"]
        slowBackend.delayPerToken = .zero

        // Send first message and fully await it.
        vm.inputText = "First message"
        await vm.sendMessage()

        // Send second message and fully await it.
        slowBackend.tokensToYield = ["second reply"]
        vm.inputText = "Second message"
        await vm.sendMessage()

        // Expect 4 messages: user₁, assistant₁, user₂, assistant₂.
        XCTAssertEqual(vm.messages.count, 4,
            "Expected 4 messages (2 user + 2 assistant); got \(vm.messages.count)")

        let msgs = vm.messages
        // Assert roles for clarity.
        XCTAssertEqual(msgs[0].role, .user)
        XCTAssertEqual(msgs[1].role, .assistant)
        XCTAssertEqual(msgs[2].role, .user)
        XCTAssertEqual(msgs[3].role, .assistant)

        // Assert monotonically non-decreasing timestamps.
        XCTAssertLessThanOrEqual(msgs[0].timestamp, msgs[1].timestamp,
            "messages[0].timestamp should be <= messages[1].timestamp")
        XCTAssertLessThanOrEqual(msgs[1].timestamp, msgs[2].timestamp,
            "messages[1].timestamp should be <= messages[2].timestamp")
        XCTAssertLessThanOrEqual(msgs[2].timestamp, msgs[3].timestamp,
            "messages[2].timestamp should be <= messages[3].timestamp")
    }

    // MARK: - Test 2: Send While Generating

    /// Start a slow generation, then attempt to send another message while it is
    /// still generating. sendMessage() does NOT guard against isGenerating, so the
    /// second send should also proceed and produce messages.
    func test_sendWhileGenerating_secondSendProceeds() async throws {
        await createAndActivateSession()

        // 5 tokens is enough to keep the stream in-flight while the second send
        // races — the test asserts concurrency behavior, not token count.
        slowBackend.tokensToYield = (0..<5).map { "tok\($0) " }
        slowBackend.delayPerToken = .milliseconds(50)

        // Start first generation.
        vm.inputText = "First message"
        let firstTask = Task { @MainActor in
            await self.vm.sendMessage()
        }

        // Wait for generation to start.
        await vm.awaitGenerating(true)

        // Send a second message while still generating.
        vm.inputText = "Second message"
        let secondTask = Task { @MainActor in
            await self.vm.sendMessage()
        }

        // Wait for both to complete.
        await firstTask.value
        await secondTask.value

        // sendMessage() does not guard isGenerating, so both messages should have
        // been sent. We should see user messages for both sends.
        let userMessages = vm.messages.filter { $0.role == .user }
        XCTAssertGreaterThanOrEqual(userMessages.count, 2,
            "Both user messages should be present since sendMessage does not guard isGenerating")
        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after all generation completes")
    }

    // MARK: - Test 3: Switch Session During Generation

    /// Start generation on session A with slow tokens. Mid-stream, switch to
    /// session B. Verify session B loads correctly and no messages from session A
    /// leak into session B's view.
    func test_switchSession_duringGeneration_noCorruption() async throws {
        // Set up session A.
        let sessionA = await createAndActivateSession(title: "Session A")
        slowBackend.tokensToYield = (0..<20).map { "alphaToken\($0) " }
        slowBackend.delayPerToken = .milliseconds(50)

        // Pre-populate session B with a known message using a fast backend.
        let sessionB = try! await sessionManager.createSession(title: "Session B")

        // Start generation on session A.
        vm.inputText = "Alpha question"
        let genTask = Task { @MainActor in
            await self.vm.sendMessage()
        }

        // Wait for generation to start streaming.
        await vm.awaitGenerating(true)

        // Switch to session B mid-generation.
        sessionManager.activeSession = sessionB
        await vm.switchToSession(sessionB)

        // Session B should have no messages (it was freshly created).
        XCTAssertTrue(vm.messages.isEmpty,
            "Session B should have no messages")
        XCTAssertEqual(vm.activeSession?.id, sessionB.id,
            "Active session should be session B")

        // Verify no session A messages appear in session B's view.
        let sessionBHasAlpha = vm.messages.contains { $0.content.contains("alpha") }
        XCTAssertFalse(sessionBHasAlpha,
            "No messages from session A should leak into session B's view")

        // Wait for the background generation to finish.
        await genTask.value

        // After generation completes, session B should still be clean.
        // Re-check: the view should still show session B's messages.
        let currentSessionID = vm.activeSession?.id
        XCTAssertEqual(currentSessionID, sessionB.id,
            "Should still be on session B after generation finishes")

        // Session A's messages should be in the database.
        let sessionAMessages = fetchMessages(for: sessionA.id)
        XCTAssertTrue(sessionAMessages.contains { $0.role == .user && $0.content == "Alpha question" },
            "Session A should have the user message persisted")
    }

    // MARK: - Test 4: Multiple Concurrent Session Creation

    /// Create 10 sessions concurrently and verify all are persisted in the database.
    func test_multipleSessionCreation_concurrent_allPersisted() async throws {
        var tasks: [Task<Void, Never>] = []

        for i in 0..<10 {
            let task = Task { @MainActor in
                _ = try! await self.sessionManager.createSession(title: "Concurrent Session \(i)")
            }
            tasks.append(task)
        }

        // Wait for all tasks to complete.
        for task in tasks {
            await task.value
        }

        let allSessions = fetchSessions()
        XCTAssertEqual(allSessions.count, 10,
            "All 10 concurrently created sessions should be persisted in the database")

        // Verify each session has a unique title.
        let titles = Set(allSessions.map(\.title))
        XCTAssertEqual(titles.count, 10, "All sessions should have unique titles")
    }

    // MARK: - Test 5: Regenerate While Generating Is Guarded

    /// Start generation, then call regenerateLastResponse() while still generating.
    /// regenerateLastResponse() guards with `guard !isGenerating else { return }`,
    /// so the regeneration should be silently skipped.
    func test_regenerateWhileGenerating_isGuarded() async throws {
        await createAndActivateSession()

        // 5 tokens is enough to hold the stream open while the regenerate races.
        slowBackend.tokensToYield = (0..<5).map { "tok\($0) " }
        slowBackend.delayPerToken = .milliseconds(50)

        // Send initial message to start generation.
        vm.inputText = "Initial question"
        let genTask = Task { @MainActor in
            await self.vm.sendMessage()
        }

        // Wait for generation to start AND for the first token to be streamed.
        // `awaitGenerating(true)` flips when the VM enters the
        // `waitingForFirstToken` phase, which can fire BEFORE the backend's
        // generate() is actually invoked (the InferenceService queues the
        // request). Waiting for the first token guarantees the backend has been
        // called, so the `generateCallCount` assertion below is meaningful.
        await vm.awaitGenerating(true)
        await vm.awaitFirstToken()

        // Capture state before the regenerate attempt. The backend must have been
        // invoked exactly once for the in-flight initial send. A guarded
        // regenerateLastResponse should NOT trigger a second backend invocation.
        //
        // Asserting on messages.count alone is too weak: even without the guard,
        // regenerateLastResponse removes the trailing empty assistant placeholder
        // and re-appends a fresh one, netting zero change in count. The
        // backend-call counter is the contract that actually catches re-entry.
        XCTAssertEqual(slowBackend.generateCallCount, 1,
            "Backend should have been called exactly once for the initial send")
        let messageCountBefore = vm.messages.count

        // The guard contract: regenerateLastResponse() must short-circuit
        // silently. That means:
        //   1. The backend must not be called a second time.
        //   2. The function must not enter its message-rewrite path
        //      (which surfaces a persistence error when it tries to delete
        //      the still-unpersisted streaming placeholder).
        //
        // Asserting on `messages.count` alone is too weak — even without the
        // guard, the rewrite path tears down and restores the placeholder via
        // its persistence-failure catch, netting zero change in count.

        // Attempt regeneration while generating -- should be silently skipped.
        await vm.regenerateLastResponse()

        // Guard contract: no additional backend invocation, no observable
        // error from a botched message-rewrite, and the message list unchanged.
        XCTAssertEqual(slowBackend.generateCallCount, 1,
            "regenerateLastResponse must not call the backend while isGenerating is true")
        XCTAssertNil(vm.activeError,
            "regenerateLastResponse must not surface an error while generating; an unguarded re-entry leaks a persistence error from attempting to delete the unpersisted streaming placeholder")
        XCTAssertEqual(vm.messages.count, messageCountBefore,
            "regenerateLastResponse should be a no-op while isGenerating is true")

        // Wait for original generation to complete.
        await genTask.value

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after generation completes")

        // Now regeneration should work.
        slowBackend.tokensToYield = ["regenerated"]
        slowBackend.delayPerToken = .zero
        await vm.regenerateLastResponse()

        let lastAssistant = vm.messages.last { $0.role == .assistant }
        XCTAssertEqual(lastAssistant?.content, "regenerated",
            "regenerateLastResponse should work after generation finishes")
        XCTAssertEqual(slowBackend.generateCallCount, 2,
            "Post-completion regenerate should call the backend a second time")
    }
}
