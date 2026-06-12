import XCTest
@testable import ManifoldHuggingFace

final class DownloadHygieneJanitorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = Self.artifactsRoot().appendingPathComponent("DownloadHygieneJanitorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
        try super.tearDownWithError()
    }

    func test_cleanupStaleTempFiles_removesOnlyMatchingOldFiles() throws {
        let janitor = DownloadHygieneJanitor(
            tempScanDirectory: root,
            tempFilePrefix: "manifoldkit-dl-",
            tempFileExtension: "download",
            staleTempFileAge: 24 * 60 * 60
        )
        let stale = try writeFile("manifoldkit-dl-\(UUID().uuidString).download", age: 48 * 60 * 60)
        let unrelated = try writeFile("other.download", age: 48 * 60 * 60)

        let result = janitor.cleanupStaleTempFiles(now: Date())

        XCTAssertEqual(result.removed, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func test_cleanupStaleTempFiles_preservesFileExactlyAtAgeThreshold() throws {
        let staleAge: TimeInterval = 24 * 60 * 60
        let now = Date(timeIntervalSince1970: 100_000)
        let janitor = DownloadHygieneJanitor(
            tempScanDirectory: root,
            tempFilePrefix: "manifoldkit-dl-",
            tempFileExtension: "download",
            staleTempFileAge: staleAge
        )
        let boundary = try writeFile(
            "manifoldkit-dl-\(UUID().uuidString).download",
            modifiedAt: now.addingTimeInterval(-staleAge)
        )

        let result = janitor.cleanupStaleTempFiles(now: now)

        XCTAssertEqual(result.removed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: boundary.path))
    }

    func test_deleteOrphanedResumeDataFiles_preservesKnownIDsAndRemovesDanglingTags() throws {
        let knownID = "repo/known"
        let safeKnown = knownID.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? knownID
        let knownBlob = root.appendingPathComponent("resume-\(safeKnown).bin")
        let orphanBlob = root.appendingPathComponent("resume-orphan.bin")
        let danglingTag = root.appendingPathComponent("resume-dangling.bin.tag")
        try Data("known".utf8).write(to: knownBlob)
        try Data("orphan".utf8).write(to: orphanBlob)
        try Data("tag".utf8).write(to: danglingTag)

        DownloadHygieneJanitor.deleteOrphanedResumeDataFiles(in: root, knownIDs: [knownID])

        XCTAssertTrue(FileManager.default.fileExists(atPath: knownBlob.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanBlob.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: danglingTag.path))
    }

    @discardableResult
    private func writeFile(_ name: String, age: TimeInterval) throws -> URL {
        try writeFile(name, modifiedAt: Date().addingTimeInterval(-age))
    }

    @discardableResult
    private func writeFile(_ name: String, modifiedAt: Date) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data("payload".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
        return url
    }

    private static func artifactsRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tmp/test-artifacts", isDirectory: true)
    }
}
