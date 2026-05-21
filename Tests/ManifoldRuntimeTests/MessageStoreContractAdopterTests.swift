import XCTest
import ManifoldRuntime
import ManifoldInference
import ManifoldTestSupport

// MARK: - InMemoryMessageStore (test double for contract adoption)

/// Minimal in-memory implementation of ``MessageStore`` used solely to validate
/// the ``MessageStoreContract`` mixin compiles and passes against a reference
/// conformer. This mirrors the shape used in other runtime test files (e.g.
/// `ConversationRuntimeAppDataTests`), keeping it local to avoid polluting
/// the global test namespace.
@MainActor
private final class InMemoryMessageStore: MessageStore {
    private var messages: [UUID: ChatMessageRecord] = [:]
    private var hooks: [any MessageStorePostWriteHook] = []

    func insertMessage(_ message: ChatMessageRecord) async throws {
        messages[message.id] = message
        for hook in hooks { await hook.messageDidWrite(message, in: message.sessionID) }
    }

    func updateMessage(_ message: ChatMessageRecord) async throws {
        guard messages[message.id] != nil else {
            throw ChatPersistenceError.messageNotFound(message.id)
        }
        messages[message.id] = message
        for hook in hooks { await hook.messageDidWrite(message, in: message.sessionID) }
    }

    func deleteMessage(_ messageID: UUID) async throws {
        guard messages.removeValue(forKey: messageID) != nil else {
            throw ChatPersistenceError.messageNotFound(messageID)
        }
    }

    func fetchMessages(for sessionID: UUID) async throws -> [ChatMessageRecord] {
        messages.values
            .filter { $0.sessionID == sessionID }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func deleteMessages(for sessionID: UUID) async throws {
        messages = messages.filter { $0.value.sessionID != sessionID }
    }

    func addPostWriteHook(_ hook: any MessageStorePostWriteHook) {
        hooks.append(hook)
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
