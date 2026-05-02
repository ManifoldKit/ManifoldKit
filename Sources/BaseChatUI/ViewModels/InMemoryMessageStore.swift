import Foundation
import BaseChatInference

/// Process-local message store used as the default backing for
/// ``ChatViewModel/conversationRuntime`` when the host did not pass a runtime
/// at construction.
///
/// Real apps wire ``BaseChatBootstrap``'s SwiftData-backed runtime through
/// ``ChatViewModel/configure(runtime:)`` so chat history outlives the process.
/// This in-memory store keeps tests and ad-hoc surfaces functional without
/// requiring every caller to assemble a ``ConversationRuntime`` themselves.
@MainActor
final class InMemoryMessageStore: MessageStore {
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
