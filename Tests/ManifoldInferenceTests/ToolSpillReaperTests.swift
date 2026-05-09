import XCTest
@testable import ManifoldInference

/// Tests for ``ToolSpillReaper`` — the spill writer + cleaner that backs
/// ``OversizeAction/spillToFile``.
///
/// Coverage:
/// - `spill(content:directory:)` writes the exact bytes to a uniquely
///   named file matching the documented pattern.
/// - `cleanOldSpills(maxAge:directory:)` removes files older than the
///   cutoff and leaves newer ones intact.
/// - The reaper tolerates a missing spill directory (no-op, no throw).
final class ToolSpillReaperTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolSpillReaperTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - spill

    func test_spill_writesBytesToFile_underExpectedPattern() throws {
        let payload = "hello world"
        let url = try ToolSpillReaper.spill(content: payload, directory: tempDir)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, payload)

        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent,
                       tempDir.lastPathComponent)
        let name = url.lastPathComponent
        XCTAssertTrue(name.hasPrefix("tool-spill-"), "got: \(name)")
        XCTAssertTrue(name.hasSuffix(".txt"))
    }

    func test_spill_createsMissingIntermediateDirectories() throws {
        let nested = tempDir.appendingPathComponent("a/b/c", isDirectory: true)
        let url = try ToolSpillReaper.spill(content: "x", directory: nested)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - cleanOldSpills

    func test_cleanOldSpills_removesFilesOlderThanCutoff() throws {
        let stale = try ToolSpillReaper.spill(content: "stale", directory: tempDir)
        let fresh = try ToolSpillReaper.spill(content: "fresh", directory: tempDir)

        // Backdate `stale` by 30 days; leave `fresh` at its true mtime.
        let thirtyDaysAgo = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        try FileManager.default.setAttributes(
            [.modificationDate: thirtyDaysAgo],
            ofItemAtPath: stale.path
        )

        ToolSpillReaper.cleanOldSpills(maxAge: 7 * 24 * 60 * 60, directory: tempDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path),
                       "stale spill should have been reaped")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path),
                      "fresh spill must survive the sweep")
    }

    func test_cleanOldSpills_isNoOp_whenDirectoryDoesNotExist() {
        let missing = tempDir.appendingPathComponent("nope", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        // Should not throw or log a fatal — opportunistic cleanup.
        ToolSpillReaper.cleanOldSpills(maxAge: 1, directory: missing)
    }
}
