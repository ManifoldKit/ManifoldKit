import Foundation
import os
import Observation

/// Wraps an async stream of generation events with observable lifecycle state.
///
/// Consumers iterate ``events`` for content (tokens, tool calls, usage).
/// The UI observes ``phase`` for lifecycle indicators (connecting, streaming,
/// stalled, retrying, done, failed) without polling or adding lifecycle
/// cases to ``GenerationEvent``.
///
/// When ``idleTimeout`` is set, iterating ``events`` will throw
/// ``CloudBackendError/timeout(_:)`` if no event arrives within the timeout.
/// The phase transitions to `.stalled` before the timeout fires.
///
/// ``setPhase(_:)`` must be called on the `@MainActor`.
@Observable
@MainActor
public final class GenerationStream: Sendable {

    /// The content event stream. Iterate this to receive tokens.
    ///
    /// When ``idleTimeout`` is configured, this stream monitors inter-event
    /// gaps and throws ``CloudBackendError/timeout(_:)`` if the gap exceeds
    /// the timeout. The ``phase`` transitions to `.stalled` at the midpoint
    /// of the timeout to give the UI a chance to show a warning before the
    /// hard timeout fires.
    public nonisolated let events: AsyncThrowingStream<GenerationEvent, Error>

    /// Current lifecycle phase. Observed by the UI via `@Observable`.
    ///
    /// Defaults to `.connecting`; queue-originated streams start at `.queued`
    /// (set by the caller after construction).
    public private(set) var phase: Phase = .connecting

    /// Optional idle timeout. When set, ``events`` will throw
    /// ``CloudBackendError/timeout(_:)`` if no event arrives within this duration.
    public nonisolated let idleTimeout: Duration?

    // MARK: - Phase

    /// Lifecycle phases for a generation stream.
    public enum Phase: Sendable, Equatable {
        /// Request is waiting in the queue for its turn.
        case queued
        /// HTTP request in flight, waiting for first byte.
        case connecting
        /// Backend is loading/pulling a model (e.g. Ollama cold start).
        case loading
        /// Tokens are actively arriving.
        case streaming
        /// No event received for longer than expected.
        case stalled
        /// Connection failed; retrying after backoff.
        case retrying(attempt: Int, of: Int)
        /// Stream completed normally.
        case done
        /// Stream terminated with an error.
        case failed(String)
    }

    // MARK: - Init

    /// Creates a generation stream wrapping the given event source.
    ///
    /// - Parameters:
    ///   - stream: The underlying async throwing stream of generation events.
    ///   - idleTimeout: Optional idle timeout duration. `nil` disables idle detection.
    public nonisolated init(
        _ stream: AsyncThrowingStream<GenerationEvent, Error>,
        idleTimeout: Duration? = nil
    ) {
        self.idleTimeout = idleTimeout

        if let idleTimeout {
            // Use a sendable callback box so we don't need to capture `self`
            // before all stored properties are initialized.
            let stalledCallback = StalledCallback()
            self.events = Self.withIdleTimeout(
                base: stream,
                timeout: idleTimeout,
                onStalled: { stalledCallback.fire() }
            )
            self._stalledCallback = stalledCallback
        } else {
            self.events = stream
            self._stalledCallback = nil
        }

        // Now that self is fully initialized, wire the stalled callback.
        // Hop to MainActor because setPhase is MainActor-isolated.
        _stalledCallback?.handler = { @Sendable [weak self] in
            Task { @MainActor in self?.setPhase(.stalled) }
        }
    }

    /// Deferred callback wired up after init completes.
    @ObservationIgnored
    private let _stalledCallback: StalledCallback?

    // MARK: - Phase Mutation

    /// Updates the lifecycle phase. Must be called on `@MainActor`.
    public func setPhase(_ newPhase: Phase) {
        phase = newPhase
    }

    // MARK: - Idle Timeout

    /// Wraps a base stream with idle-timeout detection using a monitoring task.
    ///
    /// Instead of racing `iterator.next()` against `Task.sleep` in a task group
    /// (which requires capturing a non-Sendable iterator in a @Sendable closure),
    /// this iterates the upstream stream normally and uses a separate monitoring
    /// task that periodically checks elapsed time since the last event.
    ///
    /// The monitor fires `.stalled` at the midpoint and throws at the full timeout.
    private nonisolated static func withIdleTimeout(
        base: AsyncThrowingStream<GenerationEvent, Error>,
        timeout: Duration,
        onStalled: @escaping @Sendable () -> Void
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let clock = ContinuousClock()
                let lastEventInstant = AtomicInstant(clock.now)
                let streamFinished = ManagedAtomic<Bool>(false)

                let stallThreshold = timeout / 2
                // Poll at 1/10th of timeout for responsive detection.
                let pollInterval = timeout / 10

                // Monitor task: periodically checks for idle timeout.
                let monitor = Task {
                    var stalledFired = false
                    while !Task.isCancelled && !streamFinished.load() {
                        try await Task.sleep(for: pollInterval)
                        let elapsed = lastEventInstant.load().duration(to: clock.now)
                        if !stalledFired && elapsed >= stallThreshold {
                            stalledFired = true
                            onStalled()
                        }
                        if elapsed >= timeout {
                            continuation.finish(throwing: CloudBackendError.timeout(timeout))
                            return
                        }
                    }
                }

                defer { monitor.cancel() }

                // Iterate the upstream stream normally — no Sendable capture needed.
                var iterator = base.makeAsyncIterator()
                do {
                    while !Task.isCancelled {
                        guard let event = try await iterator.next() else {
                            streamFinished.store(true)
                            continuation.finish()
                            return
                        }
                        lastEventInstant.store(clock.now)
                        continuation.yield(event)
                    }
                    streamFinished.store(true)
                    continuation.finish()
                } catch {
                    streamFinished.store(true)
                    if error is CancellationError || Task.isCancelled {
                        continuation.finish()
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

// MARK: - Thread-safe Atomics

/// Lock-protected boolean for cross-task signaling.
private final class ManagedAtomic<Value>: @unchecked Sendable {
    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    private var storage: Value

    init(_ initial: Value) {
        storage = initial
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func load() -> Value {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return storage
    }

    func store(_ value: Value) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        storage = value
    }
}

/// Lock-protected ContinuousClock.Instant for cross-task time tracking.
private typealias AtomicInstant = ManagedAtomic<ContinuousClock.Instant>

// MARK: - Stalled Callback

/// A Sendable box that can be captured in a closure before a handler is wired.
/// This breaks the init ordering problem: the closure is created before `self`
/// is available, and the handler is assigned after init completes.
private final class StalledCallback: @unchecked Sendable {
    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    var handler: (@Sendable () -> Void)? {
        get {
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            return _handler
        }
        set {
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            _handler = newValue
        }
    }
    private var _handler: (@Sendable () -> Void)?

    init() {
        lock.initialize(to: os_unfair_lock())
    }

    deinit {
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    func fire() {
        handler?()
    }
}
