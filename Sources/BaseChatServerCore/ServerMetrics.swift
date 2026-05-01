import Foundation

package struct ServerMetricsSnapshot: Equatable, Sendable {
    package var requests: Int
    package var inFlightGenerations: Int
    package var completions: Int
    package var failures: Int
    package var tokens: Int

    package init(
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

package struct ServerMetrics: Sendable {
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

    package init() {
        self.storage = Storage()
    }

    package func snapshot() -> ServerMetricsSnapshot {
        storage.read()
    }

    package func recordRequestStarted() {
        storage.mutate { $0.requests += 1 }
    }

    package func recordRequestCompleted() {}

    package func recordGenerationStarted() {
        storage.mutate { $0.inFlightGenerations += 1 }
    }

    package func recordGenerationCompleted(tokenCount: Int = 0) {
        storage.mutate {
            $0.inFlightGenerations = max(0, $0.inFlightGenerations - 1)
            $0.completions += 1
            $0.tokens += tokenCount
        }
    }

    package func recordGenerationFailed() {
        storage.mutate {
            $0.inFlightGenerations = max(0, $0.inFlightGenerations - 1)
            $0.failures += 1
        }
    }

    package func recordFailure() {
        storage.mutate { $0.failures += 1 }
    }
}
