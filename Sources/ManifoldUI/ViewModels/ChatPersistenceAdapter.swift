import Foundation
import Observation
import ManifoldRuntime
import ManifoldInference

/// Encapsulates persistence I/O that was previously scattered across
/// `ChatViewModel` and `ChatViewModel+Persistence.swift`.
///
/// Owns the `SessionController` and forwards all message and session
/// operations through it. The `onPersistenceConfigured` closure lets
/// `ChatViewModel` rebuild its `ConversationRuntime` when persistence
/// arrives late — a common pattern when hosts wire storage after
/// construction rather than via `ManifoldBootstrap`.
@Observable
@MainActor
final class ChatPersistenceAdapter {

    let sessionController: SessionController

    /// Fires every time `configure(persistence:)` is called with a valid
    /// store. `ChatViewModel` installs a closure here to rebuild the default
    /// runtime against the new store; rebuilds are idempotent and gated by
    /// `ChatViewModel.replaceDefaultRuntime(with:)` so hosts that supplied
    /// their own runtime at construction are never affected.
    var onPersistenceConfigured: (@MainActor (any SessionStore & MessageStore) -> Void)?

    init(selectedPromptTemplate: PromptTemplate = .chatML) {
        self.sessionController = SessionController(selectedPromptTemplate: selectedPromptTemplate)
    }

    // MARK: - Forwarded SessionController surface

    var persistence: (any SessionStore & MessageStore)? {
        get { sessionController.persistence }
        set { sessionController.persistence = newValue }
    }

    var activeSession: ChatSession? {
        get { sessionController.activeSession }
        set { sessionController.activeSession = newValue }
    }

    var activeSessionID: UUID? {
        sessionController.activeSessionID
    }

    var messages: [ChatMessage] {
        get { sessionController.messages }
        set { sessionController.messages = newValue }
    }

    var systemPrompt: String {
        get { sessionController.systemPrompt }
        set { sessionController.systemPrompt = newValue }
    }

    var temperature: Float {
        get { sessionController.temperature }
        set { sessionController.temperature = newValue }
    }

    var topP: Float {
        get { sessionController.topP }
        set { sessionController.topP = newValue }
    }

    var repeatPenalty: Float {
        get { sessionController.repeatPenalty }
        set { sessionController.repeatPenalty = newValue }
    }

    var selectedPromptTemplate: PromptTemplate {
        get { sessionController.selectedPromptTemplate }
        set { sessionController.selectedPromptTemplate = newValue }
    }

    var pinnedMessageIDs: Set<UUID> {
        get { sessionController.pinnedMessageIDs }
        set { sessionController.pinnedMessageIDs = newValue }
    }

    var hasOlderMessages: Bool {
        get { sessionController.hasOlderMessages }
        set { sessionController.hasOlderMessages = newValue }
    }

    var isLoadingOlderMessages: Bool {
        get { sessionController.isLoadingOlderMessages }
        set { sessionController.isLoadingOlderMessages = newValue }
    }

    // MARK: - Configure

    func configure(persistence: any SessionStore & MessageStore) {
        // Only fire onPersistenceConfigured (which rebuilds the conversation
        // runtime) when the store was actually installed. A second call with
        // a different store must be a consistent no-op end-to-end — firing
        // the rebuild here while `sessionController` keeps the original store
        // would split state: session reads from store A, new messages write
        // to store B. See #A3.
        guard sessionController.configure(persistence: persistence) else { return }
        onPersistenceConfigured?(persistence)
    }

    // MARK: - Session operations

    @discardableResult
    func activateSession(_ session: ChatSession) -> SessionController.SessionSelectionState {
        sessionController.activateSession(session)
    }

    func saveSettingsToSession(
        selectedModelID: UUID?,
        selectedEndpointID: UUID?
    ) async throws {
        try await sessionController.saveSettingsToSession(
            selectedModelID: selectedModelID,
            selectedEndpointID: selectedEndpointID
        )
    }

    func touchActiveSessionUpdatedAt(_ date: Date = Date()) async throws {
        try await sessionController.touchActiveSessionUpdatedAt(date)
    }

    /// Inserts a new session into persistence. Callers in the ingest paths use
    /// this instead of unwrapping `persistenceOrLog` themselves, so the guard
    /// and error type stay in one place.
    func insertSession(_ session: ChatSession) async throws {
        let persistence = try requirePersistence("insertSession")
        try await persistence.insertSession(session)
    }

    // MARK: - Message I/O

    func loadMessages() async {
        await sessionController.loadMessages()
    }

    @discardableResult
    func loadOlderMessages() async -> UUID? {
        await sessionController.loadOlderMessages()
    }

    func saveMessage(_ message: ChatMessage) async throws {
        try await sessionController.saveMessage(message)
    }

    func updateMessage(_ message: ChatMessage) async throws {
        try await sessionController.updateMessage(message)
    }

    func deleteMessage(_ message: ChatMessage) async throws {
        try await sessionController.deleteMessage(message)
    }

    func deleteMessages(for sessionID: UUID) async throws {
        try await sessionController.deleteMessages(for: sessionID)
    }
}
