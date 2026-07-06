import XCTest
import ManifoldInference
import ManifoldAppEval

// MARK: - AppEvalMarkdownRendererGoldenTests

/// Locks the exact Markdown ``AppEvalMarkdownRenderer`` produces for a fixed
/// ``AppEvalOutcome`` against a checked-in golden file — the renderer must be
/// a pure function of the outcome struct (no clock reads, sorted iteration),
/// so re-rendering the same input must byte-for-byte match every time.
final class AppEvalMarkdownRendererGoldenTests: XCTestCase {

    private func makeFixedOutcome() -> AppEvalOutcome {
        let passingScore = Score(value: .bool(true), metadata: ["assertion": "requiredContent"])
        let failingScore = Score(
            value: .bool(false),
            explanation: "Missing required content: goodbye",
            metadata: ["assertion": "requiredContent"]
        )
        let unavailableScore = Score(value: .unavailable, explanation: "no scorer registered for custom key 'graph'")

        let fixtureA = FixtureOutcome(
            fixtureID: "alpha-fixture",
            checkpoints: [
                CheckpointOutcome(label: "greets back", afterTurnIndex: 0, scores: [
                    "requiredContent": passingScore,
                    "expectedEvents": passingScore,
                ]),
                CheckpointOutcome(label: "turn 1", afterTurnIndex: 1, scores: [
                    "requiredContent": failingScore,
                ]),
            ]
        )
        let fixtureB = FixtureOutcome(
            fixtureID: "beta-fixture",
            checkpoints: [
                CheckpointOutcome(label: "graph check", afterTurnIndex: 0, scores: [
                    "graph": unavailableScore,
                ]),
            ]
        )
        return AppEvalOutcome(fixtures: [fixtureA, fixtureB])
    }

    func test_render_matchesGoldenMarkdown() throws {
        let rendered = AppEvalMarkdownRenderer.render(makeFixedOutcome())
        let goldenURL = try XCTUnwrap(
            Bundle.module.url(forResource: "expected-report", withExtension: "md", subdirectory: "Fixtures")
        )
        let expected = try String(contentsOf: goldenURL, encoding: .utf8)
        XCTAssertEqual(rendered, expected)
    }

    func test_render_isDeterministic_acrossRepeatedCalls() {
        let outcome = makeFixedOutcome()
        let first = AppEvalMarkdownRenderer.render(outcome)
        let second = AppEvalMarkdownRenderer.render(outcome)
        XCTAssertEqual(first, second)
    }

    func test_render_escapesPipeCharactersInExplanation() {
        let score = Score(value: .bool(false), explanation: "contains | a pipe")
        let outcome = AppEvalOutcome(fixtures: [
            FixtureOutcome(fixtureID: "pipe-fixture", checkpoints: [
                CheckpointOutcome(label: "l", afterTurnIndex: 0, scores: ["k": score]),
            ]),
        ])
        let rendered = AppEvalMarkdownRenderer.render(outcome)
        // The table must still have exactly 4 pipe-delimited columns per row —
        // an unescaped pipe in the explanation would corrupt the column count.
        let row = rendered.components(separatedBy: "\n").first { $0.contains("pipe-fixture") == false && $0.contains("l") && $0.contains("k") }
        XCTAssertNotNil(row)
        XCTAssertTrue(rendered.contains("contains \\| a pipe"))
    }
}
