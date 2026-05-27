import XCTest
@testable import ManifoldRuntime
import ManifoldInference

@MainActor
final class ConversationPersistencePortTransactionalMutationTests: XCTestCase {

    func test_performMessageMutations_usesTransactionalCapabilityAndRollsBackInjectedFailure() async throws {
        let sessionID = UUID()
        let original = ChatMessageRecord(role: .user, content: "before", sessionID: sessionID)
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
        let first = ChatMessageRecord(role: .user, content: "first", sessionID: sessionID)
        let second = ChatMessageRecord(role: .assistant, content: "second", sessionID: sessionID)
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
}

@MainActor
private final class TransactionalFakeMessageStore: TransactionalMessageStore {
    enum InjectedError: Error {
        case transactionFailed
    }

    private var messages: [UUID: ChatMessageRecord]
    var injectedFailureAfterApplyingMutationCount: Int?
    private(set) var transactionCallCount = 0
    private(set) var individualMutationCallCount = 0

    init(initialMessages: [ChatMessageRecord] = []) {
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

    func insertMessage(_ message: ChatMessageRecord) async throws {
        individualMutationCallCount += 1
        messages[message.id] = message
    }

    func updateMessage(_ message: ChatMessageRecord) async throws {
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

    func fetchMessages(for sessionID: UUID) async throws -> [ChatMessageRecord] {
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
    private var messages: [UUID: ChatMessageRecord] = [:]
    private(set) var insertCallCount = 0
    private(set) var updateCallCount = 0
    private(set) var deleteCallCount = 0

    func insertMessage(_ message: ChatMessageRecord) async throws {
        insertCallCount += 1
        messages[message.id] = message
    }

    func updateMessage(_ message: ChatMessageRecord) async throws {
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

    func fetchMessages(for sessionID: UUID) async throws -> [ChatMessageRecord] {
        messages.values
            .filter { $0.sessionID == sessionID }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func deleteMessages(for sessionID: UUID) async throws {
        messages = messages.filter { $0.value.sessionID != sessionID }
    }
}
