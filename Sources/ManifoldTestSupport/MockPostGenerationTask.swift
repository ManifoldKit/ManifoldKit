import Foundation
import ManifoldInference

/// Configurable mock for ``PostGenerationTask`` in tests.
///
/// Thread-safe via `@unchecked Sendable` — all mutations happen from test code
/// on the main actor or after the background task completes.
public final class MockPostGenerationTask: PostGenerationTask, @unchecked Sendable {

    /// Number of times ``run(message:session:)`` was called.
    public private(set) var callCount = 0

    /// Messages received by each invocation, in call order.
    public private(set) var receivedMessages: [ChatMessageRecord] = []

    /// Sessions received by each invocation, in call order.
    public private(set) var receivedSessions: [ChatSessionRecord] = []

    /// When non-nil, thrown on every call to ``run(message:session:)``.
    public var errorToThrow: Error? = nil

    /// Optional sleep before returning, to exercise cancellation paths.
    public var runDelay: Duration? = nil

    public init() {}

    public func run(message: ChatMessageRecord, session: ChatSessionRecord) async throws {
        callCount += 1
        receivedMessages.append(message)
        receivedSessions.append(session)
        if let delay = runDelay {
            try await Task.sleep(for: delay)
        }
        if let error = errorToThrow {
            throw error
        }
    }
}
