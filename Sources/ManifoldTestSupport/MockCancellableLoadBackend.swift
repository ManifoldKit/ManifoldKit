import Foundation
import ManifoldInference

/// A minimal ``InferenceBackend`` + ``CancellableModelLoading`` stub for
/// contract tests.
///
/// Simulates the hazard the protocol addresses: a native load that keeps
/// "mutating the backend" after the awaiting `loadModel` call site may have
/// already returned. The load body parks at a test-driven gate so a test can
/// observe ``isModelLoadInFlight`` while the load is mid-flight, then drive it
/// to completion (or cancellation) deterministically — no `Task.sleep`, no
/// wall-clock races.
///
/// Does not perform real inference — use `MockInferenceBackend` when generation
/// is needed.
public final class MockCancellableLoadBackend: InferenceBackend, CancellableModelLoading, @unchecked Sendable {

    // MARK: - InferenceBackend

    public var isModelLoaded: Bool = false
    public var isGenerating: Bool = false
    public var capabilities: BackendCapabilities = BackendCapabilities(
        supportedParameters: [.temperature, .topP, .repeatPenalty],
        maxContextTokens: 4096,
        requiresPromptTemplate: false,
        supportsSystemPrompt: true
    )

    // MARK: - State (guarded by `lock`)

    private let lock = NSLock()
    private var _isModelLoadInFlight = false
    private var _cancelRequested = false

    /// Synchronous gate the simulated native load parks at while "in flight".
    /// `completeInFlightLoad()` / `cancelModelLoad()` are synchronous (matching
    /// the real protocol), so the gate is a lock-guarded continuation rather
    /// than an actor: a release before the load parks is latched, otherwise it
    /// resumes the parked load.
    private var _gateReleased = false
    private var _gateWaiter: CheckedContinuation<Void, Never>?

    /// Resumed once the in-flight load has truly settled, so
    /// ``awaitModelLoadSettled()`` returns precisely on completion. A single
    /// load at a time is assumed (matches the engine's serialised load path).
    private var settledWaiters: [CheckedContinuation<Void, Never>] = []

    // MARK: - Tracking

    public private(set) var cancelModelLoadCallCount = 0

    public init() {}

    // MARK: - CancellableModelLoading

    public var isModelLoadInFlight: Bool {
        lock.withLock { _isModelLoadInFlight }
    }

    public func cancelModelLoad() {
        lock.lock()
        cancelModelLoadCallCount += 1
        // Best-effort: only meaningful while a load is actually in flight.
        // Real backends may have no interruption point — here we record the
        // request and let the load body honor it at the gate.
        if _isModelLoadInFlight {
            _cancelRequested = true
        }
        lock.unlock()
        // Releasing the gate lets a parked load proceed to settle — modelling
        // a backend whose load polls a cancel flag at a sub-step boundary.
        releaseGate()
    }

    public func awaitModelLoadSettled() async {
        // Fast path: nothing in flight → return immediately, no suspension.
        let inFlight = lock.withLock { _isModelLoadInFlight }
        guard inFlight else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if _isModelLoadInFlight {
                settledWaiters.append(cont)
                lock.unlock()
            } else {
                // Settled between the guard and acquiring the lock.
                lock.unlock()
                cont.resume()
            }
        }
    }

    /// Releases the load gate so an in-flight ``loadModel`` proceeds to settle.
    /// Test affordance for the "normal completion" path (no cancel involved).
    public func completeInFlightLoad() {
        releaseGate()
    }

    /// Synchronous gate release: resumes a parked load body, or latches the
    /// release for a load body that has not yet reached the gate.
    private func releaseGate() {
        lock.lock()
        if let waiter = _gateWaiter {
            _gateWaiter = nil
            lock.unlock()
            waiter.resume()
        } else {
            _gateReleased = true
            lock.unlock()
        }
    }

    /// Suspends the simulated load until the gate is released.
    private func parkAtGate() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if _gateReleased {
                _gateReleased = false
                lock.unlock()
                cont.resume()
            } else {
                _gateWaiter = cont
                lock.unlock()
            }
        }
    }

    // MARK: - InferenceBackend methods

    public func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        lock.withLock {
            _isModelLoadInFlight = true
            _cancelRequested = false
        }

        // Park at the gate to model the native load still mutating the backend
        // after the Swift await may have been abandoned. The test releases it
        // via `completeInFlightLoad()` or `cancelModelLoad()`.
        await parkAtGate()

        let cancelled = lock.withLock { _cancelRequested }

        // Drain settled-waiters and flip the flag atomically so a host that
        // awaited `awaitModelLoadSettled()` observes `isModelLoadInFlight ==
        // false` the instant it resumes.
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            _isModelLoadInFlight = false
            isModelLoaded = !cancelled
            let pending = settledWaiters
            settledWaiters.removeAll()
            return pending
        }
        for w in waiters { w.resume() }

        if cancelled {
            throw CancellationError()
        }
    }

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        guard isModelLoaded else { throw InferenceError.inferenceFailure("No model loaded") }
        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            continuation.finish()
        }
        return GenerationStream(stream)
    }

    public func stopGeneration() { isGenerating = false }

    public func unloadModel() {
        isModelLoaded = false
        isGenerating = false
    }
}
