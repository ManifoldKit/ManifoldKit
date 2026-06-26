import XCTest
import ManifoldInference
import ManifoldTestSupport

/// Verifies the ``CancellableModelLoading`` protocol contract using
/// ``MockCancellableLoadBackend``.
///
/// These tests confirm the seam is self-consistent: a host can observe an
/// in-flight native load, request its cancellation, and await its true
/// completion. They do **not** verify that `LlamaBackend` implements the
/// protocol correctly — that native cancel/settle wiring is a follow-up in the
/// `manifold-llama` companion repo, and real-backend coverage requires
/// hardware (`ManifoldE2ETests`).
@MainActor
final class CancellableModelLoadingContractTests: XCTestCase {

    private static let modelURL = URL(fileURLWithPath: "/tmp/fake-model")

    /// Polls `condition` until it holds or a tight deadline elapses. Used to
    /// bridge the gap between launching a detached `loadModel` and the moment
    /// its body actually reaches the in-flight gate — real `async/await`
    /// scheduling, no fixed sleep.
    private func waitUntil(
        _ condition: @escaping () -> Bool,
        timeout: TimeInterval = 2.0,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000) // 1 ms
        }
        XCTFail(message, file: file, line: line)
    }

    // MARK: - 1. Fast path: nothing in flight

    func test_noLoad_isNotInFlight_andSettleReturnsImmediately() async {
        let backend = MockCancellableLoadBackend()

        XCTAssertFalse(backend.isModelLoadInFlight, "No load started → not in flight")

        // Must return promptly without suspending on a non-existent load.
        await backend.awaitModelLoadSettled()

        XCTAssertFalse(backend.isModelLoadInFlight)
    }

    // MARK: - 2. In-flight is observable while the native load is mid-flight

    func test_loadInFlight_isObservable_thenSettlesOnCompletion() async throws {
        let backend = MockCancellableLoadBackend()

        let loadTask = Task { try await backend.loadModel(from: Self.modelURL, plan: .testStub(effectiveContextSize: 512)) }

        await waitUntil({ backend.isModelLoadInFlight }, "load should report in-flight while parked")
        XCTAssertFalse(backend.isModelLoaded, "model must not be marked loaded while still in flight")

        // Drive the simulated native load to normal completion.
        backend.completeInFlightLoad()
        try await loadTask.value

        XCTAssertFalse(backend.isModelLoadInFlight, "settled load is no longer in flight")
        XCTAssertTrue(backend.isModelLoaded, "normal completion marks the model loaded")
    }

    // MARK: - 3. awaitModelLoadSettled suspends until the load truly finishes

    func test_awaitSettled_suspendsUntilLoadFinishes() async throws {
        let backend = MockCancellableLoadBackend()

        let loadTask = Task { try await backend.loadModel(from: Self.modelURL, plan: .testStub(effectiveContextSize: 512)) }
        await waitUntil({ backend.isModelLoadInFlight }, "load should be in flight before awaiting settle")

        // Latch: this must NOT return until the in-flight load settles.
        let settledObserved = SettleProbe()
        let settleTask = Task {
            await backend.awaitModelLoadSettled()
            await settledObserved.markSettled(inFlightAtReturn: backend.isModelLoadInFlight)
        }

        // While the load is still parked, the settle latch must still be pending.
        await Task.yield()
        let returnedEarly = await settledObserved.didSettle
        XCTAssertFalse(returnedEarly, "awaitModelLoadSettled must not return while the load is in flight")

        // Now let the load finish; the latch must release.
        backend.completeInFlightLoad()
        try await loadTask.value
        await settleTask.value

        let didSettle = await settledObserved.didSettle
        let inFlightAtReturn = await settledObserved.inFlightAtReturn
        XCTAssertTrue(didSettle, "awaitModelLoadSettled must return once the load settles")
        XCTAssertEqual(inFlightAtReturn, false, "isModelLoadInFlight must be false the instant settle returns")
    }

    // MARK: - 4. cancelModelLoad requests an unwind; the load settles cancelled

    func test_cancelModelLoad_unwindsInFlightLoad() async {
        let backend = MockCancellableLoadBackend()

        let loadTask = Task { try await backend.loadModel(from: Self.modelURL, plan: .testStub(effectiveContextSize: 512)) }
        await waitUntil({ backend.isModelLoadInFlight }, "load should be in flight before cancel")

        backend.cancelModelLoad()

        // The load should unwind (cooperatively, here) rather than complete.
        var threwCancellation = false
        do {
            try await loadTask.value
            XCTFail("cancelled load should not complete normally")
        } catch is CancellationError {
            threwCancellation = true
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }

        XCTAssertTrue(threwCancellation)
        XCTAssertEqual(backend.cancelModelLoadCallCount, 1)
        XCTAssertFalse(backend.isModelLoadInFlight, "cancelled load is no longer in flight")
        XCTAssertFalse(backend.isModelLoaded, "a cancelled load must not mark the model loaded")

        // A host that latches with settle after cancel observes a settled backend.
        await backend.awaitModelLoadSettled()
        XCTAssertFalse(backend.isModelLoadInFlight)
    }

    // MARK: - 5. cancel with no load in flight is a no-op

    func test_cancel_withNoLoad_isNoOp() {
        let backend = MockCancellableLoadBackend()
        backend.cancelModelLoad()
        XCTAssertFalse(backend.isModelLoadInFlight)
        XCTAssertEqual(backend.cancelModelLoadCallCount, 1, "the call is counted but has no in-flight effect")
    }
}

/// Thread-safe probe recording whether ``CancellableModelLoading/awaitModelLoadSettled()``
/// has returned, and what it observed at return.
private actor SettleProbe {
    private(set) var didSettle = false
    private(set) var inFlightAtReturn: Bool?

    func markSettled(inFlightAtReturn: Bool) {
        didSettle = true
        self.inFlightAtReturn = inFlightAtReturn
    }
}
