import XCTest
import ManifoldRuntime
import ManifoldInference
import ManifoldTestSupport
import ManifoldContractTestSupport

// MARK: - InMemoryMessageStoreContractTests

/// Adopts ``MessageStoreContract`` via the in-memory reference implementation.
/// Passing here proves the mixin assertion helpers compile and execute correctly.
@MainActor
final class InMemoryMessageStoreContractTests: XCTestCase, MessageStoreContract {

    func makeMessageStore() -> any MessageStore {
        InMemoryMessageStore()
    }

    func test_emptyStore_returnsNoMessages() async throws {
        try await assertMessageStore_emptyStoreReturnsNoMessages()
    }

    func test_insert_thenFetch_returnsRecord() async throws {
        try await assertMessageStore_insertThenFetchReturnsRecord()
    }

    func test_fetch_isolatedBySession() async throws {
        try await assertMessageStore_fetchIsolatedBySession()
    }

    func test_fetch_ordersByTimestampAscending() async throws {
        try await assertMessageStore_fetchOrdersByTimestampAscending()
    }

    func test_update_persistsChanges() async throws {
        try await assertMessageStore_updatePersistsChanges()
    }

    func test_update_unknownID_throwsNotFound() async throws {
        try await assertMessageStore_updateUnknownIDThrowsNotFound()
    }

    func test_delete_deletedMessageNotReturned() async throws {
        try await assertMessageStore_deletedMessageNotReturned()
    }

    func test_delete_unknownID_throwsNotFound() async throws {
        try await assertMessageStore_deleteUnknownIDThrowsNotFound()
    }

    func test_deleteMessagesForSession_preservesOtherSessions() async throws {
        try await assertMessageStore_deleteMessagesForSessionPreservesOtherSessions()
    }

    func test_fetchRecentMessages_respectsLimitAndOrder() async throws {
        try await assertMessageStore_fetchRecentMessagesRespectsLimitAndOrder()
    }
}
