import Foundation
import ManifoldInference

/// Diagnostic emitted by a ``HistoryShaper`` when it removes or rewrites a
/// canonical record for prompt visibility.
public struct HistoryShapingDiagnostic: Sendable, Hashable {
    public enum Kind: String, Sendable, Hashable {
        case removed
        case rewritten
        case redacted
    }

    public let messageID: UUID
    public let kind: Kind
    public let reason: String?

    public init(
        messageID: UUID,
        kind: Kind,
        reason: String? = nil
    ) {
        self.messageID = messageID
        self.kind = kind
        self.reason = reason
    }
}

/// Request metadata passed to a ``HistoryShaper``.
///
/// The runtime resolves ``appData`` first, then invokes the shaper on the
/// canonical persisted history for the upcoming turn. The shaper's output
/// becomes the prompt-visible base history that ``HistoryProvider`` and prompt
/// context providers consume; canonical persistence is not mutated.
public struct HistoryShapingRequest: Sendable {
    public let turnContextRequest: TurnContextBuildRequest
    public let appData: (any Sendable)?

    public init(
        turnContextRequest: TurnContextBuildRequest,
        appData: (any Sendable)?
    ) {
        self.turnContextRequest = turnContextRequest
        self.appData = appData
    }
}

/// Result returned by a ``HistoryShaper``.
public struct HistoryShapingResult: Sendable {
    public let promptHistory: [ChatMessage]
    public let diagnostics: [HistoryShapingDiagnostic]

    public init(
        promptHistory: [ChatMessage],
        diagnostics: [HistoryShapingDiagnostic] = []
    ) {
        self.promptHistory = promptHistory
        self.diagnostics = diagnostics
    }
}

/// Shapes canonical persisted history into prompt-visible base history.
///
/// This seam is distinct from ``HistoryProvider``: shapers may remove or
/// rewrite existing canonical records for prompt visibility, while
/// ``HistoryProvider`` remains additive-only. The runtime validates that the
/// shaped history preserves canonical record identity and order for every
/// record that remains visible.
public protocol HistoryShaper: Sendable {
    func shape(
        history: [ChatMessage],
        request: HistoryShapingRequest
    ) async throws -> HistoryShapingResult
}
