import XCTest
@testable import ManifoldTools

final class ConformanceRecordTests: XCTestCase {

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func roundTrip(_ record: ConformanceRecord) throws -> ConformanceRecord {
        let data = try makeEncoder().encode(record)
        return try JSONDecoder().decode(ConformanceRecord.self, from: data)
    }

    /// A fully-measured cell carrying a verdict + tool-selection scores must
    /// survive encode → decode unchanged.
    func testMeasuredRecordRoundTrips() throws {
        let record = ConformanceRecord(
            backend: "llama.cpp",
            model: "mistral-7b-instruct-v0.3",
            quant: "Q4_K_M",
            renderer: "jinja-prompt",
            scenario: "weather-lookup",
            decoyLevel: 3,
            repeatIndex: 1,
            status: .measured,
            verdict: .pass,
            toolSelection: Scores(precision: 1.0, recall: 1.0, f1: 1.0),
            failureClass: nil,
            transcriptRef: "runs/llama-20260626.jsonl#weather-lookup",
            coreCommit: "ba936494",
            toolingVersions: ["llama.cpp": "b3901", "core": "0.54.0"]
        )

        let decoded = try roundTrip(record)
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.status, .measured)
        XCTAssertEqual(decoded.verdict, .pass)
        XCTAssertEqual(decoded.toolSelection, Scores(precision: 1.0, recall: 1.0, f1: 1.0))
    }

    /// The whole point of the schema: a `notMeasured` hole is a *state*, not a
    /// `fail` verdict. It must round-trip preserving its reason, and must never
    /// read as a measured failure.
    func testNotMeasuredRecordRoundTripsAndIsNotFailure() throws {
        let record = ConformanceRecord(
            backend: "mlx",
            model: "qwen2.5-7b-instruct",
            quant: "4bit",
            renderer: "swift-transformers",
            scenario: "weather-lookup",
            decoyLevel: 0,
            repeatIndex: 0,
            status: .notMeasured("weights absent on this host"),
            verdict: nil,
            toolSelection: nil,
            failureClass: nil,
            transcriptRef: "",
            coreCommit: "ba936494",
            toolingVersions: [:]
        )

        let decoded = try roundTrip(record)
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.status, .notMeasured("weights absent on this host"))

        // Absence is not failure — a not-measured cell carries no verdict at all,
        // and is distinct from a measured `.fail`.
        XCTAssertNil(decoded.verdict)
        XCTAssertNotEqual(decoded.status, .measured)
        let measuredFail = CellStatus.measured
        XCTAssertNotEqual(decoded.status, measuredFail)
    }

    /// `loadFail` carries its error reason through a round trip.
    func testLoadFailRecordRoundTrips() throws {
        let record = ConformanceRecord(
            backend: "llama.cpp",
            model: "gemma-2-9b",
            quant: "Q4_K_M",
            renderer: "jinja-prompt",
            scenario: "structured-json-extraction",
            decoyLevel: 0,
            repeatIndex: 2,
            status: .loadFail("gguf header parse error"),
            verdict: nil,
            toolSelection: nil,
            failureClass: .loadFail,
            transcriptRef: "runs/llama-20260626.jsonl",
            coreCommit: "ba936494",
            toolingVersions: ["llama.cpp": "b3901"]
        )

        let decoded = try roundTrip(record)
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.status, .loadFail("gguf header parse error"))
        XCTAssertEqual(decoded.failureClass, .loadFail)
    }

    /// `renderFail` (no associated value) round-trips and stays distinct from a
    /// measured failure.
    func testRenderFailRecordRoundTrips() throws {
        let record = ConformanceRecord(
            backend: "mlx",
            model: "mistral-7b-instruct-v0.3",
            quant: "4bit",
            renderer: "swift-transformers",
            scenario: "weather-lookup",
            decoyLevel: 0,
            repeatIndex: 0,
            status: .renderFail,
            verdict: nil,
            toolSelection: nil,
            failureClass: .renderFail,
            transcriptRef: "",
            coreCommit: "ba936494",
            toolingVersions: [:]
        )

        let decoded = try roundTrip(record)
        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.status, .renderFail)
        XCTAssertNil(decoded.verdict)
    }

    /// A measured `.fail` verdict must be distinguishable from every non-measured
    /// status — the matrix must never collapse "ran and failed" into "didn't run".
    func testMeasuredFailIsDistinctFromNotMeasured() throws {
        let measuredFail = ConformanceRecord(
            backend: "ollama",
            model: "llama3.1-8b",
            quant: "server",
            renderer: "ollama-server",
            scenario: "weather-lookup",
            decoyLevel: 0,
            repeatIndex: 0,
            status: .measured,
            verdict: .fail,
            toolSelection: Scores(precision: 0.0, recall: 0.0, f1: 0.0),
            failureClass: .noCall,
            transcriptRef: "runs/ollama.jsonl",
            coreCommit: "ba936494",
            toolingVersions: ["ollama": "0.5.4"]
        )

        let decoded = try roundTrip(measuredFail)
        XCTAssertEqual(decoded, measuredFail)
        XCTAssertEqual(decoded.status, .measured)
        XCTAssertEqual(decoded.verdict, .fail)
        XCTAssertNotEqual(decoded.status, .notMeasured("did not run"))
    }

    /// Each `CellStatus` case encodes to a stable, self-describing shape so the
    /// JSONL a human reads is unambiguous.
    func testCellStatusEncodingShape() throws {
        let encoder = makeEncoder()

        let measured = try encoder.encode(CellStatus.measured)
        XCTAssertEqual(String(decoding: measured, as: UTF8.self), #"{"kind":"measured"}"#)

        let notMeasured = try encoder.encode(CellStatus.notMeasured("offline"))
        XCTAssertEqual(String(decoding: notMeasured, as: UTF8.self), #"{"kind":"notMeasured","reason":"offline"}"#)

        let renderFail = try encoder.encode(CellStatus.renderFail)
        XCTAssertEqual(String(decoding: renderFail, as: UTF8.self), #"{"kind":"renderFail"}"#)
    }

    /// The load-bearing guard: a `CellStatus` whose `kind` discriminator is
    /// unrecognized must fail to decode — *loudly* — never silently default to
    /// `.measured`. Defaulting an unknown/garbage kind to `.measured` is exactly
    /// the "absence reads as measured" defect this schema exists to kill, so the
    /// throw is pinned here against future refactors.
    func testUnknownCellStatusKindFailsToDecode() throws {
        let json = Data(#"{"kind":"teleported"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CellStatus.self, from: json)) { error in
            XCTAssertTrue(error is DecodingError, "expected a DecodingError, got \(error)")
        }
    }

    /// A `CellStatus` with no `kind` discriminator at all must also fail loudly —
    /// a missing key must never be read as `.measured`.
    func testMissingCellStatusKindFailsToDecode() throws {
        let json = Data(#"{"reason":"offline"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CellStatus.self, from: json)) { error in
            XCTAssertTrue(error is DecodingError, "expected a DecodingError, got \(error)")
        }
    }

    /// `notMeasured`/`loadFail` carry a required reason; a record that drops it
    /// fails to decode rather than fabricating an empty reason — the reason is part
    /// of the measured-hole's identity, not optional decoration.
    func testNotMeasuredMissingReasonFailsToDecode() throws {
        let json = Data(#"{"kind":"notMeasured"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(CellStatus.self, from: json)) { error in
            XCTAssertTrue(error is DecodingError, "expected a DecodingError, got \(error)")
        }
    }
}
