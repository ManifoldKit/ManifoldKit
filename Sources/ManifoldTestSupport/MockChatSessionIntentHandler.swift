import Foundation
import ManifoldRuntime

/// Recording mock for ``ChatSessionIntentHandler``.
///
/// Captures every `(action, sessionID)` invocation in a thread-safe array
/// so tests can assert on dispatch order without coordinating actor hops.
/// Optionally throws a configured error from ``handle(_:sessionID:)`` when
/// a test needs to exercise error propagation through `ChatViewModel.dispatch`.
public final class MockChatSessionIntentHandler: ChatSessionIntentHandler, @unchecked Sendable {

    /// One recorded invocation of ``handle(_:sessionID:)``.
    public struct Invocation: Sendable, Equatable {
        public let action: ChatIntentAction
        public let sessionID: UUID?

        public init(action: ChatIntentAction, sessionID: UUID?) {
            self.action = action
            self.sessionID = sessionID
        }
    }

    private let lock = NSLock()
    private var _invocations: [Invocation] = []

    /// Error to throw on the next call to ``handle(_:sessionID:)``.
    /// When `nil` (the default) the handler records and returns successfully.
    public var errorToThrow: Error?

    public init() {}

    /// Snapshot of every invocation recorded so far, in order.
    public var invocations: [Invocation] {
        withLock { _invocations }
    }

    public func handle(_ action: ChatIntentAction, sessionID: UUID?) async throws {
        let error: Error? = withLock {
            _invocations.append(Invocation(action: action, sessionID: sessionID))
            return errorToThrow
        }

        if let error {
            throw error
        }
    }

    /// NSLock helper kept non-async so the lock/unlock pair never crosses a
    /// suspension point — `NSLock.lock()` is unavailable from async contexts
    /// in the Swift 6 concurrency model. Mirrors the pattern used by
    /// ``ChaosBackend``.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
