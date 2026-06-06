import Foundation
import UniformTypeIdentifiers
import ManifoldInference

/// A pluggable serializer for chat conversations.
///
/// Apps can ship their own format by adopting this protocol — the framework
/// provides ``MarkdownExportFormat`` and ``JSONLExportFormat`` out of the box.
/// Tree-preserving export (branching history) is intentionally out of scope:
/// `messages` is the linear active path. Apps that model branches should pass
/// the materialised path their UI is currently displaying.
public protocol ConversationExportFormat: Sendable {

    /// File extension without the leading dot, e.g. `"md"` or `"jsonl"`.
    var fileExtension: String { get }

    /// Uniform Type Identifier used by `ShareLink` and the system share sheet
    /// to pick a sensible default app for the exported file.
    var contentType: UTType { get }

    /// Serialises the session and its (linear) message history to bytes.
    ///
    /// - Parameters:
    ///   - session: Storage-agnostic snapshot of the chat session.
    ///   - messages: Messages in chronological order. Callers are responsible
    ///     for providing them in that order; formats should not re-sort.
    ///     ``ConversationExporter``'s SwiftData overload relies on
    ///     ``MessageStore/fetchMessages(for:)`` to sort, and the
    ///     pure overload trusts whatever the caller passes.
    /// - Returns: Encoded file contents.
    /// - Throws: Implementations only throw at serialization boundaries
    ///   (e.g. JSON encoder failures). Format-internal invariants should not
    ///   throw — Swift's type system enforces the input shape.
    func export(session: ChatSession, messages: [ChatMessage]) throws -> Data
}
