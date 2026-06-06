import Foundation
import Observation
import ManifoldRuntime
import ManifoldInference

@Observable
@MainActor
final class SessionController {

    static let defaultTemperature: Float = 0.7
    static let defaultTopP: Float = 0.9
    static let defaultRepeatPenalty: Float = 1.1
    static let messagePageSize = 50

    struct SessionSelectionState {
        let selectedModelID: UUID?
        let selectedEndpointID: UUID?
    }

    /// Persistence is held as a combined `SessionStore & MessageStore`
    /// existential rather than two separate references — sessions and
    /// messages travel together at the controller layer (delete-session
    /// fans out to delete-messages, etc.), and the SwiftData adapter is
    /// always one object that conforms to both protocols. Hosts that wire
    /// genuinely separate stores can pass a small composed adapter.
    var persistence: (any SessionStore & MessageStore)?
    var activeSession: ChatSession?
    var messages: [ChatMessage] = []
    var systemPrompt: String = ""
    var temperature: Float = defaultTemperature
    var topP: Float = defaultTopP
    var repeatPenalty: Float = defaultRepeatPenalty
    var selectedPromptTemplate: PromptTemplate
    let defaultPromptTemplate: PromptTemplate
    var pinnedMessageIDs: Set<UUID> = []
    var hasOlderMessages: Bool = false
    var isLoadingOlderMessages: Bool = false

    init(selectedPromptTemplate: PromptTemplate = .chatML) {
        self.selectedPromptTemplate = selectedPromptTemplate
        self.defaultPromptTemplate = selectedPromptTemplate
    }

    var activeSessionID: UUID? {
        activeSession?.id
    }

    func configure(persistence: any SessionStore & MessageStore) {
        guard self.persistence == nil else { return }
        self.persistence = persistence
        Log.persistence.info("ChatViewModel configured with persistence provider")
    }

    @discardableResult
    func activateSession(_ session: ChatSession) -> SessionSelectionState {
        activeSession = session
        systemPrompt = session.systemPrompt
        temperature = session.temperature ?? Self.defaultTemperature
        topP = session.topP ?? Self.defaultTopP
        repeatPenalty = session.repeatPenalty ?? Self.defaultRepeatPenalty
        selectedPromptTemplate = session.promptTemplate ?? defaultPromptTemplate
        pinnedMessageIDs = session.pinnedMessageIDs
        return SessionSelectionState(
            selectedModelID: session.selectedModelID,
            selectedEndpointID: session.selectedEndpointID
        )
    }

    func touchActiveSessionUpdatedAt(_ date: Date = Date()) async throws {
        guard var session = activeSession else { return }

        session.updatedAt = date
        activeSession = session

        guard let persistence = persistenceOrLog("touchActiveSessionUpdatedAt") else { return }

        do {
            try await persistence.updateSession(session)
        } catch ChatPersistenceError.sessionNotFound {
            Log.persistence.warning(
                "Active session was not yet persisted when updating session timestamp: \(session.id, privacy: .private)"
            )
        }
    }

    func saveSettingsToSession(
        selectedModelID: UUID?,
        selectedEndpointID: UUID?
    ) async throws {
        guard var session = activeSession else { return }
        let persistence = try requirePersistence("saveSettingsToSession")
        session.temperature = temperature
        session.topP = topP
        session.repeatPenalty = repeatPenalty
        session.systemPrompt = systemPrompt
        session.selectedModelID = selectedModelID
        session.selectedEndpointID = selectedEndpointID
        session.promptTemplate = selectedPromptTemplate
        session.pinnedMessageIDs = pinnedMessageIDs
        session.updatedAt = Date()
        try await persistence.updateSession(session)
        activeSession = session
    }

    func loadMessages() async {
        guard let persistence = persistenceOrLog("loadMessages") else { return }
        guard let sessionID = activeSessionID else {
            messages = []
            hasOlderMessages = false
            return
        }

        do {
            let page = try await persistence.fetchRecentMessages(for: sessionID, limit: Self.messagePageSize)
            // Heal orphan tool calls before exposing the transcript: a process
            // killed mid-tool leaves a `.toolCall` part with no matching
            // `.toolResult`, which cloud APIs reject on the next turn. The
            // healer synthesises a `.cancelled` ToolResult for each orphan so
            // the next request is well-formed without re-dispatching the
            // (potentially side-effecting) original call. See issue #629.
            messages = TranscriptHealer.heal(page)
            hasOlderMessages = page.count >= Self.messagePageSize
            Log.persistence.info("Loaded \(page.count) messages (hasOlder: \(self.hasOlderMessages))")
        } catch {
            Log.persistence.error("Failed to load messages: \(error)")
            messages = []
            hasOlderMessages = false
        }
    }

    @discardableResult
    func loadOlderMessages() async -> UUID? {
        guard !isLoadingOlderMessages, hasOlderMessages else { return nil }
        guard let persistence else { return nil }
        guard let sessionID = activeSessionID else { return nil }
        guard let oldestTimestamp = messages.first?.timestamp else { return nil }

        let anchorID = messages.first?.id
        isLoadingOlderMessages = true
        defer { isLoadingOlderMessages = false }

        do {
            let older = try await persistence.fetchMessages(
                for: sessionID,
                before: oldestTimestamp,
                limit: Self.messagePageSize
            )
            if older.isEmpty {
                hasOlderMessages = false
                return anchorID
            }
            hasOlderMessages = older.count >= Self.messagePageSize
            messages.insert(contentsOf: older, at: 0)
            Log.persistence.info("Prepended \(older.count) older messages (hasOlder: \(self.hasOlderMessages))")
        } catch {
            Log.persistence.error("Failed to load older messages: \(error)")
        }

        return anchorID
    }

    func saveMessage(_ message: ChatMessage) async throws {
        guard let persistence = persistenceOrLog("saveMessage") else { return }
        do {
            try await persistence.updateMessage(message)
        } catch ChatPersistenceError.messageNotFound {
            try await persistence.insertMessage(message)
        }
    }

    func updateMessage(_ message: ChatMessage) async throws {
        guard let persistence = persistenceOrLog("updateMessage") else { return }
        try await persistence.updateMessage(message)
    }

    func deleteMessage(_ message: ChatMessage) async throws {
        guard let persistence = persistenceOrLog("deleteMessage") else { return }
        try await persistence.deleteMessage(message.id)
    }

    func deleteMessages(for sessionID: UUID) async throws {
        guard let persistence = persistenceOrLog("deleteMessages") else { return }
        try await persistence.deleteMessages(for: sessionID)
    }
}
