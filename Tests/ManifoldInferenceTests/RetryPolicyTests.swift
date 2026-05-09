import XCTest
@testable import ManifoldTestSupport
@testable import ManifoldInference

final class RetryPolicyTests: XCTestCase {

    // MARK: - Success on First Attempt

    func test_success_noRetry() async throws {
        var callCount = 0
        let result = try await withExponentialBackoff {
            callCount += 1
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(callCount, 1, "Should only call operation once on success")
    }

    // MARK: - Retry on Rate Limit

    func test_retryOnRateLimit_succeedsAfterRetry() async throws {
        var callCount = 0
        let result: String = try await withExponentialBackoff(baseDelay: 0.01) {
            callCount += 1
            if callCount < 3 {
                throw CloudBackendError.rateLimited(retryAfter: 0.01)
            }
            return "recovered"
        }
        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(callCount, 3, "Should retry twice before succeeding")
    }

    // MARK: - Non-Rate-Limit Errors Thrown Immediately

    func test_nonRateLimitError_throwsImmediately() async {
        var callCount = 0
        do {
            _ = try await withExponentialBackoff {
                callCount += 1
                throw CloudBackendError.authenticationFailed(provider: "Test")
            }
            XCTFail("Should have thrown")
        } catch {
            guard case CloudBackendError.authenticationFailed = error else {
                XCTFail("Expected authenticationFailed, got: \(error)")
                return
            }
        }
        XCTAssertEqual(callCount, 1, "Should not retry on non-rate-limit errors")
    }

    // MARK: - Max Retries Exhausted

    func test_maxRetriesExhausted_throws() async {
        var callCount = 0
        do {
            _ = try await withExponentialBackoff(maxRetries: 2, baseDelay: 0.01) {
                callCount += 1
                throw CloudBackendError.rateLimited(retryAfter: 0.01)
            }
            XCTFail("Should have thrown after max retries")
        } catch {
            guard let exhausted = error as? RetryExhaustedError, extractCloudError(exhausted) != nil else {
                XCTFail("Expected rateLimited, got: \(error)")
                return
            }
        }
        // 1 initial + 2 retries = 3 total attempts
        XCTAssertEqual(callCount, 3, "Should attempt maxRetries + 1 times")
    }

    // MARK: - Total Delay Cap

    func test_totalDelayCapRespected() async {
        var callCount = 0
        do {
            _ = try await withExponentialBackoff(maxRetries: 10, baseDelay: 0.01, maxTotalDelay: 0.02) {
                callCount += 1
                throw CloudBackendError.rateLimited(retryAfter: 0.05)
            }
            XCTFail("Should have thrown when total delay exceeded")
        } catch {
            guard let exhausted = error as? RetryExhaustedError, extractCloudError(exhausted) != nil else {
                XCTFail("Expected rateLimited, got: \(error)")
                return
            }
        }
        // Should stop retrying before exhausting all 10 retries.
        XCTAssertLessThan(callCount, 10, "Should stop before max retries due to delay cap")
    }

    // MARK: - Retries Network Error

    func test_withExponentialBackoff_retriesNetworkError() async throws {
        var callCount = 0
        let result: String = try await withExponentialBackoff(baseDelay: 0.01) {
            callCount += 1
            if callCount < 3 {
                throw CloudBackendError.networkError(
                    underlying: NSError(domain: "test", code: -1)
                )
            }
            return "recovered"
        }
        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(callCount, 3, "Should retry networkError twice before succeeding")
    }

    // MARK: - Does Not Retry Auth Error

    func test_withExponentialBackoff_doesNotRetryAuthError() async {
        var callCount = 0
        do {
            _ = try await withExponentialBackoff(baseDelay: 0.01) {
                callCount += 1
                throw CloudBackendError.authenticationFailed(provider: "Test")
            }
            XCTFail("Should have thrown")
        } catch {
            guard case CloudBackendError.authenticationFailed = error else {
                XCTFail("Expected authenticationFailed, got: \(error)")
                return
            }
        }
        XCTAssertEqual(callCount, 1, "Should not retry non-retryable authenticationFailed error")
    }

    // MARK: - Uses Retry-After Header

    func test_usesRetryAfterWhenProvided() async throws {
        var callCount = 0
        let start = Date()
        let result: String = try await withExponentialBackoff(maxRetries: 1, baseDelay: 10.0) {
            callCount += 1
            if callCount == 1 {
                // retryAfter of 0.05s should override the 10s baseDelay
                throw CloudBackendError.rateLimited(retryAfter: 0.05)
            }
            return "ok"
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(result, "ok")
        XCTAssertLessThan(elapsed, 2.0, "Should use retryAfter (0.05s) not baseDelay (10s)")
    }

    // MARK: - RetryStrategy Protocol

    func test_withRetry_succeedsOnFirstAttempt() async throws {
        let strategy = ExponentialBackoffStrategy(maxRetries: 3, baseDelay: 0.01)
        var callCount = 0
        let result = try await withRetry(strategy: strategy) {
            callCount += 1
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(callCount, 1)
    }

    func test_withRetry_retriesRetryableError() async throws {
        let strategy = ExponentialBackoffStrategy(maxRetries: 3, baseDelay: 0.01)
        var callCount = 0
        let result: String = try await withRetry(strategy: strategy) {
            callCount += 1
            if callCount < 3 {
                throw CloudBackendError.networkError(
                    underlying: NSError(domain: "test", code: -1)
                )
            }
            return "recovered"
        }
        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(callCount, 3)
    }

    func test_withRetry_doesNotRetryNonRetryableError() async {
        let strategy = ExponentialBackoffStrategy(maxRetries: 3, baseDelay: 0.01)
        var callCount = 0
        do {
            _ = try await withRetry(strategy: strategy) {
                callCount += 1
                throw CloudBackendError.authenticationFailed(provider: "Test")
            }
            XCTFail("Should have thrown")
        } catch {
            guard let cloud = error as? CloudBackendError,
                  case .authenticationFailed = cloud else {
                XCTFail("Expected authenticationFailed, got \(error)")
                return
            }
        }
        XCTAssertEqual(callCount, 1)
    }

    func test_withRetry_doesNotRetryNonBackendError() async {
        let strategy = ExponentialBackoffStrategy(maxRetries: 3, baseDelay: 0.01)
        var callCount = 0
        do {
            _ = try await withRetry(strategy: strategy) {
                callCount += 1
                throw NSError(domain: "custom", code: 99)
            }
            XCTFail("Should have thrown")
        } catch {
            XCTAssertEqual((error as NSError).code, 99)
        }
        XCTAssertEqual(callCount, 1, "Non-BackendError should not be retried")
    }

    func test_withRetry_throwsCancellationOnCancel() async {
        let strategy = ExponentialBackoffStrategy(maxRetries: 5, baseDelay: 10.0)
        let task = Task {
            try await withRetry(strategy: strategy) {
                throw CloudBackendError.rateLimited(retryAfter: 10.0)
            }
        }
        // Cancel quickly while it's sleeping during backoff.
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is CancellationError, "Should throw CancellationError, got \(error)")
        }
    }

    func test_exponentialBackoffStrategy_respectsTotalDelayCap() {
        let strategy = ExponentialBackoffStrategy(maxRetries: 10, baseDelay: 1.0, maxTotalDelay: 5.0)
        let error = CloudBackendError.rateLimited(retryAfter: 10.0)

        // With retryAfter=10s and maxTotalDelay=5s, first retry should be refused.
        let delay = strategy.delay(for: error, attempt: 0, totalDelayed: 0)
        XCTAssertNil(delay, "Should refuse retry when delay would exceed total cap")
    }

    func test_exponentialBackoffStrategy_returnsNilAfterMaxRetries() {
        let strategy = ExponentialBackoffStrategy(maxRetries: 2, baseDelay: 0.01)
        let error = CloudBackendError.networkError(underlying: URLError(.timedOut))

        XCTAssertNotNil(strategy.delay(for: error, attempt: 0, totalDelayed: 0))
        XCTAssertNotNil(strategy.delay(for: error, attempt: 1, totalDelayed: 0.01))
        XCTAssertNil(strategy.delay(for: error, attempt: 2, totalDelayed: 0.02))
    }

    func test_withRetry_retriesTimeoutError() async throws {
        let strategy = ExponentialBackoffStrategy(maxRetries: 3, baseDelay: 0.01)
        var callCount = 0
        let result: String = try await withRetry(strategy: strategy) {
            callCount += 1
            if callCount < 2 {
                throw CloudBackendError.timeout(.seconds(120))
            }
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        XCTAssertEqual(callCount, 2, "Timeout should be retried")
    }

    func test_withRetry_doesNotRetryBackendDeallocated() async {
        let strategy = ExponentialBackoffStrategy(maxRetries: 3, baseDelay: 0.01)
        var callCount = 0
        do {
            _ = try await withRetry(strategy: strategy) {
                callCount += 1
                throw CloudBackendError.backendDeallocated
            }
            XCTFail("Should have thrown")
        } catch {
            guard let cloud = error as? CloudBackendError,
                  case .backendDeallocated = cloud else {
                XCTFail("Expected backendDeallocated, got \(error)")
                return
            }
        }
        XCTAssertEqual(callCount, 1, "backendDeallocated should not be retried")
    }
}
