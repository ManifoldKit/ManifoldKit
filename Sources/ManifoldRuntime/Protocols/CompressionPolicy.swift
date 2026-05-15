import Foundation
import ManifoldInference

/// Decides when and how to compress conversation history.
///
/// The runtime calls ``shouldCompress(promptTokens:contextSize:)`` after each
/// successful generation turn (after hooks). When it returns `true`, the runtime
/// calls ``compress(history:sessionID:generate:)``, replaces the stored
/// messages with the result, and emits ``ConversationEvent/historyCompressed(sessionID:)``.
///
/// Compression failures are logged and do not abort the turn — the existing
/// history is preserved.
///
/// ## Example
///
/// ```swift
/// struct ThresholdCompressionPolicy: CompressionPolicy {
///     let threshold: Double
///
///     func shouldCompress(promptTokens: Int, contextSize: Int) -> Bool {
///         guard contextSize > 0 else { return false }
///         return Double(promptTokens) / Double(contextSize) >= threshold
///     }
///
///     func compress(history: [ChatMessageRecord], sessionID: UUID,
///                   generate: @Sendable ([ChatMessageRecord]) async throws -> String) async throws -> [ChatMessageRecord] {
///         // Build a summarisation prompt from old messages, call generate(),
///         // return summary + recent messages
///         let summary = try await generate(history)
///         let summaryMessage = ChatMessageRecord(role: .assistant, content: summary, sessionID: sessionID)
///         return [summaryMessage]
///     }
/// }
/// ```
public protocol CompressionPolicy: Sendable {
    /// Returns `true` if the runtime should compress history before the next turn.
    ///
    /// - Parameters:
    ///   - promptTokens: Tokens consumed by the last prompt (history + slots).
    ///   - contextSize: Backend context window size. 0 when unknown; treat as "skip compression".
    func shouldCompress(promptTokens: Int, contextSize: Int) -> Bool

    /// Compresses message history and returns the replacement record set.
    ///
    /// The runtime replaces the session's stored messages with the returned
    /// array in a bulk delete + re-insert. Return the full desired history
    /// state, not just a diff.
    ///
    /// - Parameters:
    ///   - history: Current full message history, oldest-first.
    ///   - sessionID: The session being compressed.
    ///   - generate: Calls the inference backend; receives messages as a
    ///     mini-conversation and returns the model's accumulated text output.
    func compress(
        history: [ChatMessageRecord],
        sessionID: UUID,
        generate: @Sendable ([ChatMessageRecord]) async throws -> String
    ) async throws -> [ChatMessageRecord]
}
