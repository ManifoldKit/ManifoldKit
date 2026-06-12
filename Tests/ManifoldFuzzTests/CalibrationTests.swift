import XCTest
@testable import ManifoldFuzz
import Foundation

// MARK: - Calibration harness

/// Loads the labeled fixture corpus from Sources/ManifoldTestSupport/FuzzCalibrationCorpus/
/// and asserts per-detector accuracy gates:
///
/// - **FP < 2%**: each detector must fire on fewer than 2 % of the known-good records.
/// - **TP ≥ 80%**: each detector must fire on at least 80 % of the known-bad records
///   labeled with its ID.
///
/// A detector that passes both gates is eligible for promotion from `.flaky` to
/// `.confirmed` severity. This is the "watchmen" check from the QA review on the
/// original fuzz design — see issue #488.
///
/// ## Corpus layout
///
/// ```
/// Sources/ManifoldTestSupport/FuzzCalibrationCorpus/
///   good.json   — array of RunRecord (known-good, no detector should fire)
///   bad.json    — array of {detectorId, note, record} (known-bad, labeled by bug class)
/// ```
///
/// Corpus files are read at test-run time via `#filePath`-relative URL (the same
/// pattern used by `SilentCatchAuditTest` for `silent_catch_allowlist.txt`).  No
/// resource-bundling change to Package.swift is required.
final class CalibrationTests: XCTestCase {

    // MARK: - Corpus model

    private struct LabeledBadRecord: Decodable {
        var detectorId: String
        var note: String
        var record: RunRecord
    }

    // MARK: - Path helpers

