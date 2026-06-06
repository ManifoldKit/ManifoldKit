import XCTest
@testable import ManifoldModelCatalog

final class ModelCatalogTests: XCTestCase {

    private var scratchDirectory: URL!
    private var modelsDirectory: URL!
    private var storage: ModelStorageService!
    private var catalog: ModelCatalog!

    override func setUpWithError() throws {
        try super.setUpWithError()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelCatalogTests-\(UUID().uuidString)", isDirectory: true)
        modelsDirectory = scratchDirectory.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        storage = ModelStorageService(baseDirectory: modelsDirectory, includeUserDocumentsFallback: false)
        catalog = ModelCatalog(storage: storage)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratchDirectory)
        catalog = nil
        storage = nil
        modelsDirectory = nil
        scratchDirectory = nil
        try super.tearDownWithError()
    }

    func testCatalogRebuildsFromDiskWhenManifestMissing() async throws {
        let modelURL = try createGgufFile(named: "sample-Q4_K_M.gguf", size: 128)

        let entries = try await catalog.catalog()

        let entry = try XCTUnwrap(entries.first { $0.modelInfo.url.lastPathComponent == modelURL.lastPathComponent })
        XCTAssertEqual(entry.source, .imported)
        XCTAssertEqual(entry.sizeBytes, 128)
        XCTAssertEqual(entry.quantization, "Q4_K_M")
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestURL.path))
    }

    func testCatalogRebuildsCorruptManifestFromDisk() async throws {
        let modelURL = try createGgufFile(named: "corrupt-rebuild-Q8_0.gguf", size: 96)
        try Data("not json".utf8).write(to: manifestURL)

        let entries = try await catalog.catalog()

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.modelInfo.url.lastPathComponent, modelURL.lastPathComponent)
        let data = try Data(contentsOf: manifestURL)
        XCTAssertNoThrow(try JSONDecoder().decode(CatalogManifestProbe.self, from: data))
    }

    func testRecordPersistsMetadataAndTouchUpdatesLastUsed() async throws {
        let modelURL = try createGgufFile(named: "recorded-F16.gguf", size: 80)
        let model = try XCTUnwrap(ModelInfo(ggufURL: modelURL))
        let downloadedAt = Date(timeIntervalSince1970: 1_000)
        let initialUsedAt = Date(timeIntervalSince1970: 2_000)
        let touchedAt = Date(timeIntervalSince1970: 3_000)
        let entry = CatalogEntry(
            modelInfo: model,
            source: .huggingFace(repo: "test/repo", file: model.fileName),
            downloadedAt: downloadedAt,
            lastUsedAt: initialUsedAt,
            expectedSHA256: String(repeating: "a", count: 64),
            quantization: "F16"
        )

        try await catalog.record(entry)
        try await catalog.touch(model.id, at: touchedAt)

        let persistedEntries = try await catalog.catalog()
        let persisted = try XCTUnwrap(persistedEntries.first { $0.id == model.id })
        XCTAssertEqual(persisted.source, .huggingFace(repo: "test/repo", file: model.fileName))
        XCTAssertEqual(persisted.downloadedAt, downloadedAt)
        XCTAssertEqual(persisted.lastUsedAt, touchedAt)
        XCTAssertEqual(persisted.expectedSHA256, String(repeating: "a", count: 64))
        XCTAssertEqual(persisted.quantization, "F16")
    }

    func testCatalogDropsManifestEntriesMissingOnDiskAndBackfillsNewDiskModels() async throws {
        let missingModel = ModelInfo(
            name: "Missing",
            fileName: "missing.gguf",
            url: modelsDirectory.appendingPathComponent("missing.gguf"),
            fileSize: 64,
            modelType: .gguf
        )
        try await catalog.record(CatalogEntry(modelInfo: missingModel, source: .bundled))

        let presentURL = try createGgufFile(named: "present-Q5_K_M.gguf", size: 72)

        let entries = try await catalog.catalog()

        XCTAssertNil(entries.first { $0.id == missingModel.id })
        let present = try XCTUnwrap(entries.first { $0.modelInfo.url.lastPathComponent == presentURL.lastPathComponent })
        XCTAssertEqual(present.source, .imported)
    }

    func testEvictDeletesArtifactWhenRequested() async throws {
        let modelURL = try createGgufFile(named: "evict-me-Q4_0.gguf", size: 64)
        let model = try XCTUnwrap(ModelInfo(ggufURL: modelURL))
        try await catalog.record(CatalogEntry(modelInfo: model, source: .imported))

        let evicted = try await catalog.evict(model.id, deleteArtifact: true)

        XCTAssertEqual(evicted?.id, model.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: modelURL.path))
        let remaining = try await catalog.catalog()
        XCTAssertFalse(remaining.contains { $0.id == model.id })
    }

    func testEnforceDiskBudgetEvictsLeastRecentlyUsedArtifacts() async throws {
        let oldURL = try createGgufFile(named: "old-Q4_0.gguf", size: 80)
        let newURL = try createGgufFile(named: "new-Q4_0.gguf", size: 80)
        let old = try XCTUnwrap(ModelInfo(ggufURL: oldURL))
        let new = try XCTUnwrap(ModelInfo(ggufURL: newURL))
        try await catalog.record(CatalogEntry(
            modelInfo: old,
            source: .imported,
            lastUsedAt: Date(timeIntervalSince1970: 1)
        ))
        try await catalog.record(CatalogEntry(
            modelInfo: new,
            source: .imported,
            lastUsedAt: Date(timeIntervalSince1970: 2)
        ))

        let evicted = try await catalog.enforceDiskBudget(80)

        XCTAssertEqual(evicted.map(\.id), [old.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
        let secondPass = try await catalog.enforceDiskBudget(80)
        XCTAssertEqual(secondPass, [])
    }

    // MARK: - Helpers

    private var manifestURL: URL {
        modelsDirectory.appendingPathComponent(ModelCatalog.manifestFileName)
    }

    @discardableResult
    private func createGgufFile(named name: String, size: Int) throws -> URL {
        precondition(size >= 4)
        let url = modelsDirectory.appendingPathComponent(name)
        var data = Data([0x47, 0x47, 0x55, 0x46])
        data.append(Data(repeating: 0xCC, count: size - 4))
        try data.write(to: url)
        return url
    }
}

private struct CatalogManifestProbe: Decodable {
    var version: Int
    var entries: [Entry]

    struct Entry: Decodable {
        var id: UUID
    }
}
