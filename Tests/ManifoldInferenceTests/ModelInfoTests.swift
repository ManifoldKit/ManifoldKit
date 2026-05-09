import XCTest
@testable import ManifoldInference

final class ModelInfoTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelInfoTests-\(UUID().uuidString)")
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

    // MARK: - GGUF Initializer

    func test_ggufInit_validFile_createsModelInfo() throws {
        let fileURL = tempDirectory.appendingPathComponent("test-model.Q4_K_M.gguf")
        try writeGGUFFixture(at: fileURL, totalSize: 1024)

        let model = ModelInfo(ggufURL: fileURL)

        XCTAssertNotNil(model)
        XCTAssertEqual(model?.fileName, "test-model.Q4_K_M.gguf")
        XCTAssertEqual(model?.modelType, .gguf)
        XCTAssertEqual(model?.fileSize, 1024)
        XCTAssertEqual(model?.url, fileURL)
    }

    func test_ggufInit_rejectsFileWithoutMagicBytes() throws {
        // 15-byte ASCII placeholder — mirrors the leaked test-fixture shape documented in
        // `scripts/clean-leaked-test-artifacts.sh`. Before the fix these surfaced as fake
        // ~1 KB entries in the model picker.
        let fileURL = tempDirectory.appendingPathComponent("stub-\(UUID().uuidString).gguf")
        try "not-a-real-gguf".data(using: .utf8)!.write(to: fileURL)

        XCTAssertNil(
            ModelInfo(ggufURL: fileURL),
            "ModelInfo(ggufURL:) must reject files without GGUF magic"
        )
    }

    func test_ggufInit_acceptsFileWithMagicBytes() throws {
        let fileURL = tempDirectory.appendingPathComponent("real-\(UUID().uuidString).gguf")
        try Data([0x47, 0x47, 0x55, 0x46] + Array(repeating: UInt8(0), count: 16)).write(to: fileURL)

        XCTAssertNotNil(ModelInfo(ggufURL: fileURL))
    }

    func test_ggufInit_nonGgufExtension_returnsNil() throws {
        let fileURL = tempDirectory.appendingPathComponent("not-a-model.txt")
        let data = Data(repeating: 0, count: 512)
        try data.write(to: fileURL)

        let model = ModelInfo(ggufURL: fileURL)

        XCTAssertNil(model)
    }

    func test_ggufInit_missingFile_returnsNil() {
        let fileURL = tempDirectory.appendingPathComponent("nonexistent.gguf")

        let model = ModelInfo(ggufURL: fileURL)

        XCTAssertNil(model)
    }

    // MARK: - MLX Initializer

    func test_mlxInit_validDirectory_createsModelInfo() throws {
        let mlxDir = tempDirectory.appendingPathComponent("test-mlx-model")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)

        let configData = Data("{}".utf8)
        try configData.write(to: mlxDir.appendingPathComponent("config.json"))

        let weightsData = Data(repeating: 0, count: 2048)
        try weightsData.write(to: mlxDir.appendingPathComponent("weights.safetensors"))

        let model = ModelInfo(mlxDirectory: mlxDir)

        XCTAssertNotNil(model)
        XCTAssertEqual(model?.modelType, .mlx)
        XCTAssertEqual(model?.fileName, "test-mlx-model")

        // Size should be the sum of config.json + weights.safetensors
        let expectedSize = UInt64(configData.count) + UInt64(weightsData.count)
        XCTAssertEqual(model?.fileSize, expectedSize)
    }

    func test_mlxInit_noConfigJson_returnsNil() throws {
        let mlxDir = tempDirectory.appendingPathComponent("bad-mlx-model")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)

        let weightsData = Data(repeating: 0, count: 1024)
        try weightsData.write(to: mlxDir.appendingPathComponent("weights.safetensors"))

        let model = ModelInfo(mlxDirectory: mlxDir)

        XCTAssertNil(model)
    }

    func test_mlxInit_withNamespace_prefixesFileName() throws {
        let mlxDir = tempDirectory.appendingPathComponent("gemma-4-26b-a4b-it-4bit")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: mlxDir.appendingPathComponent("config.json"))
        try Data(repeating: 0, count: 1024).write(to: mlxDir.appendingPathComponent("weights.safetensors"))

        let model = try XCTUnwrap(ModelInfo(mlxDirectory: mlxDir, namespace: "mlx-community"))

        XCTAssertEqual(model.fileName, "mlx-community/gemma-4-26b-a4b-it-4bit")
        XCTAssertEqual(model.modelType, .mlx)
    }

    func test_mlxInit_nilNamespace_keepsBareFileName() throws {
        let mlxDir = tempDirectory.appendingPathComponent("flat-mlx-model")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: mlxDir.appendingPathComponent("config.json"))
        try Data(repeating: 0, count: 256).write(to: mlxDir.appendingPathComponent("weights.safetensors"))

        let model = try XCTUnwrap(ModelInfo(mlxDirectory: mlxDir, namespace: nil))

        XCTAssertEqual(model.fileName, "flat-mlx-model")
    }

    func test_mlxInit_nestedSafetensors_countsRecursiveSize() throws {
        let mlxDir = tempDirectory.appendingPathComponent("nested-mlx-model")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: mlxDir.appendingPathComponent("config.json"))

        let weightsDirectory = mlxDir.appendingPathComponent("weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weightsDirectory, withIntermediateDirectories: true)
        let weightsData = Data(repeating: 0xAB, count: 2048)
        try weightsData.write(to: weightsDirectory.appendingPathComponent("model.safetensors"))

        let model = try XCTUnwrap(ModelInfo(mlxDirectory: mlxDir))

        XCTAssertEqual(model.modelType, .mlx)
        XCTAssertEqual(model.fileSize, UInt64(2 + weightsData.count))
    }

    // MARK: - Memberwise Initializer

    func test_memberwiseInit_setsAllFields() {
        let id = UUID()
        let url = URL(fileURLWithPath: "/tmp/test.gguf")

        let model = ModelInfo(
            id: id,
            name: "Test Model",
            fileName: "test.gguf",
            url: url,
            fileSize: 4096,
            modelType: .gguf
        )

        XCTAssertEqual(model.id, id)
        XCTAssertEqual(model.name, "Test Model")
        XCTAssertEqual(model.fileName, "test.gguf")
        XCTAssertEqual(model.url, url)
        XCTAssertEqual(model.fileSize, 4096)
        XCTAssertEqual(model.modelType, .gguf)
    }

    // MARK: - Backend Label

    func test_backendLabel_gguf_returnsGGUF() {
        let model = ModelInfo(
            name: "Test",
            fileName: "test.gguf",
            url: URL(fileURLWithPath: "/tmp/test.gguf"),
            fileSize: 0,
            modelType: .gguf
        )

        XCTAssertEqual(model.backendLabel, "GGUF")
    }

    func test_backendLabel_mlx_returnsMLX() {
        let model = ModelInfo(
            name: "Test",
            fileName: "test-mlx",
            url: URL(fileURLWithPath: "/tmp/test-mlx"),
            fileSize: 0,
            modelType: .mlx
        )

        XCTAssertEqual(model.backendLabel, "MLX")
    }

    // MARK: - effectiveCapabilityTier

    func test_effectiveCapabilityTier_usesBenchmarkResultTierWhenAvailable() {
        let benchmarkResult = ModelBenchmarkResult(tier: .frontier)
        let model = ModelInfo(
            name: "Big Model",
            fileName: "big.gguf",
            url: URL(fileURLWithPath: "/tmp/big.gguf"),
            fileSize: 1_073_741_824,  // 1 GB — would estimate .minimal without benchmark
            modelType: .gguf,
            capabilityTier: .fast,
            benchmarkResult: benchmarkResult
        )

        // benchmark result tier wins over capabilityTier and static estimate
        XCTAssertEqual(model.effectiveCapabilityTier, .frontier)
    }

    func test_effectiveCapabilityTier_fallsBackToCapabilityTierWhenNoBenchmark() {
        let model = ModelInfo(
            name: "Test Model",
            fileName: "test.gguf",
            url: URL(fileURLWithPath: "/tmp/test.gguf"),
            fileSize: 1_073_741_824,  // 1 GB — would estimate .minimal
            modelType: .gguf,
            capabilityTier: .balanced,
            benchmarkResult: nil
        )

        XCTAssertEqual(model.effectiveCapabilityTier, .balanced)
    }

    func test_effectiveCapabilityTier_fallsBackToStaticEstimateWhenBothNil() {
        // 3 GB GGUF → .fast according to static estimate
        let threeGB = UInt64(3 * 1_073_741_824)
        let model = ModelInfo(
            name: "Test Model",
            fileName: "test.gguf",
            url: URL(fileURLWithPath: "/tmp/test.gguf"),
            fileSize: threeGB,
            modelType: .gguf,
            capabilityTier: nil,
            benchmarkResult: nil
        )

        XCTAssertEqual(model.effectiveCapabilityTier, .fast)
    }

    // MARK: - Stable ID

    func test_ggufInit_sameFile_producesStableID() throws {
        let fileURL = tempDirectory.appendingPathComponent("stable-id-test.gguf")
        try writeGGUFFixture(at: fileURL, totalSize: 64)

        let first = try XCTUnwrap(ModelInfo(ggufURL: fileURL))
        let second = try XCTUnwrap(ModelInfo(ggufURL: fileURL))

        XCTAssertEqual(first.id, second.id, "Same GGUF file must produce the same ID across calls")
    }

    func test_mlxInit_sameDirectory_producesStableID() throws {
        let mlxDir = tempDirectory.appendingPathComponent("stable-mlx")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: mlxDir.appendingPathComponent("config.json"))
        try Data(repeating: 0, count: 1).write(to: mlxDir.appendingPathComponent("model.safetensors"))

        let first = try XCTUnwrap(ModelInfo(mlxDirectory: mlxDir))
        let second = try XCTUnwrap(ModelInfo(mlxDirectory: mlxDir))

        XCTAssertEqual(first.id, second.id, "Same MLX directory must produce the same ID across calls")
    }

    func test_differentFiles_produceDifferentIDs() throws {
        let fileA = tempDirectory.appendingPathComponent("model-a.gguf")
        let fileB = tempDirectory.appendingPathComponent("model-b.gguf")
        try writeGGUFFixture(at: fileA, totalSize: 64)
        try writeGGUFFixture(at: fileB, totalSize: 64)

        let a = try XCTUnwrap(ModelInfo(ggufURL: fileA))
        let b = try XCTUnwrap(ModelInfo(ggufURL: fileB))

        XCTAssertNotEqual(a.id, b.id, "Different files must produce different IDs")
    }

    func test_stableID_isVersion5UUID() throws {
        let fileURL = tempDirectory.appendingPathComponent("v5-check.gguf")
        try writeGGUFFixture(at: fileURL, totalSize: 64)

        let model = try XCTUnwrap(ModelInfo(ggufURL: fileURL))
        let uuidString = model.id.uuidString

        // UUID v5 has version nibble = 5 at position 14 (0-indexed in the hex string without dashes)
        // Format: xxxxxxxx-xxxx-5xxx-yxxx-xxxxxxxxxxxx
        let parts = uuidString.split(separator: "-")
        XCTAssertTrue(parts[2].hasPrefix("5"), "Stable ID should be a version-5 UUID, got \(uuidString)")
    }

    // MARK: - Display Name

    func test_displayName_stripsGgufExtension() throws {
        let fileURL = tempDirectory.appendingPathComponent("model-name.Q4_K_M.gguf")
        try writeGGUFFixture(at: fileURL, totalSize: 64)

        let model = ModelInfo(ggufURL: fileURL)

        XCTAssertEqual(model?.name, "model name.Q4 K M")
    }

    func test_displayName_mlxDirectory_formatsName() throws {
        let mlxDir = tempDirectory.appendingPathComponent("phi-3-mini-4bit")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: mlxDir.appendingPathComponent("config.json"))
        try Data(repeating: 0x00, count: 1).write(to: mlxDir.appendingPathComponent("model.safetensors"))

        let model = ModelInfo(mlxDirectory: mlxDir)

        XCTAssertEqual(model?.name, "phi 3 mini 4bit")
    }
}