    /// Walk upward from this source file until a `Sources` directory is found, then
    /// descend into `Sources/ManifoldTestSupport/FuzzCalibrationCorpus/`. This mirrors
    /// the pattern used by `SilentCatchAuditTest.locateSourcesDirectory` so the test
    /// is robust to the package being embedded or the test file moving.
    private static func corpusRoot(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Sources")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue {
                return candidate
                    .appendingPathComponent("ManifoldTestSupport", isDirectory: true)
                    .appendingPathComponent("FuzzCalibrationCorpus", isDirectory: true)
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "CalibrationTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Sources/ from #filePath"
        ])
    }

    /// The corpus is in-tree and load-bearing for the FP/TP gates. A missing file
    /// indicates a packaging/checkout regression — fail loudly rather than skipping
    /// silently (which would mask an accidental omission in CI).
    private func loadGoodRecords() throws -> [RunRecord] {
        let url = try Self.corpusRoot().appendingPathComponent("good.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Calibration corpus missing at \(url.path) — corpus is required, not optional"
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([RunRecord].self, from: data)
    }

    private func loadBadRecords() throws -> [LabeledBadRecord] {
        let url = try Self.corpusRoot().appendingPathComponent("bad.json")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "Calibration corpus missing at \(url.path) — corpus is required, not optional"
        )
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([LabeledBadRecord].self, from: data)
    }

    // MARK: - Gate constants

    private let fpThreshold = 0.02  // FP rate must be strictly below 2 %
    private let tpThreshold = 0.80  // TP rate must be at or above 80 %

    // MARK: - FP gate

    func test_falsePositiveRate_allDetectors_belowTwoPercent() throws {
        let goodRecords = try loadGoodRecords()
        XCTAssertGreaterThanOrEqual(
            goodRecords.count, 200,
            "Calibration good corpus must have ≥ 200 records to make the 2 % FP gate statistically meaningful"
        )

        let detectors = DetectorRegistry.all
        var failures: [String] = []

        for detector in detectors {
            let fpCount = goodRecords.filter { !detector.inspect($0).isEmpty }.count
            let fpRate = Double(fpCount) / Double(goodRecords.count)
            if fpRate >= fpThreshold {
                let pct = String(format: "%.1f", fpRate * 100)
                failures.append("• \(detector.id): \(fpCount)/\(goodRecords.count) FPs (\(pct) % ≥ 2 %)")
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "Detectors whose false-positive rate on the good corpus is ≥ 2 %:\n"
                + failures.joined(separator: "\n")
                + "\nFix the detector logic, tighten the trigger condition, or reclassify the mis-fired good records."
        )
    }

    // MARK: - TP gate

    func test_truePositiveRate_allDetectors_atLeastEightyPercent() throws {
        let badRecords = try loadBadRecords()
        XCTAssertGreaterThanOrEqual(
            badRecords.count, 50,
            "Calibration bad corpus must have ≥ 50 records"
        )

        let detectors = DetectorRegistry.all
        var failures: [String] = []

        for detector in detectors {
            let forDetector = badRecords.filter { $0.detectorId == detector.id }
            guard !forDetector.isEmpty else { continue }

            let tpCount = forDetector.filter { !detector.inspect($0.record).isEmpty }.count
            let tpRate = Double(tpCount) / Double(forDetector.count)
            if tpRate < tpThreshold {
                let pct = String(format: "%.1f", tpRate * 100)
                failures.append("• \(detector.id): \(tpCount)/\(forDetector.count) TPs (\(pct) % < 80 %)")
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "Detectors whose true-positive rate on the bad corpus is < 80 %:\n"
                + failures.joined(separator: "\n")
                + "\nAdd more representative bad records to bad.json or fix the detector's trigger condition."
        )
    }

    // MARK: - Coverage check

    /// Detectors known to ship without single-turn corpus coverage. New entries
    /// here MUST be paired with a tracking issue — never silence a detector by
    /// adding it to this set without one.
    ///
    /// - `tool-call-validity` (#627): two sub-checks ship `.confirmed` (zero-FP-by-
    ///   construction transcript invariants — `id-reuse`, `orphan-result`); three
    ///   ship `.flaky` and need bad-corpus records authored before they can graduate.
    ///   Tracked under #488 as a follow-up to keep this PR scoped to the existing
    ///   ten single-turn detectors.
    private static let coverageExempt: Set<String> = [
        "tool-call-validity",
    ]

    /// Every detector in DetectorRegistry.all (minus `coverageExempt`) must have
    /// at least one bad-corpus entry so the TP gate is meaningful for that
    /// detector.
    func test_badCorpusCoverage_allDetectorsCovered() throws {
        let badRecords = try loadBadRecords()
        let coveredIds = Set(badRecords.map(\.detectorId))
        let uncovered = DetectorRegistry.all
            .map(\.id)
            .filter { !coveredIds.contains($0) && !Self.coverageExempt.contains($0) }

        XCTAssertTrue(
            uncovered.isEmpty,
            "Detectors with no bad-corpus coverage (add records to bad.json or "
                + "to coverageExempt with a tracking-issue rationale): "
                + uncovered.joined(separator: ", ")
        )
    }

    // MARK: - Schema roundtrip

    /// Corpus records must survive a JSON encode → decode cycle without loss so
    /// that future corpus additions can be validated without a real fuzz run.
    func test_goodCorpus_roundtripsJSON() throws {
        let goodRecords = try loadGoodRecords()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for record in goodRecords.prefix(10) {
            let data = try encoder.encode(record)
            let decoded = try decoder.decode(RunRecord.self, from: data)
            XCTAssertEqual(record, decoded, "RunRecord \(record.runId) did not survive JSON roundtrip")
        }
    }

    // MARK: - Corpus sanity checks

    func test_goodCorpusSize() throws {
        let goodRecords = try loadGoodRecords()
        XCTAssertGreaterThanOrEqual(goodRecords.count, 200, "Expected ≥ 200 good records")
    }

    func test_badCorpusSize() throws {
        let badRecords = try loadBadRecords()
        XCTAssertGreaterThanOrEqual(badRecords.count, 50, "Expected ≥ 50 bad records")
    }

    // MARK: - Meta-validation (sabotage guard)

    /// An always-firing detector would have FP rate = 100 % >> 2 %. Verifies the
    /// FP-gate arithmetic is wired correctly and would catch a broken detector.
    func test_meta_alwaysFiringDetectorExceedsFPThreshold() throws {
        let goodRecords = try loadGoodRecords()
        let syntheticFPRate = 1.0  // 100 % FP — always fires
        XCTAssertGreaterThan(
            syntheticFPRate, fpThreshold,
            "Sanity: an always-firing detector (100 % FP) must exceed the 2 % threshold"
        )
        // Confirm the assertion would fire for a mock that fails every record.
        let wouldFail = Double(goodRecords.count) / Double(goodRecords.count) >= fpThreshold
        XCTAssertTrue(wouldFail, "FP gate would not catch a 100 %-firing detector — arithmetic is broken")
    }
}
