import XCTest
import SwiftData
@testable import BaseChatPersistenceSwiftData
import BaseChatInference
import BaseChatTestSupport

/// Integration tests for ``SwiftDataPersistenceProvider`` against a fresh
/// in-memory SwiftData stack per test. Covers CRUD, ordering, pagination,
/// cascade scope, and the malformed-CSV footgun on `pinnedMessageIDsRaw`.
///
/// Classified integration (not unit) per CLAUDE.md: the suite drives a real
/// SwiftData `ModelContainer`. See TESTING.md §Classification audit.
@MainActor
final class SwiftDataPersistenceProviderTests: XCTestCase {

    private var stack: InMemoryPersistenceHarness.Stack!

    override func setUp() async throws {
        try await super.setUp()
        stack = try InMemoryPersistenceHarness.make()
    }

    override func tearDown() async throws {
        stack = nil
        try await super.tearDown()
    }

    private var provider: SwiftDataPersistenceProvider { stack.provider }
    private var context: ModelContext { stack.context }

    // MARK: - Sessions

    func test_insertSession_roundTripsAllFields() async throws {
        let modelID = UUID()
        let endpointID = UUID()
        let pinned: Set<UUID> = [UUID(), UUID()]
        let record = ChatSessionRecord(
            title: "Round Trip",
            systemPrompt: "be concise",
            selectedModelID: modelID,
            selectedEndpointID: endpointID,
            temperature: 0.3,
            topP: 0.8,
            repeatPenalty: 1.2,
            promptTemplate: .llama3,
            contextSizeOverride: 2048,
            pinnedMessageIDs: pinned
        )

        try await provider.insertSession(record)

        let fetched = try await provider.fetchSessions()
        XCTAssertEqual(fetched.count, 1)
        let first = fetched[0]
        XCTAssertEqual(first.id, record.id)
        XCTAssertEqual(first.title, "Round Trip")
        XCTAssertEqual(first.systemPrompt, "be concise")
        XCTAssertEqual(first.selectedModelID, modelID)
        XCTAssertEqual(first.selectedEndpointID, endpointID)
        XCTAssertEqual(first.temperature, 0.3)
        XCTAssertEqual(first.topP, 0.8)
        XCTAssertEqual(first.repeatPenalty, 1.2)
        XCTAssertEqual(first.promptTemplate, .llama3)
        XCTAssertEqual(first.contextSizeOverride, 2048)
        XCTAssertEqual(first.pinnedMessageIDs, pinned)
    }

    func test_fetchSessions_ordersByUpdatedAtDescending() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let older = ChatSessionRecord(title: "Older", updatedAt: now)
        let newer = ChatSessionRecord(title: "Newer", updatedAt: now.addingTimeInterval(60))
        let middle = ChatSessionRecord(title: "Middle", updatedAt: now.addingTimeInterval(30))

        try await provider.insertSession(older)
        try await provider.insertSession(newer)
        try await provider.insertSession(middle)

