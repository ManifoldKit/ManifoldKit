import Testing
import Foundation
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

/// E2E round-trip: send -> stream -> persist -> reload across session switch.
///
/// Uses a real in-memory SwiftData store with `MockInferenceBackend` so the
/// full ChatViewModel pipeline executes without hardware dependencies.
@Suite("Chat Turn Round-Trip E2E")
@MainActor
struct ChatTurnRoundTripE2ETests {

    private let container: ModelContainer
    private let context: ModelContext
    private let mock: MockInferenceBackend
    private let vm: ChatViewModel
    private let sessionManager: SessionManagerViewModel

    init() throws {
        container = try ModelContainerFactory.makeInMemoryContainer()
        context = container.mainContext

        mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Hello", " from", " mock"]

        let persistence = SwiftDataPersistenceProvider(modelContext: context)
        let service = InferenceService(backend: mock, name: "MockE2E")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: persistence)

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: persistence, autoLoad: false)
    }

    // MARK: - Helpers

    @discardableResult
    private func createAndActivateSession(title: String = "Test Chat") async throws -> ChatSessionRecord {
        let session = try await sessionManager.createSession(title: title)
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

    // MARK: - Tests

    @Test("Single turn: user + assistant messages appear with correct content")
    func singleTurnRoundTrip() async throws {
        let session = try await createAndActivateSession()

        mock.tokensToYield = ["Good", " morning"]
        vm.inputText = "Hello"
        await vm.sendMessage()

        #expect(vm.messages.count == 2)
        #expect(vm.messages[0].role == .user)
        #expect(vm.messages[0].content == "Hello")
        #expect(vm.messages[1].role == .assistant)
        #expect(vm.messages[1].content == "Good morning")

        let dbMessages = fetchMessages(for: session.id)
        #expect(dbMessages.count == 2)
        #expect(dbMessages[0].content == "Hello")
        #expect(dbMessages[1].content == "Good morning")
    }

    @Test("Multi-turn: all 4 messages present and ordered")
    func multiTurnRoundTrip() async throws {
        let session = try await createAndActivateSession()

        mock.tokensToYield = ["Reply", " one"]
        vm.inputText = "First"
        await vm.sendMessage()

        mock.tokensToYield = ["Reply", " two"]
        vm.inputText = "Second"
        await vm.sendMessage()

        #expect(vm.messages.count == 4)
        #expect(vm.messages[0].content == "First")
        #expect(vm.messages[1].content == "Reply one")
        #expect(vm.messages[2].content == "Second")
        #expect(vm.messages[3].content == "Reply two")

        let dbMessages = fetchMessages(for: session.id)
        #expect(dbMessages.count == 4)
        // Verify chronological ordering
        for i in 1..<dbMessages.count {
            #expect(dbMessages[i].timestamp >= dbMessages[i - 1].timestamp)
        }
    }

    @Test("New session starts empty")
    func newSessionIsEmpty() async throws {
        try await createAndActivateSession(title: "Session A")

        mock.tokensToYield = ["Alpha"]
        vm.inputText = "Question"
        await vm.sendMessage()
        #expect(vm.messages.count == 2)

        // Switch to a brand-new session
        try await createAndActivateSession(title: "Session B")

        #expect(vm.messages.isEmpty, "New session should have no messages")
    }

    @Test("Switch back reloads messages from SwiftData")
    func switchBackReloadsMessages() async throws {
        let sessionA = try await createAndActivateSession(title: "Session A")

        mock.tokensToYield = ["Alpha", " reply"]
        vm.inputText = "Alpha question"
        await vm.sendMessage()

        // Switch to session B
        try await createAndActivateSession(title: "Session B")
        #expect(vm.messages.isEmpty)

        // Switch back to session A
        await vm.switchToSession(sessionA)

        #expect(vm.messages.count == 2, "Session A messages should reload")
        #expect(vm.messages[0].content == "Alpha question")
        #expect(vm.messages[1].content == "Alpha reply")
    }

    @Test("Database persistence: direct ModelContext fetch matches")
    func databasePersistenceVerification() async throws {
        let session = try await createAndActivateSession()

        mock.tokensToYield = ["Persisted", " response"]
        vm.inputText = "Persist me"
        await vm.sendMessage()

        mock.tokensToYield = ["Second", " response"]
        vm.inputText = "And me"
        await vm.sendMessage()

        // Fetch directly from the ModelContext, bypassing the view model
        let dbMessages = fetchMessages(for: session.id)
        #expect(dbMessages.count == 4)

        #expect(dbMessages[0].role == .user)
        #expect(dbMessages[0].content == "Persist me")
        #expect(dbMessages[0].sessionID == session.id)

        #expect(dbMessages[1].role == .assistant)
        #expect(dbMessages[1].content == "Persisted response")

        #expect(dbMessages[2].role == .user)
        #expect(dbMessages[2].content == "And me")

        #expect(dbMessages[3].role == .assistant)
        #expect(dbMessages[3].content == "Second response")

        // Every message belongs to the correct session
        for msg in dbMessages {
            #expect(msg.sessionID == session.id)
        }
    }
}
