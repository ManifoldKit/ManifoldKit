import Foundation
import BaseChatInference
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

/// Default ``BackgroundTaskScheduler`` implementation.
///
/// The scheduler runs the caller's closure on a detached `Task` whose
/// lifetime is bookkept against `identifier`. Both iOS and macOS execute
/// the closure in-process — there is no `BGTaskScheduler.register(...)`
/// launch handler, so the closure does **not** survive process termination
/// and will not be relaunched by the OS later. On iOS the scheduler also
/// submits a best-effort `BGProcessingTaskRequest` so that, if a host app
/// later registers a launch handler under the same identifier, the OS has
/// the request queued. Until that handler exists, treat this type as an
/// in-process scheduler with a memory-budget watchdog, not as a true
/// background-execution bridge.
///
/// Both paths enforce the configured ``MemoryBudget``: a watchdog samples
/// the process footprint on the budget's `sampleInterval` and cancels the
/// running task when the ceiling is breached. The closure observes the
/// cancellation through the standard `Task.isCancelled` channel.
///
/// `BGTaskScheduler` requires task identifiers to be registered in the host
/// app's `Info.plist`; see ``BaseChatBackgroundTaskIdentifiers`` for the
/// recommended strings. Apps that have not registered the identifier they
/// schedule under will see the iOS submission silently fail; the inline
/// run path still executes the closure so behaviour stays identical to
/// macOS in development builds.
///
/// The implementation is `@unchecked Sendable` because it serialises
/// access to its in-flight task table behind an `NSLock` — the locked
/// dictionary is the only mutable state.
public final class DefaultBackgroundTaskScheduler: BackgroundTaskScheduler, @unchecked Sendable {

    // MARK: - Memory Sampler

    /// Hook for tests to substitute the real `phys_footprint` reader. The
    /// default uses ``AppMemoryUsage`` so production callers see the same
    /// numbers Xcode's memory gauge reports.
    public typealias MemorySampler = @Sendable () -> UInt64?

    private let memorySampler: MemorySampler

    // MARK: - In-flight Bookkeeping

    private let lock = NSLock()
    private var inFlight: [String: Task<Void, Never>] = [:]

    // MARK: - Init

    public init(memorySampler: MemorySampler? = nil) {
        self.memorySampler = memorySampler ?? { AppMemoryUsage.currentBytes() }
    }

    // MARK: - BackgroundTaskScheduler

    public func schedule(
        identifier: String,
        budget: MemoryBudget,
        work: @Sendable @escaping () async throws -> Void
    ) async {
        let sampler = memorySampler
        let task = Task.detached { [weak self] in
            await Self.runWithBudget(
                identifier: identifier,
                budget: budget,
                memorySampler: sampler,
                work: work
            )
            self?.clear(identifier: identifier)
        }

        // `schedule` as a "replace if newer" primitive: swap the new task
        // into the table atomically so two overlapping calls can't
        // interleave their cancel/insert and leave the older task winning.
        let prior = lock.withLock { () -> Task<Void, Never>? in
            let prior = inFlight[identifier]
            inFlight[identifier] = task
            return prior
        }
        prior?.cancel()

        #if os(iOS)
        submitBGTaskRequest(identifier: identifier)
        #endif
    }

    public func cancel(identifier: String) {
        let task = lock.withLock { inFlight.removeValue(forKey: identifier) }

        task?.cancel()

        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        #endif
    }

    // MARK: - Watchdog

    private static func runWithBudget(
        identifier: String,
        budget: MemoryBudget,
        memorySampler: @escaping MemorySampler,
        work: @Sendable @escaping () async throws -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in

            // Worker: the caller's closure. Cancellation is part of the
            // contract (watchdog + explicit cancel both deliver it as a
            // `CancellationError`); surface anything else through the
            // logging channel so it doesn't disappear.
            group.addTask {
                do {
                    try await work()
                } catch is CancellationError {
                    // Expected on watchdog or explicit cancel.
                } catch {
                    Log.persistence.error(
                        "BackgroundTaskScheduler work for \(identifier, privacy: .public) threw: \(error.localizedDescription, privacy: .public)"
                    )
                }
            }

            // Watchdog: samples memory on `budget.sampleInterval`. When the
            // ceiling is breached, cancels the whole group; the worker
            // observes `Task.isCancelled` and bails on its next checkpoint.
            group.addTask {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: budget.sampleInterval)
                    } catch {
                        return
                    }
                    if let bytes = memorySampler(), bytes > budget.maxBytes {
                        return
                    }
                }
            }

            // Whichever finishes first decides the outcome:
            //   - worker first  → success (or worker-internal cancel); tear down watchdog
            //   - watchdog first → budget breach; cancelling the group cancels the worker
            await group.next()
            group.cancelAll()
        }
    }

    private func clear(identifier: String) {
        lock.withLock { _ = inFlight.removeValue(forKey: identifier) }
    }

    // MARK: - iOS BGTaskScheduler bridge

    #if os(iOS)
    private func submitBGTaskRequest(identifier: String) {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // The most common failure is "identifier not registered in
            // Info.plist". The detached task is still running, so behaviour
            // matches macOS and dev builds remain functional. Production
            // builds that need real background execution must register the
            // identifier — that's a host-app responsibility documented on
            // `BaseChatBackgroundTaskIdentifiers`.
            Log.persistence.warning("BGTaskScheduler.submit failed for \(identifier): \(error.localizedDescription)")
        }
    }
    #endif
}
