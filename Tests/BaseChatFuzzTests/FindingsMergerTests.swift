import XCTest
@testable import BaseChatFuzz

final class FindingsMergerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FindingsMergerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    func test_merge_sumsTotalRunsAcrossWorkers() throws {
        let first = try writeWorker(name: "w1", totalRuns: 2, rows: [])
        let second = try writeWorker(name: "w2", totalRuns: 3, rows: [])
        let output = tempDir.appendingPathComponent("merged", isDirectory: true)

        let report = try FindingsMerger.merge(workerOutputDirs: [first, second], into: output)
        let index = try FindingsIndexCodec.load(from: output)

        XCTAssertEqual(report.totalRuns, 5)
        XCTAssertEqual(index.totalRuns, 5)
        XCTAssertTrue(index.rows.isEmpty)
    }

    func test_merge_dedupesSameHashAndAccumulatesCount() throws {
        var firstFinding = makeFinding(firstSeen: "2026-04-19T00:00:00Z", count: 2)
        var secondFinding = makeFinding(firstSeen: "2026-04-20T00:00:00Z", count: 3)
        XCTAssertEqual(firstFinding.hash, secondFinding.hash)
        firstFinding.severity = .flaky
        secondFinding.severity = .confirmed

        let first = try writeWorker(name: "w1", totalRuns: 2, rows: [makeRow(finding: firstFinding, seed: 11)])
        let second = try writeWorker(name: "w2", totalRuns: 3, rows: [makeRow(finding: secondFinding, seed: 22)])
        let output = tempDir.appendingPathComponent("merged", isDirectory: true)

        _ = try FindingsMerger.merge(workerOutputDirs: [first, second], into: output)
        let rows = try FindingsIndexCodec.load(from: output).rows

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].finding.count, 5)
        XCTAssertEqual(rows[0].finding.firstSeen, "2026-04-19T00:00:00Z")
        XCTAssertEqual(rows[0].finding.severity, .confirmed)
        XCTAssertEqual(rows[0].seed, 11)
    }

    func test_merge_preservesFirstSeenRecordForDuplicateHash() throws {
        let older = makeFinding(firstSeen: "2026-04-19T00:00:00Z", count: 1)
        let newer = makeFinding(firstSeen: "2026-04-20T00:00:00Z", count: 1)
        let first = try writeWorker(name: "w1", totalRuns: 1, rows: [makeRow(finding: newer, seed: 22)], recordMarker: "newer")
        let second = try writeWorker(name: "w2", totalRuns: 1, rows: [makeRow(finding: older, seed: 11)], recordMarker: "older")
        let output = tempDir.appendingPathComponent("merged", isDirectory: true)

        _ = try FindingsMerger.merge(workerOutputDirs: [first, second], into: output)

        let recordURL = output
            .appendingPathComponent("findings")
            .appendingPathComponent(older.detectorId)
            .appendingPathComponent(older.hash)
            .appendingPathComponent("record.json")
        let record = try String(contentsOf: recordURL, encoding: .utf8)
        XCTAssertTrue(record.contains("older"))
    }

    func test_merge_keepsDistinctHashes() throws {
        let firstFinding = makeFinding(trigger: "alpha")
        let secondFinding = makeFinding(trigger: "beta")
        XCTAssertNotEqual(firstFinding.hash, secondFinding.hash)
        let first = try writeWorker(name: "w1", totalRuns: 1, rows: [makeRow(finding: firstFinding, seed: 1)])
        let second = try writeWorker(name: "w2", totalRuns: 1, rows: [makeRow(finding: secondFinding, seed: 2)])
        let output = tempDir.appendingPathComponent("merged", isDirectory: true)

        _ = try FindingsMerger.merge(workerOutputDirs: [first, second], into: output)
        let index = try FindingsIndexCodec.load(from: output)

        XCTAssertEqual(index.rows.count, 2)
        XCTAssertTrue(index.rows.map(\.finding.hash).contains(firstFinding.hash))
        XCTAssertTrue(index.rows.map(\.finding.hash).contains(secondFinding.hash))
    }

    func test_merge_missingWorkerIndexContributesZeroRuns() throws {
        let missing = tempDir.appendingPathComponent("missing", isDirectory: true)
        let output = tempDir.appendingPathComponent("merged", isDirectory: true)

        let report = try FindingsMerger.merge(workerOutputDirs: [missing], into: output)

        XCTAssertEqual(report.totalRuns, 0)
        XCTAssertEqual(report.uniqueFindings, 0)
        XCTAssertEqual(report.skippedInputs, 0)
    }

    func test_merge_corruptWorkerIndexIsSkipped() throws {
        let broken = tempDir.appendingPathComponent("broken", isDirectory: true)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        let corruptIndex = broken.appendingPathComponent("index.json")
        try Data("{".utf8).write(to: corruptIndex, options: .atomic)
        let healthy = try writeWorker(name: "healthy", totalRuns: 2, rows: [makeRow(finding: makeFinding(trigger: "ok"), seed: 1)])
        let output = tempDir.appendingPathComponent("merged", isDirectory: true)

        let report = try FindingsMerger.merge(workerOutputDirs: [broken, healthy], into: output)
        let merged = try FindingsIndexCodec.load(from: output)

        XCTAssertEqual(report.totalRuns, 2)
        XCTAssertEqual(report.uniqueFindings, 1)
        XCTAssertEqual(report.skippedInputs, 1)
        XCTAssertEqual(merged.totalRuns, 2)
        XCTAssertEqual(merged.rows.count, 1)
    }

    private func makeFinding(
        trigger: String = "same-trigger",
        firstSeen: String = "2026-04-19T00:00:00Z",
        count: Int = 1
    ) -> Finding {
        Finding(
            detectorId: "det",
            subCheck: "sub",
            severity: .flaky,
            trigger: trigger,
            modelId: "model",
            firstSeen: firstSeen,
            count: count
        )
    }

    private func makeRow(finding: Finding, seed: UInt64) -> FindingsIndexRow {
        FindingsIndexRow(
            finding: finding,
            modelId: finding.modelId,
            seed: seed,
            lastSeen: finding.firstSeen
        )
    }

    private func writeWorker(
        name: String,
        totalRuns: Int,
        rows: [FindingsIndexRow],
        recordMarker: String = "record"
    ) throws -> URL {
        let worker = tempDir.appendingPathComponent(name, isDirectory: true)
        try FindingsIndexCodec.write(FindingsIndexFile(totalRuns: totalRuns, rows: rows), to: worker)
        for row in rows {
            let finding = row.finding
            let dir = worker
                .appendingPathComponent("findings", isDirectory: true)
                .appendingPathComponent(finding.detectorId, isDirectory: true)
                .appendingPathComponent(finding.hash, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "{\"marker\":\"\(recordMarker)\"}"
                .write(to: dir.appendingPathComponent("record.json"), atomically: true, encoding: .utf8)
        }
        return worker
    }
}
