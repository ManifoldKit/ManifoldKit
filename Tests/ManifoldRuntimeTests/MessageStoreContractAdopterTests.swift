import XCTest
import ManifoldRuntime
import ManifoldInference
import ManifoldTestSupport
import ManifoldContractTestSupport
import ManifoldPersistenceTestSupport

@MainActor
private final class LegacySwiftDataMessageStoreAdapter: MessageStore {
    private let wrapped: any MessageStore

    init(wrapping wrapped: any MessageStore) {
        self.wrapped = wrapped
    }

    func insertMessage(_ message: ChatMessage) async throws {
        try await wrapped.insertMessage(message)
    }

    func updateMessage(_ message: ChatMessage) async throws {
        try await wrapped.updateMessage(message)
    }

    func deleteMessage(_ messageID: UUID) async throws {
        try await wrapped.deleteMessage(messageID)
    }

    func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
        try await wrapped.fetchMessages(for: sessionID)
    }

    func deleteMessages(for sessionID: UUID) async throws {
        try await wrapped.deleteMessages(for: sessionID)
    }
}

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

    func test_historyPage_defaultKeepsEqualTimestampsForLegacySwiftDataAdapter() async throws {
        let stack = try InMemoryPersistenceHarness.make()
        let legacyStore: any MessageStore = LegacySwiftDataMessageStoreAdapter(wrapping: stack.provider)
        try await assertMessageStore_historyPageDefaultKeepsEqualTimestamps(store: legacyStore)
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
