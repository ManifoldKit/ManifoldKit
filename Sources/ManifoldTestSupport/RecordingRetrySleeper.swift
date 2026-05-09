import Foundation
import os

/// Records the durations passed to each retry delay call without blocking real time.
///
/// Inject via `backend.retrySleeper = recorder.asSleeper` before exercising a retry
/// path. After the operation, read `recordedSleeps` to assert delay bounds without
/// relying on wall-clock timing.
///
/// Example:
/// ```swift
/// let recorder = RecordingRetrySleeper()
/// backend.retrySleeper = recorder.asSleeper
/// backend.retryStrategy = ExponentialBackoffStrategy(
///     maxRetries: 3, baseDelay: 1.0, jitterProvider: { _ in 0 }
/// )
/// // … exercise the backend …
/// XCTAssertEqual(recorder.recordedSleeps.count, 2)
/// XCTAssertEqual(recorder.recordedSleeps[0], .milliseconds(1000))
/// XCTAssertEqual(recorder.recordedSleeps[1], .milliseconds(2000))
/// ```
public final class RecordingRetrySleeper: @unchecked Sendable {
    private let state = OSAllocatedUnfairLock(initialState: [Duration]())

    public init() {}

    /// All durations that were passed to the sleeper, in call order.
    public var recordedSleeps: [Duration] {
        state.withLock { $0 }
    }

    /// A `@Sendable` closure suitable for `backend.retrySleeper` or
    /// `withRetry(strategy:sleeper:operation:)` that records each requested
    /// duration without actually sleeping.
    public var asSleeper: @Sendable (Duration) async throws -> Void {
        { [self] duration in
            self.state.withLock { $0.append(duration) }
        }
    }
}
