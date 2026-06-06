import Foundation
import ManifoldInference

/// Decides when and how to compress conversation history.
///
/// The runtime calls ``shouldCompress(promptTokens:contextSize:contextUtilization:)``
/// after each successful generation turn (after hooks). When it returns `true`, the
/// runtime calls ``compress(history:sessionID:generate:)``, replaces the stored
/// messages with the result, and emits ``ConversationEvent/historyCompressed(sessionID:)``.
///
/// Compression failures are logged and do not abort the turn — the existing
/// history is preserved.
///
/// ## v0.26.0 Migration
///
/// The `shouldCompress` signature gained a `contextUtilization` parameter in v0.26.0.
/// Update your conformance from:
/// ```swift
/// func shouldCompress(promptTokens: Int, contextSize: Int) -> Bool
/// ```
/// to:
/// ```swift
/// func shouldCompress(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool
/// ```
/// Also update `compress(...)` return values to use `kind: .memory("summary")` instead of
/// `role: .system` for summary records — kind-aware filtering keeps them off
/// user-facing exports automatically.
///
/// ## Example
///
/// ```swift
/// struct ThresholdCompressionPolicy: CompressionPolicy {
///     let threshold: Double
///
///     func shouldCompress(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool {
///         guard contextSize > 0 else { return false }
///         return contextUtilization >= threshold
///     }
///
///     func compress(history: [ChatMessage], sessionID: UUID,
///                   generate: @Sendable ([ChatMessage]) async throws -> String) async throws -> [ChatMessage] {
///         // Build a summarisation prompt from old messages, call generate(),
///         // return summary + recent messages
///         let summary = try await generate(history)
///         // Use kind: .memory so summary records don't appear in user-facing exports.
///         let summaryMessage = ChatMessage(
///             role: .system,
///             content: summary,
///             sessionID: sessionID,
///             kind: .memory("summary")
///         )
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
    ///   - contextUtilization: `promptTokens / contextSize`. 0.0 when contextSize is 0.
    func shouldCompress(promptTokens: Int, contextSize: Int, contextUtilization: Double) -> Bool

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
        history: [ChatMessage],
        sessionID: UUID,
        generate: @Sendable ([ChatMessage]) async throws -> String
    ) async throws -> [ChatMessage]

    /// Called after history has been compressed and the replacement records
    /// have been persisted. Implementations use this for post-compression
    /// side effects (e.g. reconciling a knowledge graph with the inserted
    /// memory records).
    ///
    /// The default implementation is a no-op.
    ///
    /// - Parameters:
    ///   - sessionID: The session that was compressed.
    ///   - insertedRecords: The full replacement record set, in insertion order.
    func postCompress(sessionID: UUID, insertedRecords: [ChatMessage]) async
}

extension CompressionPolicy {
    public func postCompress(sessionID: UUID, insertedRecords: [ChatMessage]) async {}
}
