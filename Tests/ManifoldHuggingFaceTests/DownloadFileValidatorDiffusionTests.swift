import XCTest
@testable import ManifoldInference
@testable import ManifoldHuggingFace

final class DownloadFileValidatorDiffusionTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiffusionValidator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
        tempDir = nil
        try super.tearDownWithError()
    }

    // MARK: - Manifest

    func test_validate_manifest_validJSON_passes() throws {
        let url = tempDir.appendingPathComponent("model_index.json")
        try Data(#"{"unet": ["UNet2DConditionModel", "unet"]}"#.utf8).write(to: url)
        XCTAssertNoThrow(
            try DownloadFileValidator.validate(url, diffusionRole: .manifest)
        )
    }

    func test_validate_manifest_garbageJSON_throws() throws {
        let url = tempDir.appendingPathComponent("model_index.json")
        try Data("not json {{{".utf8).write(to: url)
        XCTAssertThrowsError(
            try DownloadFileValidator.validate(url, diffusionRole: .manifest)
        )
    }

    func test_validate_manifest_missingFile_throws() throws {
        let url = tempDir.appendingPathComponent("does-not-exist.json")
        XCTAssertThrowsError(
            try DownloadFileValidator.validate(url, diffusionRole: .manifest)
        )
    }

    func test_validate_manifest_emptyFile_throws() throws {
        let url = tempDir.appendingPathComponent("model_index.json")
        try Data().write(to: url)
        XCTAssertThrowsError(
            try DownloadFileValidator.validate(url, diffusionRole: .manifest)
        )
    }

    // MARK: - Submodule config

    func test_validate_submoduleConfig_validJSON_passes() throws {
        let url = tempDir.appendingPathComponent("config.json")
        try Data(#"{"sample_size": 64}"#.utf8).write(to: url)
        XCTAssertNoThrow(
            try DownloadFileValidator.validate(url, diffusionRole: .submoduleConfig)
        )
    }

    // MARK: - Weights (safetensors)

    func test_validate_weights_validHeader_passes() throws {
        let url = tempDir.appendingPathComponent("model.safetensors")
        let headerJSON = #"{"foo":{"dtype":"F16","shape":[1],"data_offsets":[0,2]}}"#
        let data = makeSafetensorsBlob(headerJSON: headerJSON, payloadByteCount: 2)
        try data.write(to: url)
        XCTAssertNoThrow(
            try DownloadFileValidator.validate(url, diffusionRole: .weights)
        )
    }

    func test_validate_weights_truncatedHeader_throws() throws {
        let url = tempDir.appendingPathComponent("truncated.safetensors")
        // Header length claims 1 GB, but the file is only 16 bytes.
        var bytes = [UInt8](repeating: 0, count: 16)
        let bogusLen: UInt64 = 1_000_000_000
        withUnsafeBytes(of: bogusLen.littleEndian) { raw in
            for i in 0..<8 { bytes[i] = raw[i] }
        }
        try Data(bytes).write(to: url)
        XCTAssertThrowsError(
            try DownloadFileValidator.validate(url, diffusionRole: .weights)
        )
    }

    func test_validate_weights_zeroHeaderLength_throws() throws {
        let url = tempDir.appendingPathComponent("zero.safetensors")
        // 8 zero bytes + a few payload bytes — header length 0 is invalid.
        try Data([0, 0, 0, 0, 0, 0, 0, 0, 0xAA, 0xBB]).write(to: url)
        XCTAssertThrowsError(
            try DownloadFileValidator.validate(url, diffusionRole: .weights)
        )
    }

    func test_validate_weights_tooSmallForHeader_throws() throws {
        let url = tempDir.appendingPathComponent("small.safetensors")
        try Data([0, 0, 0]).write(to: url)
        XCTAssertThrowsError(
            try DownloadFileValidator.validate(url, diffusionRole: .weights)
        )
    }

    // MARK: - Tokenizer vocab

    func test_validate_tokenizerVocab_validJSON_passes() throws {
        let url = tempDir.appendingPathComponent("vocab.json")
        try Data(#"{"hello": 0, "world": 1}"#.utf8).write(to: url)
        XCTAssertNoThrow(
            try DownloadFileValidator.validate(url, diffusionRole: .tokenizerVocab)
        )
    }

    func test_validate_tokenizerVocab_garbage_throws() throws {
        let url = tempDir.appendingPathComponent("vocab.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertThrowsError(
            try DownloadFileValidator.validate(url, diffusionRole: .tokenizerVocab)
        )
    }

    // MARK: - Tokenizer merges

    func test_validate_tokenizerMerges_validBPE_passes() throws {
        let url = tempDir.appendingPathComponent("merges.txt")
        try Data("#version: 0.2\nh e\nhe l\n".utf8).write(to: url)
        XCTAssertNoThrow(
            try DownloadFileValidator.validate(url, diffusionRole: .tokenizerMerges)
        )
    }

    func test_validate_tokenizerMerges_emptyFirstLine_throws() throws {
        let url = tempDir.appendingPathComponent("merges.txt")
        try Data("\nfoo bar\n".utf8).write(to: url)
        XCTAssertThrowsError(
            try DownloadFileValidator.validate(url, diffusionRole: .tokenizerMerges)
        )
    }

    // MARK: - Expected size

    func test_validate_expectedSize_match_passes() throws {
        let url = tempDir.appendingPathComponent("config.json")
        let payload = #"{"foo":1}"#
        try Data(payload.utf8).write(to: url)
        let size = Int64(payload.utf8.count)
        XCTAssertNoThrow(
            try DownloadFileValidator.validate(url, diffusionRole: .submoduleConfig, expectedSize: size)
        )
    }

    func test_validate_expectedSize_mismatch_throws() throws {
        let url = tempDir.appendingPathComponent("config.json")
        try Data(#"{"foo":1}"#.utf8).write(to: url)
        XCTAssertThrowsError(
            try DownloadFileValidator.validate(
                url, diffusionRole: .submoduleConfig, expectedSize: 9999
            )
        )
    }

    // MARK: - Helpers

    /// Builds a minimal valid safetensors blob: 8-byte little-endian header
    /// length, the JSON header, then `payloadByteCount` zero bytes.
    private func makeSafetensorsBlob(headerJSON: String, payloadByteCount: Int) -> Data {
        let headerBytes = Data(headerJSON.utf8)
        var prefix = Data(count: 8)
        let headerLen = UInt64(headerBytes.count).littleEndian
        prefix.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: headerLen, as: UInt64.self)
        }
        var blob = prefix
        blob.append(headerBytes)
        blob.append(Data(repeating: 0, count: payloadByteCount))
        return blob
    }
}
