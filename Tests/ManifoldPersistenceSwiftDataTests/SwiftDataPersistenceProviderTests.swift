import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldRuntime
import ManifoldTestSupport
import ManifoldPersistenceTestSupport

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
        let record = ManifoldInference.ChatSession(
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

    // MARK: - Narrow single-column writes (#1494 lost-update)

    /// `touch(sessionID:)` bumps `updatedAt` on the live row without rewriting
    /// the other columns. A concurrent edit to an unrelated column (here:
    /// `title`) committed between a turn-start snapshot and the touch must
    /// survive — the narrow write reads the live row, not the stale snapshot.
    func test_touch_doesNotClobberConcurrentTitleEdit() async throws {
        let original = ManifoldInference.ChatSession(title: "Original")
        try await provider.insertSession(original)

        // A turn captured this snapshot at its start (mimics the old
        // read-modify-write `touchSession`).
        let staleSnapshot = original

        // Meanwhile a host-side edit renames the session on the live row.
        var renamed = original
        renamed.title = "Renamed"
        try await provider.updateSession(renamed)

        // The narrow touch must NOT carry the stale snapshot's title back.
        let before = try await provider.fetchSessions().first!.updatedAt
        try await provider.touch(sessionID: staleSnapshot.id, date: before.addingTimeInterval(10))

        let after = try await provider.fetchSessions().first!
        XCTAssertEqual(after.title, "Renamed",
                       "touch must not clobber the concurrent title edit")
        XCTAssertEqual(after.updatedAt, before.addingTimeInterval(10),
                       "touch must bump updatedAt")

        // Sabotage check: a read-modify-write touch off `staleSnapshot` would
        // write title back to "Original", failing the first assertion.
    }

    /// `setActiveAgent(sessionID:agentID:)` swaps only the active agent on the
    /// live row. A concurrent edit to another column committed after a
    /// turn-start snapshot must survive.
    func test_setActiveAgent_doesNotClobberConcurrentEdit() async throws {
        let agentA = UUID()
        let agentB = UUID()
        let original = ManifoldInference.ChatSession(title: "Original", activeAgentID: agentA)
        try await provider.insertSession(original)

        let staleSnapshot = original

        var renamed = original
        renamed.title = "Renamed"
        try await provider.updateSession(renamed)

        try await provider.setActiveAgent(sessionID: staleSnapshot.id, agentID: agentB)

        let after = try await provider.fetchSessions().first!
        XCTAssertEqual(after.activeAgentID, agentB, "active agent must swap to B")
        XCTAssertEqual(after.title, "Renamed",
                       "setActiveAgent must not clobber the concurrent title edit")

        // Sabotage check: a read-modify-write off `staleSnapshot` would write
        // title back to "Original", failing the title assertion.
    }

    /// Both narrow writes silently no-op when the session is gone — a touch
    /// racing a delete must not surface an error to the turn loop.
    func test_narrowWrites_noOpWhenSessionMissing() async throws {
        let missing = UUID()
        // Neither call should throw.
        try await provider.touch(sessionID: missing, date: Date())
        try await provider.setActiveAgent(sessionID: missing, agentID: UUID())
        let sessions = try await provider.fetchSessions()
        XCTAssertTrue(sessions.isEmpty, "no session should have been created by the no-op writes")
    }

    func test_fetchSessions_ordersByUpdatedAtDescending() async throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let older = ManifoldInference.ChatSession(title: "Older", updatedAt: now)
        let newer = ManifoldInference.ChatSession(title: "Newer", updatedAt: now.addingTimeInterval(60))
        let middle = ManifoldInference.ChatSession(title: "Middle", updatedAt: now.addingTimeInterval(30))

        try await provider.insertSession(older)
        try await provider.insertSession(newer)
        try await provider.insertSession(middle)

        let fetched = try await provider.fetchSessions()
        XCTAssertEqual(fetched.map(\.title), ["Newer", "Middle", "Older"])
    }

    func test_updateSession_persistsFieldChanges() async throws {
        var record = ManifoldInference.ChatSession(title: "Before")
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
        let record = ManifoldInference.ChatSession(title: "Ghost")
        do {
            try await provider.updateSession(record)
            XCTFail("Expected updateSession to throw for missing session")
        } catch {
            XCTAssertEqual(error as? ChatPersistenceError, .sessionNotFound(record.id))
        }
    }

    func test_deleteSession_removesSessionAndItsMessages() async throws {
        let session = ManifoldInference.ChatSession(title: "To Delete")
        try await provider.insertSession(session)
        try await provider.insertMessage(ManifoldInference.ChatMessage(role: .user, content: "hi", sessionID: session.id))
        try await provider.insertMessage(ManifoldInference.ChatMessage(role: .assistant, content: "hello", sessionID: session.id))

        try await provider.deleteSession(session.id)

        let sessions = try await provider.fetchSessions()
        XCTAssertEqual(sessions.count, 0)
        let messages = try await provider.fetchMessages(for: session.id)
        XCTAssertEqual(messages.count, 0)
    }

    func test_deleteSession_purgesOnlyTargetSessionMessages() async throws {
        // deleteSession stages the message purge and the session delete and
        // commits them with a single save. Verify the commit is scoped to the
        // target session: a sibling session and its messages survive untouched.
        let target = ManifoldInference.ChatSession(title: "Target")
        let sibling = ManifoldInference.ChatSession(title: "Sibling")
        try await provider.insertSession(target)
        try await provider.insertSession(sibling)
        try await provider.insertMessage(ManifoldInference.ChatMessage(role: .user, content: "t1", sessionID: target.id))
        try await provider.insertMessage(ManifoldInference.ChatMessage(role: .user, content: "s1", sessionID: sibling.id))

        try await provider.deleteSession(target.id)

        let sessions = try await provider.fetchSessions()
        XCTAssertEqual(sessions.map(\.id), [sibling.id])
        let targetMessages = try await provider.fetchMessages(for: target.id)
        XCTAssertEqual(targetMessages.count, 0)
        let siblingMessages = try await provider.fetchMessages(for: sibling.id)
        XCTAssertEqual(siblingMessages.map(\.content), ["s1"])
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
        let session = ManifoldInference.ChatSession(title: "Msg Test")
        try await provider.insertSession(session)
        let record = ManifoldInference.ChatMessage(
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

    func test_insertMessage_doesNotPersistTransientStatus() async throws {
        let session = ManifoldInference.ChatSession(title: "Status Test")
        try await provider.insertSession(session)
        let record = ManifoldInference.ChatMessage(
            role: .user,
            content: "hello",
            sessionID: session.id,
            status: .sent
        )

        try await provider.insertMessage(record)

        let fetched = try await provider.fetchMessages(for: session.id)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertNil(fetched[0].status, "Message status is UI-only and must not force a SwiftData schema migration")
    }

    func test_fetchMessages_ordersByTimestampAscending() async throws {
        let session = ManifoldInference.ChatSession(title: "Order Test")
        try await provider.insertSession(session)
        let base = Date(timeIntervalSince1970: 1_000)
        // Insert in reverse order to prove the fetch re-sorts.
        try await provider.insertMessage(ManifoldInference.ChatMessage(role: .user, content: "C", timestamp: base.addingTimeInterval(20), sessionID: session.id))
        try await provider.insertMessage(ManifoldInference.ChatMessage(role: .user, content: "A", timestamp: base, sessionID: session.id))
        try await provider.insertMessage(ManifoldInference.ChatMessage(role: .user, content: "B", timestamp: base.addingTimeInterval(10), sessionID: session.id))

        let fetched = try await provider.fetchMessages(for: session.id)
        XCTAssertEqual(fetched.map(\.content), ["A", "B", "C"])
    }

    func test_fetchMessageHistoryPage_throughExistential_keepsEqualTimestampRecords() async throws {
        let session = ManifoldInference.ChatSession(title: "Keyset page")
        try await provider.insertSession(session)
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let ids = [
            "00000000-0000-0000-0000-000000000001",
            "10000000-0000-0000-0000-000000000001",
            "20000000-0000-0000-0000-000000000001",
            "7fffffff-0000-0000-0000-000000000001",
            "80000000-0000-0000-0000-000000000001",
            "a0000000-0000-0000-0000-000000000001",
            "ffffffff-0000-0000-0000-000000000001"
        ]
        let records = ids.enumerated().map { index, value in
            ManifoldInference.ChatMessage(
                id: UUID(uuidString: value)!,
                role: .user,
                content: "m\(index)",
                timestamp: timestamp,
                sessionID: session.id
            )
        }
        try await provider.performMessageMutations(records.map(MessageStoreMutation.insert))

        let store: any MessageStore = provider
        var cursor: MessageHistoryCursor?
        var pages: [[ChatMessage]] = []
        repeat {
            let page = try await store.fetchMessageHistoryPage(
                for: session.id,
                cursor: cursor,
                limit: 3
            )
            pages.append(page.messages)
            cursor = page.nextCursor
        } while cursor != nil

        XCTAssertEqual(pages.map { $0.map(\.id) }, [
            records[4...6].map(\.id),
            records[1...3].map(\.id),
            records[0...0].map(\.id)
        ])
        XCTAssertEqual(pages.reversed().flatMap(\.self).map(\.id), records.map(\.id))
    }

    func test_fetchMessages_returnsCompleteHistoryBeyondFormerCeiling() async throws {
        let session = ManifoldInference.ChatSession(title: "Complete history")
        try await provider.insertSession(session)
        let base = Date(timeIntervalSince1970: 1_000)
        let records = (0...10_000).map { index in
            ManifoldInference.ChatMessage(
                role: .user,
                content: "m\(index)",
                timestamp: base.addingTimeInterval(Double(index)),
                sessionID: session.id
            )
        }
        try await provider.performMessageMutations(records.map(MessageStoreMutation.insert))

        let fetched = try await provider.fetchMessages(for: session.id)

        XCTAssertEqual(fetched.map(\.id), records.map(\.id))
    }

    func test_fetchMessageHistoryPage_rejectsInvalidLimitAndForeignCursor() async throws {
        let session = ManifoldInference.ChatSession(title: "Invalid page")
        try await provider.insertSession(session)

        do {
            _ = try await provider.fetchMessageHistoryPage(for: session.id, cursor: nil, limit: 0)
            XCTFail("A zero page limit must fail recoverably")
        } catch let error as MessageHistoryPagingError {
            XCTAssertEqual(error, .invalidLimit(0))
        }

        let cursor = MessageHistoryCursor(
            sessionID: UUID(),
            highWaterTimestamp: .distantPast,
            highWaterID: UUID(),
            beforeTimestamp: .distantPast,
            beforeID: UUID()
        )
        do {
            _ = try await provider.fetchMessageHistoryPage(for: session.id, cursor: cursor, limit: 1)
            XCTFail("A cursor cannot cross sessions")
        } catch let error as MessageHistoryPagingError {
            XCTAssertEqual(error, .cursorSessionMismatch)
        }
    }

    func test_fetchMessageHistoryPage_excludesNewerRowsPastCapturedHighWater() async throws {
        let session = ManifoldInference.ChatSession(title: "High water")
        try await provider.insertSession(session)
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let initial = (1...4).map { suffix in
            ManifoldInference.ChatMessage(
                id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", suffix))!,
                role: .user,
                content: "m\(suffix)",
                timestamp: timestamp,
                sessionID: session.id
            )
        }
        try await provider.performMessageMutations(initial.map(MessageStoreMutation.insert))

        let first = try await provider.fetchMessageHistoryPage(for: session.id, cursor: nil, limit: 2)
        let newID = UUID(uuidString: "ffffffff-0000-0000-0000-000000000001")!
        try await provider.insertMessage(ChatMessage(
            id: newID,
            role: .user,
            content: "later",
            timestamp: timestamp,
            sessionID: session.id
        ))
        let second = try await provider.fetchMessageHistoryPage(
            for: session.id,
            cursor: first.nextCursor,
            limit: 2
        )

        XCTAssertEqual(second.messages.map(\.id) + first.messages.map(\.id), initial.map(\.id))
        XCTAssertFalse(second.messages.contains { $0.id == newID })
    }

    func test_fetchRecentMessages_returnsTailInAscendingOrder() async throws {
        let session = ManifoldInference.ChatSession(title: "Recent Test")
        try await provider.insertSession(session)
        let base = Date(timeIntervalSince1970: 1_000)
        for i in 0..<5 {
            try await provider.insertMessage(ManifoldInference.ChatMessage(
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
        let session = ManifoldInference.ChatSession(title: "Before Test")
        try await provider.insertSession(session)
        let base = Date(timeIntervalSince1970: 1_000)
        for i in 0..<5 {
            try await provider.insertMessage(ManifoldInference.ChatMessage(
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
        let session = ManifoldInference.ChatSession(title: "Empty Before")
        try await provider.insertSession(session)
        let base = Date(timeIntervalSince1970: 1_000)
        try await provider.insertMessage(ManifoldInference.ChatMessage(role: .user, content: "first", timestamp: base, sessionID: session.id))

        let older = try await provider.fetchMessages(for: session.id, before: base, limit: 10)
        XCTAssertTrue(older.isEmpty)
    }

    func test_updateMessage_throwsWhenMissing() async throws {
        let ghost = ManifoldInference.ChatMessage(role: .user, content: "ghost", sessionID: UUID())
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
        let sessionA = ManifoldInference.ChatSession(title: "A")
        let sessionB = ManifoldInference.ChatSession(title: "B")
        try await provider.insertSession(sessionA)
        try await provider.insertSession(sessionB)
        try await provider.insertMessage(ManifoldInference.ChatMessage(role: .user, content: "A1", sessionID: sessionA.id))
        try await provider.insertMessage(ManifoldInference.ChatMessage(role: .user, content: "A2", sessionID: sessionA.id))
        let keptID = UUID()
        try await provider.insertMessage(ManifoldInference.ChatMessage(id: keptID, role: .user, content: "B1", sessionID: sessionB.id))

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
        let session = PersistedChatSession(title: "Malformed")
        session.pinnedMessageIDsRaw = "not-a-uuid,also-not,@@@"
        context.insert(session)
        try context.save()

        let fetched = try await provider.fetchSessions()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].pinnedMessageIDs, [])
    }

    func test_pinnedMessageIDs_parsesTrailingCommaWithoutThrowing() async throws {
        let valid = UUID()
        let session = PersistedChatSession(title: "Trailing Comma")
        session.pinnedMessageIDsRaw = "\(valid.uuidString),"
        context.insert(session)
        try context.save()

        let fetched = try await provider.fetchSessions()
        XCTAssertEqual(fetched[0].pinnedMessageIDs, [valid])
    }

    func test_pinnedMessageIDs_filtersNonUUIDTokensMixedWithValid() async throws {
        let valid = UUID()
        let session = PersistedChatSession(title: "Mixed")
        session.pinnedMessageIDsRaw = "garbage,\(valid.uuidString),more-garbage"
        context.insert(session)
        try context.save()

        let fetched = try await provider.fetchSessions()
        XCTAssertEqual(fetched[0].pinnedMessageIDs, [valid])
    }

    func test_pinnedMessageIDs_emptyStringProducesEmptySet() async throws {
        let session = PersistedChatSession(title: "Empty Raw")
        session.pinnedMessageIDsRaw = ""
        context.insert(session)
        try context.save()

        let fetched = try await provider.fetchSessions()
        XCTAssertEqual(fetched[0].pinnedMessageIDs, [])
    }

    func test_pinnedMessageIDs_roundTripsThroughProvider() async throws {
        let pin = UUID()
        var record = ManifoldInference.ChatSession(title: "Pin", pinnedMessageIDs: [pin])
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
