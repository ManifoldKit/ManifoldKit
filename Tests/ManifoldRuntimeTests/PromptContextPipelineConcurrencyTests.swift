import XCTest
@testable import ManifoldRuntime
@testable import ManifoldInference

/// Concurrency contract for ``PromptContextPipeline``'s provider fan-out.
///
/// `PromptContextPipeline.assemble(messageCount:)` queries every registered
/// provider concurrently via a throwing task group, then reassembles their
/// contributions in registration order before sorting. Total wall time for N
/// independent providers is therefore ~the slowest single provider, not the
/// sum of their latencies. This test drives the pipeline with three providers
/// that each sleep 50 ms and asserts the observed wall time is consistent with
/// concurrent execution (~50 ms), not sequential (~150 ms).
///
/// **History**: this was `PromptContextPipelineSequentialTests`, which pinned
/// the ~150 ms sequential baseline as a perf-audit regression marker. Issue
/// https://github.com/roryford/ManifoldKit/issues/1684 parallelized the fan-out;
/// the assertion flipped from `>= 140 ms` to `< 120 ms`, proving the fan-out
/// actually happened.
///
/// Default-CI gated — runs in every PR build, not nightly. The cost is
/// negligible; what matters is the assertion contract.
final class PromptContextPipelineConcurrencyTests: XCTestCase {

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

    /// Three 50 ms providers run concurrently; total wall time is ~the slowest
    /// single provider (~50 ms), not the sum (~150 ms). Asserts < 120 ms, which
    /// is comfortably below the 140 ms sequential floor while leaving generous
    /// scheduling-jitter slack for loaded CI runners.
    func test_threeProvidersRunConcurrently() async throws {
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

        // Concurrent fan-out: three 50 ms sleeps overlap = ~50 ms.
        // Sequential execution would land at ~150 ms.
        // The 120 ms ceiling distinguishes the two and tolerates scheduling
        // jitter on loaded CI runners.
        // Tracked by https://github.com/roryford/ManifoldKit/issues/1684
        XCTAssertLessThan(
            elapsed,
            .milliseconds(120),
            """
            PromptContextPipeline ran in \(elapsed) — expected < 120 ms for \
            concurrent execution of three 50 ms providers. If this exceeded \
            120 ms, the pipeline is no longer running providers concurrently \
            (regressed to the sequential ~150 ms walk).
            """
        )
    }
}
