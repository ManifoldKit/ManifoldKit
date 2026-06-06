#if Fuzz
import XCTest
import ManifoldInference
@testable import ManifoldFuzz

/// Executes each ``FuzzScenario`` in ``ScenarioRegistry/all`` and asserts its
/// invariant held. Per CLAUDE.md, each test was sabotage-verified locally
/// (flip the relevant production emit path, watch the test fail, then
/// restore) before commit — see the PR body for the exact sabotage steps.
final class ThinkingScenarioTests: XCTestCase {

    func test_registryExposesExpectedScenarios() {
        let ids = ScenarioRegistry.all.map(\.id)
        XCTAssertTrue(ids.contains("thinking-budget-zero"), "Budget-zero scenario must be discoverable")
        XCTAssertTrue(ids.contains("cancel-during-thinking"), "Cancel-during-thinking scenario must be discoverable")
        XCTAssertTrue(ids.contains("thinking-across-retry"), "Thinking-across-retry scenario must be discoverable")
        XCTAssertTrue(ids.contains("kv-reuse-coverage"), "KV-reuse coverage scenario must be discoverable")
        XCTAssertTrue(ids.contains("mlx-vlm-gate"), "MLX VLM-gate scenario must be discoverable")
        XCTAssertTrue(ids.contains("warmup-cost"), "Warmup-cost scenario must be discoverable")
    }

    func test_kvReuseCoverage_invariantHolds() async throws {
        let outcome = try await KVReuseCoverageScenario().run()
        XCTAssertTrue(
            outcome.invariantHeld,
            "KV-reuse coverage invariant failed: \(outcome.failureReason ?? "<unknown>")"
        )

        // Every recorded `.kvCacheReuse` value must be non-negative — defensive
        // check against a backend that yields the count as a signed-int
        // overflow.
        let reuseValues = outcome.events.compactMap { event -> Int? in
            if case .kvCacheReuse(let n) = event { return n } else { return nil }
        }
        XCTAssertFalse(reuseValues.isEmpty, "scenario must record at least one .kvCacheReuse event")
        for value in reuseValues {
            XCTAssertGreaterThanOrEqual(value, 0, "promptTokensReused must never be negative")
        }
    }

    func test_warmupCost_recordsTtftDeltaInExtras() async throws {
        let outcome = try await WarmupCostScenario().run()
        XCTAssertTrue(
            outcome.invariantHeld,
            "Warmup-cost invariant failed: \(outcome.failureReason ?? "<unknown>")"
        )

        // The whole point of this scenario is the recorded numbers — assert
        // every required key is present and parseable so the summary script
        // never has to handle a half-populated record.
        XCTAssertNotNil(outcome.extras["ttft1Ms"], "TTFT-1 must be recorded")
        XCTAssertNotNil(outcome.extras["ttft2Ms"], "TTFT-2 must be recorded")
        XCTAssertNotNil(outcome.extras["warmupDeltaMs"], "warmup delta must be recorded")
        XCTAssertNotNil(outcome.extras["backendName"], "backend identity must be recorded")
        XCTAssertNotNil(outcome.extras["modelId"], "model identity must be recorded")

        if let ttft1 = outcome.extras["ttft1Ms"], let ttft2 = outcome.extras["ttft2Ms"], let delta = outcome.extras["warmupDeltaMs"] {
            XCTAssertNotNil(Double(ttft1), "ttft1Ms must parse back as a Double")
            XCTAssertNotNil(Double(ttft2), "ttft2Ms must parse back as a Double")
            XCTAssertNotNil(Double(delta), "warmupDeltaMs must parse back as a Double")
        }

        // Both turns must have produced at least one .token event — the
        // scenario's only correctness invariant beyond the recorded numbers.
        let tokenEventCount = outcome.events.reduce(0) { acc, e in
            if case .token = e { return acc + 1 }
            return acc
        }
        XCTAssertGreaterThanOrEqual(tokenEventCount, 2, "Two turns must each yield at least one token")
    }

    func test_thinkingBudgetZero_emitsNoThinkingEvents() async throws {
        let outcome = try await ThinkingBudgetZeroScenario().run()
        XCTAssertTrue(
            outcome.invariantHeld,
            "Budget-zero invariant failed: \(outcome.failureReason ?? "<unknown>")"
        )

        // Tighter per-invariant checks so a regression surfaces the exact
        // sub-invariant that broke rather than just "scenario failed".
        XCTAssertFalse(
            outcome.events.contains { if case .thinkingToken = $0 { return true } else { return false } },
            "maxThinkingTokens=0 must suppress every .thinkingToken event"
        )
        XCTAssertFalse(
            outcome.events.contains { if case .thinkingCompleted = $0 { return true } else { return false } },
            "maxThinkingTokens=0 must suppress every .thinkingCompleted event"
        )
        XCTAssertTrue(
            outcome.events.contains { if case .token = $0 { return true } else { return false } },
            "visible output must still arrive when thinking is disabled"
        )
    }

    func test_cancelDuringThinking_terminatesCleanly() async throws {
        let outcome = try await CancelDuringThinkingScenario().run()
        XCTAssertTrue(
            outcome.invariantHeld,
            "Cancel-during-thinking invariant failed: \(outcome.failureReason ?? "<unknown>")"
        )

        let completeCount = outcome.events.reduce(0) { acc, e in
            if case .thinkingCompleted = e { return acc + 1 }
            return acc
        }
        XCTAssertLessThanOrEqual(
            completeCount,
            1,
            "cancelled stream must not fire .thinkingCompleted more than once"
        )

        // If any thinkingCompleted appeared at all, at least one thinkingToken
        // must have preceded it — the canonical "no dangling complete" rule.
        if let completeIdx = outcome.events.firstIndex(where: {
            if case .thinkingCompleted = $0 { return true } else { return false }
        }) {
            let precedingTokens = outcome.events.prefix(completeIdx).contains {
                if case .thinkingToken = $0 { return true } else { return false }
            }
            XCTAssertTrue(precedingTokens, "dangling .thinkingCompleted with no prior .thinkingToken")
        }
    }

    func test_thinkingAcrossRetry_atMostOneThinkingComplete() async throws {
        let outcome = try await ThinkingAcrossRetryScenario().run()
        XCTAssertTrue(
            outcome.invariantHeld,
            "Thinking-across-retry invariant failed: \(outcome.failureReason ?? "<unknown>")"
        )

        let completeCount = outcome.events.reduce(0) { acc, e in
            if case .thinkingCompleted = e { return acc + 1 }
            return acc
        }
        XCTAssertLessThanOrEqual(
            completeCount,
            1,
            "retry must not surface more than one .thinkingCompleted to the consumer"
        )
    }

    func test_scenarioOutcome_producesFindingWhenInvariantBreaks() {
        let holding = ScenarioOutcome(scenarioId: "demo", invariantHeld: true)
        XCTAssertNil(holding.finding(modelId: "m1"), "A holding outcome must not produce a finding")

        let broken = ScenarioOutcome(
            scenarioId: "demo",
            invariantHeld: false,
            failureReason: "because reasons"
        )
        let finding = broken.finding(modelId: "m1")
        XCTAssertNotNil(finding, "A broken outcome must produce a finding")
        XCTAssertEqual(finding?.detectorId, "scenario/demo")
        XCTAssertEqual(finding?.subCheck, "invariant")
        XCTAssertEqual(finding?.trigger, "because reasons")
    }
}
#endif
