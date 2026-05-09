import Foundation
import ManifoldRuntime
import ManifoldInference

// MARK: - ChatViewModel + Persistence

extension ChatViewModel {

    /// Loads the most recent page of messages for the active session.
    func loadMessages() async {
        await sessionController.loadMessages()
    }

    /// Loads the next page of older messages and prepends them.
    ///
    /// Returns the ID of the message that was previously first in the list,
    /// so the caller can restore scroll position to it after the prepend.
    @discardableResult
    public func loadOlderMessages() async -> UUID? {
        await sessionController.loadOlderMessages()
    }

    /// Persists a message via the persistence provider.
    ///
    /// `ChatViewModel` calls this for both brand-new messages and later writes to
    /// the same logical message (for example, when a cancelled assistant reply is
    /// saved once from `stopGeneration()` and again at the end of
    /// `generateIntoMessage`). Treat it as an upsert at the view-model boundary so
    /// callers do not need to coordinate insert vs. update ownership.
    func saveMessage(_ message: ChatMessageRecord) async throws {
        try await sessionController.saveMessage(message)
    }

    /// Updates an existing message via the persistence provider.
    func updateMessage(_ message: ChatMessageRecord) async throws {
        try await sessionController.updateMessage(message)
    }

    /// Deletes a message via the persistence provider.
    func deleteMessage(_ message: ChatMessageRecord) async throws {
        try await sessionController.deleteMessage(message)
    }

    /// Deletes all messages for a session via the persistence provider.
    func deleteMessages(for sessionID: UUID) async throws {
        try await sessionController.deleteMessages(for: sessionID)
    }
}
