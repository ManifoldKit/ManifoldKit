import XCTest
import ManifoldRuntime
import ManifoldInference

// MARK: - SessionStoreContract

/// Opt-in XCTestCase mixin that exercises the ``SessionStore`` protocol contract
/// against any conforming implementation.
///
/// ```swift
/// @MainActor
/// final class InMemorySessionStoreContractTests: XCTestCase, SessionStoreContract {
///     func makeSessionStore() -> any SessionStore {
///         InMemorySessionStoreImpl()
///     }
///
///     func test_insertFetch() async throws {
///         try await assertSessionStore_insertThenFetchReturnsRecord()
///     }
/// }
/// ```
@MainActor
public protocol SessionStoreContract: AnyObject {
    /// Returns a fresh, empty session store for each assertion call.
    func makeSessionStore() -> any SessionStore
}

extension SessionStoreContract where Self: XCTestCase {

    // MARK: - Fixture helpers

    private func makeSession(
        title: String = "Test Session",
        updatedAt: Date = Date()
    ) -> ChatSession {
        ChatSession(title: title, updatedAt: updatedAt)
    }

    // MARK: - Empty-store baseline

    /// Asserts that a fresh store returns an empty array from ``fetchSessions()``.
    public func assertSessionStore_emptyStoreReturnsNoSessions(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeSessionStore()
        let result = try await store.fetchSessions()
        XCTAssertTrue(result.isEmpty, "Fresh store must return no sessions", file: file, line: line)
    }

    // MARK: - Insert / Fetch

    /// Asserts that an inserted session is returned by ``fetchSessions()``.
    public func assertSessionStore_insertThenFetchReturnsRecord(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeSessionStore()
        let session = makeSession(title: "Contract test session")
        try await store.insertSession(session)

        let fetched = try await store.fetchSessions()
        XCTAssertEqual(fetched.count, 1, file: file, line: line)
        XCTAssertEqual(fetched.first?.id, session.id, file: file, line: line)
    }

    // MARK: - Most-recently-updated ordering

    /// Asserts that ``fetchSessions()`` orders sessions most-recently-updated
    /// first, as documented on the protocol.
    public func assertSessionStore_fetchOrdersByMostRecentlyUpdatedFirst(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeSessionStore()
        let base = Date(timeIntervalSinceReferenceDate: 0)
        let older = makeSession(title: "Older", updatedAt: base)
        let newer = makeSession(title: "Newer", updatedAt: base.addingTimeInterval(10))
        // Insert older first to prove order is not insertion-order.
        try await store.insertSession(older)
        try await store.insertSession(newer)

        let fetched = try await store.fetchSessions()
        XCTAssertEqual(
            fetched.map(\.id), [newer.id, older.id],
            "fetchSessions() must return most-recently-updated first",
            file: file, line: line
        )
    }

    // MARK: - Update

    /// Asserts that ``updateSession(_:)`` persists the changed title.
    public func assertSessionStore_updatePersistsChanges(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeSessionStore()
        var session = makeSession(title: "Original")
        try await store.insertSession(session)

        session.title = "Updated"
        try await store.updateSession(session)

        let fetched = try await store.fetchSessions()
        XCTAssertEqual(fetched.first?.title, "Updated", file: file, line: line)
    }

    /// Asserts that ``updateSession(_:)`` throws
    /// ``ChatPersistenceError/sessionNotFound(_:)`` for an unknown ID.
    public func assertSessionStore_updateUnknownIDThrowsNotFound(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeSessionStore()
        let ghost = makeSession(title: "Ghost")
        do {
            try await store.updateSession(ghost)
            XCTFail("update of unknown session must throw", file: file, line: line)
        } catch ChatPersistenceError.sessionNotFound(let id) {
            XCTAssertEqual(id, ghost.id, file: file, line: line)
        } catch {
            XCTFail("Expected ChatPersistenceError.sessionNotFound, got \(error)", file: file, line: line)
        }
    }

    // MARK: - Delete

    /// Asserts that a deleted session is no longer returned by ``fetchSessions()``.
    public func assertSessionStore_deletedSessionNotReturned(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeSessionStore()
        let session = makeSession(title: "To delete")
        try await store.insertSession(session)
        try await store.deleteSession(session.id)

        let fetched = try await store.fetchSessions()
        XCTAssertFalse(
            fetched.contains { $0.id == session.id },
            "Deleted session must not appear in subsequent fetch",
            file: file, line: line
        )
    }

    /// Asserts that ``deleteSession(_:)`` throws
    /// ``ChatPersistenceError/sessionNotFound(_:)`` for an unknown ID.
    public func assertSessionStore_deleteUnknownIDThrowsNotFound(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeSessionStore()
        let unknownID = UUID()
        do {
            try await store.deleteSession(unknownID)
            XCTFail("delete of unknown id must throw", file: file, line: line)
        } catch ChatPersistenceError.sessionNotFound(let id) {
            XCTAssertEqual(id, unknownID, file: file, line: line)
        } catch {
            XCTFail("Expected ChatPersistenceError.sessionNotFound, got \(error)", file: file, line: line)
        }
    }

    // MARK: - deleteAll

    /// Asserts that ``deleteAll()`` removes every session.
    public func assertSessionStore_deleteAllRemovesEverything(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeSessionStore()
        try await store.insertSession(makeSession(title: "A"))
        try await store.insertSession(makeSession(title: "B"))
        try await store.deleteAll()

        let after = try await store.fetchSessions()
        XCTAssertTrue(after.isEmpty, "deleteAll() must remove every session", file: file, line: line)
    }

    // MARK: - Pagination

    /// Asserts that ``fetchSessions(offset:limit:)`` pages correctly over the
    /// full session list returned by ``fetchSessions()``.
    public func assertSessionStore_fetchWithPaginationReturnsCorrectSlice(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let store = makeSessionStore()
        let base = Date(timeIntervalSinceReferenceDate: 0)
        // Insert 5 sessions with distinct updatedAt timestamps so ordering is
        // deterministic. Most-recently-updated ordering means descending
        // timestamp → [s4, s3, s2, s1, s0].
        var sessions: [ChatSession] = []
        for i in 0..<5 {
            let s = ChatSession(
                title: "Session \(i)",
                updatedAt: base.addingTimeInterval(Double(i))
            )
            try await store.insertSession(s)
            sessions.append(s)
        }

        // Page 1: offset=0, limit=2 → first two most-recently-updated
        let page1 = try await store.fetchSessions(offset: 0, limit: 2)
        XCTAssertEqual(page1.count, 2, file: file, line: line)

        // Page 2: offset=2, limit=2 → next two
        let page2 = try await store.fetchSessions(offset: 2, limit: 2)
        XCTAssertEqual(page2.count, 2, file: file, line: line)

        // Pages must not overlap
        let page1IDs = Set(page1.map(\.id))
        let page2IDs = Set(page2.map(\.id))
        XCTAssertTrue(
            page1IDs.isDisjoint(with: page2IDs),
            "Pages must not overlap",
            file: file, line: line
        )

        // Page beyond end → empty
        let pastEnd = try await store.fetchSessions(offset: 100, limit: 10)
        XCTAssertTrue(pastEnd.isEmpty, file: file, line: line)
    }
}
