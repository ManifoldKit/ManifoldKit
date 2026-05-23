import Foundation
import ManifoldInference

/// Errors produced by ``ConversationImporter`` when a write cannot be completed.
public enum ConversationImportWriteError: Error, LocalizedError, Sendable {

    /// The session write failed at the storage layer.
    case sessionWriteFailed(String)

    /// A message write failed at the storage layer.
    ///
    /// The partial import is not automatically rolled back — it is the caller's
    /// responsibility to clean up if atomic behaviour is required. The
    /// associated `messageID` helps callers identify which message failed so
    /// they can log it or report it to the user.
    case messageWriteFailed(messageID: UUID, description: String)

    public var errorDescription: String? {
        switch self {
        case let .sessionWriteFailed(description):
            return "Failed to write session: \(description)"
        case let .messageWriteFailed(id, description):
            return "Failed to write message \(id.uuidString): \(description)"
        }
    }
}

/// Writes an ``ImportedConversation`` into the persistence layer.
///
/// Callers decode a file with any ``ConversationImportFormat`` and then pass
/// the result here. Separating decode from write keeps the format types free
/// of persistence dependencies and makes unit-testing the decode logic cheap
/// (no SwiftData container required).
///
/// `@MainActor` because both ``SessionStore`` and ``MessageStore`` are
/// `@MainActor`-isolated. Callers on background actors must hop to the main
/// actor before calling ``importConversation(_:)``.
@MainActor
public struct ConversationImporter {

    private let sessionStore: any SessionStore
    private let messageStore: any MessageStore

    public init(sessionStore: any SessionStore, messageStore: any MessageStore) {
        self.sessionStore = sessionStore
        self.messageStore = messageStore
    }

    /// Writes the session and its messages into the persistence stores.
    ///
    /// - Parameter imported: A decoded conversation — typically the output of
    ///   ``ConversationImportFormat/decode(_:)``.
    /// - Returns: The session ID. Callers can use it to navigate to the
    ///   newly-imported conversation immediately after import completes.
    /// - Throws: ``ConversationImportWriteError`` when a session or message
    ///   write fails. On message-write failure the session row is deleted
    ///   before rethrowing so the store is left in a consistent state.
    @discardableResult
    public func importConversation(_ imported: ImportedConversation) async throws -> UUID {
        do {
            try await sessionStore.insertSession(imported.session)
        } catch {
            Log.persistence.warning("ConversationImporter: session write failed — \(error.localizedDescription)")
            throw ConversationImportWriteError.sessionWriteFailed(error.localizedDescription)
        }

        do {
            for message in imported.messages {
                do {
                    try await messageStore.insertMessage(message)
                } catch {
                    Log.persistence.warning("ConversationImporter: message \(message.id.uuidString) write failed — \(error.localizedDescription)")
                    throw ConversationImportWriteError.messageWriteFailed(
                        messageID: message.id,
                        description: error.localizedDescription
                    )
                }
            }
        } catch {
            // Roll back the session row so the store is never left with a
            // session that has no messages due to a mid-loop write failure.
            do {
                try await sessionStore.deleteSession(imported.session.id)
            } catch let rollbackError {
                Log.persistence.warning("ConversationImporter: rollback of session \(imported.session.id.uuidString) failed — \(rollbackError.localizedDescription)")
            }
            throw error
        }

        return imported.session.id
    }
}
