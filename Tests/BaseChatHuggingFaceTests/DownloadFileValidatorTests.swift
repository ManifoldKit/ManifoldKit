import XCTest
@testable import BaseChatInference
#if HuggingFace
@testable import BaseChatHuggingFace

final class DownloadFileValidatorTests: XCTestCase {

    private var tempURLs: [URL] = []

    override func tearDown() {
        super.tearDown()
        for url in tempURLs {
            try? FileManager.default.removeItem(at: url)
        }
        tempURLs.removeAll()
    }

    // MARK: - Helpers

    private func makeTempFile(bytes: [UInt8]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try Data(bytes).write(to: url)
        tempURLs.append(url)
        return url
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        tempURLs.append(url)
        return url
    }

    // MARK: - GGUF Tests

    func testGGUF_valid_noThrow() throws {
        // Magic bytes + enough padding to exceed the 1 MB minimum-size check.
        var bytes: [UInt8] = [0x47, 0x47, 0x55, 0x46]
        bytes += [UInt8](repeating: 0x00, count: 1_000_000)
        let url = try makeTempFile(bytes: bytes)

        XCTAssertNoThrow(try DownloadFileValidator().validate(at: url, modelType: .gguf))
    }

    func testGGUF_invalidMagic_throws() throws {
        var bytes: [UInt8] = [0x00, 0x00, 0x00, 0x00]
        bytes += [UInt8](repeating: 0xAB, count: 1_000_001)
        let url = try makeTempFile(bytes: bytes)

        XCTAssertThrowsError(try DownloadFileValidator().validate(at: url, modelType: .gguf))
    }

    func testGGUF_truncatedFile_throws() throws {
        // 3 bytes — too short to read the 4-byte header.
        let url = try makeTempFile(bytes: [0x47, 0x47, 0x55])

        XCTAssertThrowsError(try DownloadFileValidator().validate(at: url, modelType: .gguf))
    }

    func testGGUF_nonExistentFile_throws() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString).gguf")

        XCTAssertThrowsError(try DownloadFileValidator().validate(at: url, modelType: .gguf))
    }

    // MARK: - MLX Tests

    func testMLX_valid_noThrow() throws {
        let dir = try makeTempDirectory()
        // config.json
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        // a .safetensors file
        try Data("weights".utf8).write(to: dir.appendingPathComponent("model.safetensors"))

        XCTAssertNoThrow(try DownloadFileValidator().validate(at: dir, modelType: .mlx))
    }

    func testMLX_missingConfig_throws() throws {
        let dir = try makeTempDirectory()
        // No config.json — only a weights file.
        try Data("weights".utf8).write(to: dir.appendingPathComponent("model.safetensors"))

        XCTAssertThrowsError(try DownloadFileValidator().validate(at: dir, modelType: .mlx))
    }

    func testMLX_missingSafetensors_throws() throws {
        let dir = try makeTempDirectory()
        // config.json present but no .safetensors files.
        try Data("{}".utf8).write(to: dir.appendingPathComponent("config.json"))
        try Data("readme".utf8).write(to: dir.appendingPathComponent("README.md"))

        XCTAssertThrowsError(try DownloadFileValidator().validate(at: dir, modelType: .mlx))
    }

    func testMLX_nonExistentPath_throws() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent-\(UUID().uuidString)", isDirectory: true)

        XCTAssertThrowsError(try DownloadFileValidator().validate(at: url, modelType: .mlx))
    }

    // MARK: - DownloadableModel.expectedSHA256 Plumbing
    //
    // Phase 1 of #367: the public `DownloadableModel.expectedSHA256` field must
    // flow through `HuggingFaceService.downloadPlan(for:)` into the validator
    // path. These tests pin the wiring so a future refactor cannot silently
    // drop the digest on the floor.

    func testDownloadPlan_GGUF_propagatesExpectedSHA256() async throws {
        let model = DownloadableModel(
            repoID: "TestOrg/Test-GGUF",
            fileName: "model.Q4_K_M.gguf",
            displayName: "Test",
            modelType: .gguf,
            sizeBytes: 1_000_000,
            expectedSHA256: "1270d22c0fbb3d092fb725d4d96c457b7b687a5f5a715abe1e818da303e562b6"
        )

        let plan = try await HuggingFaceService().downloadPlan(for: model)
        guard case .singleFile(_, let checksum) = plan else {
            return XCTFail("Expected .singleFile plan for GGUF model, got: \(plan)")
        }
        XCTAssertEqual(checksum?.algorithm, .sha256)
        XCTAssertEqual(
            checksum?.hexDigest,
            "1270d22c0fbb3d092fb725d4d96c457b7b687a5f5a715abe1e818da303e562b6"
        )
    }

    func testDownloadPlan_GGUF_nilExpectedSHA256_yieldsUnverifiedPlan() async throws {
        let model = DownloadableModel(
            repoID: "TestOrg/Test-GGUF",
            fileName: "model.Q4_K_M.gguf",
            displayName: "Test",
            modelType: .gguf,
            sizeBytes: 1_000_000,
            expectedSHA256: nil
        )

        let plan = try await HuggingFaceService().downloadPlan(for: model)
        guard case .singleFile(_, let checksum) = plan else {
            return XCTFail("Expected .singleFile plan for GGUF model, got: \(plan)")
        }
        XCTAssertNil(checksum, "Unverified models must not synthesise a checksum")
    }

    func testDownloadableModel_fromCurated_inheritsExpectedSHA256() {
        let curated = CuratedModel(
            id: "test-curated",
            displayName: "Test Curated",
            fileName: "test.gguf",
            repoID: "TestOrg/Test-GGUF",
            modelType: .gguf,
            approximateSizeBytes: 1_000_000,
            recommendedFor: [.small],
            contextSize: 2048,
            promptTemplate: .chatML,
            description: "Fixture",
            expectedSHA256: "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        )

        let downloadable = DownloadableModel(from: curated)
        XCTAssertEqual(
            downloadable.expectedSHA256,
            "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        )
    }

    func testDownloadableModel_fromCurated_nilSHA_passesThrough() {
        let curated = CuratedModel(
            id: "test-unverified",
            displayName: "Test Unverified",
            fileName: "test.gguf",
            repoID: "TestOrg/Test-GGUF",
            modelType: .gguf,
            approximateSizeBytes: 1_000_000,
            recommendedFor: [.small],
            contextSize: 2048,
            promptTemplate: .chatML,
            description: "Fixture"
        )

        let downloadable = DownloadableModel(from: curated)
        XCTAssertNil(downloadable.expectedSHA256)
    }
}
#endif
