#if Server
import Foundation

internal struct ServerMetricsSnapshot: Equatable, Sendable {
    internal var requests: Int
    internal var inFlightGenerations: Int
    internal var completions: Int
    internal var failures: Int
    internal var tokens: Int

    internal init(
        requests: Int = 0,
        inFlightGenerations: Int = 0,
        completions: Int = 0,
        failures: Int = 0,
        tokens: Int = 0
    ) {
        self.requests = requests
        self.inFlightGenerations = inFlightGenerations
        self.completions = completions
        self.failures = failures
        self.tokens = tokens
    }
}

internal struct ServerMetrics: Sendable {
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot = ServerMetricsSnapshot()

        func read() -> ServerMetricsSnapshot {
            lock.withLock { snapshot }
        }

        func mutate(_ body: (inout ServerMetricsSnapshot) -> Void) {
            lock.withLock {
                body(&snapshot)
            }
        }
    }

    private let storage: Storage

    internal init() {
        self.storage = Storage()
    }

    internal func snapshot() -> ServerMetricsSnapshot {
        storage.read()
    }

    internal func recordRequestStarted() {
        storage.mutate { $0.requests += 1 }
    }

    internal func recordRequestCompleted() {}

    internal func recordGenerationStarted() {
        storage.mutate { $0.inFlightGenerations += 1 }
    }

    internal func recordGenerationCompleted(tokenCount: Int = 0) {
        storage.mutate {
            $0.inFlightGenerations = max(0, $0.inFlightGenerations - 1)
            $0.completions += 1
            $0.tokens += tokenCount
        }
    }

    internal func recordGenerationFailed() {
        storage.mutate {
            $0.inFlightGenerations = max(0, $0.inFlightGenerations - 1)
            $0.failures += 1
        }
    }

    internal func recordFailure() {
        storage.mutate { $0.failures += 1 }
    }
}

#endif
