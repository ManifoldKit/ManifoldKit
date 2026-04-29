@preconcurrency import XCTest
@testable import BaseChatInference
#if HuggingFace
@testable import BaseChatHuggingFace

/// Integration tests for `BackgroundDownloadManager.cleanupStaleTempFiles()`.
///
/// These exercise the launch-time sweep that reclaims `.download` temp files
/// orphaned by a prior process that crashed or was force-killed between
/// `URLSession`'s handoff and the move into the models directory.
///
/// Each test gets a unique `tempScanDir` injected into its manager so that
/// parallel suites cannot accidentally sweep each other's files.
@MainActor
final class DownloadTempCleanupTests: XCTestCase {

    /// Isolated directory the manager scans — unique per test run.
    private var tempScanDir: URL!

    /// Fresh manager per test — session identifier and scan directory are both unique.
    private var manager: BackgroundDownloadManager!

    /// Per-instance UserDefaults suite — prevents parallel test runs from racing
    /// on the global `pendingDownloadsKey` in `UserDefaults.standard`.
    private var suiteName: String!
    private var testDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tempScanDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadTempCleanupTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempScanDir, withIntermediateDirectories: true)
        suiteName = "com.basechatkit.test.downloads.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        manager = BackgroundDownloadManager(
            sessionIdentifier: "com.basechatkit.test.cleanup.\(UUID().uuidString)",
            tempScanDirectory: tempScanDir,
            userDefaults: testDefaults
        )
    }

    override func tearDown() async throws {
        if let tempScanDir {
            try? FileManager.default.removeItem(at: tempScanDir)
        }
        if let suiteName {
            testDefaults?.removePersistentDomain(forName: suiteName)
        }
        tempScanDir = nil
        manager = nil
        testDefaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Creates a file in `tempScanDir` with the manager's naming signature and
    /// backdates its modification time.
    ///
    /// - Parameter age: Seconds in the past to stamp on the file's mtime.
    /// - Returns: The URL of the created file.
    @discardableResult
    private func makeTempDownloadFile(
        age: TimeInterval,
        contents: Data = Data("temp".utf8)
    ) throws -> URL {
        let name = "\(BackgroundDownloadManager.tempFilePrefix)\(UUID().uuidString).\(BackgroundDownloadManager.tempFileExtension)"
        let url = tempScanDir.appendingPathComponent(name)
        try contents.write(to: url)
        let backdatedDate = Date().addingTimeInterval(-age)
        try FileManager.default.setAttributes(
            [.modificationDate: backdatedDate],
            ofItemAtPath: url.path
        )
        return url
    }

    /// Creates a file in `tempScanDir` that does NOT match the manager's naming
    /// signature, to verify the sweep leaves unrelated files alone.
    @discardableResult
    private func makeUnrelatedTempFile(age: TimeInterval) throws -> URL {
        let name = "unrelated-\(UUID().uuidString).tmp"
        let url = tempScanDir.appendingPathComponent(name)
        try Data("unrelated".utf8).write(to: url)
        let backdatedDate = Date().addingTimeInterval(-age)
        try FileManager.default.setAttributes(
            [.modificationDate: backdatedDate],
            ofItemAtPath: url.path
        )
        return url
    }

    // MARK: - Launch Sweep

    func test_cleanup_removesFileOlderThanThreshold() throws {
        // 48h old — well past the 24h threshold.
        let staleURL = try makeTempDownloadFile(age: 48 * 60 * 60)

        manager.cleanupStaleTempFiles()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staleURL.path),
            "Stale temp file older than the threshold should have been removed"
        )
    }

    func test_cleanup_preservesFileYoungerThanThreshold() throws {
        // 1h old — well inside the 24h threshold.
        let freshURL = try makeTempDownloadFile(age: 60 * 60)

        manager.cleanupStaleTempFiles()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: freshURL.path),
            "Fresh temp file must not be touched — it may belong to an in-flight download"
        )
    }

    func test_cleanup_leavesUnrelatedFilesUntouched() throws {
        // An unrelated stale file with the same age as the sweep target,
        // to prove the prefix/extension filter is doing the work.
        let unrelatedURL = try makeUnrelatedTempFile(age: 48 * 60 * 60)
        let managedURL = try makeTempDownloadFile(age: 48 * 60 * 60)

        manager.cleanupStaleTempFiles()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: unrelatedURL.path),
            "Files that do not carry the manager's prefix/extension signature must be preserved"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: managedURL.path),
            "Managed stale file should have been removed"
        )
    }

    func test_cleanup_usesInjectedNowForAgeThreshold() throws {
        // File is 12h old, which would normally be preserved. But by passing
        // `now` far in the future we force it to cross the 24h threshold.
        let borderlineURL = try makeTempDownloadFile(age: 12 * 60 * 60)
        let forcedFuture = Date().addingTimeInterval(48 * 60 * 60)

        manager.cleanupStaleTempFiles(now: forcedFuture)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: borderlineURL.path),
            "Sweep should treat the injected now as the reference time for the age comparison"
        )
    }

    func test_cleanup_reportsReclaimCounts() throws {
        // Observability: hosts that need to surface a "freed N MB" banner after
        // a crash recovery should be able to read back what the sweep removed.
        let payload = Data(repeating: 0x41, count: 4_096)
        _ = try makeTempDownloadFile(age: 48 * 60 * 60, contents: payload)
        _ = try makeTempDownloadFile(age: 48 * 60 * 60, contents: payload)
        let forcedFuture = Date()

        let result = manager.cleanupStaleTempFiles(now: forcedFuture)

        XCTAssertGreaterThanOrEqual(
            result.removed, 2,
            "Removed count must report at least the files this test seeded"
        )
        XCTAssertGreaterThanOrEqual(
            result.bytesReclaimed, Int64(payload.count * 2),
            "Reclaimed bytes must account for the files this test seeded"
        )
    }

    func test_cleanup_isIdempotent() throws {
        // Second run with no matching files should be a silent no-op.
        let freshURL = try makeTempDownloadFile(age: 60 * 60)

        manager.cleanupStaleTempFiles()
        manager.cleanupStaleTempFiles()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: freshURL.path),
            "Repeated cleanup calls must not alter state for fresh files"
        )
    }

    // MARK: - Active Temp Path Exclusion

    func test_cleanup_preservesRegisteredActiveTempPath() throws {
        // A stale-aged file that is currently registered as an active temp path
        // (i.e. the delegate is mid-flight with it) must NOT be swept.
        let activeURL = try makeTempDownloadFile(age: 48 * 60 * 60)

        manager.registerActiveTempPath(activeURL)
        defer { manager.unregisterActiveTempPath(activeURL) }

        manager.cleanupStaleTempFiles()

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: activeURL.path),
            "A temp path registered as active must be excluded from the sweep regardless of age"
        )
    }

    func test_cleanup_sweepsPathAfterUnregister() throws {
        // Once unregistered the path falls back to normal age-based rules and
        // a stale file should then be removed on the next sweep.
        let staleURL = try makeTempDownloadFile(age: 48 * 60 * 60)

        manager.registerActiveTempPath(staleURL)
        manager.unregisterActiveTempPath(staleURL)

        manager.cleanupStaleTempFiles()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: staleURL.path),
            "After unregistering, a stale temp file should be swept on the next cleanup run"
        )
    }

    // MARK: - Constants Contract

    func test_tempFilePrefix_matchesDelegateOutput() {
        // Sanity: the prefix constant the sweep scans for is the same one the
        // delegate writes. If these drift, the sweep silently stops reclaiming
        // files — a regression that would otherwise go unnoticed.
        XCTAssertEqual(BackgroundDownloadManager.tempFilePrefix, "basechatkit-dl-")
        XCTAssertEqual(BackgroundDownloadManager.tempFileExtension, "download")
    }
}
#endif
