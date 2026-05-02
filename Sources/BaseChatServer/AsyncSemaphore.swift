#if Server
import Foundation

internal actor AsyncSemaphore {
    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Error>] = []

    internal init(value: Int) {
        let sanitized = max(1, value)
        self.limit = sanitized
        self.available = sanitized
    }

    internal func wait() async throws {
        if available > 0 {
            available -= 1
            return
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(continuation)
            }
        } onCancel: {
            Task { await self.cancelFirstWaiter() }
        }
    }

    internal func signal() {
        if waiters.isEmpty {
            available = min(limit, available + 1)
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func cancelFirstWaiter() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume(throwing: CancellationError())
    }
}

#endif
