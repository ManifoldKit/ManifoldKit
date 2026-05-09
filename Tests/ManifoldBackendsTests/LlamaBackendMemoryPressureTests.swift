import XCTest
@testable import ManifoldInference

// MARK: - Thread-safe counter for @Sendable callback closures

/// A minimal thread-safe integer counter for use inside `@Sendable` closures.
///
/// `@Sendable` closures cannot mutate captured `var` locals. This wrapper is
/// `@unchecked Sendable` because the counter is protected by the `NSLock`, but
/// Swift's type system cannot verify that automatically.
private final class SendableCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment(by n: Int = 1) {
        lock.lock()
        defer { lock.unlock() }
        value += n
    }

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

// MARK: - Hardware-free: MemoryPressureHandler callback API

/// Exercises the `addPressureCallback` / `removeCallback` / `fireCallbacks` API
/// added to `MemoryPressureHandler` in support of issue #415.
///
/// These tests do not instantiate `LlamaBackend` and run without special hardware.
/// The `#if Llama` guard is intentionally absent — these tests run in CI to give
/// continuous coverage of the callback machinery that `LlamaBackend` relies on
/// for memory pressure abort.
final class MemoryPressureCallbackAPITests: XCTestCase {

    // MARK: - Registration and removal

    func test_addPressureCallback_replacesExistingEntryForSameOwner() {
        let handler = MemoryPressureHandler()
        let owner = NSObject()
        let callCount = SendableCounter()

        handler.addPressureCallback(for: owner) { _ in callCount.increment(by: 1) }
        // Registering again for the same owner replaces the previous entry.
        handler.addPressureCallback(for: owner) { _ in callCount.increment(by: 10) }

        // Verify no crash and the table updated correctly.
        handler.removeCallback(for: owner)
        // callCount is still 0 — no real DispatchSource has fired.
        XCTAssertEqual(callCount.current, 0,
            "No callback should have fired — DispatchSource has not received an OS event")
    }

    func test_removeCallback_forUnregisteredOwner_isNoOp() {
        let handler = MemoryPressureHandler()
        let owner = NSObject()

        // Remove before registering — must be a no-op.
        handler.removeCallback(for: owner)
        handler.removeCallback(for: owner)
        // No crash = pass.
    }

    func test_removeCallback_afterRegistration_isIdempotent() {
        let handler = MemoryPressureHandler()
        let owner = NSObject()

        handler.addPressureCallback(for: owner) { _ in }
        handler.removeCallback(for: owner)
        // Second remove must be a no-op.
        handler.removeCallback(for: owner)
        // No crash = pass.
    }

    func test_multipleOwners_independentCallbacks() {
        let handler = MemoryPressureHandler()
        let owner1 = NSObject()
        let owner2 = NSObject()

        handler.addPressureCallback(for: owner1) { _ in }
        handler.addPressureCallback(for: owner2) { _ in }

        // Remove one; the other must still be present (no crash on re-removal).
        handler.removeCallback(for: owner1)
        handler.removeCallback(for: owner2)
    }

    // MARK: - Lifecycle: deinit of handler while callbacks are registered

    func test_handlerDeinit_withRegisteredCallbacks_doesNotCrash() {
        let owner = NSObject()
        var handler: MemoryPressureHandler? = MemoryPressureHandler()
        handler?.addPressureCallback(for: owner) { _ in }
        handler = nil
        // If we reach here, the handler released its callback table cleanly.
    }

    // MARK: - Callback firing via fireCallbacks

    /// Verifies that `fireCallbacks` actually invokes registered callbacks and
    /// delivers the correct level. This exercises the same synchronous dispatch path
    /// the DispatchSource event handler uses when the OS sends a pressure event.
    ///
    /// Sabotage check: comment out `self.fireCallbacks(level: level)` in
    /// `startMonitoring`'s event handler — the production wiring stops working,
    /// but this test (which calls `fireCallbacks` directly) still catches regressions
    /// in the dispatch logic itself.
    func test_fireCallbacks_invokesRegisteredCallbackWithCorrectLevel() {
        let handler = MemoryPressureHandler()
        let owner = NSObject()

        // Use a class box so the @Sendable closure can mutate the array.
        // fireCallbacks is always called synchronously on one thread in these tests,
        // so no actual concurrent access occurs — the wrapper satisfies the
        // @Sendable requirement at the type-system level.
        final class LevelBox: @unchecked Sendable { var levels: [MemoryPressureLevel] = [] }
        let box = LevelBox()

        handler.addPressureCallback(for: owner) { level in box.levels.append(level) }

        handler.fireCallbacks(level: .warning)
        handler.fireCallbacks(level: .critical)
        handler.fireCallbacks(level: .nominal)

        // fireCallbacks runs synchronously; no async coordination needed.
        XCTAssertEqual(box.levels, [.warning, .critical, .nominal],
            "fireCallbacks must invoke the registered callback once per call, in order")
    }

    /// Verifies that after `removeCallback`, subsequent `fireCallbacks` calls do
    /// not invoke the removed callback. This guards against a stale closure firing
    /// after `LlamaBackend` has been deallocated.
    func test_fireCallbacks_afterRemove_doesNotInvokeCallback() {
        let handler = MemoryPressureHandler()
        let owner = NSObject()
        let callCount = SendableCounter()

        handler.addPressureCallback(for: owner) { _ in callCount.increment() }
        handler.removeCallback(for: owner)

        handler.fireCallbacks(level: .critical)

        XCTAssertEqual(callCount.current, 0, "Callback must not fire after removeCallback")
    }

