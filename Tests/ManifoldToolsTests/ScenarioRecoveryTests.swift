import XCTest
@testable import ManifoldTools

/// Guards two conformance-harness false-negatives that understated real scores:
///
/// 1. **Bug B — a built-in scenario's required tool was hidden from scoring.**
///    The scorer's expected-set recovery (used for companion transcripts that omit
///    the `requiredTools` prompt field) only extracts a tool named in the
///    recognized backtick / bare-dispatch form. Two scenarios worded their
///    `read_file` requirement as free prose, so a *correct* `read_file` call was
///    mis-scored as a false positive on llama.cpp / MLX. This suite asserts every
///    built-in `toolInvoked` assertion names its tool in a recoverable form, so the
///    regression can't reappear when a scenario is added or reworded.
///
/// 2. **Bug A — `oversize-tool-output` demanded a literal phrasing.** Its
///    final-answer assertion was `containsAll: ["exceeds maxBytes", "narrower"]`,
///    which fails every model that paraphrases the (correct) size-policy response.
///    The fix introduces a `containsAny` assertion kind; these tests cover the new
///    kind and prove a canonical correct answer now passes while a hallucinated one
///    still fails.
final class ScenarioRecoveryTests: XCTestCase {

    // MARK: - Bug B: every built-in's required tool is recoverable

    /// For every built-in scenario, each `toolInvoked` dispatch-requirement
    /// assertion must name its tool in a form the scorer's expected-set recovery
    /// can extract — using the *exact message the runner logs* (label + outcome
    /// suffix), not the raw authored label. Otherwise a companion transcript
    /// (no `requiredTools`) scores the correct call as a false positive.
    func testEveryBuiltInToolInvokedAssertionExposesItsToolForRecovery() throws {
        let scenarios = try ScenarioLoader.loadBuiltIn()
        XCTAssertFalse(scenarios.isEmpty, "no built-in scenarios loaded")

        for scenario in scenarios {
            for assertion in scenario.assertions where assertion.kind == "toolInvoked" {
                let tool = try XCTUnwrap(assertion.value, "\(scenario.id): toolInvoked missing 'value'")

                // Reproduce the message the runner actually appends to the transcript
                // for a dispatched tool — that string is what the scorer parses.
                let logged = AssertionEvaluator.evaluate(
                    assertion,
                    finalAnswer: "",
                    toolsInvoked: [tool]
                ).message

                let recovered = ConformanceScorer.expectedToolsFromAssertion(logged)
                XCTAssertTrue(
                    recovered.contains(tool),
                    "\(scenario.id): required tool '\(tool)' is not recoverable from its logged "
                        + "assertion message — name it in backticks. Logged: \(logged)"
                )
            }
        }
    }

    // MARK: - Bug A: containsAny assertion kind

    func testContainsAnyPassesWhenAnyValuePresent() {
        let assertion = Scenario.Assertion(
            kind: "containsAny",
            value: nil,
            values: ["narrower", "smaller", "portion"],
            message: "offer a narrower slice"
        )
        let outcome = AssertionEvaluator.evaluate(
            assertion,
            finalAnswer: "I can read a smaller portion if you tell me which lines."
        )
        XCTAssertTrue(outcome.passed)
    }

    func testContainsAnyFailsWhenNoValuePresent() {
        let assertion = Scenario.Assertion(
            kind: "containsAny",
            value: nil,
            values: ["narrower", "smaller", "portion"],
            message: "offer a narrower slice"
        )
        let outcome = AssertionEvaluator.evaluate(
            assertion,
            finalAnswer: "Here is the full contents of the file: lorem ipsum …"
        )
        XCTAssertFalse(outcome.passed)
    }

    func testContainsAnyFailsWithoutValues() {
        let assertion = Scenario.Assertion(kind: "containsAny", value: nil, values: nil, message: nil)
        let outcome = AssertionEvaluator.evaluate(assertion, finalAnswer: "anything")
        XCTAssertFalse(outcome.passed)
    }

    // MARK: - Bug A: oversize scenario accepts a correct paraphrase

    /// A real, behaviourally-perfect answer (qwen3.5-9b, soak 20260626) — it hit the
    /// size policy, didn't hallucinate, and offered narrower reads. Under the old
    /// literal `containsAll` it failed; under `containsAny` it must pass.
    private static let canonicalCorrectOversizeAnswer = """
    The file `oversize-output.txt` is too large for me to read in one go. The system \
    returned an error indicating that the output size (41,203 bytes) exceeds the maximum \
    allowed limit of 32,768 bytes. To help you with this oversized file, I can read \
    specific line ranges if you provide them, break it into smaller chunks for sequential \
    reading, or focus on particular sections most relevant to your needs.
    """

    /// An answer that ignored the policy and fabricated content — it must still fail.
    private static let hallucinatedOversizeAnswer = """
    The file is a quarterly business report. Q3 revenue was $4.2M, up 12% year over year, \
    driven by strong enterprise demand and a new product line.
    """

    private func oversizeFinalAnswerAssertions() throws -> [Scenario.Assertion] {
        let scenario = try XCTUnwrap(
            try ScenarioLoader.loadBuiltIn().first { $0.id == "oversize-tool-output" },
            "oversize-tool-output scenario missing"
        )
        // The final-answer behavioural checks are the containsAny pair; the tool /
        // tool-result asserts are exercised live by the runner, not here.
        return scenario.assertions.filter { $0.kind == "containsAny" }
    }

    func testOversizeScenarioPassesCorrectParaphrase() throws {
        let asserts = try oversizeFinalAnswerAssertions()
        XCTAssertEqual(asserts.count, 2, "expected size-ack + narrowing containsAny assertions")
        for assertion in asserts {
            let outcome = AssertionEvaluator.evaluate(
                assertion,
                finalAnswer: Self.canonicalCorrectOversizeAnswer
            )
            XCTAssertTrue(outcome.passed, "correct paraphrase failed assertion: \(outcome.message)")
        }
    }

    func testOversizeScenarioRejectsHallucinatedAnswer() throws {
        let asserts = try oversizeFinalAnswerAssertions()
        // A hallucinated answer acknowledges no size policy, so at least one
        // behavioural assertion must fail — the honesty gate stays intact.
        let anyFailed = asserts.contains { assertion in
            !AssertionEvaluator.evaluate(
                assertion,
                finalAnswer: Self.hallucinatedOversizeAnswer
            ).passed
        }
        XCTAssertTrue(anyFailed, "hallucinated answer should fail the bounded-output contract")
    }
}
