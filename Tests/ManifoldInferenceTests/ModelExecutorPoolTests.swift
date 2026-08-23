import XCTest
@testable import ManifoldInference
import ManifoldContract
import ManifoldTestSupport

/// Coverage for the per-model isolated-executor subsystem (#1936): a
/// ``ModelExecutorPool`` holding N concurrently-live ``ModelExecutor`` actors,
/// hot-swap of the active model with no runtime restart, and wedge
/// detection/recovery scoped to a single model.
///
/// All tests drive ``MockInferenceBackend`` and the deterministic
/// ``ManualWedgeWatchdog`` (tripped explicitly, never wall-clock sleeping) so
/// wedge-detection coverage is race-free.
@MainActor
final class ModelExecutorPoolTests: XCTestCase {

    // MARK: - Deterministic watchdog

    /// A wedge watchdog the test arms and fires by hand. `awaitWedgeBudget()`
    /// suspends until the test calls ``fire()`` — modelling "the budget
    /// elapsed" without a timer, so the wedge race is deterministic.
    private final class ManualWedgeWatchdog: WedgeWatchdog, @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var fired = false

        func awaitWedgeBudget() async {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                lock.lock()
                if fired {
                    lock.unlock()
                    cont.resume()
                    return
                }
                waiters.append(cont)
                lock.unlock()
            }
        }

        /// Trip every armed watchdog, simulating budget expiry.
        func fire() {
            lock.lock()
            fired = true
            let pending = waiters
            waiters.removeAll()
            lock.unlock()
            for cont in pending { cont.resume() }
        }
    }

    /// Hands out a fresh ``ManualWedgeWatchdog`` per generation and remembers
    /// them in creation order so the test can fire exactly one turn's watchdog.
    private final class WatchdogCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var created: [ManualWedgeWatchdog] = []

        func make() -> ManualWedgeWatchdog {
            let w = ManualWedgeWatchdog()
            lock.lock(); created.append(w); lock.unlock()
            return w
        }

        /// Fire the first watchdog created (the first generation's turn).
        func fireFirst() {
            lock.lock(); let first = created.first; lock.unlock()
            first?.fire()
        }
    }

    /// Suspends until cancellation and then returns, matching
    /// ``RealWedgeWatchdog``'s cancelled-sleep behaviour without a timer.
    private final class CancellationReturningWatchdog: WedgeWatchdog, @unchecked Sendable {
        private let lock = NSLock()
        private var budgetContinuation: CheckedContinuation<Void, Never>?
        private var armedContinuations: [CheckedContinuation<Void, Never>] = []
        private var isArmed = false

        func awaitWedgeBudget() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    var resumeImmediately = false
                    var armed: [CheckedContinuation<Void, Never>] = []
                    lock.lock()
                    if Task.isCancelled {
                        resumeImmediately = true
                    } else {
                        budgetContinuation = continuation
                        isArmed = true
                        armed = armedContinuations
                        armedContinuations.removeAll()
                    }
                    lock.unlock()
                    armed.forEach { $0.resume() }
                    if resumeImmediately { continuation.resume() }
                }
            } onCancel: {
                self.resumeBudget()
            }
        }

        func waitUntilArmed() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if isArmed {
                    lock.unlock()
                    continuation.resume()
                } else {
                    armedContinuations.append(continuation)
                    lock.unlock()
                }
            }
        }

        private func resumeBudget() {
            lock.lock()
            let continuation = budgetContinuation
            budgetContinuation = nil
            lock.unlock()
            continuation?.resume()
        }
    }

    // MARK: - Helpers

    private func makeConfig() -> GenerationConfig { GenerationConfig() }

    /// A loader provider backed by a dictionary of pre-built mock backends.
    /// Each loader marks its backend loaded and returns it.
    private func loaderProvider(
        _ backends: [String: MockInferenceBackend]
    ) -> ModelExecutorPool.LoaderProvider {
        return { key in
            guard let backend = backends[key.rawValue] else { return nil }
            return (backendName: "Mock-\(key.rawValue)", loader: {
                try await backend.loadModel(from: URL(fileURLWithPath: "/tmp/\(key.rawValue)"), plan: ModelLoadPlan.testStub())
                return backend
            })
        }
    }

    private func consume(_ stream: GenerationStream) async throws -> String {
        var visible = ""
        for try await event in stream.events {
            if case let .token(t) = event { visible += t }
        }
        return visible
    }

    // MARK: - 1. Two models live concurrently in isolated executors

    func testTwoModelsServeConcurrentlyWithoutHeadOfLineBlocking() async throws {
        let slow = MockInferenceBackend()
        let slowGate = TokenEmissionGate()
        slow.tokenEmissionGate = slowGate
        slow.tokensToYield = ["slow"]

        let fast = MockInferenceBackend()
        fast.tokensToYield = ["fast"]

        let pool = ModelExecutorPool(loaderProvider: loaderProvider(["slow": slow, "fast": fast]))

        // Start the slow model's turn; it blocks on the gate (never advanced yet).
        let slowStream = try await pool.generate(
            on: ModelExecutorKey("slow"), prompt: "p", systemPrompt: nil, config: makeConfig()
        )
        let slowTask = Task { try await self.consume(slowStream) }

        // The fast model — a DIFFERENT executor — completes while slow is stuck.
        // If executors shared a FIFO this would deadlock behind the slow turn.
        let fastStream = try await pool.generate(
            on: ModelExecutorKey("fast"), prompt: "p", systemPrompt: nil, config: makeConfig()
        )
        let fastResult = try await consume(fastStream)
        XCTAssertEqual(fastResult, "fast", "Fast model must complete while the slow model is mid-turn")

        // Release the slow turn and confirm it finishes independently.
        await slowGate.advance()
        let slowResult = try await slowTask.value
        XCTAssertEqual(slowResult, "slow")

        XCTAssertEqual(pool.residentCount, 2, "Both executors remain resident")
    }

    // MARK: - 2. Wedge detection + recovery, sibling unaffected

    func testWedgedExecutorIsDetectedAndRecoveredWhileSiblingKeepsServing() async throws {
        // The wedging model: a backend whose stream NEVER yields an event.
        let wedger = MockInferenceBackend()
        wedger.tokensToYield = []
        let wedgeGate = TokenEmissionGate()   // gate with no tokens still lets us hold the turn open
        // Hold the turn open indefinitely: gate a (phantom) token so the stream
        // never finishes until we release it.
        wedger.tokensToYield = ["never"]
        wedger.tokenEmissionGate = wedgeGate

        let healthy = MockInferenceBackend()
        healthy.tokensToYield = ["ok"]

        // Each generation gets its OWN watchdog instance (production behaviour:
        // one watchdog per turn). We capture them so the test can fire only the
        // wedging turn's watchdog while the healthy turn's stays un-fired and
        // is cancelled when that turn completes normally.
        let watchdogs = WatchdogCollector()
        let pool = ModelExecutorPool(
            makeWatchdog: { watchdogs.make() },
            loaderProvider: loaderProvider(["wedge": wedger, "healthy": healthy])
        )

        // Start the wedging turn; it blocks (token gated, never advanced).
        let wedgeStream = try await pool.generate(
            on: ModelExecutorKey("wedge"), prompt: "p", systemPrompt: nil, config: makeConfig()
        )
        // Drain it in a task — it should terminate with idleTimeout once wedged.
        let wedgeTask = Task { () -> Error? in
            do {
                for try await _ in wedgeStream.events {}
                return nil
            } catch {
                return error
            }
        }

        // Trip the FIRST watchdog (the wedging turn's): no event arrived →
        // that executor wedges, its stream throws. The healthy turn (created
        // later) has its own un-fired watchdog.
        watchdogs.fireFirst()
        let wedgeError = await wedgeTask.value
        XCTAssertTrue(wedgeError is InferenceError, "Wedged turn must surface an error to unblock the caller")
        let wedgeState = await pool.state(of: ModelExecutorKey("wedge"))
        XCTAssertEqual(wedgeState, .wedged, "Executor must be marked wedged after the watchdog fires")

        // The SIBLING model is completely unaffected — it serves normally.
        let healthyStream = try await pool.generate(
            on: ModelExecutorKey("healthy"), prompt: "p", systemPrompt: nil, config: makeConfig()
        )
        let healthyResult = try await consume(healthyStream)
        XCTAssertEqual(healthyResult, "ok", "Sibling executor keeps serving while another is wedged")

        // Recover the wedged executor: tears down + reloads JUST that model.
        // Re-arm the backend with real tokens for the post-recovery turn.
        wedger.tokenEmissionGate = nil
        wedger.tokensToYield = ["recovered"]
        try await pool.recover(ModelExecutorKey("wedge"))
        let recoveredState = await pool.state(of: ModelExecutorKey("wedge"))
        XCTAssertEqual(recoveredState, .ready, "Recovered executor returns to ready")

        // It serves again after recovery.
        let recoveredStream = try await pool.generate(
            on: ModelExecutorKey("wedge"), prompt: "p", systemPrompt: nil, config: makeConfig()
        )
        let recoveredResult = try await consume(recoveredStream)
        XCTAssertEqual(recoveredResult, "recovered", "Recovered executor generates normally")

        // Cleanup the abandoned gated task.
        await wedgeGate.release()
    }

    // MARK: - 3. Hot-swap with no restart, old unloaded

    func testHotSwapSwitchesActiveModelAndUnloadsPrevious() async throws {
        let modelA = MockInferenceBackend()
        modelA.tokensToYield = ["A"]
        let modelB = MockInferenceBackend()
        modelB.tokensToYield = ["B"]

        let pool = ModelExecutorPool(loaderProvider: loaderProvider(["A": modelA, "B": modelB]))

        // Establish A as the active model.
        _ = try await pool.generate(
            on: ModelExecutorKey("A"), prompt: "p", systemPrompt: nil, config: makeConfig()
        )
        XCTAssertEqual(pool.activeKey, ModelExecutorKey("A"))
        XCTAssertEqual(pool.residentCount, 1)

        // Hot-swap to B. Load-before-evict guarantees B is ready BEFORE A is
        // torn down, so there is never a zero-executor window for the active model.
        try await pool.hotSwap(to: ModelExecutorKey("B"))
        XCTAssertEqual(pool.activeKey, ModelExecutorKey("B"), "Active model switched with no restart")
        XCTAssertEqual(pool.residentCount, 1, "Previous active executor was unloaded")
        let oldState = await pool.state(of: ModelExecutorKey("A"))
        XCTAssertNil(oldState, "Old executor removed from registry")
        XCTAssertTrue(modelA.unloadCallCount >= 1, "Old backend was unloaded")

        // The new active model serves via the default (active) route.
        let stream = try await pool.generate(prompt: "p", systemPrompt: nil, config: makeConfig())
        let swapped = try await consume(stream)
        XCTAssertEqual(swapped, "B")
    }

    func testHotSwapCanKeepPreviousResidentForWarmStandby() async throws {
        let modelA = MockInferenceBackend(); modelA.tokensToYield = ["A"]
        let modelB = MockInferenceBackend(); modelB.tokensToYield = ["B"]
        let pool = ModelExecutorPool(loaderProvider: loaderProvider(["A": modelA, "B": modelB]))

        _ = try await pool.generate(on: ModelExecutorKey("A"), prompt: "p", systemPrompt: nil, config: makeConfig())
        try await pool.hotSwap(to: ModelExecutorKey("B"), unloadPrevious: false)

        XCTAssertEqual(pool.activeKey, ModelExecutorKey("B"))
        XCTAssertEqual(pool.residentCount, 2, "Warm-standby keeps the previous model resident")
        XCTAssertEqual(modelA.unloadCallCount, 0, "Previous backend not unloaded under warm standby")
    }

    func testFailedHotSwapPreservesActiveModelNoZeroExecutorWindow() async throws {
        let modelA = MockInferenceBackend(); modelA.tokensToYield = ["A"]
        // Model B's load FAILS — load-before-evict means A must survive intact.
        let modelB = MockInferenceBackend()
        modelB.shouldThrowOnLoad = InferenceError.modelLoadFailed(underlying: InferenceError.inferenceFailure("boom"))

        let pool = ModelExecutorPool(loaderProvider: loaderProvider(["A": modelA, "B": modelB]))
        _ = try await consume(
            try await pool.generate(on: ModelExecutorKey("A"), prompt: "p", systemPrompt: nil, config: makeConfig())
        )

        // Attempt the swap; it must throw (B can't load).
        do {
            try await pool.hotSwap(to: ModelExecutorKey("B"))
            XCTFail("Swap to an unloadable model must throw")
        } catch {
            // expected
        }

        // CRITICAL: with load-before-evict, A is still active and resident.
        // (An evict-first ordering would have torn A down before B failed,
        // leaving a zero-executor window — the sabotage this test guards.)
        XCTAssertEqual(pool.activeKey, ModelExecutorKey("A"), "Active model preserved after failed swap")
        let stateA = await pool.state(of: ModelExecutorKey("A"))
        XCTAssertEqual(stateA, .ready, "Active executor still ready after failed swap")
        XCTAssertEqual(modelA.unloadCallCount, 0, "Active backend was not torn down by the failed swap")

        // And it still serves.
        let stream = try await pool.generate(prompt: "p", systemPrompt: nil, config: makeConfig())
        let result = try await consume(stream)
        XCTAssertEqual(result, "A")
    }

    func testCancelledWatchdogReturnDoesNotWedgeExecutor() async throws {
        let backend = MockInferenceBackend()
        let gate = TokenEmissionGate()
        backend.tokenEmissionGate = gate
        backend.tokensToYield = ["blocked"]
        let watchdog = CancellationReturningWatchdog()
        let executor = ModelExecutor(
            key: ModelExecutorKey("cancelled"),
            backendName: "Mock",
            loader: {
                try await backend.loadModel(
                    from: URL(fileURLWithPath: "/tmp/cancelled"),
                    plan: ModelLoadPlan.testStub()
                )
                return backend
            },
            makeWatchdog: { watchdog }
        )
        try await executor.load()

        let stream = try await executor.generate(
            prompt: "p",
            systemPrompt: nil,
            config: makeConfig(),
            hints: GenerationRuntimeHints()
        )
        let consumer = Task { try await self.consume(stream) }
        await watchdog.waitUntilArmed()

        consumer.cancel()
        await gate.release()
        _ = await consumer.result

        for _ in 0..<1_000 {
            if await executor.state == .ready { return }
            await Task.yield()
        }
        XCTFail("Cancelling a watchdog must return the executor to ready, never mark it wedged")
    }

    // MARK: - 4. Single-executor pool preserves single-model semantics

    func testSingleExecutorPoolBehavesLikeSingleModelPath() async throws {
        let only = MockInferenceBackend()
        only.tokensToYield = ["one"]
        let pool = ModelExecutorPool(maxResidentExecutors: 1, loaderProvider: loaderProvider(["only": only]))

        let stream = try await pool.generate(
            on: ModelExecutorKey("only"), prompt: "p", systemPrompt: nil, config: makeConfig()
        )
        let firstResult = try await consume(stream)
        XCTAssertEqual(firstResult, "one")
        XCTAssertEqual(pool.residentCount, 1)
        XCTAssertEqual(pool.activeKey, ModelExecutorKey("only"))

        // A second generation on the same executor after the first completes
        // succeeds (FIFO-equivalent: executor returns to .ready between turns).
        let stream2 = try await pool.generate(
            on: ModelExecutorKey("only"), prompt: "p2", systemPrompt: nil, config: makeConfig()
        )
        let secondResult = try await consume(stream2)
        XCTAssertEqual(secondResult, "one")
        XCTAssertEqual(only.generateCallCount, 2)
    }

    // MARK: - 5. Capacity-bounded admission evicts LRU non-active executor

    func testCapacityEvictsLeastRecentlyActiveNonActiveExecutor() async throws {
        let a = MockInferenceBackend(); a.tokensToYield = ["a"]
        let b = MockInferenceBackend(); b.tokensToYield = ["b"]
        let c = MockInferenceBackend(); c.tokensToYield = ["c"]
        let pool = ModelExecutorPool(
            maxResidentExecutors: 2,
            loaderProvider: loaderProvider(["a": a, "b": b, "c": c])
        )

        // Make A the active model, then load B (non-active).
        _ = try await consume(try await pool.generate(on: ModelExecutorKey("a"), prompt: "p", systemPrompt: nil, config: makeConfig()))
        _ = try await consume(try await pool.generate(on: ModelExecutorKey("b"), prompt: "p", systemPrompt: nil, config: makeConfig()))
        XCTAssertEqual(pool.residentCount, 2)

        // Loading C must evict B (the LRU non-active executor) — never A (active).
        _ = try await consume(try await pool.generate(on: ModelExecutorKey("c"), prompt: "p", systemPrompt: nil, config: makeConfig()))
        XCTAssertEqual(pool.residentCount, 2, "Capacity cap respected")
        let stateA = await pool.state(of: ModelExecutorKey("a"))
        let stateC = await pool.state(of: ModelExecutorKey("c"))
        let stateB = await pool.state(of: ModelExecutorKey("b"))
        XCTAssertNotNil(stateA, "Active executor never evicted")
        XCTAssertNotNil(stateC, "Newly-loaded executor resident")
        XCTAssertNil(stateB, "LRU non-active executor evicted")
    }

    // MARK: - Executor-level: double generate rejected (serialization contract)

    func testExecutorRejectsConcurrentGenerateOnSameModel() async throws {
        let backend = MockInferenceBackend()
        let gate = TokenEmissionGate()
        backend.tokenEmissionGate = gate
        backend.tokensToYield = ["x"]

        let executor = ModelExecutor(
            key: ModelExecutorKey("m"),
            backendName: "Mock",
            loader: {
                try await backend.loadModel(from: URL(fileURLWithPath: "/tmp/m"), plan: ModelLoadPlan.testStub())
                return backend
            }
        )
        try await executor.load()

        let first = try await executor.generate(prompt: "p", systemPrompt: nil, config: makeConfig(), hints: GenerationRuntimeHints())
        let firstTask = Task { try await self.consume(first) }

        // A second generate while the first is in flight must throw.
        do {
            _ = try await executor.generate(prompt: "p2", systemPrompt: nil, config: makeConfig(), hints: GenerationRuntimeHints())
            XCTFail("Concurrent generate on the same executor must throw alreadyGenerating")
        } catch let error as InferenceError {
            guard case .alreadyGenerating = error else {
                return XCTFail("Expected alreadyGenerating, got \(error)")
            }
        }

        await gate.advance()
        _ = try await firstTask.value
        // After the turn completes the executor is ready for reuse.
        let state = await executor.state
        XCTAssertEqual(state, .ready)
    }
}
