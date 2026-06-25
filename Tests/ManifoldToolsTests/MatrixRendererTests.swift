import XCTest
@testable import ManifoldTools

/// Verifies ``MatrixRenderer`` is a pure, deterministic rendered query over
/// `[ConformanceRecord]` — and, load-bearingly, that a `.notMeasured` /
/// `.loadFail` hole renders as a *distinct* row carrying its reason, never as a
/// measured `0.000`, while a genuinely measured failure (`.noCall`) does show its
/// real `0.000`. Hermetic: every record is hand-authored, no models.
final class MatrixRendererTests: XCTestCase {

    // MARK: Builders

    private func record(
        backend: String = "ollama",
        model: String = "mistral-7b-tools",
        quant: String = "Q4_K_M",
        renderer: String = "ollama-server",
        scenario: String = "01-now",
        decoyLevel: Int = 0,
        status: CellStatus = .measured,
        verdict: ConformanceScorer.Verdict? = .pass,
        toolSelection: Scores? = Scores(precision: 1, recall: 1, f1: 1),
        failureClass: FailureClass? = nil
    ) -> ConformanceRecord {
        ConformanceRecord(
            backend: backend,
            model: model,
            quant: quant,
            renderer: renderer,
            scenario: scenario,
            decoyLevel: decoyLevel,
            repeatIndex: 0,
            status: status,
            verdict: verdict,
            toolSelection: toolSelection,
            failureClass: failureClass,
            transcriptRef: "fixture.jsonl",
            coreCommit: "deadbeef",
            toolingVersions: [:]
        )
    }

    /// Returns the single rendered table line containing `needle`, or fails.
    private func line(_ markdown: String, containing needle: String) throws -> String {
        let matches = markdown.split(separator: "\n").map(String.init).filter { $0.contains(needle) }
        return try XCTUnwrap(matches.first, "no rendered line contains '\(needle)'")
    }

    // MARK: (a) main table means + Runs count from a multi-record cell

    func testMainTableMeansAndRunsCount() throws {
        // One cell, two measured records (separate transcripts → "runs" = 2).
        // F1 1.0 and 0.5 → mean 0.750; precision 1.0 and 0.0 → 0.500.
        let records = [
            record(scenario: "01-now", toolSelection: Scores(precision: 1, recall: 1, f1: 1)),
            record(scenario: "02-calc", toolSelection: Scores(precision: 0, recall: 1, f1: 0.5))
        ]
        let markdown = MatrixRenderer.render(records)
        let row = try line(markdown, containing: "mistral-7b-tools")

        // Runs is the record count, NOT a keyed repeat dimension.
        XCTAssertTrue(row.contains("| 2 |"), "Runs must be the cell's record count (2): \(row)")
        XCTAssertTrue(row.contains("0.750"), "mean F1 = (1.0 + 0.5)/2 = 0.750: \(row)")
        XCTAssertTrue(row.contains("0.500"), "mean precision = (1.0 + 0.0)/2 = 0.500: \(row)")
        XCTAssertTrue(row.contains("✅ pass"), "both records pass → dominant verdict pass: \(row)")

        // Sabotage guard: a single-record reading would mis-count Runs as 1.
        XCTAssertFalse(row.contains("| 1 |"), "two records must not collapse to Runs=1")
    }

    // MARK: (b) notMeasured + loadFail render as distinct, non-measured rows

    func testHolesRenderAsDistinctRowsNotMeasuredZeros() throws {
        let records = [
            record(
                backend: "llama.cpp", model: "llama3.1-8b", quant: "Q4_K_M", renderer: "jinja-prompt",
                status: .notMeasured("GGUF absent"), verdict: nil, toolSelection: nil
            ),
            record(
                backend: "llama.cpp", model: "gemma-4-E4B", quant: "Q4_K_M", renderer: "jinja-prompt",
                status: .loadFail("Unsupported model architecture: gemma4"),
                verdict: nil, toolSelection: nil, failureClass: .loadFail
            )
        ]
        let markdown = MatrixRenderer.render(records)

        let notMeasured = try line(markdown, containing: "llama3.1-8b")
        XCTAssertTrue(notMeasured.contains("🚫 not measured (GGUF absent)"), notMeasured)
        XCTAssertTrue(notMeasured.contains("| — | — | — |"), "metrics must be em-dashes, not zeros: \(notMeasured)")

        let loadFail = try line(markdown, containing: "gemma-4-E4B")
        XCTAssertTrue(loadFail.contains("💥 load-fail (Unsupported model architecture: gemma4)"), loadFail)
        XCTAssertTrue(loadFail.contains("| — | — | — |"), loadFail)

        // The whole point: absence is NEVER a measured zero.
        XCTAssertFalse(notMeasured.contains("0.000"), "a hole must not read as 0.000: \(notMeasured)")
        XCTAssertFalse(loadFail.contains("0.000"), "a load-fail must not read as 0.000: \(loadFail)")
    }

    // MARK: (c) measured + noCall is a measured failure, NOT a hole

