import Foundation
import ManifoldInference

// MARK: - RunStatus

/// The lifecycle state of a ``ConversationRun``.
///
/// Transitions:
///   `pending` → `running` → `paused` → `running` (resume) → `completed`
///                         → `cancelled`
///                         → `failed`
///   `running` → `completed`
///   `running` → `cancelled`
///   `running` → `failed`
package enum RunStatus: String, Sendable, CaseIterable, Equatable {
    /// Created but not yet started.
    case pending
    /// Actively executing steps.
    case running
    /// Execution suspended; can be resumed.
    case paused
    /// All steps completed successfully.
    case completed
    /// Explicitly stopped by the host or user.
    case cancelled
    /// Terminated by an unrecoverable error.
    case failed
}

// MARK: - ConversationRun

/// A multi-step unit above a ``ConversationRuntime`` turn.
///
/// A `ConversationRun` groups one or more ``RunStep`` values into a
/// checkpointed execution unit. The ``RunStore`` port persists the run
/// record and each step on every boundary so the run's progress is durable.
///
/// - Note: In-process pause/resume/cancel ship in this phase (P3b) via
///   ``ResumableRunDriver``. Cross-process resume — reloading an interrupted
///   run from ``RunStore`` and continuing from the last checkpointed step —
///   requires the SwiftData `RunStore` adapter that is deferred to the P3b
///   persistence sub-phase. Until that lands, a process that dies mid-run
///   leaves a durable checkpoint record but does not auto-continue.
///
/// ## Lifecycle
///
/// The host creates a `ConversationRun` with a goal (a text prompt or a
/// structured goal object) and starts it via
/// ``ConversationRuntime/startRun(_:using:)``. The runtime delegates to the
/// wired ``ResumableRunDriver``, which drives the multi-step loop, pausing
/// and checkpointing on each step boundary. The active run can be paused,
/// resumed, or cancelled via the ``ResumableRunDriver`` instance that was
/// injected into the runtime (``ResumableRunDriver/pauseRun()``,
/// ``ResumableRunDriver/resumeRun()``, ``ResumableRunDriver/cancelRun()``).
///
/// ## Identity injection
///
/// IDs and timestamps are constructor-injected so tests can produce
/// deterministic fixtures without special test hooks. Production callers
/// use the `init(sessionID:goal:)` convenience that supplies stable defaults.
package struct ConversationRun: Sendable, Equatable {

    // MARK: Identity

    /// Stable run identifier.
    package let id: UUID

    /// The session this run is executing within.
    package let sessionID: UUID

    // MARK: Goal

    /// The top-level goal or prompt that drives this run.
    /// Persisted verbatim so resume can reconstruct context.
    package let goal: String

    // MARK: Lifecycle

    /// Current status. Mutated by the ``ResumableRunDriver`` as the run
    /// progresses through its lifecycle.
    package var status: RunStatus

    /// Total number of steps taken so far (completed or in-progress).
    package var stepCount: Int

    /// Maximum number of steps allowed. The driver halts with
    /// ``RunStatus/completed`` when this limit is reached, regardless
    /// of whether the goal is fully achieved. `nil` means unlimited.
    package let maxSteps: Int?

    // MARK: Timestamps

    /// When this run record was created.
    package let createdAt: Date

    /// When this run last transitioned to a new status.
    package var updatedAt: Date

    // MARK: Init

    /// Creates a `ConversationRun` with all fields provided.
    ///
    /// Prefer the convenience init for production use; this form is for
    /// test fixtures that need deterministic IDs and timestamps.
    package init(
        id: UUID,
        sessionID: UUID,
        goal: String,
        status: RunStatus = .pending,
        stepCount: Int = 0,
        maxSteps: Int? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.sessionID = sessionID
        self.goal = goal
        self.status = status
        self.stepCount = stepCount
        self.maxSteps = maxSteps
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Creates a new pending `ConversationRun` with stable defaults for
    /// production use.
    package init(
        sessionID: UUID,
        goal: String,
        maxSteps: Int? = nil
    ) {
        let now = Date()
        self.init(
            id: UUID(),
            sessionID: sessionID,
            goal: goal,
            status: .pending,
            stepCount: 0,
            maxSteps: maxSteps,
            createdAt: now,
            updatedAt: now
        )
    }
}

// MARK: - RunStep

/// A single step within a ``ConversationRun``.
///
/// Each step corresponds to one ``ConversationRuntime`` turn (a send, tool
/// call, follow-up, etc.). The ``ResumableRunDriver`` inserts a step record
/// before executing the turn and updates it when the turn completes, so the
/// ``RunStore`` always reflects the current execution state.
///
/// `stepIndex` is 0-based and assigned by the driver at insertion time;
/// within a run, steps are ordered by index ascending.
package struct RunStep: Sendable {

    // MARK: Identity

    /// Stable step identifier.
    package let id: UUID

    /// The run this step belongs to.
    package let runID: UUID

    /// 0-based position of this step within the run.
    package let stepIndex: Int

    // MARK: Content

    /// The turn input that drove this step.
    ///
    /// Persisted so resume can reconstruct what was requested on each step.
    /// `nil` for steps that were derived from the run's own goal (e.g. the
    /// driver synthesised a follow-up without explicit host input).
    package let turnInput: TurnInput?

    /// The ID of the assistant message produced by this step, when one was
    /// persisted. `nil` for steps that did not produce a message (cancelled,
    /// failed before enqueue, or tool-only turns with no assistant text).
    package var messageID: UUID?

    /// Whether this step completed successfully.
    package var isCompleted: Bool

    /// Whether this step failed.
    package var isFailed: Bool

    /// Optional reason string when the step failed.
    package var failureReason: String?

    // MARK: Timestamps

    package let createdAt: Date
    package var updatedAt: Date

    // MARK: Init

    /// Creates a `RunStep` with all fields provided.
    package init(
        id: UUID,
        runID: UUID,
        stepIndex: Int,
        turnInput: TurnInput?,
        messageID: UUID? = nil,
        isCompleted: Bool = false,
        isFailed: Bool = false,
        failureReason: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.runID = runID
        self.stepIndex = stepIndex
        self.turnInput = turnInput
        self.messageID = messageID
        self.isCompleted = isCompleted
        self.isFailed = isFailed
        self.failureReason = failureReason
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Creates a new `RunStep` with stable defaults for production use.
    package init(
        runID: UUID,
        stepIndex: Int,
        turnInput: TurnInput?
    ) {
        let now = Date()
        self.init(
            id: UUID(),
            runID: runID,
            stepIndex: stepIndex,
            turnInput: turnInput,
            messageID: nil,
            isCompleted: false,
            isFailed: false,
            failureReason: nil,
            createdAt: now,
            updatedAt: now
        )
    }
}
