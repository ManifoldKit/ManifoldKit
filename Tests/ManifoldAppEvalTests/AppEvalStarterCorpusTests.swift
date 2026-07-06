import XCTest
import ManifoldAppEval

// MARK: - AppEvalStarterCorpusTests

/// Executes every public starter scenario through the scripted lane — the
/// corpus is the advertised app-facing entry point (docs/APP-EVAL.md step 3),
/// so it must be proven runnable in-repo, not just compiled.
@MainActor
final class AppEvalStarterCorpusTests: XCTestCase {

    func test_allStarterScenarios_passInScriptedMode() async throws {
        XCTAssertFalse(AppEvalStarterCorpus.all.isEmpty)
        for scenario in AppEvalStarterCorpus.all {
            let result = try await RuntimeScenarioRunner.run(scenario)
            XCTAssertTrue(
                result.subsequencePassed,
                "starter scenario '\(scenario.id)' failed: \(result.subsequenceFailureReason ?? "no reason")"
            )
        }
    }

    /// The documented throwing helper (docs/APP-EVAL.md) is the XCTest-free
    /// pass/fail surface — verify both directions: it is silent on pass and
    /// throws a descriptive error on failure.
    func test_checkPassed_throwsDescriptiveErrorOnFailure() async throws {
        // Passing case: the starter smoke scenario checks cleanly.
        let passing = try await RuntimeScenarioRunner.run(.starterSendReceiveSmoke)
        XCTAssertNoThrow(try passing.checkPassed())

        // Failing case: same scripted turns, impossible expected subsequence.
        let impossible = RuntimeScenario(
            id: "impossible-subsequence",
            displayName: "Impossible",
            scenarioDescription: "Expects a tool call no script produces.",
            userMessages: ["Hello."],
            scriptedTurns: [.tokens(["Hi"])],
            expectedSubsequence: [.toolCallRequested]
        )
        let failing = try await RuntimeScenarioRunner.run(impossible)
        XCTAssertThrowsError(try failing.checkPassed()) { error in
            let description = String(describing: error)
            XCTAssertTrue(description.contains("impossible-subsequence"), description)
        }
    }
}
