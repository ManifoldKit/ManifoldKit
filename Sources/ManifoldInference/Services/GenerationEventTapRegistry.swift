import Foundation
import Synchronization

// MARK: - GenerationEventTapRegistry

/// Maintains a mutable collection of `AsyncStream<GenerationEvent>`
/// continuations and fans out each event to every registered consumer.
///
/// Generation-layer counterpart to `ManifoldRuntime`'s
/// `EventTapRegistry<Event>` — deliberately re-implemented here rather than
/// shared, because `ManifoldInference` cannot depend on `ManifoldRuntime`
/// (dependencies flow one way; see AGENTS.md Part 0 §2) and the generic
/// registry lives in the higher layer. This is the fan-out backing
/// ``InferenceService/addGenerationEventTap(bufferingPolicy:)`` (#2206).
///
/// ### Yield-outside-lock invariant
///
/// `broadcast` snapshots the continuation map under the lock, releases the
/// lock, and *then* calls `yield` on each continuation. This is a
/// correctness requirement, not a performance hint:
/// `AsyncStream.Continuation.onTermination` calls back synchronously on the
/// thread that detects stream cancellation, which re-enters `deregister`. If
/// `yield` were called while the lock is held the re-entrant `deregister`
/// would deadlock.
final class GenerationEventTapRegistry: Sendable {
    private let taps = Mutex<[UUID: AsyncStream<GenerationEvent>.Continuation]>([:])

    /// Adds a continuation to the fan-out set and returns the opaque token
    /// needed to remove it later via ``deregister(_:)``.
    func register(_ continuation: AsyncStream<GenerationEvent>.Continuation) -> UUID {
        let id = UUID()
        taps.withLock { $0[id] = continuation }
        return id
    }

    /// Removes the continuation identified by `id` from the fan-out set.
    /// Safe to call from any thread, including from inside a continuation's
    /// `onTermination` handler (see yield-outside-lock invariant above).
    func deregister(_ id: UUID) {
        taps.withLock { _ = $0.removeValue(forKey: id) }
    }

    /// Delivers `event` to every registered continuation.
    ///
    /// Continuations are snapshotted under the lock and then yielded to
    /// outside the lock. See the yield-outside-lock invariant for why this
    /// ordering matters.
    func broadcast(_ event: GenerationEvent) {
        let snapshot = taps.withLock { Array($0.values) }
        for continuation in snapshot {
            continuation.yield(event)
        }
    }

    /// Calls `finish()` on every registered continuation and removes them
    /// all from the registry. Subsequent `broadcast` calls are no-ops.
    ///
    /// Continuations are snapshotted and cleared under the lock, then
    /// finished outside it — same ordering invariant as ``broadcast(_:)``.
    func finishAll() {
        let snapshot = taps.withLock { existing -> [AsyncStream<GenerationEvent>.Continuation] in
            let values = Array(existing.values)
            existing.removeAll()
            return values
        }
        for continuation in snapshot {
            continuation.finish()
        }
    }
}
