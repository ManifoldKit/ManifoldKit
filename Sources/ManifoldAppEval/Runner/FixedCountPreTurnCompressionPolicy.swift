import Foundation
import ManifoldInference
import ManifoldRuntime

/// A ``PreTurnCompressionPolicy`` that fires after a fixed number of messages
/// have accumulated. Designed for hermetic ``RuntimeScenario`` runs where
/// compression must trigger deterministically without real token-usage data.
///
/// The policy fires at the top of the turn after `compressAfterMessages`
/// messages exist in the session. It returns a single `.system` memory record
/// whose content is a synthetic summary, exercising the full
/// ``ConversationEvent/historyCompressed(sessionID:insertedRecords:)`` path
/// without calling the inference backend for summarisation.
///
/// The `generate` closure supplied by the runtime is intentionally ignored —
/// scripted runs need zero network or model activity for compression.
///
/// ## Thread safety
///
/// Value type — inherits `Sendable` implicitly.
public struct FixedCountPreTurnCompressionPolicy: PreTurnCompressionPolicy {

    /// Number of messages that must exist before compression fires.
    ///
    /// Compression triggers at the start of the turn after `compressAfterMessages`
    /// messages are present — i.e. the *first* turn where `messageCount >=
    /// compressAfterMessages`.
    public let compressAfterMessages: Int

    /// Content written into the synthetic memory record emitted by compression.
    public let summaryContent: String

    public init(
        compressAfterMessages: Int,
        summaryContent: String = "Compressed history summary."
    ) {
        self.compressAfterMessages = compressAfterMessages
        self.summaryContent = summaryContent
    }

    // MARK: - PreTurnCompressionPolicy

    public func shouldCompressBeforeTurn(messageCount: Int, lastPromptTokens: Int?) -> Bool {
        messageCount >= compressAfterMessages
    }

    public func compressBeforeTurn(
        history: [ChatMessage],
        sessionID: UUID,
        systemPrompt: String?,
        generate: @Sendable ([ChatMessage]) async throws -> String
    ) async throws -> [ChatMessage] {
        // Return a single memory record instead of calling `generate` — the
        // scripted backend's turns are pre-assigned to user turns, and consuming
        // one here would mis-align the scripted turn sequence.
        [ChatMessage(
            role: .system,
            content: summaryContent,
            sessionID: sessionID,
            kind: .memory("scripted-compression-summary")
        )]
    }
}
