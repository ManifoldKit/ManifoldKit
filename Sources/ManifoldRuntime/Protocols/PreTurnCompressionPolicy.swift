import Foundation
import ManifoldInference

/// Decides when and how to compress conversation history before the user
/// message is appended for a `.send` turn.
///
/// The runtime calls
/// ``shouldCompressBeforeTurn(messageCount:lastPromptTokens:)`` at the start
/// of each `.send` turn, before the new user record is inserted into the store.
/// When it returns `true`, the runtime calls
/// ``compressBeforeTurn(history:sessionID:generate:)``, replaces the stored
/// messages with the result, emits
/// ``ConversationEvent/historyCompressed(sessionID:insertedRecords:)``, then
/// calls ``postCompressBeforeTurn(sessionID:insertedRecords:)``, and *then*
/// appends the new user message. The just-submitted user action is therefore
/// always outside the compressed segment.
///
/// Pre-turn compression adds inference latency before the user's message
/// appears in the UI — the `generate:` closure is called as part of turn
/// setup, before the user message is persisted. Implementations should design
/// ``shouldCompressBeforeTurn(messageCount:lastPromptTokens:)`` to return
/// `false` when context utilisation is low so the latency is paid only when
/// necessary.
///
/// ## Applies to `.send` only
///
/// Pre-turn compression runs for new `.send` turns only. It does not run for
/// `.regenerate`, `.edit`, or `.branch` turns because those flows mutate
/// existing history rather than appending a new user action.
///
/// ## Error policy
///
/// Failures from ``compressBeforeTurn(history:sessionID:generate:)`` — or an
/// empty return value — throw
/// ``ConversationError/preTurnCompressionFailed(_:)`` to the caller of
/// ``ConversationRuntime/processTurn(_:)``. Existing history is preserved when
/// a failure occurs. Unlike post-turn compression (which logs and continues),
/// pre-turn failure aborts the turn because the host's ordering invariant
/// depends on compression completing before the new message is appended.
///
/// ## Example
///
/// ```swift
/// struct StoryCompressionPolicy: PreTurnCompressionPolicy {
///     func shouldCompressBeforeTurn(messageCount: Int, lastPromptTokens: Int?) -> Bool {
///         messageCount >= 20
///     }
///
///     func compressBeforeTurn(
///         history: [ChatMessageRecord],
///         sessionID: UUID,
///         generate: @Sendable ([ChatMessageRecord]) async throws -> String
///     ) async throws -> [ChatMessageRecord] {
///         let summary = try await generate(history)
///         return [ChatMessageRecord(
///             role: .system,
///             content: summary,
///             sessionID: sessionID,
///             kind: .memory("story-summary")
///         )]
///     }
/// }
/// ```
public protocol PreTurnCompressionPolicy: Sendable {
    /// Returns `true` if the runtime should compress history before this turn.
    ///
    /// Called synchronously before user-message append. Avoid I/O here —
    /// use `messageCount` and `lastPromptTokens` for lightweight threshold
    /// logic.
    ///
    /// - Parameters:
    ///   - messageCount: Number of messages in the session's current history
    ///     (not including the user message about to be submitted).
    ///   - lastPromptTokens: Prompt-token count recorded on the most recent
    ///     assistant message, or `nil` if no prior turn has recorded usage.
    func shouldCompressBeforeTurn(messageCount: Int, lastPromptTokens: Int?) -> Bool

    /// Compresses the current message history and returns the replacement
    /// record set.
    ///
    /// The history provided does **not** include the user message being
    /// submitted this turn. Return the full desired history state — the
    /// runtime replaces the session's stored messages with the returned array
    /// in a bulk delete + re-insert. Returning an empty array throws
    /// ``ConversationError/preTurnCompressionFailed(_:)`` to guard against
    /// silently wiping the conversation.
    ///
    /// - Parameters:
    ///   - history: Current full message history, oldest-first, *without* the
    ///     user message being submitted this turn.
    ///   - sessionID: The session being compressed.
    ///   - generate: Calls the inference backend; receives messages as a
    ///     mini-conversation and returns the model's accumulated text output.
    func compressBeforeTurn(
        history: [ChatMessageRecord],
        sessionID: UUID,
        generate: @Sendable ([ChatMessageRecord]) async throws -> String
    ) async throws -> [ChatMessageRecord]

    /// Called after history has been compressed and the replacement records
    /// have been persisted, immediately before the user message is inserted.
    ///
    /// Implementations use this for post-compression side effects (e.g.
    /// reconciling a knowledge graph with the inserted memory records).
    /// The default implementation is a no-op.
    ///
    /// - Parameters:
    ///   - sessionID: The session that was compressed.
    ///   - insertedRecords: The full replacement record set, in insertion order.
    func postCompressBeforeTurn(sessionID: UUID, insertedRecords: [ChatMessageRecord]) async
}

extension PreTurnCompressionPolicy {
    public func postCompressBeforeTurn(sessionID: UUID, insertedRecords: [ChatMessageRecord]) async {}
}
