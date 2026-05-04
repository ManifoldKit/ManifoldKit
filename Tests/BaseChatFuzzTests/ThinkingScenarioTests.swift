#if Fuzz
import XCTest
import BaseChatInference
@testable import BaseChatFuzz

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
            outcome.events.contains { if case .thinkingComplete = $0 { return true } else { return false } },
            "maxThinkingTokens=0 must suppress every .thinkingComplete event"
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
            if case .thinkingComplete = e { return acc + 1 }
            return acc
        }
        XCTAssertLessThanOrEqual(
            completeCount,
            1,
            "cancelled stream must not fire .thinkingComplete more than once"
        )

        // If any thinkingComplete appeared at all, at least one thinkingToken
        // must have preceded it — the canonical "no dangling complete" rule.
        if let completeIdx = outcome.events.firstIndex(where: {
            if case .thinkingComplete = $0 { return true } else { return false }
        }) {
            let precedingTokens = outcome.events.prefix(completeIdx).contains {
                if case .thinkingToken = $0 { return true } else { return false }
            }
            XCTAssertTrue(precedingTokens, "dangling .thinkingComplete with no prior .thinkingToken")
        }
    }

    func test_thinkingAcrossRetry_atMostOneThinkingComplete() async throws {
        let outcome = try await ThinkingAcrossRetryScenario().run()
        XCTAssertTrue(
            outcome.invariantHeld,
            "Thinking-across-retry invariant failed: \(outcome.failureReason ?? "<unknown>")"
        )

        let completeCount = outcome.events.reduce(0) { acc, e in
            if case .thinkingComplete = e { return acc + 1 }
            return acc
        }
        XCTAssertLessThanOrEqual(
            completeCount,
            1,
            "retry must not surface more than one .thinkingComplete to the consumer"
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