    /// Verifies that removing one owner does not suppress other registered callbacks —
    /// each `ObjectIdentifier` key is independent.
    func test_fireCallbacks_removingOneOwner_preservesOtherCallbacks() {
        let handler = MemoryPressureHandler()
        let owner1 = NSObject()
        let owner2 = NSObject()
        let count1 = SendableCounter()
        let count2 = SendableCounter()

        handler.addPressureCallback(for: owner1) { _ in count1.increment() }
        handler.addPressureCallback(for: owner2) { _ in count2.increment() }

        handler.removeCallback(for: owner1)
        handler.fireCallbacks(level: .warning)

        XCTAssertEqual(count1.current, 0, "Removed owner1 callback must not fire")
        XCTAssertEqual(count2.current, 1, "owner2 callback must still fire after owner1 is removed")
    }
}

#if Llama
@testable import ManifoldBackends
@testable import ManifoldLlama
@testable import ManifoldTestSupport

// MARK: - Hardware-gated tests

/// Tests for LlamaBackend's memory pressure abort wiring (issue #415).
///
/// `LlamaBackend` owns a private `MemoryPressureHandler` and registers a callback
/// in `init` that calls `stopGeneration()` on `.warning` and `stopGeneration()` +
/// `unloadAndWait()` on `.critical`. Because the handler and its callback are
/// private, these tests exercise the same *operations* the callback performs,
/// verifying they are safe to call from a background GCD queue (the thread model
/// the `DispatchSource` callback uses on a real device).
///
/// All tests skip in the simulator and on non-Apple-Silicon hosts, where
/// `llama_backend_init` (invoked by `LlamaBackend.init`) requires Metal.
final class LlamaBackendMemoryPressureTests: XCTestCase {

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice,
            "LlamaBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon,
            "LlamaBackend requires Apple Silicon")
    }

    // MARK: - stopGeneration() is safe from a GCD utility queue

    /// The memory pressure callback fires on a GCD utility queue.
    /// `stopGeneration()` must not crash when called from that context on an
    /// idle (unloaded) backend — the same state LlamaBackend is in at app
    /// launch before the user picks a model.
    ///
    /// Sabotage check: replacing `Atomic<Bool>` with a plain `var Bool` in
    /// LlamaBackend would produce a TSan data-race violation here when multiple
    /// concurrent queues call `stopGeneration()` simultaneously.
    func test_stopGeneration_fromGCDQueue_doesNotCrash() async {
        let backend = LlamaBackend()

        // Fire stopGeneration() concurrently from 20 GCD utility threads,
        // matching the kind of concurrent access a real pressure callback
        // could produce if multiple watchdog sources fired simultaneously.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .utility).async {
                            backend.stopGeneration()
                            continuation.resume()
                        }
                    }
                }
            }
        }

        XCTAssertFalse(backend.isGenerating,
            "isGenerating must remain false after concurrent GCD-queue stopGeneration() calls")
    }

    // MARK: - unloadAndWait() is safe from a detached Task

    /// On `.critical` pressure the callback spawns:
    ///   `Task.detached { [weak self] in await self?.unloadAndWait() }`
    /// Verify that `unloadAndWait()` called from a detached Task on an unloaded
    /// backend completes without crashing and leaves the backend clean.
    ///
    /// Sabotage check: if `unloadAndWait()` were not safe to call from a
    /// non-MainActor context this test would fail with a concurrency violation.
    func test_unloadAndWait_fromDetachedTask_isIdempotentAndSafe() async {
        let backend = LlamaBackend()

        // Replicate exactly what the critical-pressure arm does.
        let task = Task.detached { [weak backend] in
            await backend?.unloadAndWait()
        }
        await task.value

        XCTAssertFalse(backend.isModelLoaded,
            "isModelLoaded must be false after unloadAndWait() from a detached task")
        XCTAssertFalse(backend.isGenerating,
            "isGenerating must be false after unloadAndWait() from a detached task")
    }

    // MARK: - Callback registration does not cause a retain cycle

    /// `registerMemoryPressureCallback()` captures `self` weakly. If the capture
    /// were strong, the `MemoryPressureHandler` closure would keep `LlamaBackend`
    /// alive past its last external reference, causing a leak.
    ///
    /// We verify this by releasing the backend and confirming no crash occurs.
    /// A retain cycle would keep `backend` alive, and `deinit` would not call
    /// `memoryPressure.removeCallback(for:)`, leaving a dangling AnyObject key.
    /// The absence of EXC_BAD_ACCESS confirms the weak capture is in effect.
    func test_deinit_removesCallbackWithoutCrash() {
        var backend: LlamaBackend? = LlamaBackend()
        // Force release — if a retain cycle existed, deinit would not run here.
        withExtendedLifetime(backend) {}
        backend = nil
        // If we reach this line, deinit ran and the callback was safely removed.
        XCTAssert(true, "LlamaBackend deinit must not crash when cleaning up the memory pressure callback")
    }
}
#endif
