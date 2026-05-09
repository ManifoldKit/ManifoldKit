#if Fuzz
import XCTest
@testable import ManifoldFuzz

final class RunRecordRoundTripTests: XCTestCase {

    // MARK: - Fixture

    /// Builds a fully-populated `RunRecord` with every optional field set so
    /// encode→decode equality catches any codable gap (leaving a field `nil`
    /// would let a missing `decode` go unnoticed).
    private func fullyPopulatedRecord(schemaVersion: Int = RunRecord.currentSchema) -> RunRecord {
        RunRecord(
            schemaVersion: schemaVersion,
            runId: "94a7b2e0-1234-5678-9abc-def012345678",
            ts: "2026-04-19T12:34:56Z",
            harness: .init(
                fuzzVersion: "0.9.0",
                packageGitRev: "abcdef0",
                packageGitDirty: true,
                swiftVersion: "6.1",
                osBuild: "macOS-26A5279q",
                thermalState: "nominal"
            ),
            model: .init(
                backend: "ollama",
                id: "qwen3.5:4b",
                url: "http://localhost:11434",
                fileSHA256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd",
                tokenizerHash: "deadbeefcafef00d"
            ),
            config: .init(
                seed: 12345,
                temperature: 0.8,
                topP: 0.95,
                maxTokens: 512,
                systemPrompt: "You are a helpful fuzz target."
            ),
            prompt: .init(
                corpusId: "seed-001",
                mutators: ["emoji-spray", "utf8-homoglyph"],
                messages: [
                    .init(role: "system", text: "You are a helpful fuzz target."),
                    .init(role: "user", text: "what is two plus two?")
                ]
            ),
            events: [
                .init(t: 0.0, kind: "generationStart", v: nil),
                .init(t: 0.12, kind: "delta", v: "four"),
                .init(t: 0.34, kind: "generationEnd", v: "naturalStop")
            ],
            raw: "<think>trivial</think>four",
            rendered: "four",
            thinkingRaw: "trivial",
            thinkingParts: ["triv", "ial"],
            thinkingCompleteCount: 1,
            templateMarkers: .init(open: "<think>", close: "</think>"),
            memory: .init(beforeBytes: 1_024_000, peakBytes: 2_048_000, afterBytes: 1_536_000),
            timing: .init(firstTokenMs: 87.5, totalMs: 342.1, tokensPerSec: 12.7),
            phase: "done",
            error: "illustrative-error-string",
            stopReason: "naturalStop"
        )
    }

    private func makeEncoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return enc
    }

    // MARK: - Round trip

    func test_encodeDecode_preservesEveryField() throws {
        let record = fullyPopulatedRecord()
        let data = try makeEncoder().encode(record)
        let decoded = try JSONDecoder().decode(RunRecord.self, from: data)
        XCTAssertEqual(record, decoded)
    }

    // MARK: - Legacy record (no schemaVersion key)

    func test_legacyJSONWithoutSchemaVersion_decodesAsV1() throws {
        // Encode a fully-populated record, then strip the `schemaVersion` key
        // from the resulting JSON to simulate a record written before #497.
        let record = fullyPopulatedRecord()
        let data = try makeEncoder().encode(record)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(json["schemaVersion"], "fixture must include schemaVersion before we strip it")
        json.removeValue(forKey: "schemaVersion")
        let stripped = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])

        let decoded = try JSONDecoder().decode(RunRecord.self, from: stripped)

        XCTAssertEqual(decoded.schemaVersion, 1)
        // And the rest of the record must round-trip intact — the missing
        // schemaVersion is the *only* tolerated difference.
        var expected = record
        expected.schemaVersion = 1
        XCTAssertEqual(decoded, expected)
    }

    // MARK: - Future record (schemaVersion > currentSchema)

    func test_futureSchemaVersion_validatorThrows() throws {
        // A loader built today should refuse a record written by a future
        // writer rather than silently misinterpret it.
        XCTAssertThrowsError(try RunRecord.validate(schemaVersion: 99)) { error in
            XCTAssertEqual(error as? RunRecord.SchemaError, .unsupportedFutureSchema(99))
        }
    }

    func test_currentAndLegacyVersions_validatorAccepts() throws {
        // Current passes silently; legacy passes with a log warning (not asserted here).
        XCTAssertNoThrow(try RunRecord.validate(schemaVersion: RunRecord.currentSchema))
        XCTAssertNoThrow(try RunRecord.validate(schemaVersion: 1))
    }

    // MARK: - Decoding a future-version payload still succeeds; validation is the gate

    func test_decodingFutureVersionRecord_succeeds_butValidateRejects() throws {
        // Encode, bump the schemaVersion key in the JSON, then decode.
        let record = fullyPopulatedRecord()
        let data = try makeEncoder().encode(record)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["schemaVersion"] = 99
        let futureData = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])

        let decoded = try JSONDecoder().decode(RunRecord.self, from: futureData)
        XCTAssertEqual(decoded.schemaVersion, 99)

        XCTAssertThrowsError(try RunRecord.validate(schemaVersion: decoded.schemaVersion)) { error in
            XCTAssertEqual(error as? RunRecord.SchemaError, .unsupportedFutureSchema(99))
        }
    }
}
#endif
