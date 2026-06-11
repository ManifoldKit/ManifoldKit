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
public enum RunStatus: String, Sendable, CaseIterable, Equatable {
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
/// resumable, checkpointed execution unit. Runs survive app suspension:
/// the ``RunStore`` port persists the run record and each step so the
/// ``ResumableRunDriver`` can pick up exactly where it left off.
///
/// ## Lifecycle
///
/// The host creates a `ConversationRun` with a goal (a text prompt or a
/// structured goal object) and starts it via
/// ``ConversationRuntime/startRun(_:)``. The runtime delegates to the
/// wired ``ResumableRunDriver``, which drives the multi-step loop, pausing
/// and checkpointing on each step boundary. Runs can be paused,
/// resumed, or cancelled at any time via the runtime's run API.
///
/// ## Identity injection
///
/// IDs and timestamps are constructor-injected so tests can produce
/// deterministic fixtures without special test hooks. Production callers
/// use the `init(sessionID:goal:)` convenience that supplies stable defaults.
public struct ConversationRun: Sendable, Equatable {

    // MARK: Identity

    /// Stable run identifier.
    public let id: UUID

    /// The session this run is executing within.
    public let sessionID: UUID

    // MARK: Goal

    /// The top-level goal or prompt that drives this run.
    /// Persisted verbatim so resume can reconstruct context.
    public let goal: String

    // MARK: Lifecycle

    /// Current status. Mutated by the ``ResumableRunDriver`` as the run
    /// progresses through its lifecycle.
    public var status: RunStatus

    /// Total number of steps taken so far (completed or in-progress).
    public var stepCount: Int

    /// Maximum number of steps allowed. The driver halts with
    /// ``RunStatus/completed`` when this limit is reached, regardless
    /// of whether the goal is fully achieved. `nil` means unlimited.
    public let maxSteps: Int?

    // MARK: Timestamps

    /// When this run record was created.
    public let createdAt: Date

    /// When this run last transitioned to a new status.
    public var updatedAt: Date

    // MARK: Init

    /// Creates a `ConversationRun` with all fields provided.
    ///
    /// Prefer the convenience init for production use; this form is for
    /// test fixtures that need deterministic IDs and timestamps.
    public init(
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
    public init(
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
public struct RunStep: Sendable {

    // MARK: Identity

    /// Stable step identifier.
    public let id: UUID

    /// The run this step belongs to.
    public let runID: UUID

    /// 0-based position of this step within the run.
    public let stepIndex: Int

    // MARK: Content

    /// The turn input that drove this step.
    ///
    /// Persisted so resume can reconstruct what was requested on each step.
    /// `nil` for steps that were derived from the run's own goal (e.g. the
    /// driver synthesised a follow-up without explicit host input).
    public let turnInput: TurnInput?

    /// The ID of the assistant message produced by this step, when one was
    /// persisted. `nil` for steps that did not produce a message (cancelled,
    /// failed before enqueue, or tool-only turns with no assistant text).
    public var messageID: UUID?

    /// Whether this step completed successfully.
    public var isCompleted: Bool

    /// Whether this step failed.
    public var isFailed: Bool

    /// Optional reason string when the step failed.
    public var failureReason: String?

    // MARK: Timestamps

    public let createdAt: Date
    public var updatedAt: Date

    // MARK: Init

    /// Creates a `RunStep` with all fields provided.
    public init(
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
    public init(
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
