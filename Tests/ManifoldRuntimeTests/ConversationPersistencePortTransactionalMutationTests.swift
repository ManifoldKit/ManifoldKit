import XCTest
@testable import ManifoldRuntime
import ManifoldInference

@MainActor
final class ConversationPersistencePortTransactionalMutationTests: XCTestCase {

    func test_performMessageMutations_usesTransactionalCapabilityAndRollsBackInjectedFailure() async throws {
        let sessionID = UUID()
        let original = ChatMessage(role: .user, content: "before", sessionID: sessionID)
        let store = TransactionalFakeMessageStore(initialMessages: [original])
        store.injectedFailureAfterApplyingMutationCount = 1
        let port = ConversationPersistencePort(messageStore: store, sessionStore: nil)

        var updated = original
        updated.content = "after"

        do {
            try await port.performMessageMutations([
                .update(updated),
                .delete(UUID()),
            ])
            XCTFail("Expected injected transaction failure")
        } catch TransactionalFakeMessageStore.InjectedError.transactionFailed {
            // Expected failure path.
        }

        let messages = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(messages.map(\.content), ["before"])
        XCTAssertEqual(store.transactionCallCount, 1)
        XCTAssertEqual(store.individualMutationCallCount, 0)
    }

    func test_performMessageMutations_fallsBackToLegacyMessageStoreMethods() async throws {
        let sessionID = UUID()
        let first = ChatMessage(role: .user, content: "first", sessionID: sessionID)
        let second = ChatMessage(role: .assistant, content: "second", sessionID: sessionID)
        var updatedFirst = first
        updatedFirst.content = "updated"

        let store = LegacyMessageStore()
        let port = ConversationPersistencePort(messageStore: store, sessionStore: nil)

        try await port.performMessageMutations([
            .insert(first),
            .insert(second),
            .update(updatedFirst),
            .delete(second.id),
        ])

        let messages = try await store.fetchMessages(for: sessionID)
        XCTAssertEqual(messages.map(\.id), [first.id])
        XCTAssertEqual(messages.first?.content, "updated")
        XCTAssertEqual(store.insertCallCount, 2)
        XCTAssertEqual(store.updateCallCount, 1)
        XCTAssertEqual(store.deleteCallCount, 1)
    }

    func test_deleteSession_forwardsToSessionStore() async throws {
        let store = LegacyMessageStore()
        let sessionStore = RecordingSessionStore()
        let port = ConversationPersistencePort(messageStore: store, sessionStore: sessionStore)

        let sessionID = UUID()
        await port.deleteSession(sessionID)

        XCTAssertEqual(sessionStore.deletedSessionIDs, [sessionID])
    }

    func test_deleteSession_swallowsSessionStoreError() async throws {
        let store = LegacyMessageStore()
        let sessionStore = RecordingSessionStore()
        sessionStore.shouldThrowOnDelete = true
        let port = ConversationPersistencePort(messageStore: store, sessionStore: sessionStore)

        // Best-effort: must not throw even when the underlying delete fails, so
        // the branch flow surfaces the original copy error, not the cleanup error.
        await port.deleteSession(UUID())
        XCTAssertEqual(sessionStore.deletedSessionIDs.count, 1)
    }
}

@MainActor
private final class RecordingSessionStore: SessionStore {
    private(set) var deletedSessionIDs: [UUID] = []
    var shouldThrowOnDelete = false
    private var sessions: [UUID: ChatSession] = [:]

    enum StoreError: Error { case deleteFailed }

    func insertSession(_ session: ChatSession) async throws {
        sessions[session.id] = session
    }

    func updateSession(_ session: ChatSession) async throws {
        sessions[session.id] = session
    }

    func deleteSession(_ sessionID: UUID) async throws {
        deletedSessionIDs.append(sessionID)
        if shouldThrowOnDelete { throw StoreError.deleteFailed }
        sessions.removeValue(forKey: sessionID)
    }

    func fetchSessions() async throws -> [ChatSession] {
        Array(sessions.values)
    }
}

@MainActor
private final class TransactionalFakeMessageStore: TransactionalMessageStore {
    enum InjectedError: Error {
        case transactionFailed
    }

    private var messages: [UUID: ChatMessage]
    var injectedFailureAfterApplyingMutationCount: Int?
    private(set) var transactionCallCount = 0
    private(set) var individualMutationCallCount = 0

    init(initialMessages: [ChatMessage] = []) {
        self.messages = Dictionary(uniqueKeysWithValues: initialMessages.map { ($0.id, $0) })
    }

    func performMessageMutations(_ mutations: [MessageStoreMutation]) async throws {
        transactionCallCount += 1
        let snapshot = messages
        var appliedCount = 0

        do {
            for mutation in mutations {
                try apply(mutation)
                appliedCount += 1
                if injectedFailureAfterApplyingMutationCount == appliedCount {
                    throw InjectedError.transactionFailed
                }
            }
        } catch {
            messages = snapshot
            throw error
        }
    }

    func insertMessage(_ message: ChatMessage) async throws {
        individualMutationCallCount += 1
        messages[message.id] = message
    }

    func updateMessage(_ message: ChatMessage) async throws {
        individualMutationCallCount += 1
        guard messages[message.id] != nil else {
            throw ChatPersistenceError.messageNotFound(message.id)
        }
        messages[message.id] = message
    }

    func deleteMessage(_ messageID: UUID) async throws {
        individualMutationCallCount += 1
        guard messages.removeValue(forKey: messageID) != nil else {
            throw ChatPersistenceError.messageNotFound(messageID)
        }
    }

    func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
        messages.values
            .filter { $0.sessionID == sessionID }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func deleteMessages(for sessionID: UUID) async throws {
        individualMutationCallCount += 1
        messages = messages.filter { $0.value.sessionID != sessionID }
    }

    private func apply(_ mutation: MessageStoreMutation) throws {
        switch mutation {
        case let .insert(message):
            messages[message.id] = message
        case let .update(message):
            guard messages[message.id] != nil else {
                throw ChatPersistenceError.messageNotFound(message.id)
            }
            messages[message.id] = message
        case let .delete(messageID):
            guard messages.removeValue(forKey: messageID) != nil else {
                throw ChatPersistenceError.messageNotFound(messageID)
            }
        case let .deleteMessages(sessionID):
            messages = messages.filter { $0.value.sessionID != sessionID }
        }
    }
}

@MainActor
private final class LegacyMessageStore: MessageStore {
    private var messages: [UUID: ChatMessage] = [:]
    private(set) var insertCallCount = 0
    private(set) var updateCallCount = 0
    private(set) var deleteCallCount = 0

    func insertMessage(_ message: ChatMessage) async throws {
        insertCallCount += 1
        messages[message.id] = message
    }

    func updateMessage(_ message: ChatMessage) async throws {
        updateCallCount += 1
        guard messages[message.id] != nil else {
            throw ChatPersistenceError.messageNotFound(message.id)
        }
        messages[message.id] = message
    }

    func deleteMessage(_ messageID: UUID) async throws {
        deleteCallCount += 1
        guard messages.removeValue(forKey: messageID) != nil else {
            throw ChatPersistenceError.messageNotFound(messageID)
        }
    }

    func fetchMessages(for sessionID: UUID) async throws -> [ChatMessage] {
        messages.values
            .filter { $0.sessionID == sessionID }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func deleteMessages(for sessionID: UUID) async throws {
        messages = messages.filter { $0.value.sessionID != sessionID }
    }
}
