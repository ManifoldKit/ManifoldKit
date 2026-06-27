import XCTest
@testable import ManifoldTools
import ManifoldInference

/// Unit coverage for ``BFCLRunner`` — the backend-agnostic scoring loop shared by
/// core `manifold-tools` (Ollama) and the companion CLIs (Llama / MLX). Driven
/// through the `emit` seam with canned tool calls, so the orchestration (scoring,
/// record capture, summary counts, output format) is verified with no live model.
@MainActor
final class BFCLRunnerTests: XCTestCase {

    /// `add(a:17, b:4)`, both required.
    private func addCase(id: String) -> BFCLLoadedCase {
        BFCLLoadedCase(
            id: id,
            prompt: "add 17 and 4",
            tools: [],
            groundTruth: [BFCLExpectedCall(functionName: "add", acceptedValues: ["a": [.integer(17)], "b": [.integer(4)]])]
        )
    }

    private func call(_ name: String, _ argsJSON: String) -> ToolCall {
        ToolCall(id: "c", toolName: name, arguments: argsJSON)
    }

    struct EmitFailure: Error {}

    func test_run_scoresMatchWrongArgsAndError_withCorrectCountsAndRecords() async {
        let cases = [addCase(id: "c_match"), addCase(id: "c_wrongargs"), addCase(id: "c_error")]
        var lines: [String] = []
        let runner = BFCLRunner { lines.append($0) }

        let outcome = await runner.run(cases: cases, modelLabel: "test/model") { testCase in
            switch testCase.id {
            case "c_match":     return [self.call("add", #"{"a":17,"b":4}"#)]   // ast + name match
            case "c_wrongargs": return [self.call("add", #"{"a":1,"b":2}"#)]    // name match, ast fail
            default:            throw EmitFailure()                              // errored, no record
            }
        }

        // Summary: 3 cases, 1 AST match, 2 name matches, 1 errored.
        XCTAssertEqual(outcome.summary, .init(total: 3, astMatched: 1, nameMatched: 2, errored: 1))
        // Errored case produces no record; the two scored cases do.
        XCTAssertEqual(outcome.records.map(\.id), ["c_match", "c_wrongargs"])
        XCTAssertEqual(outcome.records[0].model, "test/model")
        XCTAssertTrue(outcome.records[0].astMatched)
        XCTAssertFalse(outcome.records[1].astMatched)
        XCTAssertTrue(outcome.records[1].nameMatched)
    }

    func test_run_emitsHeaderRowsAndSummaryLines() async {
        let cases = [addCase(id: "c_match"), addCase(id: "c_wrongargs")]
        var lines: [String] = []
        let runner = BFCLRunner { lines.append($0) }

        _ = await runner.run(cases: cases, modelLabel: "ollama/llama3.1-8b") { testCase in
            testCase.id == "c_match"
                ? [self.call("add", #"{"a":17,"b":4}"#)]
                : [self.call("add", #"{"a":1,"b":2}"#)]
        }

        let out = lines.joined(separator: "\n")
        XCTAssertTrue(out.contains("ollama/llama3.1-8b"))
        XCTAssertTrue(out.contains("✓ c_match"))
        XCTAssertTrue(out.contains("✗ c_wrongargs"))
        XCTAssertTrue(out.contains("AST accuracy (right function + right arguments): 1/2"))
        XCTAssertTrue(out.contains("Name-only (what ConformanceScorer credits):      2/2"))
        // The gap line is the whole point — name-only credits a case AST rejects.
        XCTAssertTrue(out.contains("1 case(s) called the right tool with WRONG arguments"))
    }

    func test_run_noToolCallEmitted_isAFailWithNoCrash() async {
        let cases = [addCase(id: "c_silent")]
        let runner = BFCLRunner { _ in }
        let outcome = await runner.run(cases: cases, modelLabel: "m") { _ in [] }

        XCTAssertEqual(outcome.summary, .init(total: 1, astMatched: 0, nameMatched: 0, errored: 0))
        XCTAssertEqual(outcome.records.count, 1)
        XCTAssertFalse(outcome.records[0].astMatched)
        XCTAssertTrue(outcome.records[0].decoded.isEmpty)
    }
}
