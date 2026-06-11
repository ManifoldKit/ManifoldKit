import Foundation
import os

// MARK: - MemoryPressureBroadcaster

/// Fan-out relay that delivers ``MemoryPressureEvent`` values to an arbitrary
/// number of independent ``AsyncStream`` subscribers.
///
/// Each call to ``makeStream()`` returns a fresh stream backed by its own
/// continuation. ``send(_:)`` iterates all live continuations under a lock
/// so the caller never needs to coordinate with subscriber count.
///
/// Thread-safety is provided by `OSAllocatedUnfairLock`, which is available
/// on macOS 15 / iOS 18 — the n-1 minimum for this codebase.
package final class MemoryPressureBroadcaster: @unchecked Sendable {

    private struct Registration {
        let key: UUID
        let continuation: AsyncStream<MemoryPressureEvent>.Continuation
    }

    // All mutable state is guarded by `lock`.
    private let lock = OSAllocatedUnfairLock(initialState: [UUID: AsyncStream<MemoryPressureEvent>.Continuation]())

    package init() {}

    // MARK: - Subscriber Creation

    /// Creates a new ``AsyncStream<MemoryPressureEvent>`` and registers its
    /// continuation with this broadcaster.
    ///
    /// The stream finishes automatically when the subscriber lets it go out of
    /// scope (Swift's `AsyncStream` calls the `onTermination` handler, which
    /// removes the continuation from the registry).
    package func makeStream() -> AsyncStream<MemoryPressureEvent> {
        let key = UUID()
        let stream = AsyncStream<MemoryPressureEvent>(bufferingPolicy: .bufferingNewest(64)) { [weak self] continuation in
            guard let self else {
                continuation.finish()
                return
            }
            lock.withLock { continuations in
                continuations[key] = continuation
            }
            continuation.onTermination = { [weak self] _ in
                self?.lock.withLock { continuations in
                    _ = continuations.removeValue(forKey: key)
                }
            }
        }
        return stream
    }

    // MARK: - Broadcast

    /// Sends `event` to every live subscriber.
    package func send(_ event: MemoryPressureEvent) {
        let snapshot = lock.withLock { $0.values.map { $0 } }
        for continuation in snapshot {
            continuation.yield(event)
        }
    }

    // MARK: - Teardown

    /// Finishes all live streams and clears the registry.
    ///
    /// Call from the owning object's `deinit` to allow subscriber tasks to
    /// terminate cleanly rather than waiting forever.
    package func finishAll() {
        let snapshot = lock.withLock { continuations -> [AsyncStream<MemoryPressureEvent>.Continuation] in
            let values = continuations.values.map { $0 }
            continuations.removeAll()
            return values
        }
        for continuation in snapshot {
            continuation.finish()
        }
    }
}
