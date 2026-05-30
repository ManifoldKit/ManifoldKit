import Foundation
@testable import ManifoldRuntime
@testable import ManifoldInference

/// Shared in-memory MessageStore for ManifoldRuntimeTests unit tests.
@MainActor
final class InMemoryMessageStore: MessageStore {
    private(set) var messages: [UUID: ChatMessageRecord] = [:]
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
