@preconcurrency import XCTest
import SwiftData
@testable import ManifoldUI
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport

/// Integration tests for the edit-user-message feature (`ChatViewModel.editMessage`).
///
/// Verifies that editing a user message:
/// 1. Updates the content in memory
/// 2. Persists the change to SwiftData
/// 3. Does not create duplicate messages
/// 4. Preserves the original message ID (no phantom inserts)
/// 5. Removes subsequent messages and regenerates the assistant response
@MainActor
final class EditUserMessageIntegrationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var vm: ChatViewModel!
    private var sessionManager: SessionManagerViewModel!
    private var mock: MockInferenceBackend!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        container = try makeInMemoryContainer()
        context = container.mainContext

        mock = MockInferenceBackend()
        mock.isModelLoaded = true
        mock.tokensToYield = ["Hello", " world"]

        let service = InferenceService(backend: mock, name: "MockEdit")
        vm = ChatViewModel(inferenceService: service)
        vm.configure(persistence: SwiftDataPersistenceProvider(modelContext: context))

        sessionManager = SessionManagerViewModel()
        sessionManager.configure(persistence: SwiftDataPersistenceProvider(modelContext: context), autoLoad: false)
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
    private func createAndActivateSession(title: String = "Test Chat") async -> ManifoldInference.ChatSession {
        let session = try! await sessionManager.createSession(title: title)
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

    /// Fetches ALL ManifoldSchemaV9.ChatMessage records across all sessions.
    private func fetchAllMessages() -> [ManifoldSchemaV9.ChatMessage] {
        let descriptor = FetchDescriptor<ManifoldSchemaV9.ChatMessage>(
            sortBy: [SortDescriptor(\.timestamp)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    // MARK: - Edit Updates Content In Memory

    func test_editMessage_updatesContentInMemory() async {
        await createAndActivateSession()

        mock.tokensToYield = ["Original", " reply"]
        vm.inputText = "Original question"
        await vm.sendMessage()

        XCTAssertEqual(vm.messages[0].content, "Original question")

        mock.tokensToYield = ["New", " reply"]
        await vm.editMessage(vm.messages[0].id, newContent: "Edited question")

        XCTAssertEqual(vm.messages[0].content, "Edited question",
                       "In-memory user message content should be updated")
        XCTAssertEqual(vm.messages[0].role, .user,
                       "Role should remain .user after edit")
        XCTAssertEqual(vm.messages.count, 2,
                       "Should have exactly 2 messages after edit (user + regenerated assistant)")
        XCTAssertEqual(vm.messages[1].content, "New reply",
                       "Assistant response should be regenerated with new tokens")
    }

    // MARK: - Edit Persists To SwiftData

    func test_editMessage_persistsChangesToDatabase() async {
        let session = await createAndActivateSession()

        mock.tokensToYield = ["Original", " reply"]
        vm.inputText = "Before edit"
        await vm.sendMessage()

        mock.tokensToYield = ["After", " edit", " reply"]
        let userMessageID = vm.messages[0].id
        await vm.editMessage(userMessageID, newContent: "After edit")

        let dbMessages = fetchMessages(for: session.id)
        XCTAssertEqual(dbMessages.first(where: { $0.role == .user })?.content, "After edit",
                       "Edited content should be persisted to SwiftData")
        XCTAssertEqual(dbMessages.first(where: { $0.role == .assistant })?.content, "After edit reply",
                       "Regenerated assistant response should be persisted to SwiftData")
    }

    // MARK: - Edit Does Not Create Duplicate Messages

    func test_editMessage_doesNotCreateDuplicateMessages() async {
        let session = await createAndActivateSession()

        mock.tokensToYield = ["Reply", " one"]
        vm.inputText = "Question"
        await vm.sendMessage()

        let messageCountBefore = fetchMessages(for: session.id).count
        XCTAssertEqual(messageCountBefore, 2, "Should start with 2 messages (user + assistant)")

        mock.tokensToYield = ["Reply", " two"]
        await vm.editMessage(vm.messages[0].id, newContent: "Edited question")

        // After edit: still exactly 2 messages (edited user + regenerated assistant)
        let dbMessages = fetchMessages(for: session.id)
        XCTAssertEqual(dbMessages.count, 2,
                       "Edit should not create duplicate messages; expected 2, got \(dbMessages.count)")

        // Also verify no orphan messages leaked into other sessions
        let allMessages = fetchAllMessages()
        XCTAssertEqual(allMessages.count, 2,
                       "No orphan messages should exist outside the session")
    }

    // MARK: - Edit Preserves Original Message ID

    func test_editMessage_preservesOriginalUserMessageID() async {
        await createAndActivateSession()

        mock.tokensToYield = ["Reply"]
        vm.inputText = "Original"
        await vm.sendMessage()

        let originalID = vm.messages[0].id

        mock.tokensToYield = ["New", " reply"]
        await vm.editMessage(originalID, newContent: "Edited")

        XCTAssertEqual(vm.messages[0].id, originalID,
                       "User message ID should be preserved after edit -- no replacement should occur")
    }

    // MARK: - Edit Removes Subsequent Messages And Regenerates

    func test_editMessage_removesSubsequentMessagesAndRegenerates() async {
        let session = await createAndActivateSession()

        // Build a 3-turn conversation (6 messages)
        mock.tokensToYield = ["Reply", " 1"]
        vm.inputText = "Question 1"
        await vm.sendMessage()

        mock.tokensToYield = ["Reply", " 2"]
        vm.inputText = "Question 2"
        await vm.sendMessage()

        mock.tokensToYield = ["Reply", " 3"]
        vm.inputText = "Question 3"
        await vm.sendMessage()

        XCTAssertEqual(vm.messages.count, 6)

        // Edit the first user message -- everything after it should be removed and regenerated
        mock.tokensToYield = ["Regenerated"]
        await vm.editMessage(vm.messages[0].id, newContent: "Edited Q1")

        // Should have 2 messages: edited user + regenerated assistant
        XCTAssertEqual(vm.messages.count, 2,
                       "Editing first message should remove all subsequent messages")
        XCTAssertEqual(vm.messages[0].content, "Edited Q1")
        XCTAssertEqual(vm.messages[0].role, .user)
        XCTAssertEqual(vm.messages[1].content, "Regenerated")
        XCTAssertEqual(vm.messages[1].role, .assistant)

        // Database should match
        let dbMessages = fetchMessages(for: session.id)
        XCTAssertEqual(dbMessages.count, 2,
                       "Database should only have 2 messages after editing first message")
    }

    // MARK: - Edit With Same Content Is Idempotent

    func test_editMessage_withSameContent_doesNotCorruptState() async {
        let session = await createAndActivateSession()

        mock.tokensToYield = ["Reply"]
        vm.inputText = "Question"
        await vm.sendMessage()

        let messageCountBefore = fetchMessages(for: session.id).count

        // Edit with the same content -- should still work without corruption
        mock.tokensToYield = ["Regenerated", " reply"]
        await vm.editMessage(vm.messages[0].id, newContent: "Question")

        let dbMessages = fetchMessages(for: session.id)
        XCTAssertEqual(dbMessages.count, messageCountBefore,
                       "Editing with same content should not create extra messages")
        XCTAssertEqual(dbMessages[0].content, "Question")
        XCTAssertEqual(dbMessages[1].content, "Regenerated reply",
                       "Assistant response should be regenerated even when user content is unchanged")
    }

    // MARK: - Edit Nonexistent Message Is No-Op

    func test_editMessage_withInvalidID_isNoOp() async {
        let session = await createAndActivateSession()

        mock.tokensToYield = ["Reply"]
        vm.inputText = "Question"
        await vm.sendMessage()

        let messagesBefore = vm.messages
        let dbCountBefore = fetchMessages(for: session.id).count

        await vm.editMessage(UUID(), newContent: "Ghost edit")

        XCTAssertEqual(vm.messages, messagesBefore,
                       "Editing a nonexistent message should not change state")
        XCTAssertEqual(fetchMessages(for: session.id).count, dbCountBefore,
                       "Database should be unchanged after editing nonexistent message")
    }
}
