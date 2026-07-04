import XCTest
import ManifoldInference
@testable import ManifoldTools

/// Verifies ``ConformanceScorer`` emits the normalized ``ConformanceRecord``
/// schema (#2041) from a scored transcript, and — load-bearingly — that an
/// absent/empty transcript reads as a `.notMeasured` / `.loadFail` hole rather
/// than a silently-dropped row or a measured zero ("absence is not failure").
final class ConformanceRecordEmitTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"),
            "fixture \(name).jsonl not bundled"
        )
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }

    private func context(transcriptRef: String = "fixture") -> ConformanceScorer.RecordContext {
        ConformanceScorer.RecordContext(
            renderer: "llama-cpp",
            coreCommit: "deadbeef",
            toolingVersions: ["llama.cpp": "b1234"],
            transcriptRef: transcriptRef
        )
    }

    private func record(_ records: [ConformanceRecord], scenario: String) throws -> ConformanceRecord {
        try XCTUnwrap(records.first { $0.scenario == scenario }, "no record for \(scenario)")
    }

    // MARK: (a) measured records carry the correct verdict + non-empty Scores

    /// The #2043 golden transcript dispatched the correct tool on every scenario.
    /// The emitted record must be `.measured` with verdict `.pass` and a non-nil
    /// `toolSelection` whose F1 == 1.0 — the correctly-dispatched tool is a TP.
    func testMeasuredRecordCarriesVerdictAndScores() throws {
        let records = ConformanceScorer.records(
            jsonl: try loadFixture("llama-mistral-toolcall-attribution"),
            context: context()
        )

        XCTAssertEqual(records.count, 2, "one record per scored (cell × scenario) group")

        let list = try record(records, scenario: "04-list")
        XCTAssertEqual(list.status, .measured)
        XCTAssertEqual(list.verdict, .pass)
        let listScores = try XCTUnwrap(list.toolSelection, "tool-bearing scenario must carry Scores")
        XCTAssertEqual(listScores.f1, 1.0, accuracy: 1e-9, "correct dispatch is a TP → F1 == 1")
        XCTAssertEqual(listScores.precision, 1.0, accuracy: 1e-9)
        XCTAssertEqual(listScores.recall, 1.0, accuracy: 1e-9)
        XCTAssertNil(list.failureClass, "a clean pass has no failure bucket")
        // Provenance/identity flows from the caller-supplied context.
        XCTAssertEqual(list.renderer, "llama-cpp")
        XCTAssertEqual(list.coreCommit, "deadbeef")
        XCTAssertEqual(list.toolingVersions, ["llama.cpp": "b1234"])

        // Control: the backtick-named scenario keeps working too.
        let now = try record(records, scenario: "01-now")
        XCTAssertEqual(now.verdict, .pass)
        XCTAssertEqual(try XCTUnwrap(now.toolSelection).f1, 1.0, accuracy: 1e-9)
    }

    /// A wrong-tool transcript must surface as a measured failure with a non-nil
    /// failure bucket and a non-empty (but imperfect) Scores — distinct from the
    /// un-measured hole tested below.
    func testWrongToolIsMeasuredFailureNotHole() throws {
        let jsonl = """
        {"kind":"prompt","scenario":"neg","user":"add it up","requiredTools":["calc"]}
        {"kind":"tool_call","scenario":"neg","name":"read_file","arguments":"{}"}
        {"kind":"assertion","scenario":"neg","passed":false,"message":"Scenario requires `calc` to actually be dispatched — never dispatched"}
        """
        let records = ConformanceScorer.records(jsonl: jsonl, context: context())
        let neg = try record(records, scenario: "neg")

        XCTAssertEqual(neg.status, .measured, "a wrong tool is measured, not a hole")
        XCTAssertEqual(neg.verdict, .fail)
        XCTAssertEqual(neg.failureClass, .lowPrecision, "wrong tool called → low selection precision")
        let scores = try XCTUnwrap(neg.toolSelection)
        XCTAssertEqual(scores.f1, 0.0, accuracy: 1e-9)
    }

    /// Decoy pressure is recovered from the advertised set. Pre-shared-pool
    /// transcripts named decoys `decoy_tool_<n>_<base>` — the legacy prefix
    /// fallback must keep scoring them.
    func testDecoyLevelDerivedFromAdvertisedTools() throws {
        let jsonl = """
        {"kind":"prompt","scenario":"dec","user":"x","requiredTools":["now"],"advertisedTools":["now","calc","decoy_tool_1_get_weather","decoy_tool_2_send_email"]}
        {"kind":"tool_call","scenario":"dec","name":"now","arguments":"{}"}
        {"kind":"assertion","scenario":"dec","passed":true,"message":"Scenario requires `now` to actually be dispatched — dispatched"}
        """
        let rec = try record(ConformanceScorer.records(jsonl: jsonl, context: context()), scenario: "dec")
        XCTAssertEqual(rec.decoyLevel, 2, "two decoy_tool_* entries advertised")
    }

    /// Binds the shared ``DecoyTools`` pool to the scorer: decoys now advertise
    /// under their real names (no `decoy_tool_` prefix), so `decoyLevel` must be
    /// derived by pool membership — a prefix-only derivation would emit
    /// `decoyLevel: 0` for every pressured run and pollute the d0 baseline.
    func testDecoyLevelDerivedFromSharedPoolNames() throws {
        let n = 3
        let decoys = DecoyTools.names(n)
        XCTAssertEqual(decoys.count, n, "pool must satisfy the requested pressure level")
        let advertised = (["now", "calc"] + decoys).map { "\"\($0)\"" }.joined(separator: ",")
        let jsonl = """
        {"kind":"prompt","scenario":"dec-pool","user":"x","requiredTools":["now"],"advertisedTools":[\(advertised)]}
        {"kind":"tool_call","scenario":"dec-pool","name":"now","arguments":"{}"}
        {"kind":"assertion","scenario":"dec-pool","passed":true,"message":"Scenario requires `now` to actually be dispatched — dispatched"}
        """
        let rec = try record(ConformanceScorer.records(jsonl: jsonl, context: context()), scenario: "dec-pool")
        XCTAssertEqual(rec.decoyLevel, n, "pool-named decoys must count toward decoy pressure")
    }

    // MARK: (c) #2087 — a run that never produced a model turn is a hole, not a zero

    /// A backend-rejected run (nonexistent model → 404) leaves a transcript with
    /// only a `prompt` event. It must read as `.notMeasured` (🚫), NOT a measured
    /// `noCall` false-zero indistinguishable from a model that ran and declined.
    func testPromptOnlyTranscriptIsNotMeasuredNotNoCall() throws {
        let jsonl = #"{"kind":"prompt","scenario":"04-list","backend":"ollama","model":"ghost-model","quant":"server","user":"list the files","requiredTools":["list_dir"]}"#
        let rec = try record(ConformanceScorer.records(jsonl: jsonl, context: context()), scenario: "04-list")

        guard case .notMeasured = rec.status else {
            return XCTFail("a prompt-only transcript must read as .notMeasured, got \(rec.status)")
        }
        XCTAssertNil(rec.verdict, "an un-measured cell carries no verdict (never .fail)")
        XCTAssertNil(rec.toolSelection, "an un-measured cell carries no Scores (never a zero)")
        XCTAssertNotEqual(rec.failureClass, .noCall, "must NOT be a measured noCall false-zero (#2087)")
    }

    /// An explicit `error` event (ScenarioRunner records one on generation failure)
    /// is a positive infra-failure signal → a `.loadFail` (💥) hole.
    func testPromptPlusErrorEventIsLoadFail() throws {
        let jsonl = """
        {"kind":"prompt","scenario":"04-list","backend":"ollama","model":"ghost","quant":"server","user":"x","requiredTools":["list_dir"]}
        {"kind":"error","scenario":"04-list","backend":"ollama","model":"ghost","quant":"server","message":"HTTP 404: model 'ghost' not found"}
        """
        let rec = try record(ConformanceScorer.records(jsonl: jsonl, context: context()), scenario: "04-list")

        guard case .loadFail = rec.status else {
            return XCTFail("an explicit error event must read as .loadFail, got \(rec.status)")
        }
        XCTAssertEqual(rec.failureClass, .loadFail)
        XCTAssertNil(rec.verdict, "an un-measured cell carries no verdict")
        XCTAssertNil(rec.toolSelection)
    }

    /// 2026-07 inert-code audit, finding #24: an `error` event whose message
    /// carries `InferenceError.promptRenderFailurePrefix` (the shared constant
    /// `PromptRenderer` throws with) must route to `.renderFail` — the only
    /// distinguishable "no usable prompt" signal available today — not the
    /// generic `.loadFail` bucket.
    func testPromptRendererErrorEventIsRenderFail() throws {
        let jsonl = """
        {"kind":"prompt","scenario":"04-list","backend":"ollama","model":"ghost","quant":"server","user":"x","requiredTools":["list_dir"]}
        {"kind":"error","scenario":"04-list","backend":"ollama","model":"ghost","quant":"server","message":"\(InferenceError.promptRenderFailurePrefix) the model's embedded chat template could not be rendered and tools were requested"}
        """
        let rec = try record(ConformanceScorer.records(jsonl: jsonl, context: context()), scenario: "04-list")

        XCTAssertEqual(rec.status, .renderFail, "a PromptRenderer failure message must route to .renderFail")
        XCTAssertEqual(rec.failureClass, .renderFail)
        XCTAssertNil(rec.verdict, "an un-measured cell carries no verdict")
        XCTAssertNil(rec.toolSelection)
    }

    /// The crux control: a model that DID run and produced a `final` but called no
    /// tool is a *real, measured* decline — it must stay `.measured` / `.fail` /
    /// `.noCall` and NOT be reclassified as a hole by the #2087 fix.
    func testModelRanButDeclinedToolStaysMeasuredNoCall() throws {
        let jsonl = """
        {"kind":"prompt","scenario":"04-list","backend":"ollama","model":"real","quant":"server","user":"x","requiredTools":["list_dir"]}
        {"kind":"final","scenario":"04-list","backend":"ollama","model":"real","quant":"server","text":"I don't think I need a tool for that."}
        {"kind":"assertion","scenario":"04-list","backend":"ollama","model":"real","quant":"server","passed":false,"message":"Scenario requires `list_dir` to actually be dispatched — never dispatched"}
        """
        let rec = try record(ConformanceScorer.records(jsonl: jsonl, context: context()), scenario: "04-list")

        XCTAssertEqual(rec.status, .measured, "a model that ran and declined is a real measurement, not a hole")
        XCTAssertEqual(rec.verdict, .fail)
        XCTAssertEqual(rec.failureClass, .noCall, "declined-to-call is a measured noCall — preserved")
        XCTAssertEqual(try XCTUnwrap(rec.toolSelection).f1, 0.0, accuracy: 1e-9)
    }

    // MARK: (b) absence is not failure

    /// An empty transcript with a declared expected cell must produce a single
    /// `.notMeasured` record — NOT an empty array (dropped row) and NOT a measured
    /// zero with a `.fail` verdict.
    func testEmptyTranscriptYieldsNotMeasuredNotZero() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).jsonl")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let cell = ConformanceScorer.ExpectedCell(
            backend: "llama.cpp",
            model: "mistral-7b-instruct-v0.3",
            quant: "Q4_K_M",
            scenario: "04-list"
        )
        let records = ConformanceScorer.records(fileAt: tmp, context: context(transcriptRef: tmp.path), expectedCell: cell)

        XCTAssertEqual(records.count, 1, "the hole must be recorded, not dropped")
        let rec = records[0]
        guard case .notMeasured = rec.status else {
            return XCTFail("empty transcript must read as .notMeasured, got \(rec.status)")
        }
        XCTAssertNil(rec.verdict, "an un-measured cell carries no verdict (never .fail)")
        XCTAssertNil(rec.toolSelection, "an un-measured cell carries no Scores (never a zero)")
        XCTAssertEqual(rec.backend, "llama.cpp")
        XCTAssertEqual(rec.scenario, "04-list")
    }

    /// A missing transcript file (the run never wrote one — weights absent) must
    /// read as `.loadFail`, again with no measured verdict/Scores.
    func testMissingFileYieldsLoadFail() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString).jsonl")
        let cell = ConformanceScorer.ExpectedCell(
            backend: "llama.cpp", model: "m", quant: "Q4", scenario: "01-now"
        )
        let records = ConformanceScorer.records(fileAt: missing, context: context(), expectedCell: cell)

        XCTAssertEqual(records.count, 1)
        let rec = records[0]
        guard case .loadFail = rec.status else {
            return XCTFail("missing file must read as .loadFail, got \(rec.status)")
        }
        XCTAssertEqual(rec.failureClass, .loadFail)
        XCTAssertNil(rec.verdict)
        XCTAssertNil(rec.toolSelection)
    }

    /// Without a declared expected cell there is nothing to attribute the hole to,
    /// so an empty transcript returns `[]` (the caller opted out of hole-tracking).
    func testEmptyTranscriptWithoutCellReturnsEmpty() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString).jsonl")
        try Data().write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let records = ConformanceScorer.records(fileAt: tmp, context: context(), expectedCell: nil)
        XCTAssertTrue(records.isEmpty)
    }

    /// The emitted record round-trips through JSON (the `--emit-records` payload).
    func testRecordsRoundTripThroughJSON() throws {
        let records = ConformanceScorer.records(
            jsonl: try loadFixture("llama-mistral-toolcall-attribution"),
            context: context()
        )
        let data = try ConformanceScorer.encodeJSON(records)
        let decoded = try JSONDecoder().decode([ConformanceRecord].self, from: data)
        XCTAssertEqual(decoded, records)
    }
}