    func testMeasuredNoCallRendersAsMeasuredFailure() throws {
        // The model called no tool where one was required: tp=fp=0, fn>0 → real
        // measured 0.000. This DID get measured, so 0.000 is honest here.
        let records = [
            record(
                backend: "ollama", model: "gemma3-4b-tools", quant: "Q4_K_M", renderer: "ollama-server",
                status: .measured, verdict: .fail,
                toolSelection: Scores(precision: 0, recall: 0, f1: 0), failureClass: .noCall
            )
        ]
        let markdown = MatrixRenderer.render(records)
        let row = try line(markdown, containing: "gemma3-4b-tools")

        XCTAssertTrue(row.contains("0.000"), "a measured no-call shows its real 0.000: \(row)")
        XCTAssertTrue(row.contains("⚠️ renders-no-call"), row)
        XCTAssertTrue(row.contains("| 1 |"), "one measured record → Runs=1: \(row)")
        // It must NOT be mistaken for an un-measured hole.
        XCTAssertFalse(row.contains("🚫 not measured"), row)
        XCTAssertFalse(row.contains("| — | — | — |"), "a measured row carries numbers, not em-dashes: \(row)")
    }

    // MARK: (d) decoy ladder renders when decoyLevel > 0

    func testDecoyLadderRendersWhenDecoyLevelsPresent() throws {
        let records = [
            record(scenario: "01-now", decoyLevel: 0, toolSelection: Scores(precision: 1, recall: 1, f1: 1)),
            record(scenario: "01-now", decoyLevel: 1, toolSelection: Scores(precision: 1, recall: 0.8, f1: 0.9)),
            record(scenario: "01-now", decoyLevel: 5, toolSelection: Scores(precision: 0.5, recall: 0.5, f1: 0.5))
        ]
        let markdown = MatrixRenderer.render(records)

        XCTAssertTrue(markdown.contains("## Decoy ladder"), "ladder section must render")
        // The ladder header is the only one carrying decoy-level columns.
        let header = try line(markdown, containing: "| +1 |")
        // Headers cover every present level (baseline d0 included), in order.
        XCTAssertTrue(header.contains("d0"), header)
        XCTAssertTrue(header.contains("+5"), header)
        let ladderRow = try line(markdown, containing: "| ollama | mistral-7b-tools | Q4_K_M | ollama-server | 1.000")
        XCTAssertTrue(ladderRow.contains("0.900"), "F1 at +1: \(ladderRow)")
        XCTAssertTrue(ladderRow.contains("0.500"), "F1 at +5: \(ladderRow)")

        // Sabotage guard: with no decoy records the section must be absent.
        let baselineOnly = MatrixRenderer.render([record(decoyLevel: 0)])
        XCTAssertFalse(baselineOnly.contains("## Decoy ladder"), "no ladder when all decoyLevel==0")
    }

    // MARK: (e) deterministic — same records render byte-identical

    func testDeterministicAcrossInputOrder() throws {
        let records = [
            record(backend: "ollama", model: "qwen3.5-9b", scenario: "01-now", toolSelection: Scores(precision: 1, recall: 1, f1: 1)),
            record(backend: "mlx", model: "Mistral-v0.3", quant: "4bit", renderer: "swift-transformers",
                   scenario: "02-calc", status: .measured, verdict: .fail,
                   toolSelection: Scores(precision: 0, recall: 0, f1: 0), failureClass: .noCall),
            record(backend: "llama.cpp", model: "gemma-4-E4B", renderer: "jinja-prompt",
                   status: .loadFail("arch gemma4"), verdict: nil, toolSelection: nil, failureClass: .loadFail),
            record(backend: "ollama", model: "qwen3.5-9b", scenario: "03-list", decoyLevel: 3,
                   toolSelection: Scores(precision: 0.9, recall: 0.9, f1: 0.9))
        ]
        let first = MatrixRenderer.render(records)
        let second = MatrixRenderer.render(records)
        XCTAssertEqual(first, second, "same input renders identically")
        // Input order must not change output (grouping is stable-sorted).
        let reversed = MatrixRenderer.render(records.reversed())
        XCTAssertEqual(first, reversed, "input order must not affect rendered output")
    }

    // MARK: Cross-runtime view honest labeling

    func testCrossRuntimeViewIsHonestlyLabeledAndGroupsByLogicalModel() throws {
        // Same logical model name, two backends/quants/renderers — must sit
        // adjacently AND carry the "not necessarily a backend bug" caveat.
        let records = [
            record(backend: "ollama", model: "mistral-7b-tools", quant: "Q4_K_M", renderer: "ollama-server",
                   toolSelection: Scores(precision: 0.8, recall: 0.8, f1: 0.8)),
            record(backend: "mlx", model: "mistral-7b-instruct", quant: "4bit", renderer: "swift-transformers",
                   status: .measured, verdict: .fail,
                   toolSelection: Scores(precision: 0, recall: 0, f1: 0), failureClass: .noCall)
        ]
        let markdown = MatrixRenderer.render(records)
        XCTAssertTrue(markdown.contains("## Cross-runtime view"), "cross-runtime section must render for a multi-cell logical group")
        XCTAssertTrue(
            markdown.contains("not, on its own, evidence of a backend bug"),
            "the divergence-is-confounded caveat must be present — no authoritative 'divergence = bug' claim"
        )
        // Both cells appear under one normalized logical key.
        XCTAssertEqual(MatrixRenderer.normalizedModelKey("mistral-7b-tools"),
                       MatrixRenderer.normalizedModelKey("mistral-7b-instruct"),
                       "role/format suffixes are stripped so the twin groups together")
    }
}
