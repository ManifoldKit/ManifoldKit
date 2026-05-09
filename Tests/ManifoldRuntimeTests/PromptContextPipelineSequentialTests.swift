import XCTest
@testable import ManifoldRuntime
@testable import ManifoldInference

/// Perf-audit baseline (PR-β work unit β-3) for ``PromptContextPipeline``'s
/// sequential provider walk.
///
/// `PromptContextPipeline.assemble(messageCount:)` queries every registered
/// provider in registration order with `await` between each call, so total
/// wall time for N independent providers is the sum of their latencies. This
/// test drives the pipeline with three providers that each sleep 50 ms and
/// asserts the observed wall time is consistent with sequential execution.
///
/// **Why this exists**: the audit flagged this as a parallelization candidate.
/// Today's wall time should be ~150 ms; concurrent fan-out via `async let`
/// or `withTaskGroup` would drop to ~50 ms for the same workload. This test
/// is the regression baseline. After the eventual fix lands, the assertion
/// flips to `< 80 ms` (50 ms sleep + scheduling slack) and proves the
/// fan-out actually happened.
///
/// Default-CI gated — runs in every PR build, not nightly. The 150 ms cost is
/// negligible; what matters is the assertion contract.
final class PromptContextPipelineSequentialTests: XCTestCase {

    /// Provider that sleeps for a fixed duration before returning empty slots.
    /// Sleeping in `Task.sleep` simulates an I/O-bound provider (retrieval,
    /// DB read, RPC) — the dominant shape of real providers.
    private struct SleepingProvider: PromptContextProvider {
        let sleep: Duration

        func contributeSlots(messageCount: Int) async throws -> [PromptSlot] {
            try await Task.sleep(for: sleep)
            return []
        }
    }

    /// Three 50 ms providers run sequentially today; total wall time is the
    /// sum (~150 ms). Asserts >= 140 ms to leave 10 ms of jitter slack while
    /// still distinguishing sequential from concurrent execution.
    func test_threeProvidersRunSequentially() async throws {
        let providers: [any PromptContextProvider] = [
            SleepingProvider(sleep: .milliseconds(50)),
            SleepingProvider(sleep: .milliseconds(50)),
            SleepingProvider(sleep: .milliseconds(50)),
        ]
        let pipeline = PromptContextPipeline(providers: providers)

        let clock = ContinuousClock()
        let elapsed = try await clock.measure {
            _ = try await pipeline.assemble(messageCount: 0)
        }

        // Sequential execution: three 50 ms sleeps = ~150 ms.
        // Concurrent fan-out would land in ~50 ms.
        // The 140 ms floor distinguishes the two and tolerates scheduling jitter.
        XCTAssertGreaterThanOrEqual(
            elapsed,
            .milliseconds(140),
            """
            PromptContextPipeline ran in \(elapsed) — expected >= 140 ms for \
            sequential execution. If this dropped below 140 ms, the pipeline \
            now runs providers concurrently; flip this assertion to < 80 ms \
            and update the comment.
            """
        )
    }
}
