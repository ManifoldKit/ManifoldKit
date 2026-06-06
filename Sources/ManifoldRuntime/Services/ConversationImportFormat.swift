import Foundation
import ManifoldInference

/// A decoded conversation ready to be written into the persistence layer.
///
/// Carries a session record and its ordered messages in one value so the
/// importer never partially writes a conversation (session exists, messages
/// lost) because the caller forgot to pass one side.
public struct ImportedConversation: Sendable {
    public let session: ChatSession
    public let messages: [ChatMessage]

    public init(session: ChatSession, messages: [ChatMessage]) {
        self.session = session
        self.messages = messages
    }
}

/// Symmetric counterpart to ``ConversationExportFormat``: decodes a `Data`
/// blob produced by an export and reconstructs the session + messages.
///
/// Implementations throw on malformed input — callers should present a
/// user-facing error message rather than silently discarding the import.
public protocol ConversationImportFormat: Sendable {

    /// Decodes `data` into a session and its ordered messages.
    ///
    /// - Parameter data: Raw bytes of a previously-exported conversation.
    /// - Returns: The decoded session and messages in chronological order.
    /// - Throws: A typed import error on empty data, malformed structure,
    ///   or missing required fields. Never `try?` — the error surface is
    ///   the caller's only signal that the file is corrupt or wrong format.
    func decode(_ data: Data) throws -> ImportedConversation
}
