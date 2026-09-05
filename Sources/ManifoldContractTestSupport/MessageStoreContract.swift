import XCTest
import ManifoldRuntime
import ManifoldInference

// MARK: - MessageStoreContract

/// Opt-in XCTestCase mixin that exercises the ``MessageStore`` protocol contract
/// against any conforming implementation.
///
/// Each adopter provides a fresh store via ``makeMessageStore()`` and calls the
/// assertion helpers from concrete `test_`-prefixed methods so XCTest can
/// discover them:
///
/// ```swift
/// @MainActor
/// final class InMemoryMessageStoreContractTests: XCTestCase, MessageStoreContract {
///     func makeMessageStore() -> any MessageStore {
///         InMemoryMessageStoreImpl()
///     }
///
///     func test_insertFetch() async throws {
///         try await assertMessageStore_insertThenFetchReturnsRecord()
///     }
/// }
/// ```
@MainActor
public protocol MessageStoreContract: AnyObject {
    /// Returns a fresh, empty message store for each assertion call.
    func makeMessageStore() -> any MessageStore
}

extension MessageStoreContract where Self: XCTestCase {

    // MARK: - Fixture helpers

    private func makeMessage(
        sessionID: UUID,
        role: MessageRole = .user,
        content: String = "Hello",
        timestamp: Date = Date()
    ) -> ChatMessage {
        ChatMessage(
            role: role,
            contentParts: [.text(content)],
            timestamp: timestamp,
            sessionID: sessionID
        )
    }

    // MARK: - Empty-store baseline

    /// Asserts that a fresh store returns an empty array for a new session.
    public func assertMessageStore_emptyStoreReturnsNoMessages(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeMessageStore()
        let result = try await store.fetchMessages(for: UUID())
        XCTAssertTrue(result.isEmpty, "Fresh store must return no messages", file: file, line: line)
    }

    // MARK: - Insert / Fetch

    /// Asserts that an inserted message is returned by ``fetchMessages(for:)``.
    public func assertMessageStore_insertThenFetchReturnsRecord(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeMessageStore()
        let sessionID = UUID()
        let msg = makeMessage(sessionID: sessionID, content: "Contract test")
        try await store.insertMessage(msg)

        let fetched = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(fetched.count, 1, file: file, line: line)
        XCTAssertEqual(fetched.first?.id, msg.id, file: file, line: line)
    }

    // MARK: - Session isolation

    /// Asserts that messages from different sessions are not commingled.
    public func assertMessageStore_fetchIsolatedBySession(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeMessageStore()
        let sessionA = UUID()
        let sessionB = UUID()
        let msgA = makeMessage(sessionID: sessionA, content: "Session A")
        let msgB = makeMessage(sessionID: sessionB, content: "Session B")
        try await store.insertMessage(msgA)
        try await store.insertMessage(msgB)

        let fetchedA = try await store.fetchMessages(for: sessionA)
        let fetchedB = try await store.fetchMessages(for: sessionB)
        XCTAssertEqual(fetchedA.map(\.id), [msgA.id], file: file, line: line)
        XCTAssertEqual(fetchedB.map(\.id), [msgB.id], file: file, line: line)
    }

    // MARK: - Timestamp ordering

    /// Asserts that ``fetchMessages(for:)`` returns messages in ascending
    /// timestamp order (oldest first), matching the documented contract.
    public func assertMessageStore_fetchOrdersByTimestampAscending(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeMessageStore()
        let sessionID = UUID()
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let older = makeMessage(sessionID: sessionID, content: "Older", timestamp: base)
        let newer = makeMessage(sessionID: sessionID, content: "Newer", timestamp: base.addingTimeInterval(10))
        // Insert out of order to prove ordering is not insertion-order.
        try await store.insertMessage(newer)
        try await store.insertMessage(older)

        let fetched = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(fetched.map(\.id), [older.id, newer.id],
                       "fetchMessages() must return records in ascending timestamp order",
                       file: file, line: line)
    }

