@preconcurrency import XCTest
import SwiftData
@testable import BaseChatUI
@testable import BaseChatCore
@testable import BaseChatInference
import BaseChatTestSupport

// MARK: - Session Queue Isolation Tests

/// Tests that session switching correctly isolates the generation queue:
/// discards stale requests, cancels active generation, and blocks
/// regeneration while the queue is active.
@MainActor
final class SessionQueueIsolationTests: XCTestCase {

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
    private func createAndActivateSession(title: String = "Test Chat") async throws -> ChatSessionRecord {
        let session = try await sessionManager.createSession(title: title)
        sessionManager.activeSession = session
        await vm.switchToSession(session)
        return session
    }

    // MARK: - Tests

    /// Switching sessions discards queued requests belonging to the old session.
    func test_switchSession_discardsQueuedRequestsForOldSession() async throws {
        let sessionA = try await createAndActivateSession(title: "Session A")

        // Enqueue a request scoped to session A.
        let (_, stream) = try vm.inferenceService.enqueue(
            messages: [("user", "hello")],
            sessionID: sessionA.id
        )

        // Create session B and switch to it.
        let sessionB = try await sessionManager.createSession(title: "Session B")
        sessionManager.activeSession = sessionB
        await vm.switchToSession(sessionB)

        // Session A's stream should terminate with an error because
        // discardRequests(notMatching:) cancelled it.
        var gotError = false
        do {
            for try await _ in stream.events {}
        } catch {
            gotError = true
        }
        XCTAssertTrue(gotError, "Stream for old session should terminate with an error after session switch")
    }

    /// Active generation is cancelled when switching sessions.
    func test_switchSession_activeGeneration_cancelledOnSwitch() async throws {
        try await createAndActivateSession(title: "Session A")

        // Start generation on session A.
        vm.inputText = "question for A"
        let genTask = Task { @MainActor in
            await self.vm.sendMessage()
        }
        await vm.awaitFirstToken()
        XCTAssertTrue(vm.isGenerating, "Should be generating before switch")

        // Switch to session B — should stop generation.
        let sessionB = try await sessionManager.createSession(title: "Session B")
        sessionManager.activeSession = sessionB
        await vm.switchToSession(sessionB)

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after session switch")

        await genTask.value
    }

    /// stopGeneration drains the entire queue (active + queued).
    func test_stopGeneration_drainsEntireQueue() async throws {
        try await createAndActivateSession(title: "Test")

        // Start generation to make isGenerating true.
        vm.inputText = "first"
        let genTask = Task { @MainActor in
            await self.vm.sendMessage()
        }
        await vm.awaitGenerating(true)

        // Enqueue additional requests directly on the service.
        let (_, stream2) = try vm.inferenceService.enqueue(
            messages: [("user", "second")]
        )
        let (_, stream3) = try vm.inferenceService.enqueue(
            messages: [("user", "third")]
        )

        XCTAssertTrue(vm.inferenceService.hasQueuedRequests, "Should have queued requests")

        // Stop everything.
        vm.stopGeneration()
        await genTask.value

        XCTAssertFalse(vm.isGenerating, "isGenerating should be false after stopGeneration")
        XCTAssertFalse(vm.inferenceService.hasQueuedRequests, "Queue should be empty after stopGeneration")

        // Both extra streams should have terminated.
        var stream2Terminated = false
        do {
            for try await _ in stream2.events {}
        } catch {
            stream2Terminated = true
        }
        XCTAssertTrue(stream2Terminated, "Second queued stream should have been cancelled")

        var stream3Terminated = false
        do {
            for try await _ in stream3.events {}
        } catch {
            stream3Terminated = true
        }
        XCTAssertTrue(stream3Terminated, "Third queued stream should have been cancelled")
    }

    /// regenerateLastResponse is a no-op while generation is active (queue busy).
    func test_regenerateWhileQueued_isBlocked() async throws {
        try await createAndActivateSession(title: "Test")

        // Send a message and let it complete to have an assistant message to regenerate.
        slowBackend.tokensToYield = ["first", " reply"]
        slowBackend.delayPerToken = .milliseconds(10)
        vm.inputText = "hello"
        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 2, "Should have user + assistant")

        // Now start a second generation (slow) so isGenerating is true.
        slowBackend.tokensToYield = (0..<20).map { "t\($0) " }
        slowBackend.delayPerToken = .milliseconds(50)
        vm.inputText = "another question"
        let genTask = Task { @MainActor in
            await self.vm.sendMessage()
        }
        await vm.awaitGenerating(true)

        let messageCountBefore = vm.messages.count

        // Attempt regeneration while generating — should be blocked by guard.
        await vm.regenerateLastResponse()

        XCTAssertEqual(vm.messages.count, messageCountBefore,
            "regenerateLastResponse should be a no-op while isGenerating is true")

        vm.stopGeneration()
        await genTask.value
    }
}
