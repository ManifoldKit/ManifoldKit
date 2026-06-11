import Foundation
import ManifoldInference

// MARK: - RunEvent
//
// P3b: run-level lifecycle events for ConversationRun.
//
// Per target-architecture.md invariant 6 and target-architecture-migration.md:
//   "run-level events must NOT be added as GenerationEvent cases — they
//    ride their own event type (precedent: ImageRuntimeEvent is deliberately
//    separate from the text-path event vocabulary so exhaustive switches
//    stay closed)."
//
// `RunEvent` is the vocabulary P3 was expected to contribute before the 1.0
// GenerationEvent freeze. It is a sibling to ConversationEvent, not a subset.
// Text-side consumers exhaustively switch over ConversationEvent; adding run
// cases there would push unreachable switch arms into every text consumer.
//
// `ResumableRunDriver` emits these events on the AsyncStream<RunEvent> that
// ConversationRuntime.startRun returns. Text-path consumers that do not care
// about resumable runs never see RunEvent at all.

/// Run-level lifecycle events for ``ConversationRun`` executions.
///
/// Parallel to ``ConversationEvent`` — run-side events are deliberately a
/// separate type so exhaustive switches in text consumers stay closed.
/// ``ResumableRunDriver`` emits these on the ``AsyncStream`` returned by
/// ``ConversationRuntime/startRun(_:)``.
///
/// Invariant: no run-level payload appears as a ``ConversationEvent`` case.
/// ``GenerationEventClosedAuditTest`` enforces this with a tripwire.
public enum RunEvent: Sendable, Equatable {

    /// The run transitioned from `.pending` to `.running`. Fires once per
    /// run, before the first step begins.
    case runStarted(runID: UUID, sessionID: UUID, goal: String)

    /// A step began executing. `stepIndex` is 0-based.
    case stepStarted(runID: UUID, stepIndex: Int, stepID: UUID)

    /// A step completed successfully. `messageID` is the assistant message
    /// persisted by the step, when one was produced.
    case stepCompleted(runID: UUID, stepIndex: Int, stepID: UUID, messageID: UUID?)

    /// A step failed. The run transitions to `.failed` on the first
    /// unrecoverable step failure.
    case stepFailed(runID: UUID, stepIndex: Int, stepID: UUID, reason: String)

    /// The run was paused by the host. The current step index is preserved;
    /// the run can be resumed via ``ConversationRuntime/resumeRun(_:)``.
    case runPaused(runID: UUID, stepCount: Int)

    /// A previously-paused run resumed execution.
    case runResumed(runID: UUID, stepCount: Int)

    /// The run completed. `stepCount` is the total number of completed steps.
    case runCompleted(runID: UUID, stepCount: Int)

    /// The run was cancelled by the host or user.
    case runCancelled(runID: UUID, stepCount: Int)

    /// The run failed due to an unrecoverable error.
    case runFailed(runID: UUID, reason: String)
}
