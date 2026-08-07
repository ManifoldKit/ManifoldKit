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

    /// #2411: `normalizedModelKey` split GGUF quant labels like "Q4_K_M" on the
    /// underscore into three tokens ("q4", "k", "m"); only the "q4" head matched
    /// `isQuantToken`, so "k"/"m" survived as residue and the GGUF key never
    /// matched its MLX counterpart ("4bit") for the same weights. Table-drives
    /// real observed identifiers from both runtimes with EXACT expected keys —
    /// not a "no underscore remains" or "non-empty" check, either of which a
    /// broken normalizer could still satisfy.
    func testNormalizedModelKeyExactValues() throws {
        let cases: [(input: String, expected: String, why: String)] = [
            ("Llama-3.1-8B-Instruct-Q4_K_M", "llama-3-1-8b",
             "GGUF quant with K/M residue must fully strip to the bare family/size"),
            ("Llama-3.1-8B-Instruct-4bit", "llama-3-1-8b",
             "MLX quant label strips cleanly (this side never regressed)"),
            ("Mistral-7B-Instruct-v0.3-Q4_K_S", "mistral-7b-v0-3",
             "Q4_K_S (not just _M) must also fully absorb"),
            ("Mistral-7B-Instruct-v0.3-4bit", "mistral-7b-v0-3",
             "MLX counterpart for the v0.3 mistral case"),
            ("gemma-3-4b-it-Q4_K_L", "gemma-3-4b",
             "Q4_K_L (the third K-suffix variant) must also fully absorb"),
            ("gemma-3-4b-it-8bit", "gemma-3-4b",
             "MLX counterpart for gemma-3-4b"),
            // #2411 names the fuller suffix vocabulary explicitly: k, m, s, l,
            // xs, xxs, 0, 1. Q8_0 is the ONLY 8-bit GGUF spelling (there is no
            // "Q8_K_M"), so without these the entire 8-bit cross-runtime
            // comparison stays dead even after the k/m/s/l fix above.
            ("Llama-3.1-8B-Instruct-Q8_0", "llama-3-1-8b",
             "Q8_0 (bare-'0' legacy quant, the only 8-bit GGUF spelling) must fully absorb"),
            ("Llama-3.1-8B-Instruct-Q4_0", "llama-3-1-8b",
             "Q4_0 (bare-'0' legacy quant) must fully absorb"),
            ("Llama-3.1-8B-Instruct-Q5_1", "llama-3-1-8b",
             "Q5_1 (bare-'1' legacy quant) must fully absorb"),
            ("Llama-3.1-8B-Instruct-IQ4_XS", "llama-3-1-8b",
             "IQ4_XS (the 'iq' head family) must fully absorb"),
            ("Llama-3.1-8B-Instruct-IQ2_XS", "llama-3-1-8b",
             "IQ2_XS (a different iq bit-width) must fully absorb"),
        ]
        for c in cases {
            XCTAssertEqual(
                MatrixRenderer.normalizedModelKey(c.input), c.expected,
                "\(c.why) — input: \(c.input)"
            )
        }

        // Cross-runtime pairs for the same logical weights must land on the SAME
        // normalized *model* key. Note the key deliberately excludes quant —
        // MatrixRenderer keeps a separate "Quant" column (see the cross-runtime
        // table header) — so these assertions are about the logical model
        // identity, not a claim that a 4-bit and an 8-bit quant ARE the same
        // weights.
        XCTAssertEqual(
            MatrixRenderer.normalizedModelKey("Llama-3.1-8B-Instruct-Q4_K_M"),
            MatrixRenderer.normalizedModelKey("Llama-3.1-8B-Instruct-4bit"),
            "GGUF Q4_K_M and MLX 4bit must normalize to the same logical-model key"
        )
        XCTAssertEqual(
            MatrixRenderer.normalizedModelKey("Mistral-7B-Instruct-v0.3-Q4_K_S"),
            MatrixRenderer.normalizedModelKey("Mistral-7B-Instruct-v0.3-4bit"),
            "GGUF Q4_K_S and MLX 4bit must normalize to the same logical-model key"
        )
        XCTAssertEqual(
            MatrixRenderer.normalizedModelKey("gemma-3-4b-it-Q4_K_L"),
            MatrixRenderer.normalizedModelKey("gemma-3-4b-it-8bit"),
            "GGUF Q4_K_L and MLX 8bit must normalize to the same logical-model key "
            + "despite the quant precision differing — the key intentionally omits "
            + "quant, which is why the cross-runtime table carries it in its own column"
        )
        XCTAssertEqual(
            MatrixRenderer.normalizedModelKey("Llama-3.1-8B-Instruct-Q8_0"),
            MatrixRenderer.normalizedModelKey("Llama-3.1-8B-Instruct-8bit"),
            "GGUF Q8_0 (the only 8-bit GGUF spelling) and MLX 8bit must normalize "
            + "to the same logical-model key"
        )
        XCTAssertEqual(
            MatrixRenderer.normalizedModelKey("Llama-3.1-8B-Instruct-IQ4_XS"),
            MatrixRenderer.normalizedModelKey("Llama-3.1-8B-Instruct-4bit"),
            "GGUF IQ4_XS and MLX 4bit must normalize to the same logical-model key"
        )

        // Negative: genuinely different models/sizes must NOT collide. An
        // over-eager normalizer that collapses everything to the family name
        // would "pair" rows that are not comparable and silently fabricate a
        // cross-runtime comparison — this is the failure mode the brief warns
        // about, and it is the opposite defect from #2411's residue bug.
        XCTAssertNotEqual(
            MatrixRenderer.normalizedModelKey("Llama-3.1-8B-Instruct-Q4_K_M"),
            MatrixRenderer.normalizedModelKey("Llama-3.1-70B-Instruct-Q4_K_M"),
            "different parameter counts (8B vs 70B) of the same family must NOT collide"
        )
        XCTAssertNotEqual(
            MatrixRenderer.normalizedModelKey("Mistral-7B-Instruct-v0.3-Q4_K_S"),
            MatrixRenderer.normalizedModelKey("Mistral-7B-Instruct-v0.1-Q4_K_S"),
            "different checkpoint versions (v0.3 vs v0.1) must NOT collide"
        )
        XCTAssertNotEqual(
            MatrixRenderer.normalizedModelKey("Llama-3.1-8B-Instruct-Q4_K_M"),
            MatrixRenderer.normalizedModelKey("Mistral-7B-Instruct-v0.3-Q4_K_M"),
            "different model families must NOT collide"
        )
        // AC2 guard rail: a genuine trailing model-name token that happens to be
        // a single letter used elsewhere as a K-quant suffix must survive intact
        // when it appears AFTER an already-complete quant label, not be read as
        // a continuation of that label. Contrived, but it's the input shape
        // where "absorb suffix letters after a quant head" is genuinely wrong if
        // the absorption isn't bounded to the known K_S/K_M/K_L/bare-K shapes.
        XCTAssertNotEqual(
            MatrixRenderer.normalizedModelKey("Model-Q4_K_M-S"),
            MatrixRenderer.normalizedModelKey("Model"),
            "a trailing name token after an already-complete Q4_K_M must not be swallowed as a second K variant"
        )
    }

    /// #2411 AC3: the pre-existing end-to-end test
    /// (`testCrossRuntimeViewIsHonestlyLabeledAndGroupsByLogicalModel` above)
    /// passes the quant through a SEPARATE `quant:` field on the fixture
    /// builder — so the quant string never actually reaches
    /// `normalizedModelKey`, which is exactly how the K/M-residue defect
    /// shipped green in the first place. Real llama.cpp/Ollama identifiers
    /// carry the quant IN the model string itself (e.g.
    /// "mistral:7b-instruct-v0.3-q4_K_M"), so this fixture puts it there too,
    /// through the full `render()` pipeline — not a direct
    /// `normalizedModelKey` call — to prove the fix is live end-to-end, not
    /// just at the unit level.
    func testCrossRuntimeGroupingWithQuantEmbeddedInModelString() throws {
        let records = [
            record(backend: "ollama", model: "mistral:7b-instruct-v0.3-q4_K_M", quant: "n/a",
                   renderer: "ollama-server",
                   toolSelection: Scores(precision: 0.8, recall: 0.8, f1: 0.8)),
            record(backend: "mlx", model: "mistral-7b-instruct-v0.3-4bit", quant: "n/a",
                   renderer: "swift-transformers",
                   status: .measured, verdict: .fail,
                   toolSelection: Scores(precision: 0, recall: 0, f1: 0), failureClass: .noCall)
        ]
        let markdown = MatrixRenderer.render(records)
        XCTAssertTrue(
            markdown.contains("## Cross-runtime view"),
            "the two backends must pair into a cross-runtime group even with the quant embedded in the model string (not a separate field)"
        )
        let normalized = MatrixRenderer.normalizedModelKey("mistral:7b-instruct-v0.3-q4_K_M")
        XCTAssertEqual(
            normalized,
            MatrixRenderer.normalizedModelKey("mistral-7b-instruct-v0.3-4bit"),
            "GGUF and MLX identifiers with quant embedded in the model string must still normalize identically"
        )
        // Both backends' rows must render under the SAME logical-model column
        // value — a no-op fix (or one that only works via the separate `quant:`
        // field) would render the two rows in ungrouped/unpaired cells instead.
        let rowPrefix = "| \(normalized) |"
        let occurrences = markdown.components(separatedBy: rowPrefix).count - 1
        XCTAssertEqual(
            occurrences, 2,
            "expected exactly 2 rows (one per backend) under the shared logical-model key '\(normalized)' in:\n\(markdown)"
        )
    }

    // MARK: Verdict label is F1-aware, not failure-subtype-dominant

    /// Reproduces the live-soak shape that mislabeled `llama3.1-8b` d0: 27 records,
    /// verdicts {pass:6, partial:9, fail:12}, failureClass {noCall:6, lowPrecision:3,
    /// nil:18}, mean tool-selection F1 0.750. `noCall` is the *dominant failure
    /// subtype*, so the OLD subtype-first logic stamped "⚠️ renders-no-call" on a
    /// cell that in fact calls the right tool ~75% of the time. The F1-aware logic
    /// must NOT — a 0.750-F1 cell does call.
    func testHighF1NoCallDominantCellIsNotRendersNoCall() throws {
        var records: [ConformanceRecord] = []
        // 6 pass + 9 partial: perfect tool selection, no failure class.
        records += Array(repeating: record(model: "llama3.1-8b", verdict: .pass,
                                            toolSelection: Scores(precision: 1, recall: 1, f1: 1)), count: 6)
        records += Array(repeating: record(model: "llama3.1-8b", verdict: .partial,
                                            toolSelection: Scores(precision: 1, recall: 1, f1: 1)), count: 9)
        // 6 noCall fails (real 0.000) — the dominant failure subtype.
        records += Array(repeating: record(model: "llama3.1-8b", verdict: .fail,
                                            toolSelection: Scores(precision: 0, recall: 0, f1: 0),
                                            failureClass: .noCall), count: 6)
        // 3 low-precision fails.
        records += Array(repeating: record(model: "llama3.1-8b", verdict: .fail,
                                            toolSelection: Scores(precision: 0.6, recall: 1, f1: 0.75),
                                            failureClass: .lowPrecision), count: 3)
        // 3 fails with perfect tool selection but a non-tool (argument) assertion
        // miss → verdict fail, failureClass nil. Keeps the F1 mean at 0.750.
        records += Array(repeating: record(model: "llama3.1-8b", verdict: .fail,
                                            toolSelection: Scores(precision: 1, recall: 1, f1: 1),
                                            failureClass: nil), count: 3)

        let markdown = MatrixRenderer.render(records)
        let row = try line(markdown, containing: "llama3.1-8b")

        XCTAssertTrue(row.contains("0.750"), "mean tool-selection F1 must read 0.750: \(row)")
        // The fix: a 0.750-F1 cell calls the right tool most of the time — it is
        // NOT a renders-no-call cell. (Fails under the OLD subtype-dominant logic.)
        XCTAssertFalse(row.contains("renders-no-call"),
                       "a 0.750-F1 cell must never be labeled renders-no-call: \(row)")
        XCTAssertTrue(row.contains("⚠️ partial"),
                      "a mid-band F1 cell reads as partial: \(row)")
    }

    /// The genuine no-call cell: every record is a `noCall` fail, mean F1 0.000.
    /// This SHOULD keep "renders-no-call" — the model truly never calls.
    func testAllNoCallZeroF1CellStaysRendersNoCall() throws {
        let records = Array(repeating: record(
            model: "gemma3-4b-tools", verdict: .fail,
            toolSelection: Scores(precision: 0, recall: 0, f1: 0), failureClass: .noCall
        ), count: 27)

        let markdown = MatrixRenderer.render(records)
        let row = try line(markdown, containing: "gemma3-4b-tools")

        XCTAssertTrue(row.contains("0.000"), "an all-no-call cell shows its real 0.000: \(row)")
        XCTAssertTrue(row.contains("⚠️ renders-no-call"),
                      "F1 ≈ 0 with no-call dominant is a genuine renders-no-call: \(row)")
    }

    /// A perfect cell (mean F1 1.000) reads as pass.
    func testPerfectF1CellIsPass() throws {
        let records = Array(repeating: record(
            model: "qwen3.5-9b", verdict: .pass,
            toolSelection: Scores(precision: 1, recall: 1, f1: 1)
        ), count: 5)

        let markdown = MatrixRenderer.render(records)
        let row = try line(markdown, containing: "qwen3.5-9b")
        XCTAssertTrue(row.contains("1.000"), row)
        XCTAssertTrue(row.contains("✅ pass"), row)
    }

    /// High aggregate F1 (≥ 0.9) bands to pass even when a minority of records fail
    /// — the F1-floor short-circuit, exercised directly on `dominantVerdictLabel`.
    func testHighF1WithMinorityFailuresBandsToPass() {
        var records = Array(repeating: record(
            verdict: .pass, toolSelection: Scores(precision: 1, recall: 1, f1: 1)
        ), count: 9)
        records.append(record(verdict: .fail,
                              toolSelection: Scores(precision: 0, recall: 0, f1: 0),
                              failureClass: .noCall))
        // Mean F1 = 9/10 = 0.900 → at the pass floor.
        XCTAssertEqual(MatrixRenderer.dominantVerdictLabel(records), "✅ pass")
    }
}
