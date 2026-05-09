import Foundation
import ManifoldInference

struct ConversationPersistencePort: Sendable {
    private let messageStore: any MessageStore
    private let sessionStore: (any SessionStore)?

    init(messageStore: any MessageStore, sessionStore: (any SessionStore)?) {
        self.messageStore = messageStore
        self.sessionStore = sessionStore
    }

    @MainActor
    func insertMessage(_ message: ChatMessageRecord) async throws {
        try await messageStore.insertMessage(message)
    }

    @MainActor
    func updateMessage(_ message: ChatMessageRecord) async throws {
        try await messageStore.updateMessage(message)
    }

    @MainActor
    func deleteMessage(_ messageID: UUID) async throws {
        try await messageStore.deleteMessage(messageID)
    }

    @MainActor
    func fetchMessages(sessionID: UUID) async throws -> [ChatMessageRecord] {
        try await messageStore.fetchMessages(for: sessionID)
    }

    @MainActor
    func insertSession(_ session: ChatSessionRecord) async throws {
        guard let sessionStore else { return }
        try await sessionStore.insertSession(session)
    }

    @MainActor
    func sessionTitle(sessionID: UUID, fallback: String) async -> String {
        guard let sessionStore else { return fallback }
        do {
            let sessions = try await sessionStore.fetchSessions()
            return sessions.first(where: { $0.id == sessionID })?.title ?? fallback
        } catch {
            Log.persistence.warning(
                "ConversationRuntime.branch: title lookup failed: \(error.localizedDescription); using fallback title"
            )
            return fallback
        }
    }

    @MainActor
    func touchSession(sessionID: UUID) async -> Bool {
        guard let sessionStore else { return true }
        do {
            let sessions = try await sessionStore.fetchSessions()
            guard var session = sessions.first(where: { $0.id == sessionID }) else { return true }
            session.updatedAt = Date()
            try await sessionStore.updateSession(session)
            return true
        } catch {
            Log.persistence.warning(
                "ConversationRuntime: touchSession failed: \(error.localizedDescription)"
            )
            return false
        }
    }
}
