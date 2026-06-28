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
/// https://github.com/ManifoldKit/ManifoldKit/issues/1684 parallelized the fan-out;
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
    /// single provider (~50 ms), not the sum (~150 ms). The assertion is
    /// relative — pipeline wall time vs a same-process sequential walk of the
    /// identical providers — because an absolute ceiling cannot tolerate
    /// loaded CI runners (a 120 ms ceiling flaked twice at ~160 ms while the
    /// fan-out was demonstrably still concurrent). Scheduler load inflates
    /// both measurements together; the ratio survives it.
    func test_threeProvidersRunConcurrently() async throws {
        let providers: [any PromptContextProvider] = [
            SleepingProvider(sleep: .milliseconds(50)),
            SleepingProvider(sleep: .milliseconds(50)),
            SleepingProvider(sleep: .milliseconds(50)),
        ]
        let pipeline = PromptContextPipeline(providers: providers)

        let clock = ContinuousClock()
        let concurrent = try await clock.measure {
            _ = try await pipeline.assemble(messageCount: 0)
        }
        // Sequential baseline: the same three providers awaited back-to-back
        // under the same scheduler conditions (~150 ms unloaded).
        let sequential = try await clock.measure {
            for provider in providers {
                _ = try await provider.contributeSlots(messageCount: 0)
            }
        }

        // True fan-out lands near 1/3 of the sequential walk; a regression to
        // sequential execution lands near 1.0. 0.75 splits them with generous
        // jitter slack in both directions.
        // Tracked by https://github.com/ManifoldKit/ManifoldKit/issues/1684
        let ratio = concurrent / sequential
        XCTAssertLessThan(
            ratio,
            0.75,
            """
            PromptContextPipeline ran in \(concurrent) vs \(sequential) for the \
            sequential walk of the same providers (ratio \(ratio)) — expected \
            < 0.75 for concurrent fan-out. A ratio near 1.0 means the pipeline \
            is no longer running providers concurrently.
            """
        )
    }
}