    /// Exercises the compatibility page default through an existential. This
    /// protects source-compatible external stores that implement only the
    /// long-standing complete ``MessageStore/fetchMessages(for:)`` contract.
    public func assertMessageStore_historyPageDefaultKeepsEqualTimestamps(
        store: any MessageStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let sessionID = UUID()
        let timestamp = Date(timeIntervalSinceReferenceDate: 0)
        let records = try (0..<5).map { index in
            ChatMessage(
                id: try XCTUnwrap(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))),
                role: .user,
                content: "equal-\(index)",
                timestamp: timestamp,
                sessionID: sessionID
            )
        }
        for record in records {
            try await store.insertMessage(record)
        }

        let first = try await store.fetchMessageHistoryPage(for: sessionID, cursor: nil, limit: 3)
        let second = try await store.fetchMessageHistoryPage(
            for: sessionID,
            cursor: first.nextCursor,
            limit: 3
        )
        XCTAssertEqual(second.messages.map(\.id) + first.messages.map(\.id), records.map(\.id), file: file, line: line)
        XCTAssertNil(second.nextCursor, file: file, line: line)
    }

    public func assertMessageStore_historyPageDefaultKeepsEqualTimestamps(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try await assertMessageStore_historyPageDefaultKeepsEqualTimestamps(
            store: makeMessageStore(),
            file: file,
            line: line
        )
    }

    // MARK: - Update

    /// Asserts that ``updateMessage(_:)`` persists the changed content.
    public func assertMessageStore_updatePersistsChanges(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeMessageStore()
        let sessionID = UUID()
        var msg = makeMessage(sessionID: sessionID, content: "Original")
        try await store.insertMessage(msg)

        msg.contentParts = [.text("Updated")]
        try await store.updateMessage(msg)

        let fetched = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(fetched.first?.contentParts, [.text("Updated")], file: file, line: line)
    }

    /// Asserts that ``updateMessage(_:)`` throws
    /// ``ChatPersistenceError/messageNotFound(_:)`` for an unknown ID.
    public func assertMessageStore_updateUnknownIDThrowsNotFound(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeMessageStore()
        let ghost = makeMessage(sessionID: UUID(), content: "Ghost")
        do {
            try await store.updateMessage(ghost)
            XCTFail("update of unknown message must throw", file: file, line: line)
        } catch ChatPersistenceError.messageNotFound(let id) {
            XCTAssertEqual(id, ghost.id, file: file, line: line)
        } catch {
            XCTFail("Expected ChatPersistenceError.messageNotFound, got \(error)", file: file, line: line)
        }
    }

    // MARK: - Delete

    /// Asserts that a deleted message is no longer returned by
    /// ``fetchMessages(for:)``.
    public func assertMessageStore_deletedMessageNotReturned(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeMessageStore()
        let sessionID = UUID()
        let msg = makeMessage(sessionID: sessionID, content: "To delete")
        try await store.insertMessage(msg)
        try await store.deleteMessage(msg.id)

        let fetched = try await store.fetchMessages(for: sessionID)
        XCTAssertFalse(
            fetched.contains { $0.id == msg.id },
            "Deleted message must not appear in subsequent fetch",
            file: file, line: line
        )
    }

    /// Asserts that ``deleteMessage(_:)`` throws
    /// ``ChatPersistenceError/messageNotFound(_:)`` for an unknown ID.
    public func assertMessageStore_deleteUnknownIDThrowsNotFound(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeMessageStore()
        let unknownID = UUID()
        do {
            try await store.deleteMessage(unknownID)
            XCTFail("delete of unknown id must throw", file: file, line: line)
        } catch ChatPersistenceError.messageNotFound(let id) {
            XCTAssertEqual(id, unknownID, file: file, line: line)
        } catch {
            XCTFail("Expected ChatPersistenceError.messageNotFound, got \(error)", file: file, line: line)
        }
    }

    // MARK: - deleteMessages(for:)

    /// Asserts that ``deleteMessages(for:)`` removes all messages in a session
    /// without affecting messages in other sessions.
    public func assertMessageStore_deleteMessagesForSessionPreservesOtherSessions(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeMessageStore()
        let sessionA = UUID()
        let sessionB = UUID()
        try await store.insertMessage(makeMessage(sessionID: sessionA, content: "A1"))
        try await store.insertMessage(makeMessage(sessionID: sessionA, content: "A2"))
        try await store.insertMessage(makeMessage(sessionID: sessionB, content: "B1"))

        try await store.deleteMessages(for: sessionA)

        let afterA = try await store.fetchMessages(for: sessionA)
        let afterB = try await store.fetchMessages(for: sessionB)
        XCTAssertTrue(afterA.isEmpty,
                      "deleteMessages(for:) must remove all messages in the target session",
                      file: file, line: line)
        XCTAssertEqual(afterB.count, 1,
                       "deleteMessages(for:) must not affect messages in other sessions",
                       file: file, line: line)
    }

    // MARK: - fetchRecentMessages

    /// Asserts that ``fetchRecentMessages(for:limit:)`` returns at most `limit`
    /// records in ascending timestamp order.
    public func assertMessageStore_fetchRecentMessagesRespectsLimitAndOrder(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeMessageStore()
        let sessionID = UUID()
        let base = Date(timeIntervalSinceReferenceDate: 0)
        for i in 0..<5 {
            try await store.insertMessage(
                makeMessage(sessionID: sessionID,
                            content: "Message \(i)",
                            timestamp: base.addingTimeInterval(Double(i)))
            )
        }

        let recent = try await store.fetchRecentMessages(for: sessionID, limit: 3)
        XCTAssertEqual(recent.count, 3, "fetchRecentMessages must respect the limit", file: file, line: line)
        // Ascending order — oldest of the most-recent window first
        let timestamps = recent.map { $0.timestamp }
        XCTAssertEqual(timestamps, timestamps.sorted(),
                       "fetchRecentMessages must return records in ascending timestamp order",
                       file: file, line: line)
    }
}
