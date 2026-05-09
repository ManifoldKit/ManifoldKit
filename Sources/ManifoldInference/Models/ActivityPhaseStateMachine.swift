import Foundation

/// Explicit, validated transitions for ``BackendActivityPhase``.
///
/// Before this machine existed, phase mutations were scattered across
/// `ChatViewModel+Generation`, `ChatViewModel+ModelLoading`, and
/// `ChatViewModel+Messages`, each enforcing its own ad-hoc preconditions.
/// That made races like "model load fails while user taps send" fragile —
/// nothing centralised the question "is this transition legal?"
///
/// `ActivityPhaseStateMachine` is the single source of truth for the
/// legal transition graph. Every phase mutation in the view model now
/// goes through ``transition(to:)``, which reports the outcome via
/// ``TransitionResult`` so callers can branch on it.
///
/// ## Illegal-transition policy
///
/// Per `CLAUDE.md`, `assertionFailure` is reserved for true programmer
/// errors with no recovery path. Illegal transitions here are always
/// recoverable — they arise from async races (e.g. a late load-progress
/// callback arriving after cancellation flipped the phase to `.idle`, or
/// a stalled-backend notification landing after the user cancelled). The
/// machine therefore rejects every illegal transition the same way:
/// `phase` is left untouched and the caller receives
/// ``TransitionResult/rejected(from:to:)``. Callers log and move on; the
/// machine never traps.
public struct ActivityPhaseStateMachine: Sendable {

    /// The machine's current phase. Callers mutate this via ``transition(to:)``.
    public private(set) var phase: BackendActivityPhase

    public init(phase: BackendActivityPhase = .idle) {
        self.phase = phase
    }

    /// Result of an attempted transition.
    public enum TransitionResult: Sendable, Equatable {
        /// The transition was applied. `phase` now reflects the new state.
        case applied
        /// No state change occurred — the transition was a same-phase no-op
        /// (e.g. progress update during `.modelLoading`, or token arriving
        /// mid-`.streaming`).
        case unchanged
        /// The transition was rejected as illegal for the current phase.
        case rejected(from: BackendActivityPhase, to: BackendActivityPhase)
    }

    /// Attempt to move to `to`. Returns the outcome so callers can decide
    /// whether to proceed. Rejected transitions leave `phase` unchanged.
    @discardableResult
    public mutating func transition(to: BackendActivityPhase) -> TransitionResult {
        let from = phase
        if Self.isSameStatePhase(from, to) {
            // Progress updates (same case, possibly different payload) are
            // always permitted — they're how the UI mirrors long-running
            // work without hitting the illegal-transition path.
            phase = to
            return from == to ? .unchanged : .applied
        }
        guard Self.isLegalTransition(from: from, to: to) else {
            return .rejected(from: from, to: to)
        }
        phase = to
        return .applied
    }

    /// Static predicate exposed for tests and for callers that want to
    /// check legality without mutating.
    public static func isLegalTransition(
        from: BackendActivityPhase,
        to: BackendActivityPhase
    ) -> Bool {
        // Same-case transitions (e.g. .modelLoading → .modelLoading with a
        // new progress value) are handled separately in `transition(to:)`.
        if isSameStatePhase(from, to) { return true }

        // Universal escapes: cancellation and model swap can happen from
        // any state. `.idle` is always safe (cancel/reset), and the user
        // can always start loading a different model mid-activity — the
        // old activity is cancelled as a side effect at the call site.
        if case .idle = to { return true }
        if case .modelLoading = to { return true }

        switch (from, to) {

        // MARK: From .idle
        case (.idle, .waitingForFirstToken):
            // User tapped send while a model was already loaded.
            return true

        // MARK: From .modelLoading
        case (.modelLoading, .waitingForFirstToken):
            // Rare: a queued send runs the instant a load completes, before
            // the load bridge has flipped to `.idle`. We allow it so the
            // send doesn't have to wait a tick for the idle intermediate.
            return true

        // MARK: From .waitingForFirstToken
        case (.waitingForFirstToken, .streaming),
             (.waitingForFirstToken, .stalled),
             (.waitingForFirstToken, .retrying):
            return true

        // MARK: From .streaming
        case (.streaming, .stalled),
             (.streaming, .retrying):
            return true

        // MARK: From .stalled
        case (.stalled, .streaming),
             (.stalled, .waitingForFirstToken),
             (.stalled, .retrying):
            return true

        // MARK: From .retrying
        case (.retrying, .streaming),
             (.retrying, .waitingForFirstToken),
             (.retrying, .stalled):
            return true

        default:
            return false
        }
    }

    /// Two phases are considered the "same state" if they use the same
    /// enum case even if their associated values differ. Progress updates
    /// inside `.modelLoading` and retry-attempt updates inside `.retrying`
    /// are not real transitions.
    public static func isSameStatePhase(
        _ a: BackendActivityPhase,
        _ b: BackendActivityPhase
    ) -> Bool {
        switch (a, b) {
        case (.idle, .idle),
             (.waitingForFirstToken, .waitingForFirstToken),
             (.streaming, .streaming),
             (.stalled, .stalled):
            return true
        case (.modelLoading, .modelLoading):
            return true
        case (.retrying, .retrying):
            return true
        default:
            return false
        }
    }
}
