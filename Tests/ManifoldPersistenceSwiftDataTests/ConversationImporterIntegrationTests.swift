import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldRuntime
import ManifoldTestSupport

/// Integration tests for ``ConversationImporter`` against the real SwiftData
/// adapter on an in-memory container.
///
/// Per CLAUDE.md, the persistence layer is never mocked. Every assertion here
/// verifies that written data can be read back through the store, not just
/// that the right methods were called.
///
/// **Idempotency behaviour:** The SwiftData in-memory container does not
/// enforce UUID uniqueness at the model level — inserting a session with the
/// same UUID twice creates two rows rather than throwing. Callers that need
/// idempotent import must fetch-and-skip themselves before calling
/// ``ConversationImporter/importConversation(_:)``. See
/// ``test_idempotency_duplicateImportBehaviourDocumented`` for the explicit
/// coverage of this contract.
@MainActor
final class ConversationImporterIntegrationTests: XCTestCase {

    private var stack: InMemoryPersistenceHarness.Stack!
    private var importer: ConversationImporter!

    override func setUp() async throws {
        try await super.setUp()
        stack = try InMemoryPersistenceHarness.make()
        importer = ConversationImporter(
            sessionStore: stack.provider,
            messageStore: stack.provider
        )
    }

    override func tearDown() async throws {
        importer = nil
        stack = nil
        try await super.tearDown()
    }

    private var provider: SwiftDataPersistenceProvider { stack.provider }

    // MARK: - Helpers

    private func makeImportedConversation(
        sessionID: UUID = UUID(),
        title: String = "Imported",
        messageCount: Int = 3
    ) -> ImportedConversation {
        let session = ManifoldInference.ChatSession(
            id: sessionID,
            title: title,
            createdAt: Date(timeIntervalSinceReferenceDate: 0),
            updatedAt: Date(timeIntervalSinceReferenceDate: 0)
        )
        let messages = (0..<messageCount).map { i in
            ManifoldInference.ChatMessage(
                role: i.isMultiple(of: 2) ? .user : .assistant,
                content: "message \(i)",
                timestamp: Date(timeIntervalSinceReferenceDate: TimeInterval(i)),
                sessionID: sessionID
            )
        }
        return ImportedConversation(session: session, messages: messages)
    }

    // MARK: - Basic import

    func test_importConversation_returnedIDMatchesSession() async throws {
        let conversation = makeImportedConversation()
        let returnedID = try await importer.importConversation(conversation)

        XCTAssertEqual(returnedID, conversation.session.id,
                       "importConversation must return the session's own UUID")
    }

