import Foundation
import Synchronization

// MARK: - EventTapRegistry

/// Maintains a mutable collection of AsyncStream continuations and fans out
/// each `Event` to every registered consumer.
///
/// Generic over the event type so the same fan-out machinery backs
/// ``ConversationRuntime``'s ``ConversationEvent`` taps as well as the
/// ``ImageGenerationRuntime`` / ``VideoGenerationRuntime`` runtime-event taps.
/// `Event` must be `Sendable` so the buffered continuations are safe to hold
/// across actors.
///
/// ### Yield-outside-lock invariant
///
/// `broadcast` snapshots the continuation map under the lock, releases the
/// lock, and *then* calls `yield` on each continuation. This is a correctness
/// requirement, not a performance hint: `AsyncStream.Continuation.onTermination`
/// calls back synchronously on the thread that detects stream cancellation,
/// which re-enters `deregister`. If `yield` were called while the lock is held
/// the re-entrant `deregister` would deadlock.
final class EventTapRegistry<Event: Sendable>: Sendable {
    private let taps = Mutex<[UUID: AsyncStream<Event>.Continuation]>([:])

    /// Adds a continuation to the fan-out set and returns the opaque token
    /// needed to remove it later via ``deregister(_:)``.
    func register(_ continuation: AsyncStream<Event>.Continuation) -> UUID {
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
    func broadcast(_ event: Event) {
        let snapshot = taps.withLock { Array($0.values) }
        for continuation in snapshot {
            continuation.yield(event)
        }
    }

    /// Calls `finish()` on every registered continuation and removes them all
    /// from the registry. Subsequent `broadcast` calls are no-ops.
    ///
    /// Continuations are snapshotted and cleared under the lock, then finished
    /// outside it — same ordering invariant as ``broadcast(_:)``.
    func finishAll() {
        let snapshot = taps.withLock { existing -> [AsyncStream<Event>.Continuation] in
            let values = Array(existing.values)
            existing.removeAll()
            return values
        }
        for continuation in snapshot {
            continuation.finish()
        }
    }
}
