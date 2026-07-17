import Foundation
import ManifoldInference

/// Decides when and how to compress conversation history.
///
/// The runtime calls ``shouldCompress(promptTokens:contextSize:contextUtilization:)``
/// after each successful generation turn (after hooks). When it returns `true`, the
/// runtime calls ``compress(history:sessionID:systemPrompt:generate:)``, replaces the stored
/// messages with the result, and emits ``ConversationEvent/historyCompressed(sessionID:)``.
///
/// Compression failures are logged and do not abort the turn — the existing
/// history is preserved.
///
/// ## Per-message pins (#2204)
///
/// `compress(history:sessionID:systemPrompt:generate:)` still passes only a
/// `[ChatMessage]`, the `sessionID`, and the `systemPrompt` — **not** the set
/// of user-pinned message IDs — because threading a pinned-ID set through
/// this protocol's signature would be a breaking change to every conformance,
/// not just `DefaultCompressionPolicy`. Instead, ``DefaultCompressionPolicy``'s
/// strategy factories (`.anchored`, `.extractive`, `.truncating`) accept an
/// `isPinned` predicate at construction time, resolved fresh on every
/// `compress` call and honored alongside `.system`-role and `.memory`-kind
/// records as load-bearing. A custom `CompressionPolicy` conformance that is
/// not `DefaultCompressionPolicy` must still capture whatever pin source it
/// needs itself.
///
/// ## v0.72.0 Migration — `systemPrompt` parameter (#1957)
///
/// `compress` gained a `systemPrompt: String?` parameter in v0.72.0 so a
/// conformance can size its budget against what is actually sent on the wire,
/// instead of guessing an allowance for the session's system prompt. Update:
/// ```swift
/// func compress(history: [ChatMessage], sessionID: UUID,
///               generate: @Sendable ([ChatMessage]) async throws -> String) async throws -> [ChatMessage]
/// ```
/// to:
/// ```swift
/// func compress(history: [ChatMessage], sessionID: UUID, systemPrompt: String?,
///               generate: @Sendable ([ChatMessage]) async throws -> String) async throws -> [ChatMessage]
/// ```
/// The tokenizer used to size that budget stays **construction-injected**
/// (unchanged) — pass a real `tokenizer:` to ``DefaultCompressionPolicy``'s
/// factories; there is no call-time tokenizer override. `systemPrompt` is
/// `nil` when the session has no system prompt configured or it could not be
/// resolved; treat `nil` the same as an empty string.
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
///     func compress(history: [ChatMessage], sessionID: UUID, systemPrompt: String?,
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
    ///   - systemPrompt: The session's resolved system prompt, or `nil` when
    ///     none is configured. Not part of `history` — size the budget
    ///     against its real token cost rather than a static allowance (#1957).
    ///   - generate: Calls the inference backend; receives messages as a
    ///     mini-conversation and returns the model's accumulated text output.
    func compress(
        history: [ChatMessage],
        sessionID: UUID,
        systemPrompt: String?,
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
