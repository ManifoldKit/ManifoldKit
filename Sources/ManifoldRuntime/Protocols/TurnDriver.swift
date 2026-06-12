import Foundation
import ManifoldInference

// MARK: - TurnDriver
//
// P3a: the pluggable strategy that decides *how* a goal becomes turns/steps.
// `ConversationRuntime` stays the public conversation API. Internally it
// delegates the per-turn machinery to a `TurnDriver` conformer.
//
// Today there is exactly one conformer: `SingleTurnDriver`, which reproduces
// the linear send/regenerate/edit/branch behavior that existed before this
// seam. Behavior-preserving: golden transcripts must diff clean against the
// P0c snapshots.
//
// `ResumableRunDriver` (P3b) is the second shipped conformer, and it is
// built on the same seam. Adding a future driver (multi-agent, plan-execute)
// is EDGE — conform `TurnDriver`, 0 engine-core edits. Invariant 7.

/// The pluggable strategy for executing a ``TurnInput`` within a
/// ``ConversationRuntime``.
///
/// Conform this protocol to add a new execution strategy without modifying
/// the orchestration core. Adding a driver is EDGE — zero engine-core edits
/// required. ``SingleTurnDriver`` is the default and reproduces the linear
/// single-turn behavior. ``ResumableRunDriver`` enables long-running,
/// checkpointed, resumable runs.
///
/// ## Visibility
///
/// `TurnDriver` is `package` rather than `public` because its `executeTurn`
/// method references ``ConversationTurnExecutor`` and
/// ``ConversationTurnTaskRegistry``, which are package-internal types. The
/// seam can be widened to `public` in a future phase once those types are
/// surfaced. In the meantime, custom driver conformers live within the
/// ManifoldKit package boundary.
///
/// ## Concurrency
///
/// Implementations must be `Sendable`. The runtime calls `executeTurn` from a
/// concurrent context (inside a detached task). Drivers that need per-turn
/// mutable state should use an `actor` or `OSAllocatedUnfairLock`.
package protocol TurnDriver: Sendable {

    /// Executes the turn described by `input` and returns a handle when the
    /// flow drives generation, or `nil` when it does not (e.g. branch without
    /// generation, edit of a non-user message).
    ///
    /// The driver is responsible for all aspects of the turn that fall within
    /// its strategy boundary: context assembly, enqueue, stream consumption,
    /// persistence, and event emission. The orchestration core owns the public
    /// verb API and the event fan-out; the driver owns the mechanics.
    ///
    /// Throwing from this method aborts the turn with an `errorRaised` event.
    func executeTurn(
        _ input: TurnInput,
        executor: ConversationTurnExecutor,
        taskRegistry: ConversationTurnTaskRegistry,
        outcomeCompletion: ConversationTurnOutcomeCompletion?
    ) async throws -> ConversationStreamHandle?
}
