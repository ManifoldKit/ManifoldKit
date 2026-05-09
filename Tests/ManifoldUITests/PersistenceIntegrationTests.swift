@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

/// Integration tests for ChatViewModel persistence using REAL SwiftData (in-memory).
///
/// Exercises loadMessages, saveMessage, deleteMessage, and multi-session isolation
/// against a real ModelContainer. Only the inference backend is mocked.
@MainActor
final class PersistenceIntegrationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var mock: MockInferenceBackend!

    override func setUp() async throws {
        try await super.setUp()

        container = try makeInMemoryContainer()
        context = container.mainContext

        mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Reply"]

        let service = InferenceService(backend: mock, name: "MockPersistence")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))
    }

    override func tearDown() async throws {
        vm = nil
        mock = nil
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    @discardableResult
    private func createSession(title: String = "Persistence Test") async -> ChatSession {
        let session = ChatSession(title: title)
        context.insert(session)
        try? context.save()
        await vm.switchToSession(session.toRecord())
        return session
    }

    private func fetchMessages(for sessionID: UUID) -> [ChatMessage] {
        let descriptor = FetchDescriptor<ChatMessage>(
            predicate: #Predicate { $0.sessionID == sessionID },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchAllMessages() -> [ChatMessage] {
        let descriptor = FetchDescriptor<ChatMessage>(
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchSessions() -> [ChatSession] {
        let descriptor = FetchDescriptor<ChatSession>()
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - loadMessages with No modelContext

    func test_loadMessages_withNoModelContext_returnsEmpty() async {
        // Create a VM without configuring modelContext.
        let service = InferenceService(backend: mock, name: "NoContext")
        let unconfiguredVM = ChatViewModel(inferenceService: service)
        // Do NOT call configure(persistence:)

        // Create a session and set it directly so loadMessages has a sessionID.
        let session = ChatSession(title: "Test")
        unconfiguredVM.activeSession = session.toRecord()

        await unconfiguredVM.loadMessages()

        XCTAssertTrue(
            unconfiguredVM.messages.isEmpty,
            "loadMessages without modelContext should return empty"
        )
    }

    // MARK: - loadMessages with No activeSession

    func test_loadMessages_withNoActiveSession_clearsMessages() async {
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))

        // Manually add a message to the in-memory messages array.
        let dummyMessage = ChatMessage(role: .user, content: "stale", sessionID: UUID())
        vm.messages = [dummyMessage.toRecord()]
        XCTAssertEqual(vm.messages.count, 1)

        // Ensure no active session.
        vm.activeSession = nil
        await vm.loadMessages()

        XCTAssertTrue(
            vm.messages.isEmpty,
            "loadMessages with no active session should clear messages"
        )
    }

    // MARK: - loadMessages Fetches and Sorts by Timestamp

    func test_loadMessages_fetchesAndSortsByTimestamp() async {
        let session = await createSession()

        // Insert messages with explicit timestamps out of order.
        let msg1 = ChatMessage(role: .user, content: "First", sessionID: session.id)
        let msg2 = ChatMessage(role: .assistant, content: "Second", sessionID: session.id)
        let msg3 = ChatMessage(role: .user, content: "Third", sessionID: session.id)

        // Set timestamps to enforce ordering.
        msg1.timestamp = Date(timeIntervalSince1970: 1000)
        msg2.timestamp = Date(timeIntervalSince1970: 2000)
        msg3.timestamp = Date(timeIntervalSince1970: 3000)

        // Insert in reverse order to test sorting.
        context.insert(msg3)
        context.insert(msg1)
        context.insert(msg2)
        try? context.save()

        await vm.loadMessages()

        XCTAssertEqual(vm.messages.count, 3)
        XCTAssertEqual(vm.messages[0].content, "First", "Messages should be sorted by timestamp ascending")
        XCTAssertEqual(vm.messages[1].content, "Second")
        XCTAssertEqual(vm.messages[2].content, "Third")
    }

    // MARK: - saveMessage Inserts and Can Be Fetched Back

    func test_saveMessage_insertsIntoContextAndFetchesBack() async {
        let session = await createSession()

        let message = ChatMessage(role: .user, content: "Persisted message", sessionID: session.id)
        try! await vm.saveMessage(message.toRecord())

        let fetched = fetchMessages(for: session.id)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].content, "Persisted message")
        XCTAssertEqual(fetched[0].role, .user)
        XCTAssertEqual(fetched[0].sessionID, session.id)
    }

    func test_saveMessage_multipleMessages_allPersisted() async {
        let session = await createSession()

        let msg1 = ChatMessage(role: .user, content: "User msg", sessionID: session.id)
        let msg2 = ChatMessage(role: .assistant, content: "Assistant msg", sessionID: session.id)
        try! await vm.saveMessage(msg1.toRecord())
        try! await vm.saveMessage(msg2.toRecord())

        let fetched = fetchMessages(for: session.id)
        XCTAssertEqual(fetched.count, 2)
    }

    // MARK: - deleteMessage Removes from Context

    func test_deleteMessage_removesFromContext() async {
        let session = await createSession()

        let message = ChatMessage(role: .user, content: "To be deleted", sessionID: session.id)
        try! await vm.saveMessage(message.toRecord())
        XCTAssertEqual(fetchMessages(for: session.id).count, 1)

        try! await vm.deleteMessage(message.toRecord())
        XCTAssertEqual(
            fetchMessages(for: session.id).count, 0,
            "Message should be removed from the database after deletion"
        )
    }

    func test_deleteMessage_onlyRemovesTargetMessage() async {
        let session = await createSession()

        let msg1 = ChatMessage(role: .user, content: "Keep this", sessionID: session.id)
        let msg2 = ChatMessage(role: .assistant, content: "Delete this", sessionID: session.id)
        try! await vm.saveMessage(msg1.toRecord())
        try! await vm.saveMessage(msg2.toRecord())
        XCTAssertEqual(fetchMessages(for: session.id).count, 2)

        try! await vm.deleteMessage(msg2.toRecord())

        let remaining = fetchMessages(for: session.id)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].content, "Keep this")
    }

    // MARK: - Multi-Session Isolation

    func test_multiSessionIsolation_messagesDoNotBleed() async {
        // Session A
        let sessionA = await createSession(title: "Session A")
        mock.tokensToYield = ["Alpha", " reply"]
        vm.inputText = "Alpha question"
        await vm.sendMessage()

        let sessionAMessages = fetchMessages(for: sessionA.id)
        XCTAssertEqual(sessionAMessages.count, 2)

        // Session B
        let sessionB = await createSession(title: "Session B")
        mock.tokensToYield = ["Beta", " reply"]
        vm.inputText = "Beta question"
        await vm.sendMessage()

        let sessionBMessages = fetchMessages(for: sessionB.id)
        XCTAssertEqual(sessionBMessages.count, 2)

        // Verify isolation: session A messages should not include session B content.
        let sessionAContent = fetchMessages(for: sessionA.id).map(\.content)
        XCTAssertTrue(sessionAContent.contains("Alpha question"))
        XCTAssertFalse(sessionAContent.contains("Beta question"), "Session B messages should not appear in session A")

        let sessionBContent = fetchMessages(for: sessionB.id).map(\.content)
        XCTAssertTrue(sessionBContent.contains("Beta question"))
        XCTAssertFalse(sessionBContent.contains("Alpha question"), "Session A messages should not appear in session B")
    }

    func test_multiSessionIsolation_switchingReloadsCorrectMessages() async {
        let sessionA = await createSession(title: "Session A")
        mock.tokensToYield = ["A", " response"]
        vm.inputText = "Question for A"
        await vm.sendMessage()
        XCTAssertEqual(vm.messages.count, 2)

        let sessionB = await createSession(title: "Session B")
        mock.tokensToYield = ["B", " response"]
        vm.inputText = "Question for B"
        await vm.sendMessage()
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[0].content, "Question for B")

        // Switch back to A.
        await vm.switchToSession(sessionA.toRecord())
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[0].content, "Question for A", "Switching should reload session A messages")

        // Switch to B.
        await vm.switchToSession(sessionB.toRecord())
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertEqual(vm.messages[0].content, "Question for B", "Switching should reload session B messages")
    }

    // MARK: - Cascade: Deleting a Session Handles Its Messages

    func test_deleteSession_removesAssociatedMessages() async throws {
        let session = await createSession(title: "Doomed Session")
        mock.tokensToYield = ["Doomed", " reply"]
        vm.inputText = "Message in doomed session"
        await vm.sendMessage()
        vm.inputText = "Another message"
        await vm.sendMessage()

        let sessionID = session.id
        XCTAssertEqual(fetchMessages(for: sessionID).count, 4)

        // Use SessionManagerViewModel to delete the session (it handles cascade).
        let sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: SwiftDataPersistenceProvider(modelContext: context), autoLoad: false)
        try await sessionManager.deleteSession(session.toRecord())

        XCTAssertEqual(
            fetchMessages(for: sessionID).count, 0,
            "Deleting a session should remove all its messages"
        )
        XCTAssertFalse(
            fetchSessions().contains(where: { $0.id == sessionID }),
            "Session itself should be deleted"
        )
    }

    func test_deleteSession_doesNotAffectOtherSessions() async throws {
        // Create session A with messages.
        let sessionA = await createSession(title: "Survivor")
        mock.tokensToYield = ["Survivor", " reply"]
        vm.inputText = "Survivor question"
        await vm.sendMessage()

        // Create session B with messages.
        let sessionB = await createSession(title: "Victim")
        mock.tokensToYield = ["Victim", " reply"]
        vm.inputText = "Victim question"
        await vm.sendMessage()

        XCTAssertEqual(fetchMessages(for: sessionA.id).count, 2)
        XCTAssertEqual(fetchMessages(for: sessionB.id).count, 2)

        // Delete session B.
        let sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: SwiftDataPersistenceProvider(modelContext: context), autoLoad: false)
        try await sessionManager.deleteSession(sessionB.toRecord())

        // Session A should be unaffected.
        XCTAssertEqual(
            fetchMessages(for: sessionA.id).count, 2,
            "Deleting session B should not affect session A's messages"
        )
        XCTAssertEqual(
            fetchMessages(for: sessionB.id).count, 0,
            "Session B's messages should be deleted"
        )
    }

    // MARK: - Typed Record Field Round-Trips

    func test_sessionRecord_promptTemplate_roundTrips() async throws {
        let persistence = SwiftDataPersistenceProvider(modelContext: context)
        var record = ChatSessionRecord(title: "Template Test")
        record.promptTemplate = .llama3
        try await persistence.insertSession(record)

        let fetched = try await persistence.fetchSessions().first { $0.id == record.id }
        XCTAssertEqual(fetched?.promptTemplate, .llama3)
    }

    func test_sessionRecord_pinnedMessageIDs_roundTrips() async throws {
        let persistence = SwiftDataPersistenceProvider(modelContext: context)
        let pinA = UUID()
        let pinB = UUID()
        var record = ChatSessionRecord(title: "Pin Test")
        record.pinnedMessageIDs = [pinA, pinB]
        try await persistence.insertSession(record)

        let fetched = try await persistence.fetchSessions().first { $0.id == record.id }
        XCTAssertEqual(fetched?.pinnedMessageIDs, [pinA, pinB])
    }

    func test_sessionRecord_defaults_roundTrip() async throws {
        let persistence = SwiftDataPersistenceProvider(modelContext: context)
        let record = ChatSessionRecord(title: "Defaults Test")
        try await persistence.insertSession(record)

        let fetched = try await persistence.fetchSessions().first { $0.id == record.id }
        XCTAssertNil(fetched?.promptTemplate)
        XCTAssertEqual(fetched?.pinnedMessageIDs, [])
    }
}
