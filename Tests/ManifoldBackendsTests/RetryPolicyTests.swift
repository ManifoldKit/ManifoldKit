import XCTest
@testable import ManifoldInference
import ManifoldTestSupport

/// Unit tests for `ExponentialBackoffStrategy` delay bounds and `withRetry` sleep behaviour.
///
/// These tests use zero-jitter injection and `RecordingRetrySleeper` so assertions are
/// fully deterministic — no wall-clock timing required.
final class RetryPolicyTests: XCTestCase {

    // MARK: - Delay math (zero jitter)

    /// Without jitter the exponential formula is `base * 2^attempt`.
    func test_delayIsExponential_withZeroJitter() {
        let strategy = ExponentialBackoffStrategy(
            maxRetries: 4,
            baseDelay: 1.0,
            maxTotalDelay: 60.0,
            jitterProvider: { _ in 0 }
        )
        let error = CloudBackendError.networkError(underlying: URLError(.timedOut))

        // attempt 0 → 1 * 2^0 = 1s
        XCTAssertEqual(strategy.delay(for: error, attempt: 0, totalDelayed: 0)!, 1.0, accuracy: 1e-9)
        // attempt 1 → 1 * 2^1 = 2s
        XCTAssertEqual(strategy.delay(for: error, attempt: 1, totalDelayed: 0)!, 2.0, accuracy: 1e-9)
        // attempt 2 → 1 * 2^2 = 4s
        XCTAssertEqual(strategy.delay(for: error, attempt: 2, totalDelayed: 0)!, 4.0, accuracy: 1e-9)
        // attempt 3 → 1 * 2^3 = 8s
        XCTAssertEqual(strategy.delay(for: error, attempt: 3, totalDelayed: 0)!, 8.0, accuracy: 1e-9)
    }

    /// Jitter must stay within [0, exponentialDelay * 0.25].
    func test_delayBoundsWithMaxJitter() {
        let strategy = ExponentialBackoffStrategy(
            maxRetries: 4,
            baseDelay: 1.0,
            maxTotalDelay: 60.0,
            jitterProvider: { $0 }          // always max jitter
        )
        let error = CloudBackendError.networkError(underlying: URLError(.timedOut))

        // attempt 0: exponential = 1.0, max jitter = 0.25 → expected = 1.25
        XCTAssertEqual(strategy.delay(for: error, attempt: 0, totalDelayed: 0)!, 1.25, accuracy: 1e-9)
        // attempt 1: exponential = 2.0, max jitter = 0.50 → expected = 2.50
        XCTAssertEqual(strategy.delay(for: error, attempt: 1, totalDelayed: 0)!, 2.50, accuracy: 1e-9)
        // attempt 2: exponential = 4.0, max jitter = 1.00 → expected = 5.00
        XCTAssertEqual(strategy.delay(for: error, attempt: 2, totalDelayed: 0)!, 5.00, accuracy: 1e-9)
    }

    /// Delays with live random jitter should always land in [base*2^n, base*2^n * 1.25].
    func test_liveJitterStaysWithinBounds() {
        let strategy = ExponentialBackoffStrategy(maxRetries: 10, baseDelay: 1.0, maxTotalDelay: 600.0)
        let error = CloudBackendError.networkError(underlying: URLError(.timedOut))

        for attempt in 0..<3 {
            let base = 1.0 * pow(2.0, Double(attempt))
            guard let delay = strategy.delay(for: error, attempt: attempt, totalDelayed: 0) else {
                XCTFail("Expected non-nil delay for attempt \(attempt)")
                continue
            }
            XCTAssertGreaterThanOrEqual(delay, base, "attempt \(attempt): delay below base")
            XCTAssertLessThanOrEqual(delay, base * 1.25, "attempt \(attempt): delay above base * 1.25")
        }
    }

    // MARK: - Retry-After overrides exponential delay

    /// When the error carries a `Retry-After` header value, that overrides the exponential formula.
    func test_retryAfterOverridesExponentialDelay() {
        let strategy = ExponentialBackoffStrategy(
            maxRetries: 3,
            baseDelay: 1.0,
            maxTotalDelay: 60.0,
            jitterProvider: { _ in 0 }
        )
        let error = CloudBackendError.rateLimited(retryAfter: 5.0)

        XCTAssertEqual(strategy.delay(for: error, attempt: 0, totalDelayed: 0)!, 5.0, accuracy: 1e-9,
                       "Retry-After=5 must take priority over exponential formula")
    }

