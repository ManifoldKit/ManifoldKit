import XCTest
@testable import ManifoldTestSupport

/// Tests for the ``withTimeout`` helper in `ManifoldTestSupport`.
///
/// The helper exists so sabotage-verify tests that would otherwise hang on a
/// regression (e.g. a missing latch causing `await gate.approve(...)` to
/// suspend forever) instead fail deterministically within a bounded deadline.
/// These tests pin that contract: hangs throw `TimeoutError`, fast operations
/// return their value, and the helper's own bookkeeping stays cheap.
final class WithTimeoutTests: XCTestCase {

    // MARK: - Hang path

    func test_withTimeout_throwsOnHang() async {
        // A millisecond-scale timeout keeps the suite fast while still
        // comfortably clear of scheduling noise on CI hardware.
        let timeout: Duration = .milliseconds(50)

        do {
            _ = try await withTimeout(timeout) {
                // Simulate a hang: a very long sleep we expect the helper
                // to cancel when the deadline elapses.
                try await Task.sleep(for: .seconds(60))
                return 42
            }
            XCTFail("Expected TimeoutError.timedOut but operation returned a value")
        } catch let error as TimeoutError {
            XCTAssertEqual(error, .timedOut(timeout))
        } catch {
            XCTFail("Expected TimeoutError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - Happy path

    func test_withTimeout_returnsValueUnderBudget() async throws {
        // Give the operation a generous budget — we're pinning the fast-path
        // contract, not measuring wall-clock overhead.
        let value = try await withTimeout(.seconds(5)) {
            // Tiny async hop so the operation actually suspends; otherwise we'd
            // be asserting on a synchronous return that doesn't exercise the
            // race machinery.
            try await Task.sleep(for: .milliseconds(1))
            return "ok"
        }
        XCTAssertEqual(value, "ok")
    }

    // MARK: - Overhead budget

    func test_withTimeout_overheadStaysUnderBudget() async throws {
        // The unstructured-concurrency implementation (withCheckedThrowingContinuation
        // + two Tasks) trades some overhead for correctness — it guarantees the
        // timeout fires even for non-cancellation-aware operations. The budget is
        // set to 500 ms: tight enough to catch runaway blocking, but large enough
        // to absorb the two-task launch cost and CI scheduler variability.
        let opDuration: Duration = .milliseconds(10)
        let start = ContinuousClock.now

        _ = try await withTimeout(.seconds(1)) {
            try await Task.sleep(for: opDuration)
            return ()
        }

        let elapsed = ContinuousClock.now - start
        let budget: Duration = opDuration + .milliseconds(500)
        XCTAssertLessThan(
            elapsed,
            budget,
            "withTimeout overhead exceeded 500 ms budget (elapsed=\(elapsed), op=\(opDuration))"
        )
    }

    // MARK: - Non-cancellation-aware hang

    func test_withTimeout_throwsOnNonCancellationAwareHang() async {
        // Use a DispatchSemaphore to model a gate that doesn't check Swift
        // cancellation (e.g. UIToolApprovalGate.awaitDecision awaiting user input).
        // The latch is signalled 1 s from now — long enough to prove the thread
        // eventually resumes (preventing a permanently-leaked Task) with a 5×
        // safety margin over the 200 ms timeout so loaded macOS CI runners don't
        // race the timeout's scheduler hop against the latch fire. An earlier
        // 100 ms ↔ 50 ms (2×) gap flaked on PR #1337's first CI attempt.
        let latch = DispatchSemaphore(value: 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { latch.signal() }

        let timeout: Duration = .milliseconds(200)
        do {
            _ = try await withTimeout(timeout) {
                await withCheckedContinuation { (cont: CheckedContinuation<Int, Never>) in
                    latch.wait()       // blocks until latch fires (~100 ms from now)
                    cont.resume(returning: 0)
                }
            }
            XCTFail("Expected TimeoutError.timedOut but operation returned a value")
        } catch let error as TimeoutError {
            XCTAssertEqual(error, .timedOut(timeout))
        } catch {
            XCTFail("Expected TimeoutError, got \(type(of: error)): \(error)")
        }
    }

    // MARK: - Error rethrow

    func test_withTimeout_rethrowsOperationError() async {
        struct Boom: Error, Equatable {}

        do {
            _ = try await withTimeout(.seconds(5)) {
                throw Boom()
            }
            XCTFail("Expected Boom to propagate")
        } catch let error as Boom {
            XCTAssertEqual(error, Boom())
        } catch {
            XCTFail("Expected Boom, got \(type(of: error)): \(error)")
        }
    }
}
