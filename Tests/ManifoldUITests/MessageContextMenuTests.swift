@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport
import ManifoldPersistenceTestSupport

/// Tests for the per-message context menu introduced in #1011.
///
/// Verifies the wire-up of the context menu's default actions against the
/// underlying ``ConversationRuntime`` — `deleteMessage`, `branch(from:)`,
/// `regenerateLastResponse`, and the `onSessionBranched` callback.
@MainActor
final class MessageContextMenuTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var mock: MockInferenceBackend!
    private var sessionManager: SessionManagerViewModel!

    override func setUp() async throws {
        try await super.setUp()

        container = try makeInMemoryContainer()
        context = container.mainContext

        mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Hello", " world"]

        let service = InferenceService(backend: mock, name: "MockMenu")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(
            persistence: SwiftDataPersistenceProvider(modelContext: context),
            autoLoad: false
        )
    }

    override func tearDown() async throws {
        vm = nil
        sessionManager = nil
        mock = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func createAndActivateSession(title: String = "Menu Test") async throws -> ManifoldInference.ChatSession {
        let session = try await sessionManager.createSession(title: title)
        sessionManager.activeSession = session
        await vm.switchToSession(session)
        return session
    }

    private func fetchMessages(for sessionID: UUID) -> [ManifoldSchemaV9.ChatMessage] {
        let descriptor = FetchDescriptor<ManifoldSchemaV9.ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchSessions() -> [PersistedChatSession] {
        let descriptor = FetchDescriptor<PersistedChatSession>()
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - deleteMessage

    func test_deleteMessage_removesFromInMemoryTranscript() async throws {
        try await createAndActivateSession()
        mock.tokensToYield = ["Reply"]
        vm.inputText = "First"
        await vm.sendMessage()
        XCTAssertEqual(vm.messages.count, 2)

        let assistant = vm.messages[1]
        await vm.deleteMessage(id: assistant.id)

        XCTAssertEqual(vm.messages.count, 1, "Assistant message should be removed from transcript")
        XCTAssertEqual(vm.messages.first?.role, .user, "User message should remain")
    }

    func test_deleteMessage_persistsRemoval() async throws {
        let session = try await createAndActivateSession()
        mock.tokensToYield = ["Reply"]
        vm.inputText = "Persisted"
        await vm.sendMessage()
        XCTAssertEqual(fetchMessages(for: session.id).count, 2)

        let assistantID = vm.messages[1].id
        await vm.deleteMessage(id: assistantID)

        let remaining = fetchMessages(for: session.id)
        XCTAssertEqual(remaining.count, 1, "Persisted assistant record should be deleted")
        XCTAssertFalse(remaining.contains(where: { $0.id == assistantID }))
    }

    func test_deleteMessage_unknownID_isNoOp() async throws {
        try await createAndActivateSession()
        mock.tokensToYield = ["Reply"]
        vm.inputText = "Question"
        await vm.sendMessage()
        let beforeCount = vm.messages.count

        await vm.deleteMessage(id: UUID())

        XCTAssertEqual(vm.messages.count, beforeCount, "Unknown ID should not mutate the transcript")
    }

    func test_deleteMessage_alsoUnpins() async throws {
        try await createAndActivateSession()
        mock.tokensToYield = ["Reply"]
        vm.inputText = "Pin me"
        await vm.sendMessage()
        let userID = vm.messages[0].id

        await vm.pinMessage(id: userID)
        XCTAssertTrue(vm.isMessagePinned(id: userID))

        await vm.deleteMessage(id: userID)

        XCTAssertFalse(vm.pinnedMessageIDs.contains(userID),
                       "Deleted message must drop from pinned set so the pin badge does not linger")
    }

    // MARK: - branch(from:)

    func test_branch_createsNewSessionWithCopiedMessages() async throws {
        let source = try await createAndActivateSession(title: "Source")
        mock.tokensToYield = ["Reply"]
        vm.inputText = "Original"
        await vm.sendMessage()
        XCTAssertEqual(vm.messages.count, 2)

        let branchPoint = vm.messages[1].id  // assistant reply
        let beforeSessionCount = fetchSessions().count

        await vm.branch(from: branchPoint)
        // Drain the runtime event so the .sessionBranched callback (and any
        // host-installed observer) lands before we read state.
        await Task.yield()
        await Task.yield()

        let sessions = fetchSessions()
        XCTAssertEqual(sessions.count, beforeSessionCount + 1,
                       "branch should produce exactly one new session")

        let newSession = sessions.first(where: { $0.id != source.id })
        XCTAssertNotNil(newSession, "New session should exist alongside the source")
        let newID = try XCTUnwrap(newSession?.id)
        XCTAssertEqual(fetchMessages(for: newID).count, 2,
                       "Both source messages should be copied to the new session")
    }

    func test_branch_firesOnSessionBranchedCallback() async throws {
        try await createAndActivateSession()
        mock.tokensToYield = ["Reply"]
        vm.inputText = "Source question"
        await vm.sendMessage()

        let captured = NewSessionIDBox()
        vm.onSessionBranched = { id in
            await captured.set(id)
        }

        let branchPoint = vm.messages[0].id
        await vm.branch(from: branchPoint)

        // Spin until the runtime emits .sessionBranched (typically 1–2 yields).
        for _ in 0..<10 {
            if await captured.get() != nil { break }
            await Task.yield()
        }

        let observed = await captured.get()
        XCTAssertNotNil(observed, "onSessionBranched should fire with the new session ID")
    }

    func test_branch_withoutActiveSession_isNoOp() async {
        // No session activated.
        let beforeCount = fetchSessions().count

        await vm.branch(from: UUID())

        XCTAssertEqual(fetchSessions().count, beforeCount,
                       "branch with no active session must not create a session")
    }

    // MARK: - regenerate wire-up (sanity)

    func test_regenerate_replacesAssistantMessage() async throws {
        try await createAndActivateSession()
        mock.tokensToYield = ["First"]
        vm.inputText = "Hello"
        await vm.sendMessage()
        let firstAssistantID = vm.messages[1].id
        XCTAssertEqual(vm.messages[1].content, "First")

        mock.tokensToYield = ["Second"]
        await vm.regenerateLastResponse()

        XCTAssertEqual(vm.messages.count, 2,
                       "Regenerate should replace, not append, the assistant message")
        XCTAssertNotEqual(vm.messages[1].id, firstAssistantID,
                          "Regenerated response should have a fresh ID")
        XCTAssertEqual(vm.messages[1].content, "Second")
    }
}

/// Actor box used to capture the new-session ID emitted by
/// `onSessionBranched` from the long-lived runtime drain task. The callback
/// is `@MainActor`, but the test reads via `Task.yield()` interleaving so we
/// shield the storage with an actor to satisfy strict-concurrency checks.
private actor NewSessionIDBox {
    private var value: UUID?
    func set(_ newValue: UUID) { value = newValue }
    func get() -> UUID? { value }
}