    /// A `rateLimited` error with no `Retry-After` value falls back to exponential.
    func test_missingRetryAfterFallsBackToExponential() {
        let strategy = ExponentialBackoffStrategy(
            maxRetries: 3,
            baseDelay: 1.0,
            maxTotalDelay: 60.0,
            jitterProvider: { _ in 0 }
        )
        let error = CloudBackendError.rateLimited(retryAfter: nil)

        XCTAssertEqual(strategy.delay(for: error, attempt: 0, totalDelayed: 0)!, 1.0, accuracy: 1e-9,
                       "No Retry-After must fall back to base * 2^0 = 1s")
    }

    // MARK: - Retry exhaustion

    /// `delay` returns `nil` once `attempt >= maxRetries`.
    func test_returnsNilWhenRetriesExhausted() {
        let strategy = ExponentialBackoffStrategy(maxRetries: 3, baseDelay: 1.0, maxTotalDelay: 60.0)
        let error = CloudBackendError.networkError(underlying: URLError(.timedOut))

        XCTAssertNil(strategy.delay(for: error, attempt: 3, totalDelayed: 0),
                     "attempt == maxRetries should yield nil")
        XCTAssertNil(strategy.delay(for: error, attempt: 4, totalDelayed: 0))
    }

    /// `delay` returns `nil` when the total delay budget is exhausted.
    func test_returnsNilWhenTotalDelayExceeded() {
        let strategy = ExponentialBackoffStrategy(maxRetries: 10, baseDelay: 1.0, maxTotalDelay: 5.0,
                                                  jitterProvider: { _ in 0 })
        let error = CloudBackendError.networkError(underlying: URLError(.timedOut))

        // totalDelayed = 4.9, next delay = 1.0 → 5.9 > maxTotalDelay
        XCTAssertNil(strategy.delay(for: error, attempt: 0, totalDelayed: 4.9))
    }

    // MARK: - Non-retryable errors

    func test_nonRetryableErrorReturnsNilDelay() {
        let strategy = ExponentialBackoffStrategy(maxRetries: 3, baseDelay: 1.0, maxTotalDelay: 60.0)

        // Authentication failure is non-retryable.
        let error = CloudBackendError.authenticationFailed(provider: "TestProvider")
        XCTAssertNil(strategy.delay(for: error, attempt: 0, totalDelayed: 0))
    }

    func test_nonBackendErrorReturnsNilDelay() {
        let strategy = ExponentialBackoffStrategy(maxRetries: 3, baseDelay: 1.0, maxTotalDelay: 60.0)
        let error = NSError(domain: "test", code: 42)
        XCTAssertNil(strategy.delay(for: error, attempt: 0, totalDelayed: 0))
    }

    // MARK: - withRetry records correct sleep durations

    /// The sleeper receives the exact millisecond-rounded durations dictated by the strategy.
    func test_withRetryCallsSleeperWithCorrectDurations() async throws {
        let recorder = RecordingRetrySleeper()
        let strategy = ExponentialBackoffStrategy(
            maxRetries: 3,
            baseDelay: 1.0,
            maxTotalDelay: 60.0,
            jitterProvider: { _ in 0 }
        )

        var callCount = 0
        let networkError = CloudBackendError.networkError(underlying: URLError(.timedOut))

        // Fails twice, then succeeds on the third attempt.
        try await withRetry(strategy: strategy, sleeper: recorder.asSleeper) {
            callCount += 1
            if callCount < 3 { throw networkError }
        }

        XCTAssertEqual(callCount, 3, "Should succeed on the third attempt")
        XCTAssertEqual(recorder.recordedSleeps.count, 2, "Two retries → two sleep calls")
        // attempt 0 delay: 1.0s → 1000ms
        XCTAssertEqual(recorder.recordedSleeps[0], .milliseconds(1000))
        // attempt 1 delay: 2.0s → 2000ms
        XCTAssertEqual(recorder.recordedSleeps[1], .milliseconds(2000))
    }