        let fetched = try await provider.fetchSessions()
        XCTAssertEqual(fetched.map(\.title), ["Newer", "Middle", "Older"])
    }

    func test_updateSession_persistsFieldChanges() async throws {
        var record = ChatSessionRecord(title: "Before")
        try await provider.insertSession(record)

        record.title = "After"
        record.systemPrompt = "new prompt"
        record.temperature = 0.9
        record.updatedAt = Date()
        try await provider.updateSession(record)

        let fetched = try await provider.fetchSessions()
        XCTAssertEqual(fetched[0].title, "After")
        XCTAssertEqual(fetched[0].systemPrompt, "new prompt")
        XCTAssertEqual(fetched[0].temperature, 0.9)
    }

    func test_updateSession_throwsWhenSessionMissing() async throws {
        let record = ChatSessionRecord(title: "Ghost")
        do {
            try await provider.updateSession(record)
            XCTFail("Expected updateSession to throw for missing session")
        } catch {
            XCTAssertEqual(error as? ChatPersistenceError, .sessionNotFound(record.id))
        }
    }

    func test_deleteSession_removesSessionAndItsMessages() async throws {
        let session = ChatSessionRecord(title: "To Delete")
        try await provider.insertSession(session)
        try await provider.insertMessage(ChatMessageRecord(role: .user, content: "hi", sessionID: session.id))
        try await provider.insertMessage(ChatMessageRecord(role: .assistant, content: "hello", sessionID: session.id))

        try await provider.deleteSession(session.id)

        let sessions = try await provider.fetchSessions()
        XCTAssertEqual(sessions.count, 0)
        let messages = try await provider.fetchMessages(for: session.id)
        XCTAssertEqual(messages.count, 0)
    }

    func test_deleteSession_throwsWhenSessionMissing() async throws {
        let ghost = UUID()
        do {
            try await provider.deleteSession(ghost)
            XCTFail("Expected deleteSession to throw for missing session")
        } catch {
            XCTAssertEqual(error as? ChatPersistenceError, .sessionNotFound(ghost))
        }
    }

    // MARK: - Messages

    func test_insertMessage_roundTripsAllFields() async throws {
        let session = ChatSessionRecord(title: "Msg Test")
        try await provider.insertSession(session)
        let record = ChatMessageRecord(
            role: .assistant,
            content: "answer",
            sessionID: session.id,
            promptTokens: 12,
            completionTokens: 7
        )

        try await provider.insertMessage(record)

        let fetched = try await provider.fetchMessages(for: session.id)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].id, record.id)
        XCTAssertEqual(fetched[0].role, .assistant)
        XCTAssertEqual(fetched[0].content, "answer")
        XCTAssertEqual(fetched[0].promptTokens, 12)
        XCTAssertEqual(fetched[0].completionTokens, 7)
    }

    func test_fetchMessages_ordersByTimestampAscending() async throws {
        let session = ChatSessionRecord(title: "Order Test")
        try await provider.insertSession(session)
        let base = Date(timeIntervalSince1970: 1_000)
        // Insert in reverse order to prove the fetch re-sorts.
        try await provider.insertMessage(ChatMessageRecord(role: .user, content: "C", timestamp: base.addingTimeInterval(20), sessionID: session.id))
        try await provider.insertMessage(ChatMessageRecord(role: .user, content: "A", timestamp: base, sessionID: session.id))
        try await provider.insertMessage(ChatMessageRecord(role: .user, content: "B", timestamp: base.addingTimeInterval(10), sessionID: session.id))

        let fetched = try await provider.fetchMessages(for: session.id)
        XCTAssertEqual(fetched.map(\.content), ["A", "B", "C"])
    }

    func test_fetchRecentMessages_returnsTailInAscendingOrder() async throws {
        let session = ChatSessionRecord(title: "Recent Test")
        try await provider.insertSession(session)
        let base = Date(timeIntervalSince1970: 1_000)
        for i in 0..<5 {
            try await provider.insertMessage(ChatMessageRecord(
                role: .user,
                content: "m\(i)",
                timestamp: base.addingTimeInterval(Double(i)),
                sessionID: session.id
            ))
        }

        let recent = try await provider.fetchRecentMessages(for: session.id, limit: 3)
        XCTAssertEqual(recent.map(\.content), ["m2", "m3", "m4"])
    }

    func test_fetchMessagesBefore_returnsOlderPageInAscendingOrder() async throws {
        let session = ChatSessionRecord(title: "Before Test")
        try await provider.insertSession(session)
        let base = Date(timeIntervalSince1970: 1_000)
        for i in 0..<5 {
            try await provider.insertMessage(ChatMessageRecord(
                role: .user,
                content: "m\(i)",
                timestamp: base.addingTimeInterval(Double(i)),
                sessionID: session.id
            ))
        }

        // Anchor at m3's timestamp — expect m0, m1, m2 in ascending order.
        let cursor = base.addingTimeInterval(3)
        let older = try await provider.fetchMessages(for: session.id, before: cursor, limit: 10)
        XCTAssertEqual(older.map(\.content), ["m0", "m1", "m2"])
    }

    func test_fetchMessagesBefore_returnsEmptyAtOldestCursor() async throws {
        let session = ChatSessionRecord(title: "Empty Before")
        try await provider.insertSession(session)
        let base = Date(timeIntervalSince1970: 1_000)
        try await provider.insertMessage(ChatMessageRecord(role: .user, content: "first", timestamp: base, sessionID: session.id))

        let older = try await provider.fetchMessages(for: session.id, before: base, limit: 10)
        XCTAssertTrue(older.isEmpty)
    }

    func test_updateMessage_throwsWhenMissing() async throws {
        let ghost = ChatMessageRecord(role: .user, content: "ghost", sessionID: UUID())
        do {
            try await provider.updateMessage(ghost)
            XCTFail("Expected updateMessage to throw for missing message")
        } catch {
            XCTAssertEqual(error as? ChatPersistenceError, .messageNotFound(ghost.id))
        }
    }

    func test_deleteMessage_throwsWhenMissing() async throws {
        let ghost = UUID()
        do {
            try await provider.deleteMessage(ghost)
            XCTFail("Expected deleteMessage to throw for missing message")
        } catch {
            XCTAssertEqual(error as? ChatPersistenceError, .messageNotFound(ghost))
        }
    }

    /// The exact bug shape that silently nukes user data: a session-scoped
    /// delete that accidentally matches messages in other sessions.
    func test_deleteMessages_doesNotCascadeAcrossSessions() async throws {
        let sessionA = ChatSessionRecord(title: "A")
        let sessionB = ChatSessionRecord(title: "B")
        try await provider.insertSession(sessionA)
        try await provider.insertSession(sessionB)
        try await provider.insertMessage(ChatMessageRecord(role: .user, content: "A1", sessionID: sessionA.id))
        try await provider.insertMessage(ChatMessageRecord(role: .user, content: "A2", sessionID: sessionA.id))
        let keptID = UUID()
        try await provider.insertMessage(ChatMessageRecord(id: keptID, role: .user, content: "B1", sessionID: sessionB.id))

        try await provider.deleteMessages(for: sessionA.id)

        let messagesA = try await provider.fetchMessages(for: sessionA.id)
        XCTAssertEqual(messagesA.count, 0)
        let remaining = try await provider.fetchMessages(for: sessionB.id)
        XCTAssertEqual(remaining.map(\.id), [keptID])
    }

    // MARK: - pinnedMessageIDs CSV parsing (model-level footgun)

    func test_pinnedMessageIDs_parsesMalformedCSVAsEmpty() async throws {
        // Bypass the provider to write a raw CSV value that a buggy migration
        // or corrupt store could produce, then verify the model's getter is
        // tolerant — empty set, no crash.
        let session = ChatSession(title: "Malformed")
        session.pinnedMessageIDsRaw = "not-a-uuid,also-not,@@@"
        context.insert(session)
        try context.save()

        let fetched = try await provider.fetchSessions()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].pinnedMessageIDs, [])
    }

    func test_pinnedMessageIDs_parsesTrailingCommaWithoutThrowing() async throws {
        let valid = UUID()
        let session = ChatSession(title: "Trailing Comma")
        session.pinnedMessageIDsRaw = "\(valid.uuidString),"
        context.insert(session)
        try context.save()

        let fetched = try await provider.fetchSessions()
        XCTAssertEqual(fetched[0].pinnedMessageIDs, [valid])
    }

    func test_pinnedMessageIDs_filtersNonUUIDTokensMixedWithValid() async throws {
        let valid = UUID()
        let session = ChatSession(title: "Mixed")
        session.pinnedMessageIDsRaw = "garbage,\(valid.uuidString),more-garbage"
        context.insert(session)
        try context.save()

        let fetched = try await provider.fetchSessions()
        XCTAssertEqual(fetched[0].pinnedMessageIDs, [valid])
    }

    func test_pinnedMessageIDs_emptyStringProducesEmptySet() async throws {
        let session = ChatSession(title: "Empty Raw")
        session.pinnedMessageIDsRaw = ""
        context.insert(session)
        try context.save()

        let fetched = try await provider.fetchSessions()
        XCTAssertEqual(fetched[0].pinnedMessageIDs, [])
    }

    func test_pinnedMessageIDs_roundTripsThroughProvider() async throws {
        let pin = UUID()
        var record = ChatSessionRecord(title: "Pin", pinnedMessageIDs: [pin])
        try await provider.insertSession(record)

        record.pinnedMessageIDs = [pin, UUID()]
        try await provider.updateSession(record)

        let fetched = try await provider.fetchSessions()
        XCTAssertEqual(fetched[0].pinnedMessageIDs.count, 2)
        XCTAssertTrue(fetched[0].pinnedMessageIDs.contains(pin))
    }

    // MARK: - Harness invariant

    func test_harness_isInMemoryStore() throws {
        let freshStack = try InMemoryPersistenceHarness.make()
        XCTAssertTrue(
            InMemoryPersistenceHarness.isInMemoryStore(freshStack.container),
            "Harness must resolve to an in-memory store so tests never touch disk"
        )
    }
}
