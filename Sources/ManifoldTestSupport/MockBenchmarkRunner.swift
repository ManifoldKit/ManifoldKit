import Foundation
import ManifoldInference

/// Mock benchmark runner for testing. Returns a configurable result or throws on demand.
public final class MockBenchmarkRunner: ModelBenchmarkRunner, @unchecked Sendable {

    /// The result returned by ``runBenchmark(for:)``.
    public var result: ModelBenchmarkResult

    /// When `true`, ``runBenchmark(for:)`` throws instead of returning a result.
    public var shouldThrow: Bool = false

    /// Number of times ``runBenchmark(for:)`` has been called.
    public private(set) var callCount: Int = 0

    public init(result: ModelBenchmarkResult = ModelBenchmarkResult(tier: .fast)) {
        self.result = result
    }

    public func runBenchmark(for model: ModelInfo) async throws -> ModelBenchmarkResult {
        callCount += 1
        if shouldThrow {
            throw NSError(domain: "MockBenchmarkRunner", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Mock benchmark error"
            ])
        }
        return result
    }
}
