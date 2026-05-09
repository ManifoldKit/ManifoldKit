import Foundation

// MARK: - RetryStrategy Protocol

/// Determines whether and how long to wait before retrying a failed operation.
///
/// Implementations decide based on the error type, attempt number, and
/// cumulative delay whether another attempt should be made.
public protocol RetryStrategy: Sendable {
    /// Returns the delay before the next retry, or `nil` to stop retrying.
    ///
    /// - Parameters:
    ///   - error: The error from the most recent failed attempt.
    ///   - attempt: Zero-based attempt number (0 = first retry after initial failure).
    ///   - totalDelayed: Cumulative delay already spent across all retries.
    /// - Returns: Delay in seconds, or `nil` to propagate the error immediately.
    func delay(for error: any Error, attempt: Int, totalDelayed: TimeInterval) -> TimeInterval?
}

// MARK: - ExponentialBackoffStrategy

/// Retry strategy with exponential backoff, jitter, and total delay cap.
///
/// Retries errors that conform to ``BackendError`` where `isRetryable` is true.
/// Uses `Retry-After` from ``CloudBackendError/rateLimited(retryAfter:)`` when
/// available, otherwise falls back to exponential backoff with 25% jitter.
///
/// The `jitterProvider` closure receives the maximum allowed jitter (25% of the
/// exponential delay) and returns the actual jitter to apply. The default draws
/// from a live `SystemRandomNumberGenerator`. In tests, pass `{ _ in 0.0 }` for
/// deterministic delay bounds or `{ $0 }` to lock jitter at its maximum.
public struct ExponentialBackoffStrategy: RetryStrategy, Sendable {
    public let maxRetries: Int
    public let baseDelay: TimeInterval
    public let maxTotalDelay: TimeInterval
    /// Returns the jitter to add, given the maximum jitter ceiling for this attempt.
    public let jitterProvider: @Sendable (Double) -> Double

    public init(
        maxRetries: Int = 3,
        baseDelay: TimeInterval = 1.0,
        maxTotalDelay: TimeInterval = 60.0,
        jitterProvider: @escaping @Sendable (Double) -> Double = { Double.random(in: 0...$0) }
    ) {
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxTotalDelay = maxTotalDelay
        self.jitterProvider = jitterProvider
    }

    public func delay(for error: any Error, attempt: Int, totalDelayed: TimeInterval) -> TimeInterval? {
        // Only retry errors that declare themselves retryable.
        if let backendError = error as? any BackendError {
            guard backendError.isRetryable else { return nil }
        } else {
            // Non-BackendError errors are not retried.
            return nil
        }

        guard attempt < maxRetries else { return nil }

        // Use Retry-After header for rate limits when available.
        let retryAfter: TimeInterval?
        if let cloud = error as? CloudBackendError, case .rateLimited(let ra) = cloud {
            retryAfter = ra
        } else {
            retryAfter = nil
        }

        let exponentialDelay = baseDelay * pow(2.0, Double(attempt))
        let maxJitter = exponentialDelay * 0.25
        // Clamp the injected jitter to [0, maxJitter] and reject NaN. This keeps
        // a misbehaving jitterProvider from producing negative or >max delays.
        let rawJitter = jitterProvider(maxJitter)
        let jitter = rawJitter.isFinite ? min(max(rawJitter, 0.0), maxJitter) : 0.0
        let delay = retryAfter ?? (exponentialDelay + jitter)

        guard totalDelayed + delay <= maxTotalDelay else { return nil }

        return delay
    }
}

// MARK: - RetryExhaustedError

/// Thrown when all retry attempts have been exhausted.
///
/// Wraps the last error encountered so callers can distinguish "failed after
/// retries" from a single failure.
public struct RetryExhaustedError: Error, LocalizedError {
    /// The error from the final retry attempt.
    public let lastError: any Error
    /// Total number of attempts made (initial + retries).
    public let attempts: Int

    public var errorDescription: String? {
        "Operation failed after \(attempts) attempts: \(lastError.localizedDescription)"
    }
}

// MARK: - withRetry

/// Executes an async operation with a configurable retry strategy.
///
/// - Parameters:
///   - strategy: The retry strategy that determines backoff timing and stop conditions.
///   - sleeper: Called to perform each retry delay. Defaults to `Task.sleep`, which blocks
///     the real wall clock. Inject a ``RecordingRetrySleeper`` in tests to assert delay
///     bounds without real-time blocking.
///   - operation: The async throwing operation to execute.
/// - Returns: The result of the operation.
/// - Throws: The last error if all retries are exhausted (wrapped in ``RetryExhaustedError``),
///   `CancellationError` if the task is cancelled during a retry delay,
///   or any non-retryable error immediately.
public func withRetry<T>(
    strategy: some RetryStrategy,
    sleeper: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    operation: () async throws -> T
) async throws -> T {
    var totalDelayed: TimeInterval = 0

    for attempt in 0... {
        do {
            return try await operation()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }

            // Non-retryable and non-backend errors pass through immediately.
            if let backendError = error as? any BackendError {
                if !backendError.isRetryable { throw error }
            } else {
                throw error
            }

            guard let delay = strategy.delay(for: error, attempt: attempt, totalDelayed: totalDelayed) else {
                throw RetryExhaustedError(lastError: error, attempts: attempt + 1)
            }

            Log.network.info("Retryable error (attempt \(attempt + 1), \(error)). Retrying in \(String(format: "%.1f", delay))s")

            // Round (not truncate) to milliseconds so sub-millisecond Retry-After
            // values like 0.0005s don't collapse to a zero-duration sleep.
            try await sleeper(.milliseconds(Int((delay * 1000).rounded())))
            totalDelayed += delay

            if Task.isCancelled {
                throw CancellationError()
            }
        }
    }

    // Unreachable — the loop is unbounded and exits via return or throw.
    throw RetryExhaustedError(lastError: CloudBackendError.networkError(underlying: URLError(.unknown)), attempts: 0)
}

// MARK: - Backward Compatibility

/// Executes an async operation with exponential backoff on retryable errors.
///
/// Convenience wrapper around ``withRetry(strategy:sleeper:operation:)`` using
/// ``ExponentialBackoffStrategy``.
func withExponentialBackoff<T>(
    maxRetries: Int = 3,
    baseDelay: TimeInterval = 1.0,
    maxTotalDelay: TimeInterval = 60.0,
    operation: () async throws -> T
) async throws -> T {
    try await withRetry(
        strategy: ExponentialBackoffStrategy(
            maxRetries: maxRetries,
            baseDelay: baseDelay,
            maxTotalDelay: maxTotalDelay
        ),
        operation: operation
    )
}
