import Foundation
import ManifoldInference
import ManifoldRuntime

/// A ``PreTurnCompressionPolicy`` that fires when the *real* prompt-token usage
/// recorded by the previous turn crosses a fraction of the model's context
/// window — not after a fixed message count.
///
/// This is the live-mode counterpart of ``FixedCountPreTurnCompressionPolicy``
/// (#1575). Where the fixed-count policy triggers deterministically on
/// `messageCount` for hermetic CI runs, this policy reads `lastPromptTokens`
/// (recorded on the most recent assistant message by a real backend) and
/// compares it against `contextWindow * triggerFraction`. Compression therefore
/// fires against the genuine context-window pressure of the live conversation.
///
/// `compressBeforeTurn` returns a single `.memory` system record. It does
/// **not** call the supplied `generate` closure: in a scripted ``RuntimeScenario``
/// run the backend's turns are pre-assigned to user turns, so consuming one for
/// summarisation would mis-align the scripted sequence (the same constraint
/// ``FixedCountPreTurnCompressionPolicy`` observes). The *decision* of whether
/// to compress, however, is driven by the real context-window pressure
/// (`lastPromptTokens` vs `contextWindow`), which is what distinguishes this
/// policy from a fixed message-count trigger.
public struct ContextWindowPreTurnCompressionPolicy: PreTurnCompressionPolicy {

    /// The model's usable context window in tokens.
    public let contextWindow: Int

    /// Fraction of ``contextWindow`` that, once the recorded prompt token count
    /// meets or exceeds it, triggers compression. Default `0.5`.
    public let triggerFraction: Double

    /// Fallback message-count threshold used only when no prior turn has
    /// recorded prompt-token usage yet (`lastPromptTokens == nil`). Guarantees
    /// compression still fires in a multi-turn session even if a backend never
    /// reports usage. Default `4` (2 user + 2 assistant).
    public let messageCountFallback: Int

    public init(
        contextWindow: Int,
        triggerFraction: Double = 0.5,
        messageCountFallback: Int = 4
    ) {
        self.contextWindow = contextWindow
        self.triggerFraction = triggerFraction
        self.messageCountFallback = messageCountFallback
    }

    // MARK: - PreTurnCompressionPolicy

    public func shouldCompressBeforeTurn(messageCount: Int, lastPromptTokens: Int?) -> Bool {
        guard let lastPromptTokens else {
            // No usage recorded yet — fall back to a count threshold so a real
            // multi-turn session still exercises compression at least once.
            return messageCount >= messageCountFallback
        }
        let threshold = Int(Double(contextWindow) * triggerFraction)
        return lastPromptTokens >= threshold
    }

    public func compressBeforeTurn(
        history: [ChatMessage],
        sessionID: UUID,
        systemPrompt: String?,
        generate: @Sendable ([ChatMessage]) async throws -> String
    ) async throws -> [ChatMessage] {
        // Deliberately does not call `generate` — see the type doc. The
        // synthetic memory record exercises the full historyCompressed path
        // without disturbing a scripted backend's turn cursor.
        [ChatMessage(
            role: .system,
            content: "Compressed conversation memory (context-window pressure).",
            sessionID: sessionID,
            kind: .memory("context-window-compression-summary")
        )]
    }
}
