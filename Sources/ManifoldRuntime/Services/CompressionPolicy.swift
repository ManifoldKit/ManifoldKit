import Foundation
import ManifoldInference

/// Decides whether to compress conversation history and performs the
/// compression when the threshold is crossed.
///
/// ``ConversationTurnExecutor`` calls ``shouldCompress(promptTokens:contextSize:)``
/// at the end of every successful turn. When it returns `true`, the executor
/// calls ``compress(history:sessionID:generate:)`` and replaces the session's
/// messages with the compressed result.
///
/// Implementations must be `Sendable` because the executor is `Sendable` and
/// holds the policy as a stored property.
///
/// - Note: Compression is skipped when token usage is unavailable (`promptTokens`
///   is nil) or when the backend does not report a context size
///   (`contextSize == 0`). The policy is never consulted in those cases.
public protocol CompressionPolicy: Sendable {
    /// Returns `true` when the session history should be compressed.
    ///
    /// - Parameters:
    ///   - promptTokens: Tokens consumed by the prompt on the most recent turn.
    ///   - contextSize: The backend's full context window size in tokens.
    /// - Returns: `true` to trigger compression; `false` to skip.
    func shouldCompress(promptTokens: Int, contextSize: Int) -> Bool

    /// Compresses `history` into a shorter replacement message list.
    ///
    /// The executor calls `generate` to produce summaries via the active
    /// backend. Implementations that don't need summarisation can ignore it.
    ///
    /// - Parameters:
    ///   - history: The full message list for `sessionID` at compression time.
    ///   - sessionID: The session being compressed.
    ///   - generate: A closure that sends `messages` to the backend and returns
    ///     the generated text. May throw if the backend is unavailable.
    /// - Returns: Replacement messages. The executor deletes all existing
    ///   messages and inserts these in order.
    /// - Throws: Propagated to the executor, which logs and skips persistence
    ///   replacement (the original history is preserved).
    func compress(
        history: [ChatMessageRecord],
        sessionID: UUID,
        generate: @Sendable ([ChatMessageRecord]) async throws -> String
    ) async throws -> [ChatMessageRecord]
}
