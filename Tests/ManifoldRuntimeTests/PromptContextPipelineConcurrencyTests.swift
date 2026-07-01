import XCTest
@testable import ManifoldRuntime
@testable import ManifoldInference

/// Concurrency contract for ``PromptContextPipeline``'s provider fan-out.
///
/// `PromptContextPipeline.assemble(messageCount:)` queries every registered
/// provider concurrently via a throwing task group, then reassembles their
/// contributions in registration order before sorting. With N independent
/// providers, all N should therefore be in-flight simultaneously — the whole
/// point of the fan-out.
///
/// This test asserts that contract **directly and deterministically**: each
/// provider marks itself in-flight against a shared actor gauge, holds briefly
/// so its siblings overlap, then marks itself done. Concurrent fan-out drives
/// the gauge's peak to N (all in-flight at once); a regression to sequential
/// execution — where each provider fully completes before the next starts —
/// caps the peak at 1.
///
/// **History**: this was `PromptContextPipelineSequentialTests`, which pinned a
/// ~150 ms sequential baseline as a perf-audit regression marker. Issue
/// https://github.com/ManifoldKit/ManifoldKit/issues/1684 parallelized the fan-out
/// and the assertion flipped to prove concurrency. That proof was originally a
/// wall-clock ratio (concurrent-time / sequential-time < 0.75), which flaked on
/// loaded CI runners: additive scheduler wake-latency inflates the concurrent
/// measurement disproportionately (its wall time is one sleep plus wake latency,
/// so a fixed latency floor dominates), pushing the ratio toward 1.0 while the
/// fan-out was demonstrably still concurrent (observed 0.815 on the nightly
/// runner — issue #2085). The peak-concurrency gauge below carries no wall-clock
/// dependency, so it is immune to scheduler load.
///
/// Default-CI gated — runs in every PR build. The cost is negligible; what
/// matters is the assertion contract.
final class PromptContextPipelineConcurrencyTests: XCTestCase {

    /// Records the peak number of providers running at the same instant.
    private actor ConcurrencyGauge {
        private var inFlight = 0
        private(set) var peak = 0

        func enter() {
            inFlight += 1
            peak = max(peak, inFlight)
        }

        func leave() {
            inFlight -= 1
        }
    }

    /// Provider that marks itself in-flight, holds long enough for its fanned-out
    /// siblings to enter before it leaves, then marks itself done. Under true
    /// concurrent fan-out every provider enters before any leaves, so the gauge
    /// peaks at N. Under sequential execution each provider runs to completion in
    /// isolation, so `inFlight` never exceeds 1.
    ///
    /// The hold is a plain `Task.sleep`. Scheduler load can make the sleep *wake
    /// late*, but every provider still calls `enter()` before it sleeps, so the
    /// peak is unaffected — that is exactly the property the old wall-clock ratio
    /// lacked.
    private struct GaugedProvider: PromptContextProvider {
        let gauge: ConcurrencyGauge

        func contributeSlots(messageCount: Int) async throws -> [PromptSlot] {
            await gauge.enter()
            try await Task.sleep(for: .milliseconds(100))
            await gauge.leave()
            return []
        }
    }

    /// Three providers fanned out concurrently are all in-flight at once, so the
    /// gauge's peak is 3. A regression to sequential execution caps it at 1.
    /// Tracked by https://github.com/ManifoldKit/ManifoldKit/issues/1684
    func test_threeProvidersRunConcurrently() async throws {
        let gauge = ConcurrencyGauge()
        let providers: [any PromptContextProvider] = [
            GaugedProvider(gauge: gauge),
            GaugedProvider(gauge: gauge),
            GaugedProvider(gauge: gauge),
        ]
        let pipeline = PromptContextPipeline(providers: providers)

        _ = try await pipeline.assemble(messageCount: 0)

        let peak = await gauge.peak
        XCTAssertEqual(
            peak,
            3,
            """
            Expected all 3 providers in-flight simultaneously (peak concurrency \
            3) but observed \(peak). A peak of 1 means the pipeline serialized \
            the fan-out instead of running providers concurrently.
            """
        )
    }
}
