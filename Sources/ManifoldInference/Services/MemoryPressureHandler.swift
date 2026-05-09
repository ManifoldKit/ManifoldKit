import Foundation
import Observation

// MARK: - Memory Pressure Level

public enum MemoryPressureLevel: String, Sendable {
    /// System memory is comfortable. Normal operation.
    case nominal
    /// System memory is getting tight. Pause heavy work (e.g., token generation).
    case warning
    /// System memory is critically low. Unload the model to avoid being killed.
    case critical
}

// MARK: - Memory Pressure Handler

/// Monitors OS-level memory pressure and exposes the current level so ViewModels
/// can react (pause generation on `.warning`, unload the model on `.critical`).
///
/// Uses `DispatchSource.makeMemoryPressureSource`, which works identically on iOS and macOS.
///
/// In addition to the `@Observable` `pressureLevel` property (for SwiftUI / MainActor
/// consumers), backends can register a callback via `addPressureCallback(_:)` that
/// fires **synchronously on the GCD dispatch queue** before the MainActor hop. This
/// lets `LlamaBackend` call `stopGeneration()` — an atomic, thread-safe operation —
/// immediately when pressure is detected, rather than waiting for the next run-loop
/// cycle. The callback fires from an arbitrary thread; callers must not perform
/// blocking work inside it.
@Observable
package final class MemoryPressureHandler: @unchecked Sendable {

    // MARK: - Published State

    /// The current memory pressure level reported by the OS.
    package internal(set) var pressureLevel: MemoryPressureLevel = .nominal

    // MARK: - Private State

    /// The GCD memory-pressure dispatch source. Retained while monitoring is active.
    private var source: DispatchSourceMemoryPressure?

    /// Serial queue for processing memory pressure events.
    private let queue = DispatchQueue(
        label: ManifoldConfiguration.shared.memoryPressureQueueLabel,
        qos: .utility
    )

    /// Guards `_callbacks` from concurrent mutation.
    private let callbackLock = NSLock()
    /// Registered callbacks keyed by opaque token. Callbacks fire on `queue`.
    private var _callbacks: [ObjectIdentifier: @Sendable (MemoryPressureLevel) -> Void] = [:]

    // MARK: - Lifecycle

    package init() {}

    deinit {
        stopMonitoring()
    }

    // MARK: - Public API

    /// Begins listening for memory pressure notifications from the OS.
    ///
    /// Safe to call multiple times -- subsequent calls are no-ops while monitoring is active.
    package func startMonitoring() {
        guard source == nil else { return }

        let newSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical, .normal],
            queue: queue
        )

        newSource.setEventHandler { [weak self] in
            guard let self else { return }
            let event = newSource.data

            // DispatchSource.MemoryPressureEvent is an OptionSet.
            // Map it to our simpler enum.
            let level: MemoryPressureLevel
            if event.contains(.critical) {
                level = .critical
            } else if event.contains(.warning) {
                level = .warning
            } else {
                level = .nominal
            }

            // Fire registered callbacks synchronously on this queue before the
            // MainActor hop. This lets backends (e.g. LlamaBackend) abort the
            // decode loop immediately, before the OS can escalate further.
            self.fireCallbacks(level: level)

            // Update on main actor so SwiftUI observation triggers correctly.
            Task { @MainActor in
                self.pressureLevel = level
            }
        }

        newSource.setCancelHandler { [weak self] in
            // Ensure we nil out the source on cancellation to allow re-start.
            // Weak capture in the Task prevents sending self across isolation boundaries.
            Task { @MainActor [weak self] in
                self?.source = nil
            }
        }

        source = newSource
        newSource.activate()
    }

    /// Stops listening for memory pressure notifications.
    ///
    /// Safe to call multiple times -- subsequent calls are no-ops if not monitoring.
    package func stopMonitoring() {
        source?.cancel()
        source = nil
    }

    // MARK: - Callback Registration

    /// Registers a callback to be invoked synchronously on the pressure dispatch queue
    /// whenever the pressure level changes.
    ///
    /// The callback fires **before** the `@MainActor` `pressureLevel` update — use
    /// this when latency matters (e.g., stopping the llama.cpp decode loop before the
    /// OS can revoke Metal buffers).
    ///
    /// - Parameters:
    ///   - owner: An object whose lifetime gates the callback. Pass `self` from the
    ///     registering type and use `removeCallback(for:)` in that type's `deinit`.
    ///   - callback: A `@Sendable` closure that receives the new pressure level.
    ///     Must not perform blocking work — it runs on a utility GCD queue.
    package func addPressureCallback(
        for owner: AnyObject,
        _ callback: @escaping @Sendable (MemoryPressureLevel) -> Void
    ) {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        _callbacks[ObjectIdentifier(owner)] = callback
    }

    /// Removes the callback previously registered for `owner`.
    ///
    /// Safe to call from `deinit` — no-op if no callback was registered.
    package func removeCallback(for owner: AnyObject) {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        _callbacks.removeValue(forKey: ObjectIdentifier(owner))
    }

    // MARK: - Private

    /// Fires all registered callbacks with `level`.
    ///
    /// Package-internal so tests can simulate a pressure event without relying on a
    /// real OS `DispatchSource` firing. Takes a snapshot under the lock so callbacks
    /// run outside the critical section, allowing re-entrant `addPressureCallback` /
    /// `removeCallback` calls from within a callback.
    package func fireCallbacks(level: MemoryPressureLevel) {
        // Take a snapshot under the lock so callbacks run outside it.
        callbackLock.lock()
        let snapshot = _callbacks.values.map { $0 }
        callbackLock.unlock()
        for callback in snapshot {
            callback(level)
        }
    }
}
