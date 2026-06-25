import XCTest
@testable import ManifoldTools

/// Golden-transcript regression for the tool-call true-positive attribution bug:
/// a llama.cpp Mistral run that dispatched the *correct* tool on every scenario
/// (assertions `passed: true`) was scored `toolTP=0, toolFP=1, f1=0`.
///
/// Root cause: the manifold-llama soak emitter renders the dispatch-requirement
/// assertion's required-tool token WITHOUT backticks for some scenarios
/// (`Scenario requires list_dir to actually be dispatched`) while wrapping it for
/// others (`Scenario requires `now` to actually be dispatched`). The scorer's
/// expected-set recovery only extracted backtick-quoted tokens, so the bare-token
/// scenarios recovered an *empty* expected set — and the correct call then landed
/// in `calledTools − expectedTools` as a false positive instead of a true positive.
final class ConformanceScorerAttributionTests: XCTestCase {

    /// Loads the minimal real-run transcript slice bundled as a test resource.
    private func loadFixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"),
            "fixture \(name).jsonl not bundled"
        )
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func row(_ rows: [ConformanceScorer.ResultRow], scenario: String) throws -> ConformanceScorer.ResultRow {
        try XCTUnwrap(rows.first { $0.scenario == scenario }, "no scored row for \(scenario)")
    }

    /// The bug case: `04-list` dispatched `list_dir` correctly, but the
    /// dispatch-requirement assertion names the tool *bare* (no backticks). It
    /// must be scored as a true positive with F1 == 1.0 — not a false positive.
    func testBareDispatchAssertionCreditsCorrectToolAsTruePositive() throws {
        let rows = ConformanceScorer.score(jsonl: try loadFixture("llama-mistral-toolcall-attribution"))

        let listRow = try row(rows, scenario: "04-list")
        XCTAssertEqual(listRow.expectedTools, ["list_dir"], "bare-named required tool should be recovered")
        XCTAssertEqual(listRow.calledTools, ["list_dir"])
        XCTAssertEqual(listRow.toolTP, 1, "correct dispatch must count as a TP, not an FP")
        XCTAssertEqual(listRow.toolFP, 0)
        XCTAssertEqual(listRow.toolFN, 0)
        XCTAssertEqual(listRow.confusion.f1, 1.0, accuracy: 1e-9)
    }

    /// Control: the backtick-quoted dispatch template (`01-now`) already worked
    /// and must keep working — the bare-token fix is additive, not a replacement.
    func testBacktickDispatchAssertionStillCreditsTruePositive() throws {
        let rows = ConformanceScorer.score(jsonl: try loadFixture("llama-mistral-toolcall-attribution"))

        let nowRow = try row(rows, scenario: "01-now")
        XCTAssertEqual(nowRow.expectedTools, ["now"])
        XCTAssertEqual(nowRow.calledTools, ["now"])
        XCTAssertEqual(nowRow.toolTP, 1)
        XCTAssertEqual(nowRow.toolFP, 0)
        XCTAssertEqual(nowRow.confusion.f1, 1.0, accuracy: 1e-9)
    }

    /// Negative guard: the loosened recovery must not credit a *wrong* tool. When
    /// the scenario requires `calc` (named in the dispatch assertion) but the model
    /// dispatched `read_file`, the call must still score FP and the miss FN.
    func testWrongToolStillScoresFalsePositive() {
        let jsonl = """
        {"kind":"prompt","scenario":"neg","user":"add it up"}
        {"kind":"tool_call","scenario":"neg","name":"read_file","arguments":"{}"}
        {"kind":"assertion","scenario":"neg","passed":false,"message":"Scenario requires `calc` to actually be dispatched — never dispatched"}
        """

        let rows = ConformanceScorer.score(jsonl: jsonl)
        guard let neg = rows.first(where: { $0.scenario == "neg" }) else {
            return XCTFail("no scored row for neg")
        }
        XCTAssertEqual(neg.expectedTools, ["calc"])
        XCTAssertEqual(neg.calledTools, ["read_file"])
        XCTAssertEqual(neg.toolTP, 0)
        XCTAssertEqual(neg.toolFP, 1, "wrong tool must remain a false positive")
        XCTAssertEqual(neg.toolFN, 1)
    }

    /// Negative guard: a free-prose requirement assertion (no structural
    /// `… to actually be dispatched` frame) must recover nothing, so it can never
    /// manufacture a phantom expected tool from an English word.
    func testProseRequirementRecoversNoTool() {
        XCTAssertEqual(
            ConformanceScorer.expectedToolsFromAssertion(
                "Scenario requires the shopping list to be read from the fixture — dispatched"
            ),
            []
        )
    }
}