    func test_importConversation_sessionAppearsInStore() async throws {
        let conversation = makeImportedConversation(title: "My Imported Chat")
        try await importer.importConversation(conversation)

        let sessions = try await provider.fetchSessions()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, conversation.session.id,
                       "Imported session must be fetchable by its original ID")
        XCTAssertEqual(sessions[0].title, "My Imported Chat",
                       "Session title must survive the import write")
    }

    func test_importConversation_messagesAppearsInStore() async throws {
        let conversation = makeImportedConversation(messageCount: 5)
        try await importer.importConversation(conversation)

        let messages = try await provider.fetchMessages(for: conversation.session.id)
        XCTAssertEqual(messages.count, 5,
                       "All 5 messages must be fetchable after import")
    }

    func test_importConversation_messageContentPreserved() async throws {
        let conversation = makeImportedConversation(messageCount: 3)
        try await importer.importConversation(conversation)

        let messages = try await provider.fetchMessages(for: conversation.session.id)
        let importedContents = conversation.messages.map(\.content).sorted()
        let storedContents = messages.map(\.content).sorted()

        XCTAssertEqual(storedContents, importedContents,
                       "Every imported message's content must survive the write and read-back")
    }

    func test_importConversation_messageRolesPreserved() async throws {
        let conversation = makeImportedConversation(messageCount: 4)
        try await importer.importConversation(conversation)

        let messages = try await provider.fetchMessages(for: conversation.session.id)
        // Messages come back sorted by timestamp; the makeImportedConversation
        // helper uses offset timestamps so the order is deterministic.
        for (i, msg) in messages.enumerated() {
            let expected = i.isMultiple(of: 2) ? MessageRole.user : .assistant
            XCTAssertEqual(msg.role, expected,
                           "Role of message at index \(i) must survive the import")
        }
    }

    func test_importConversation_zeroMessages_onlySessionWritten() async throws {
        let session = ManifoldInference.ChatSession(id: UUID(), title: "Empty Chat")
        let conversation = ImportedConversation(session: session, messages: [])

        try await importer.importConversation(conversation)

        let sessions = try await provider.fetchSessions()
        XCTAssertEqual(sessions.count, 1, "Session must be written even when there are no messages")

        let messages = try await provider.fetchMessages(for: session.id)
        XCTAssertEqual(messages.count, 0)
    }

    // MARK: - UUID preservation (idempotency prerequisite)

    func test_importConversation_preservesSessionUUID() async throws {
        let knownID = UUID()
        let conversation = makeImportedConversation(sessionID: knownID)
        try await importer.importConversation(conversation)

        let sessions = try await provider.fetchSessions()
        XCTAssertEqual(sessions.first?.id, knownID,
                       "Imported session must retain the UUID from the import payload")
    }

    func test_importConversation_preservesMessageUUIDs() async throws {
        let sessionID = UUID()
        let knownMsgID = UUID()
        let msg = ManifoldInference.ChatMessage(
            id: knownMsgID,
            role: .user,
            content: "known id message",
            timestamp: Date(timeIntervalSinceReferenceDate: 0),
            sessionID: sessionID
        )
        let session = ManifoldInference.ChatSession(id: sessionID, title: "UUID Test")
        let conversation = ImportedConversation(session: session, messages: [msg])

        try await importer.importConversation(conversation)

        let messages = try await provider.fetchMessages(for: sessionID)
        XCTAssertEqual(messages.first?.id, knownMsgID,
                       "Imported message must retain the UUID from the import payload")
    }

    // MARK: - Idempotency (duplicate-import behaviour)

    func test_idempotency_duplicateImportBehaviourDocumented() async throws {
        // The SwiftData in-memory store does NOT enforce UUID uniqueness —
        // a second insert with the same UUID succeeds rather than throwing.
        // This means importing the same conversation twice creates two session
        // rows with identical IDs. Callers that need idempotent import must
        // fetch first and skip the import if the session already exists.
        //
        // This test documents the actual behaviour so it is clearly understood
        // and not accidentally "fixed" in a way that breaks callers who already
        // rely on it.
        let conversation = makeImportedConversation()

        try await importer.importConversation(conversation)
        // Second import does NOT throw — it inserts a duplicate.
        try await importer.importConversation(conversation)

        let sessions = try await provider.fetchSessions()
        // Both rows land in the store because SwiftData's in-memory container
        // does not deduplicate on @Model primary-key fields.
        XCTAssertEqual(sessions.count, 2,
                       "SwiftData in-memory store does not deduplicate on UUID — callers own idempotency")
    }

    // MARK: - Multiple independent imports

    func test_multipleImports_distinctSessions() async throws {
        // Importing two different conversations must produce two independent
        // sessions with their correct message sets.
        let conv1 = makeImportedConversation(title: "First", messageCount: 2)
        let conv2 = makeImportedConversation(title: "Second", messageCount: 4)

        try await importer.importConversation(conv1)
        try await importer.importConversation(conv2)

        let sessions = try await provider.fetchSessions()
        XCTAssertEqual(sessions.count, 2)

        let msgs1 = try await provider.fetchMessages(for: conv1.session.id)
        let msgs2 = try await provider.fetchMessages(for: conv2.session.id)
        XCTAssertEqual(msgs1.count, 2, "First session must have exactly 2 messages")
        XCTAssertEqual(msgs2.count, 4, "Second session must have exactly 4 messages")
    }
}
