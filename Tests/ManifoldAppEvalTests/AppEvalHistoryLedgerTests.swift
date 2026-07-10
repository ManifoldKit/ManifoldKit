import XCTest
import ManifoldInference
import ManifoldAppEval

// MARK: - AppEvalHistoryLedgerTests

final class AppEvalHistoryLedgerTests: XCTestCase {

    private func makeOutcome() -> AppEvalOutcome {
        let passingScore = EvalScore(value: .bool(true))
        let failingScore = EvalScore(value: .bool(false), explanation: "missing content")
        return AppEvalOutcome(fixtures: [
            FixtureOutcome(fixtureID: "alpha", checkpoints: [
                CheckpointOutcome(label: "c0", afterTurnIndex: 0, scores: ["requiredContent": passingScore]),
            ]),
            FixtureOutcome(fixtureID: "beta", checkpoints: [
                CheckpointOutcome(label: "c0", afterTurnIndex: 0, scores: ["requiredContent": failingScore]),
            ]),
        ])
    }

    func test_appendThenRead_roundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appeval-ledger-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        try AppEvalHistoryLedger.append(makeOutcome(), to: url)
        let entries = try AppEvalHistoryLedger.read(from: url)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].fixtureID, "alpha")
        XCTAssertEqual(entries[0].verdict, "pass")
        XCTAssertNil(entries[0].failingCheckpointLabels)
        XCTAssertEqual(entries[1].fixtureID, "beta")
        XCTAssertEqual(entries[1].verdict, "fail")
        XCTAssertEqual(entries[1].failingCheckpointLabels, ["c0"])
        XCTAssertEqual(entries[0].schemaVersion, AppEvalLedgerEntry.currentSchemaVersion)
    }

    /// The ledger is append-only: a second call appends new lines rather
    /// than overwriting the file.
    func test_append_isAppendOnly_acrossMultipleCalls() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appeval-ledger-append-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        try AppEvalHistoryLedger.append(makeOutcome(), to: url)
        try AppEvalHistoryLedger.append(makeOutcome(), to: url)

        let entries = try AppEvalHistoryLedger.read(from: url)
        XCTAssertEqual(entries.count, 4)
    }

    /// Each line is a standalone JSON object with sorted keys — verify the
    /// on-disk shape directly, not just the round-trip through the reader.
    func test_appendedLines_areSortedKeysJSON() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appeval-ledger-shape-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        try AppEvalHistoryLedger.append(makeOutcome(), to: url)
        let content = try String(contentsOf: url, encoding: .utf8)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2)
        for line in lines {
            // sortedKeys formatting places "checkpointCount" before "fixtureID"
            // before "schemaVersion" before "verdict" alphabetically.
            let checkpointIdx = line.range(of: "\"checkpointCount\"")?.lowerBound
            let fixtureIdx = line.range(of: "\"fixtureID\"")?.lowerBound
            XCTAssertNotNil(checkpointIdx)
            XCTAssertNotNil(fixtureIdx)
            if let c = checkpointIdx, let f = fixtureIdx {
                XCTAssertLessThan(c, f, "expected sorted-keys JSON (checkpointCount before fixtureID)")
            }
        }
    }

    /// A reader built against this schema version must tolerate an
    /// unrecognized field a future writer might add, per the ledger's
    /// documented forward-compatibility contract.
    func test_read_toleratesUnknownNewerFields() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appeval-ledger-future-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        let futureLine = #"{"checkpointCount":1,"fixtureID":"gamma","schemaVersion":2,"someBrandNewField":"ignored","verdict":"pass"}"#
        try (futureLine + "\n").write(to: url, atomically: true, encoding: .utf8)

        let entries = try AppEvalHistoryLedger.read(from: url)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].fixtureID, "gamma")
        XCTAssertEqual(entries[0].schemaVersion, 2)
    }

    func test_read_malformedLine_throwsWithLineNumber() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("appeval-ledger-malformed-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }

        try "not json at all\n".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try AppEvalHistoryLedger.read(from: url)) { error in
            guard let ledgerError = error as? AppEvalHistoryLedger.LedgerError else {
                return XCTFail("expected AppEvalHistoryLedger.LedgerError, got \(error)")
            }
            if case .malformedLine(let line, _) = ledgerError {
                XCTAssertEqual(line, 1)
            } else {
                XCTFail("expected .malformedLine, got \(ledgerError)")
            }
        }
    }
}