    /// After all retries are exhausted, the recorder captures the full sequence of delays.
    func test_withRetryExhaustsAndRecordsAllDelays() async throws {
        let recorder = RecordingRetrySleeper()
        let strategy = ExponentialBackoffStrategy(
            maxRetries: 3,
            baseDelay: 1.0,
            maxTotalDelay: 60.0,
            jitterProvider: { _ in 0 }
        )
        let networkError = CloudBackendError.networkError(underlying: URLError(.timedOut))

        do {
            try await withRetry(strategy: strategy, sleeper: recorder.asSleeper) {
                throw networkError
            }
            XCTFail("Should have thrown after exhausting retries")
        } catch is RetryExhaustedError {
            // Expected.
        }

        XCTAssertEqual(recorder.recordedSleeps.count, 3, "Three retries → three sleep calls")
        XCTAssertEqual(recorder.recordedSleeps[0], .milliseconds(1000))
        XCTAssertEqual(recorder.recordedSleeps[1], .milliseconds(2000))
        XCTAssertEqual(recorder.recordedSleeps[2], .milliseconds(4000))
    }

    /// Non-retryable errors bypass the sleeper entirely.
    func test_nonRetryableErrorSkipsSleeper() async throws {
        let recorder = RecordingRetrySleeper()
        let strategy = ExponentialBackoffStrategy(maxRetries: 3, baseDelay: 1.0, maxTotalDelay: 60.0)
        let authError = CloudBackendError.authenticationFailed(provider: "TestProvider")

        do {
            try await withRetry(strategy: strategy, sleeper: recorder.asSleeper) {
                throw authError
            }
            XCTFail("Should have thrown immediately")
        } catch CloudBackendError.authenticationFailed(_) {
            // Expected — passes through unchanged.
        }

        XCTAssertTrue(recorder.recordedSleeps.isEmpty, "Non-retryable error must not trigger any sleep")
    }

    // MARK: - Cancellation propagates through the sleeper

    /// A sleeper that throws `CancellationError` must surface from `withRetry` unchanged,
    /// so cancelled retry waits short-circuit instead of swallowing the cancel.
    func test_cancellingSleeperPropagatesCancellationError() async {
        struct CancellingSleeper {
            static let asSleeper: @Sendable (Duration) async throws -> Void = { _ in
                throw CancellationError()
            }
        }
        let strategy = ExponentialBackoffStrategy(
            maxRetries: 3,
            baseDelay: 1.0,
            maxTotalDelay: 60.0,
            jitterProvider: { _ in 0 }
        )
        let networkError = CloudBackendError.networkError(underlying: URLError(.timedOut))

        do {
            try await withRetry(strategy: strategy, sleeper: CancellingSleeper.asSleeper) {
                throw networkError
            }
            XCTFail("Expected CancellationError to propagate from the sleeper")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    // MARK: - Jitter clamping

    /// A jitterProvider that returns a value greater than its ceiling must be clamped
    /// so the delay never exceeds `exponentialDelay * 1.25`.
    func test_jitterAboveCeilingIsClamped() {
        let strategy = ExponentialBackoffStrategy(
            maxRetries: 3,
            baseDelay: 1.0,
            maxTotalDelay: 60.0,
            jitterProvider: { $0 * 10.0 }    // misbehaving — returns 10x the ceiling
        )
        let error = CloudBackendError.networkError(underlying: URLError(.timedOut))

        // attempt 0: exponential = 1.0, max jitter = 0.25 → clamped delay = 1.25
        XCTAssertEqual(strategy.delay(for: error, attempt: 0, totalDelayed: 0)!, 1.25, accuracy: 1e-9)
    }

    /// A negative or NaN jitter must collapse to 0 — never produce a delay below the
    /// exponential base.
    func test_negativeOrNaNJitterIsClamped() {
        let negativeStrategy = ExponentialBackoffStrategy(
            maxRetries: 3, baseDelay: 1.0, maxTotalDelay: 60.0,
            jitterProvider: { _ in -5.0 }
        )
        let nanStrategy = ExponentialBackoffStrategy(
            maxRetries: 3, baseDelay: 1.0, maxTotalDelay: 60.0,
            jitterProvider: { _ in .nan }
        )
        let error = CloudBackendError.networkError(underlying: URLError(.timedOut))

        XCTAssertEqual(negativeStrategy.delay(for: error, attempt: 0, totalDelayed: 0)!, 1.0, accuracy: 1e-9)
        XCTAssertEqual(nanStrategy.delay(for: error, attempt: 0, totalDelayed: 0)!, 1.0, accuracy: 1e-9)
    }
}
