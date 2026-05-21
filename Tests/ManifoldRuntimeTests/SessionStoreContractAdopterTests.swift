import XCTest
import ManifoldRuntime
import ManifoldInference
import ManifoldTestSupport
import ManifoldContractTestSupport

// MARK: - InMemorySessionStore (test double for contract adoption)

@MainActor
private final class InMemorySessionStore: SessionStore {
    private var sessions: [UUID: ChatSessionRecord] = [:]

    func insertSession(_ session: ChatSessionRecord) async throws {
        sessions[session.id] = session
    }

    func updateSession(_ session: ChatSessionRecord) async throws {
        guard sessions[session.id] != nil else {
            throw ChatPersistenceError.sessionNotFound(session.id)
        }
        sessions[session.id] = session
    }

    func deleteSession(_ sessionID: UUID) async throws {
        guard sessions.removeValue(forKey: sessionID) != nil else {
            throw ChatPersistenceError.sessionNotFound(sessionID)
        }
    }

    func fetchSessions() async throws -> [ChatSessionRecord] {
        sessions.values.sorted { $0.updatedAt > $1.updatedAt }
    }
}

// MARK: - InMemorySessionStoreContractTests

@MainActor
final class InMemorySessionStoreContractTests: XCTestCase, SessionStoreContract {

    func makeSessionStore() -> any SessionStore {
        InMemorySessionStore()
    }

    func test_emptyStore_returnsNoSessions() async throws {
        try await assertSessionStore_emptyStoreReturnsNoSessions()
    }

    func test_insert_thenFetch_returnsRecord() async throws {
        try await assertSessionStore_insertThenFetchReturnsRecord()
    }

    func test_fetch_ordersByMostRecentlyUpdatedFirst() async throws {
        try await assertSessionStore_fetchOrdersByMostRecentlyUpdatedFirst()
    }

    func test_update_persistsChanges() async throws {
        try await assertSessionStore_updatePersistsChanges()
    }

    func test_update_unknownID_throwsNotFound() async throws {
        try await assertSessionStore_updateUnknownIDThrowsNotFound()
    }

    func test_delete_deletedSessionNotReturned() async throws {
        try await assertSessionStore_deletedSessionNotReturned()
    }

    func test_delete_unknownID_throwsNotFound() async throws {
        try await assertSessionStore_deleteUnknownIDThrowsNotFound()
    }

    func test_deleteAll_removesEverything() async throws {
        try await assertSessionStore_deleteAllRemovesEverything()
    }

    func test_fetchWithPagination_returnsCorrectSlice() async throws {
        try await assertSessionStore_fetchWithPaginationReturnsCorrectSlice()
    }
}
