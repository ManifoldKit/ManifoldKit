import XCTest
@testable import ManifoldModelCatalog

final class ModelInfoHuggingFaceFactoryTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelInfoHuggingFaceFactoryTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Writes a minimal fixture with a real GGUF magic-bytes header padded to the requested size.
    /// The first 4 bytes are `[0x47, 0x47, 0x55, 0x46]` so the file passes
    /// `GGUFMetadataReader.isValidGGUF(at:)` without needing a full GGUF structure.
    @discardableResult
    private func writeGGUFFixture(at url: URL, totalSize: Int = 1024) throws -> URL {
        precondition(totalSize >= 4, "GGUF fixture must be at least 4 bytes for the magic header")
        var data = Data([0x47, 0x47, 0x55, 0x46])
        data.append(Data(repeating: 0, count: totalSize - 4))
        try data.write(to: url)
        return url
    }

    // MARK: - Happy Path

    func test_huggingFaceInit_validGGUF_populatesAllFields() throws {
        let localURL = tempDirectory.appendingPathComponent("Llama-3.2-3B-Instruct-Q4_K_M.gguf")
        try writeGGUFFixture(at: localURL, totalSize: 2048)

        let model = try XCTUnwrap(ModelInfo(
            huggingFaceRepoID: "bartowski/Llama-3.2-3B-Instruct-GGUF",
            fileName: "Llama-3.2-3B-Instruct-Q4_K_M.gguf",
            sizeBytes: 1_234_567_890,
            localURL: localURL
        ))

        XCTAssertEqual(model.fileName, "Llama-3.2-3B-Instruct-Q4_K_M.gguf")
        XCTAssertEqual(model.modelType, .gguf)
        XCTAssertEqual(model.url, localURL)
        XCTAssertEqual(model.huggingFaceRepoID, "bartowski/Llama-3.2-3B-Instruct-GGUF")
        XCTAssertNotNil(model.capabilityTier, "capabilityTier should be set after init")
        // Display name should strip .gguf and replace separators with spaces.
        XCTAssertEqual(model.name, "Llama 3.2 3B Instruct Q4 K M")
    }

    // MARK: - Validation

    func test_huggingFaceInit_wrongExtension_returnsNil() throws {
        let localURL = tempDirectory.appendingPathComponent("config.txt")
        try Data(repeating: 0, count: 512).write(to: localURL)

        let model = ModelInfo(
            huggingFaceRepoID: "user/repo",
            fileName: "config.txt",
            sizeBytes: 512,
            localURL: localURL
        )

        XCTAssertNil(model, "Non-.gguf extension must return nil")
    }

    func test_huggingFaceInit_missingMagicBytes_returnsNil() throws {
        // 100-byte file of zeros — passes the extension check but fails the magic-byte check.
        let localURL = tempDirectory.appendingPathComponent("fake.gguf")
        try Data(repeating: 0, count: 100).write(to: localURL)

        let model = ModelInfo(
            huggingFaceRepoID: "user/repo",
            fileName: "fake.gguf",
            sizeBytes: 100,
            localURL: localURL
        )

        XCTAssertNil(model, "GGUF without magic bytes must return nil")
    }

    func test_huggingFaceInit_missingFile_returnsNil() {
        let localURL = tempDirectory.appendingPathComponent("nonexistent.gguf")

        let model = ModelInfo(
            huggingFaceRepoID: "user/repo",
            fileName: "nonexistent.gguf",
            sizeBytes: 1024,
            localURL: localURL
        )

        XCTAssertNil(model)
    }

    // MARK: - Field Round-trips

    func test_huggingFaceInit_repoID_roundTrips() throws {
        let localURL = tempDirectory.appendingPathComponent("model.gguf")
        try writeGGUFFixture(at: localURL, totalSize: 64)

        let model = try XCTUnwrap(ModelInfo(
            huggingFaceRepoID: "TheBloke/Mistral-7B-Instruct-v0.2-GGUF",
            fileName: "model.gguf",
            sizeBytes: 7_000_000_000,
            localURL: localURL
        ))

        XCTAssertEqual(model.huggingFaceRepoID, "TheBloke/Mistral-7B-Instruct-v0.2-GGUF")
    }

    func test_huggingFaceInit_trustsCallerSizeBytes_skipsDiskAttributes() throws {
        // Write a 64-byte fixture but tell the factory the size is 4 GB. If the
        // factory honoured the caller-supplied value, fileSize must be 4 GB.
        // If it secretly fell through to attributesOfItem, fileSize would be 64.
        let localURL = tempDirectory.appendingPathComponent("trust-test.gguf")
        try writeGGUFFixture(at: localURL, totalSize: 64)

        let claimedSize: UInt64 = 4_000_000_000
        let model = try XCTUnwrap(ModelInfo(
            huggingFaceRepoID: "user/repo",
            fileName: "trust-test.gguf",
            sizeBytes: claimedSize,
            localURL: localURL
        ))

        XCTAssertEqual(model.fileSize, claimedSize, "fileSize must match caller-supplied sizeBytes, not the on-disk size")
    }

    func test_huggingFaceInit_useCallerFileName_notDerivedFromURL() throws {
        // localURL has a different basename than the supplied fileName — the
        // factory must use the caller-supplied value verbatim.
        let localURL = tempDirectory.appendingPathComponent("cached-blob-abc123.gguf")
        try writeGGUFFixture(at: localURL, totalSize: 64)

        let model = try XCTUnwrap(ModelInfo(
            huggingFaceRepoID: "user/repo",
            fileName: "Llama-3.2-3B-Q4_K_M.gguf",
            sizeBytes: 1024,
            localURL: localURL
        ))

        XCTAssertEqual(model.fileName, "Llama-3.2-3B-Q4_K_M.gguf")
    }

    // MARK: - Stable ID

    func test_huggingFaceInit_sameLocalURL_producesStableID() throws {
        let localURL = tempDirectory.appendingPathComponent("stable.gguf")
        try writeGGUFFixture(at: localURL, totalSize: 64)

        let first = try XCTUnwrap(ModelInfo(
            huggingFaceRepoID: "user/repo",
            fileName: "stable.gguf",
            sizeBytes: 64,
            localURL: localURL
        ))
        let second = try XCTUnwrap(ModelInfo(
            huggingFaceRepoID: "user/repo",
            fileName: "stable.gguf",
            sizeBytes: 64,
            localURL: localURL
        ))

        XCTAssertEqual(first.id, second.id)
    }
}
