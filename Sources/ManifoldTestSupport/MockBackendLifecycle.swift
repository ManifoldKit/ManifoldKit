import Foundation
import ManifoldInference

/// Composition helper that unifies the `Task` + cancellation + state-lock
/// dance every test mock backend used to hand-roll.
///
/// Three test mock backends (`ChaosBackend`, `PerceivedLatencyBackend`,
/// `SlowMockBackend`) all need the same lifecycle plumbing around their
/// `generate()` implementation:
///
/// - kick off an `AsyncThrowingStream` whose continuation is fed by a `Task`
/// - wire `continuation.onTermination` so a dropped consumer cancels the task
/// - record the task so an external `cancelGeneration()` can stop it
/// - clear the slot when the task finishes naturally
/// - flip the per-backend `_isGenerating` flag back to `false` once the body
///   returns, regardless of whether it threw, finished, or was cancelled
///
/// The body closure is responsible for the actual token production. The
/// `onFinish` closure is the per-backend "I'm done generating" signal. The
/// helper does not hold any lock while invoking it — each conformer is
/// responsible for acquiring its own `NSLock` (or other state-lock
/// discipline) inside the closure if it needs one.
///
/// ## Termination ordering
///
/// `body()` runs to completion → `onFinish()` fires → `continuation.finish()`
/// is called → the slot is cleared (only if it still holds *this* task).
/// `onFinish` runs *before* `continuation.finish()` so that consumers
/// iterating `events` see the `isGenerating == false` state before their
/// `for try await` loop exits — matching the original
/// `defer { finishGeneration() }` ordering. The identity-aware clear means
/// a re-entrant `makeStream` call from inside `onFinish` (which sets a new
/// task in the slot) is not clobbered by the original task's cleanup.
///
/// ## Why a class, not a `@MainActor` protocol
///
/// The conformer classes are `final class @unchecked Sendable` with
/// non-`@MainActor` `deinit`s. A `@MainActor protocol ... { var generationTask:
/// Task<Void, Never>? { get set } }` would (a) be unsatisfiable by stored
/// properties on non-`@MainActor` classes under Swift 6 strict concurrency,
/// (b) make the existing `deinit` cancellation illegal, and (c) collide with
/// the existing `NSLock` discipline. Composition keeps each backend's
/// concurrency story intact.
package final class MockBackendLifecycle: @unchecked Sendable {
    private let stateLock = NSLock()
    private var generationTask: Task<Void, Never>?

    package init() {}

    /// Records the active generation task. Replaces any previously recorded
    /// task without cancelling it — callers are expected to clear the slot
    /// from inside the task's own completion block.
    package func setTask(_ task: Task<Void, Never>) {
        stateLock.lock()
        defer { stateLock.unlock() }
        generationTask = task
    }

    /// Drops the recorded task reference. Called from the task's own
    /// completion path so back-to-back `makeStream` calls never see a
    /// stale slot.
    package func clearTask() {
        stateLock.lock()
        defer { stateLock.unlock() }
        generationTask = nil
    }

    /// Identity-aware clear: only drops the slot if the recorded task is
    /// still `task`. Used by `makeStream`'s completion path so a re-entrant
    /// `makeStream` call from inside `onFinish` (which sets a new task in
    /// the slot) is not clobbered by the original task's cleanup.
    private func clearTaskIfMatches(_ task: Task<Void, Never>) {
        stateLock.lock()
        defer { stateLock.unlock() }
        if generationTask == task {
            generationTask = nil
        }
    }

    /// Test-only: reports whether the task slot is currently occupied.
    /// Used by `MockBackendLifecycleTests` to prove the slot is cleared
    /// on the natural completion path.
    package var hasActiveTask: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generationTask != nil
    }

    /// Cancels the recorded task and clears the slot. Safe to call from
    /// `deinit` (the lock is released before `task.cancel()` so the task's
    /// own state-flip cannot deadlock).
    package func cancel() {
        stateLock.lock()
        let task = generationTask
        generationTask = nil
        stateLock.unlock()
        task?.cancel()
    }

    /// Builds a `GenerationStream` whose underlying task runs `body` and
    /// then signals completion via `onFinish`.
    ///
    /// - Parameters:
    ///   - onFinish: Per-backend "generation finished" signal. Runs inside
    ///     the underlying task on the same hop as `body`'s natural exit,
    ///     and runs *before* the stream's continuation is finished so that
    ///     consumers see the post-generation state on their last awaited
    ///     iteration. Always fires exactly once after `body` returns —
    ///     including when `body` terminates the stream early via
    ///     `continuation.finish(throwing:)` (as `ChaosBackend` does for its
    ///     mid-stream failure modes) or when the body returns early after
    ///     observing `Task.isCancelled`.
    ///   - body: The token-producing closure. It owns yielding events and
    ///     handling cancellation. It may finish the continuation early via
    ///     `continuation.finish(throwing:)` to surface an error, but must
    ///     not call `continuation.finish()` (without an error) itself — the
    ///     helper does that after the closure returns.
    package func makeStream(
        onFinish: @escaping @Sendable () -> Void,
        body: @escaping @Sendable (AsyncThrowingStream<GenerationEvent, Error>.Continuation) async -> Void
    ) -> GenerationStream {
        let stream = AsyncThrowingStream<GenerationEvent, Error> { [weak self] continuation in
            // Hold the task in a Sendable box so the task body can refer to
            // its own identity for the identity-aware clear below.
            let taskBox = TaskBox()
            let task = Task { [weak self] in
                await body(continuation)
                // Signal finish *before* closing the stream so the consumer
                // sees the post-generation state on its last iteration —
                // matches the original `defer { finishGeneration() }` order.
                onFinish()
                continuation.finish()
                if let t = taskBox.task {
                    self?.clearTaskIfMatches(t)
                }
            }
            taskBox.task = task
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
            self?.setTask(task)
        }
        return GenerationStream(stream)
    }
}

/// Tiny one-shot box so a Task's body can recover its own `Task` identity
/// for the identity-aware clear in `makeStream`. Safe under
/// `@unchecked Sendable` because the only writer is the synchronous
/// `AsyncThrowingStream` builder closure — by the time the task body reads
/// `task`, the write has happened-before via task creation.
private final class TaskBox: @unchecked Sendable {
    var task: Task<Void, Never>?
}
