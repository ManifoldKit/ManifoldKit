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
    func insertMessage(_ message: ChatMessage) async throws {
        try await messageStore.insertMessage(message)
    }

    @MainActor
    func updateMessage(_ message: ChatMessage) async throws {
        try await messageStore.updateMessage(message)
    }

    @MainActor
    func deleteMessage(_ messageID: UUID) async throws {
        try await messageStore.deleteMessage(messageID)
    }

    @MainActor
    func deleteMessages(for sessionID: UUID) async throws {
        try await messageStore.deleteMessages(for: sessionID)
    }

    @MainActor
    func performMessageMutations(_ mutations: [MessageStoreMutation]) async throws {
        guard !mutations.isEmpty else { return }

        if let transactionalStore = messageStore as? any TransactionalMessageStore {
            try await transactionalStore.performMessageMutations(mutations)
            return
        }

        for mutation in mutations {
            switch mutation {
            case let .insert(message):
                try await messageStore.insertMessage(message)
            case let .update(message):
                try await messageStore.updateMessage(message)
            case let .delete(messageID):
                try await messageStore.deleteMessage(messageID)
            case let .deleteMessages(sessionID):
                try await messageStore.deleteMessages(for: sessionID)
            }
        }
    }

    @MainActor
    func fetchMessages(sessionID: UUID) async throws -> [ChatMessage] {
        try await messageStore.fetchMessages(for: sessionID)
    }

    /// Generation-bound fetch: canonical history with orphan tool calls
    /// healed. Use this — not ``fetchMessages(sessionID:)`` — whenever the
    /// result feeds a backend `generate()` call. See `HealedHistoryFetch.swift`
    /// for the seam contract and the caller list.
    @MainActor
    func fetchHealedMessages(sessionID: UUID) async throws -> [ChatMessage] {
        try await messageStore.fetchHealedMessages(for: sessionID)
    }

    @MainActor
    func fetchRecentHealedMessages(sessionID: UUID, limit: Int) async throws -> [ChatMessage] {
        try await messageStore.fetchRecentHealedMessages(for: sessionID, limit: limit)
    }

    @MainActor
    func insertSession(_ session: ChatSession) async throws {
        guard let sessionStore else { return }
        try await sessionStore.insertSession(session)
    }

    /// Best-effort session delete used to unwind a partially-created branch
    /// when the message-copy batch fails. The message mutations roll back on
    /// their own (the adapter's `performMessageMutations` calls `rollback()`),
    /// but the session insert commits separately because the adapter's
    /// transactional batch spans messages only — so the branch flow deletes
    /// the orphaned session here. Logs rather than throwing so the original
    /// copy failure is the error the caller surfaces.
    @MainActor
    func deleteSession(_ sessionID: UUID) async {
        guard let sessionStore else { return }
        do {
            try await sessionStore.deleteSession(sessionID)
        } catch {
            Log.persistence.warning(
                "ConversationRuntime.branch: rollback deleteSession failed: \(error.localizedDescription)"
            )
        }
    }

    /// Fetches the storage-agnostic record for a single session, or `nil`
    /// when no session matches. Used by the executor to read multi-agent
    /// state (`activeAgentID`, `agents`) per turn so handoff detection and
    /// system-prompt re-derivation can run without coupling to the
    /// SwiftData adapter.
    @MainActor
    func fetchSession(sessionID: UUID) async -> ChatSession? {
        guard let sessionStore else { return nil }
        do {
            return try await sessionStore.fetchSession(id: sessionID)
        } catch {
            Log.persistence.warning(
                "ConversationRuntime: fetchSession failed: \(error.localizedDescription)"
            )
            return nil
        }
    }

    /// Best-effort session update. Returns `false` and logs on failure so
    /// the caller doesn't have to swallow a thrown error inline.
    @MainActor
    func updateSession(_ record: ChatSession) async -> Bool {
        guard let sessionStore else { return true }
        do {
            try await sessionStore.updateSession(record)
            return true
        } catch {
            Log.persistence.warning(
                "ConversationRuntime: updateSession failed: \(error.localizedDescription)"
            )
            return false
        }
    }

    @MainActor
    func sessionTitle(sessionID: UUID, fallback: String) async -> String {
        guard let sessionStore else { return fallback }
        do {
            return try await sessionStore.fetchSession(id: sessionID)?.title ?? fallback
        } catch {
            Log.persistence.warning(
                "ConversationRuntime.branch: title lookup failed: \(error.localizedDescription); using fallback title"
            )
            return fallback
        }
    }

    /// Bumps the session's `updatedAt` via the store's narrow single-column
    /// write so a concurrent turn or host-side session edit isn't clobbered by
    /// a stale-snapshot rewrite (see ``SessionStore/touch(sessionID:date:)``).
    /// Best-effort: returns `false` and logs on failure.
    @MainActor
    func touchSession(sessionID: UUID) async -> Bool {
        guard let sessionStore else { return true }
        do {
            try await sessionStore.touch(sessionID: sessionID, date: Date())
            return true
        } catch {
            Log.persistence.warning(
                "ConversationRuntime: touchSession failed: \(error.localizedDescription)"
            )
            return false
        }
    }

    /// Swaps the session's active agent via the store's narrow single-column
    /// write so a mid-stream handoff doesn't clobber concurrent edits to other
    /// session columns (see ``SessionStore/setActiveAgent(sessionID:agentID:)``).
    /// Best-effort: returns `false` and logs on failure.
    @MainActor
    func setActiveAgent(sessionID: UUID, agentID: UUID?) async -> Bool {
        guard let sessionStore else { return true }
        do {
            try await sessionStore.setActiveAgent(sessionID: sessionID, agentID: agentID)
            return true
        } catch {
            Log.persistence.warning(
                "ConversationRuntime: setActiveAgent failed: \(error.localizedDescription)"
            )
            return false
        }
    }
}
