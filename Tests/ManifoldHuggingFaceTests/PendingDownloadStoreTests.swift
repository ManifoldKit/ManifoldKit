import XCTest
@testable import ManifoldInference
#if HuggingFace
@testable import ManifoldHuggingFace

final class PendingDownloadStoreTests: XCTestCase {
    private var root: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = Self.artifactsRoot().appendingPathComponent("PendingDownloadStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "com.manifoldkit.pending-store.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDownWithError() throws {
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        PendingDownloadStore._resetResumeHMACKeyCacheForTesting()
        root = nil
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    func test_saveLoadRemovePendingDownload_roundTripsMetadata() throws {
        let store = PendingDownloadStore(persistenceDirectory: root, userDefaults: defaults)
        let model = DownloadableModel(
            repoID: "test/repo",
            fileName: "model.gguf",
            displayName: "Model",
            modelType: .gguf,
            sizeBytes: 42
        )

        try store.savePendingDownload(model: model)

        let saved = try XCTUnwrap(store.loadPendingMetadata()?[model.id])
        XCTAssertEqual(saved["repoID"], "test/repo")
        XCTAssertEqual(saved["fileName"], "model.gguf")
        XCTAssertEqual(saved["sizeBytes"], "42")

        store.removePendingDownload(id: model.id)
        XCTAssertNil(store.loadPendingMetadata()?[model.id])
    }

    func test_savePendingDownload_roundTripsSnapshotMetadata() throws {
        let store = PendingDownloadStore(persistenceDirectory: root, userDefaults: defaults)
        let model = DownloadableModel(
            repoID: "test/diffusion",
            fileName: "snapshot",
            displayName: "Diffusion",
            modelType: .mlx,
            sizeBytes: 123,
            packageKind: .diffusion
        )
        let files = [
            SnapshotFileMetadata(
                relativePath: "model_index.json",
                sizeBytes: 12,
                expectedChecksum: ModelFileChecksum(algorithm: .sha256, hexDigest: String(repeating: "a", count: 64))
            ),
            SnapshotFileMetadata(relativePath: "unet/config.json", sizeBytes: 34, expectedChecksum: nil),
        ]

        try store.savePendingDownload(
            model: model,
            snapshotFiles: files,
            stagingDirectoryName: ".staging-\(UUID().uuidString)"
        )

        let saved = try XCTUnwrap(store.loadPendingMetadata()?[model.id])
        XCTAssertEqual(saved["packageKind"], ModelPackageKind.diffusion.rawValue)
        XCTAssertTrue(saved["stagingDirectoryName"]?.hasPrefix(".staging-") == true)
        let json = try XCTUnwrap(saved["snapshotFiles"])
        let data = try XCTUnwrap(json.data(using: .utf8))
        let decoded = try JSONDecoder().decode([SnapshotFileMetadata].self, from: data)
        XCTAssertEqual(decoded.map(\.relativePath), files.map(\.relativePath))
        XCTAssertEqual(decoded.map(\.sizeBytes), files.map(\.sizeBytes))
        XCTAssertEqual(decoded.first?.expectedChecksum, files.first?.expectedChecksum)
    }

    func test_resumeDataConsumptionVerifiesAndRemovesTaggedBlob() {
        let store = PendingDownloadStore(persistenceDirectory: root, userDefaults: defaults)
        let payload = Data("resume-data".utf8)

        store.persistResumeData(payload, for: "repo/model")

        XCTAssertEqual(store.consumeResumeData(for: "repo/model"), payload)
        XCTAssertNil(store.consumeResumeData(for: "repo/model"))
    }

    func test_consumeResumeData_rejectsTamperedBlob() throws {
        let store = PendingDownloadStore(persistenceDirectory: root, userDefaults: defaults)
        let id = "repo/tampered"

        store.persistResumeData(Data("original".utf8), for: id)
        try Data("modified".utf8).write(to: store.resumeDataFileURL(for: id), options: .atomic)

        XCTAssertNil(store.consumeResumeData(for: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.resumeDataFileURL(for: id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.resumeDataTagURL(for: id).path))
    }

    func test_consumeResumeData_rejectsMissingTag() throws {
        let store = PendingDownloadStore(persistenceDirectory: root, userDefaults: defaults)
        let id = "repo/missing-tag"

        store.persistResumeData(Data("payload".utf8), for: id)
        try FileManager.default.removeItem(at: store.resumeDataTagURL(for: id))

        XCTAssertNil(store.consumeResumeData(for: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.resumeDataFileURL(for: id).path))
    }

    func test_consumeResumeData_rejectsCorruptedTag() throws {
        let store = PendingDownloadStore(persistenceDirectory: root, userDefaults: defaults)
        let id = "repo/corrupt-tag"

        store.persistResumeData(Data("payload".utf8), for: id)
        try Data("bad-tag".utf8).write(to: store.resumeDataTagURL(for: id), options: .atomic)

        XCTAssertNil(store.consumeResumeData(for: id))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.resumeDataFileURL(for: id).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.resumeDataTagURL(for: id).path))
    }

    func test_migrateFromUserDefaults_writesTaggedResumeDataAndClearsLegacyKey() {
        let store = PendingDownloadStore(persistenceDirectory: root, userDefaults: defaults)
        let id = "repo/migrated-model"
        let key = "resumeData.\(id)"
        let payload = Data("legacy-resume".utf8)
        defaults.set(payload, forKey: key)

        store.migrateFromUserDefaults()

        XCTAssertNil(defaults.data(forKey: key))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.resumeDataFileURL(for: id).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.resumeDataTagURL(for: id).path))
        XCTAssertEqual(store.consumeResumeData(for: id), payload)
    }

    func test_migrateFromUserDefaults_keepsResumeDataKeyWhenTaggedPairCannotBeWritten() throws {
        let blockedPath = root.appendingPathComponent("blocked")
        try Data("not-a-directory".utf8).write(to: blockedPath)
        let store = PendingDownloadStore(persistenceDirectory: blockedPath, userDefaults: defaults)
        let id = "repo/retry-migration"
        let key = "resumeData.\(id)"
        let payload = Data("legacy-resume".utf8)
        defaults.set(payload, forKey: key)

        store.migrateFromUserDefaults()

        XCTAssertEqual(defaults.data(forKey: key), payload)
    }

    private static func artifactsRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("tmp/test-artifacts", isDirectory: true)
    }
}
#endif
