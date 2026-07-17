// MARK: - GenerationEventKind

/// The kind of a ``GenerationEvent``, stripped of associated values.
///
/// Generation-layer counterpart to `ManifoldRuntime`'s
/// `ConversationEventKind`. Used as the stable key in JSONL trace files
/// written by ``GenerationEventTrace`` and as the discriminant for
/// generation-level event-subsequence assertions — the direct-
/// `InferenceService` tap introduced for #2206, so apps that drive
/// `InferenceService` without adopting `ConversationRuntime` can still
/// produce a Glass-Box-shaped trace (see ``GenerationEventRecorder``).
///
/// ## Wire-contract posture
///
/// Mirrors `ConversationEventKind`'s posture: the `String` raw value of
/// every existing case is a **persisted JSONL trace contract** and must
/// remain decodable — never renamed or renumbered, even in a MAJOR release.
/// New kinds are **append-only**, added alongside new ``GenerationEvent``
/// cases. Trace **readers** must tolerate an unknown kind string (decode to
/// `nil` / skip the line) rather than throwing, so a trace written by a
/// newer ManifoldKit stays readable by an older reader.
///
/// Note this tracks the *shape* of ``GenerationEvent``, not
/// `ConversationEventKind` — the two vocabularies are related (both surface
/// the same underlying generation activity) but are not the same enum,
/// because `ConversationEvent` lives in `ManifoldRuntime`, a layer above
/// `ManifoldInference`, and cannot be referenced from here (dependencies
/// flow one way — see AGENTS.md Part 0 §2).
public enum GenerationEventKind: String, Codable, Sendable, CaseIterable {
    case prefillProgress
    case promptRendered
    case token
    case usage
    case toolCall
    case toolCallStart
    case toolCallArgumentsDelta
    case thinkingToken
    case thinkingCompleted
    case thinkingSignature
    case toolIterationLimitExceeded
    case runTokenBudgetExceeded
    case toolResult
    case toolProgress
    case kvCacheReuse
    case throttleDiagnostic
    case toolCallParseFailed
    case toolCallTruncated
    case toolDispatchStarted
    case toolCallApproved
    case toolDispatchCompleted
    case handoffRequested
    case generationCompleted
}

// MARK: - Kind

extension GenerationEvent {

    /// The kind of this event, stripped of associated values.
    ///
    /// Used as the stable discriminant in ``GenerationEventTrace`` JSONL
    /// output and by consumers scanning a recorded trace for an ordered
    /// event subsequence.
    public var kind: GenerationEventKind {
        switch self {
        case .prefillProgress:            return .prefillProgress
        case .promptRendered:             return .promptRendered
        case .token:                      return .token
        case .usage:                      return .usage
        case .toolCall:                   return .toolCall
        case .toolCallStart:              return .toolCallStart
        case .toolCallArgumentsDelta:     return .toolCallArgumentsDelta
        case .thinkingToken:              return .thinkingToken
        case .thinkingCompleted:          return .thinkingCompleted
        case .thinkingSignature:          return .thinkingSignature
        case .toolIterationLimitExceeded: return .toolIterationLimitExceeded
        case .runTokenBudgetExceeded:     return .runTokenBudgetExceeded
        case .toolResult:                 return .toolResult
        case .toolProgress:               return .toolProgress
        case .kvCacheReuse:               return .kvCacheReuse
        case .throttleDiagnostic:         return .throttleDiagnostic
        case .toolCallParseFailed:        return .toolCallParseFailed
        case .toolCallTruncated:          return .toolCallTruncated
        case .toolDispatchStarted:        return .toolDispatchStarted
        case .toolCallApproved:           return .toolCallApproved
        case .toolDispatchCompleted:      return .toolDispatchCompleted
        case .handoffRequested:           return .handoffRequested
        case .generationCompleted:        return .generationCompleted
        }
    }
}
