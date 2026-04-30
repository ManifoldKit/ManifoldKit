import Foundation
import BaseChatRuntime
import BaseChatInference

/// In-memory ``BackgroundTaskScheduler`` for tests.
///
/// `schedule` runs the closure on a detached task immediately, recording the
/// identifier and budget. Tests can drive cancellation either explicitly via
/// ``BackgroundTaskScheduler/cancel(identifier:)`` or by calling
/// ``simulateMemoryBudgetExceeded(identifier:)`` to mimic the watchdog path
/// without actually allocating memory.
///
/// `await waitForFinish(identifier:)` blocks until the recorded task settles,
/// removing the need for fixed sleeps in tests.
///
/// Thread-safe via `NSLock`.
public final class MockBackgroundTaskScheduler: BackgroundTaskScheduler, @unchecked Sendable {

    // MARK: - Recorded Calls

    public struct ScheduledCall: Sendable {
        public let identifier: String
        public let budget: MemoryBudget
    }

    private let lock = NSLock()
    private var _calls: [ScheduledCall] = []
    private var _cancellations: [String] = []
    /// Tasks keyed by identifier, tagged with a monotonic generation so
    /// the worker's self-clean on settle won't evict a newer task that
    /// has already taken over the slot.
    private var _tasks: [String: (generation: UInt64, task: Task<Void, Never>)] = [:]
    private var _nextGeneration: UInt64 = 0

    /// Every call to ``schedule(identifier:budget:work:)``, in order.
    public var calls: [ScheduledCall] {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    /// Every identifier passed to ``cancel(identifier:)``, in order.
    public var cancellations: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _cancellations
    }

    public init() {}

    // MARK: - BackgroundTaskScheduler

    public func schedule(
        identifier: String,
        budget: MemoryBudget,
        work: @Sendable @escaping () async throws -> Void
    ) async {
        // Allocate this run's generation number under the lock so the
        // worker's self-clean can compare against it without racing a
        // newer schedule.
        let generation: UInt64 = lock.withLock {
            _nextGeneration += 1
            return _nextGeneration
        }

        let task = Task.detached { [weak self] in
            do {
                try await work()
            } catch is CancellationError {
                // Expected when tests cancel or simulate budget breach.
            } catch {
                Log.persistence.error(
                    "MockBackgroundTaskScheduler work for \(identifier, privacy: .public) threw: \(error.localizedDescription, privacy: .public)"
                )
            }
            self?.clearIfCurrent(identifier: identifier, generation: generation)
        }

        // Atomic record + replace-if-newer: append the call, swap the new
        // task into the table, then cancel the old task (if any) outside
        // the lock so we never block the lock holder on a Task cancel.
        let prior = lock.withLock { () -> Task<Void, Never>? in
            _calls.append(ScheduledCall(identifier: identifier, budget: budget))
            let prior = _tasks[identifier]?.task
            _tasks[identifier] = (generation, task)
            return prior
        }
        prior?.cancel()
    }

    public func cancel(identifier: String) {
        let task = lock.withLock { () -> Task<Void, Never>? in
            let removed = _tasks.removeValue(forKey: identifier)
            if removed != nil {
                // Only record cancellations that actually cancelled a
                // tracked task. Cancelling an unknown identifier (or one
                // whose work has already finished and self-cleared)
                // shouldn't pollute the test-visible record.
                _cancellations.append(identifier)
            }
            return removed?.task
        }
        task?.cancel()
    }

    /// Removes the slot for `identifier` only if it still points at the
    /// generation that just settled. A newer schedule has a higher
    /// generation and is left in place.
    private func clearIfCurrent(identifier: String, generation: UInt64) {
        lock.withLock {
            if _tasks[identifier]?.generation == generation {
                _tasks.removeValue(forKey: identifier)
            }
        }
    }

    // MARK: - Test Helpers

    /// Simulates the watchdog observing a memory-budget breach for the
    /// in-flight task under `identifier`. The task is cancelled exactly the
    /// way ``DefaultBackgroundTaskScheduler`` would cancel it on a real
    /// `phys_footprint` overrun.
    public func simulateMemoryBudgetExceeded(identifier: String) {
        let task = lock.withLock { _tasks.removeValue(forKey: identifier)?.task }
        task?.cancel()
    }

    /// Awaits the in-flight task for `identifier`. Returns immediately if no
    /// task is recorded under that identifier.
    public func waitForFinish(identifier: String) async {
        let task = lock.withLock { _tasks[identifier]?.task }
        await task?.value
    }
}
