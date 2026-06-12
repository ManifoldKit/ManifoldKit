import Testing
import Foundation
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldHuggingFace

/// E2E tests for the download validation pipeline using the real filesystem.
///
/// Each test creates temporary files/directories, exercises
/// `BackgroundDownloadManager.validateDownloadedFile(at:modelType:)`,
/// and cleans up afterwards.
@Suite("Download Validation E2E")
@MainActor
struct DownloadValidationE2ETests {

    private let fm = FileManager.default
    private let manager = BackgroundDownloadManager()

    // MARK: - GGUF Validation

    @Test func gguf_validMagicButTooSmall_isRejected() throws {
        let dir = try makeE2ETempDir()
        defer { cleanupE2ETempDir(dir) }

        let fileURL = dir.appendingPathComponent("tiny.gguf")

        // Write correct magic bytes but only a few hundred bytes total.
        var data = Data(ggufMagic)
        data.append(Data(repeating: 0x00, count: 500))
        try data.write(to: fileURL)

        #expect(throws: HuggingFaceError.self) {
            try manager.validateDownloadedFile(at: fileURL, modelType: .gguf)
        }
    }

    @Test func gguf_wrongMagicBytes_isRejected() throws {
        let dir = try makeE2ETempDir()
        defer { cleanupE2ETempDir(dir) }

        let fileURL = dir.appendingPathComponent("bad.gguf")

        // Write wrong magic but large enough size.
        var data = Data([0x00, 0x00, 0x00, 0x00])
        data.append(Data(repeating: 0xAA, count: 2_000_000))
        try data.write(to: fileURL)

        #expect(throws: HuggingFaceError.self) {
            try manager.validateDownloadedFile(at: fileURL, modelType: .gguf)
        }
    }

    @Test func gguf_validFile_isAccepted() throws {
        let dir = try makeE2ETempDir()
        defer { cleanupE2ETempDir(dir) }

        let fileURL = dir.appendingPathComponent("model.gguf")

        // Write correct magic bytes + enough data to pass the 1MB threshold.
        var data = Data(ggufMagic)
        data.append(Data(repeating: 0xFF, count: 1_100_000))
        try data.write(to: fileURL)

        // Should not throw.
        try manager.validateDownloadedFile(at: fileURL, modelType: .gguf)
    }

    @Test func gguf_emptyFile_isRejected() throws {
        let dir = try makeE2ETempDir()
        defer { cleanupE2ETempDir(dir) }

        let fileURL = dir.appendingPathComponent("empty.gguf")
        fm.createFile(atPath: fileURL.path, contents: Data(), attributes: nil)

        #expect(throws: HuggingFaceError.self) {
            try manager.validateDownloadedFile(at: fileURL, modelType: .gguf)
        }
    }

    // MARK: - MLX Validation

    @Test func mlx_directoryMissingConfigJSON_isRejected() throws {
        let dir = try makeE2ETempDir()
        defer { cleanupE2ETempDir(dir) }

        let mlxDir = dir.appendingPathComponent("model-mlx")
        try fm.createDirectory(at: mlxDir, withIntermediateDirectories: true)

        // Create a .safetensors file but no config.json.
        let safetensors = mlxDir.appendingPathComponent("weights.safetensors")
        try Data("fake weights".utf8).write(to: safetensors)

        #expect(throws: HuggingFaceError.self) {
            try manager.validateDownloadedFile(at: mlxDir, modelType: .mlx)
        }
    }

    @Test func mlx_directoryMissingSafetensors_isRejected() throws {
        let dir = try makeE2ETempDir()
        defer { cleanupE2ETempDir(dir) }

        let mlxDir = dir.appendingPathComponent("model-mlx")
        try fm.createDirectory(at: mlxDir, withIntermediateDirectories: true)

        // Create config.json but no .safetensors files.
        let configPath = mlxDir.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: configPath)

        #expect(throws: HuggingFaceError.self) {
            try manager.validateDownloadedFile(at: mlxDir, modelType: .mlx)
        }
    }

    @Test func mlx_validDirectory_isAccepted() throws {
        let dir = try makeE2ETempDir()
        defer { cleanupE2ETempDir(dir) }

        let mlxDir = dir.appendingPathComponent("model-mlx")
        try fm.createDirectory(at: mlxDir, withIntermediateDirectories: true)

        // config.json
        let configPath = mlxDir.appendingPathComponent("config.json")
        try Data("{\"model_type\":\"llama\"}".utf8).write(to: configPath)

        // At least one .safetensors file
        let weightsPath = mlxDir.appendingPathComponent("model.safetensors")
        try Data("fake tensor data".utf8).write(to: weightsPath)

        // Should not throw.
        try manager.validateDownloadedFile(at: mlxDir, modelType: .mlx)
    }

    @Test func mlx_singleFile_isRejected() throws {
        let dir = try makeE2ETempDir()
        defer { cleanupE2ETempDir(dir) }

        // A single file is not a valid MLX snapshot.
        let fileURL = dir.appendingPathComponent("tokenizer.json")
        try Data("{}".utf8).write(to: fileURL)

        #expect(throws: HuggingFaceError.self) {
            try manager.validateDownloadedFile(at: fileURL, modelType: .mlx)
        }
    }

    @Test func mlx_nonExistentFile_isRejected() throws {
        let dir = try makeE2ETempDir()
        defer { cleanupE2ETempDir(dir) }

        let fakeURL = dir.appendingPathComponent("does-not-exist.json")

        #expect(throws: HuggingFaceError.self) {
            try manager.validateDownloadedFile(at: fakeURL, modelType: .mlx)
        }
    }

    // MARK: - Foundation Type Rejection

    @Test func foundation_modelType_isAlwaysRejected() throws {
        let dir = try makeE2ETempDir()
        defer { cleanupE2ETempDir(dir) }

        let fileURL = dir.appendingPathComponent("anything")
        try Data("data".utf8).write(to: fileURL)

        #expect(throws: HuggingFaceError.self) {
            try manager.validateDownloadedFile(at: fileURL, modelType: .foundation)
        }
    }

    // MARK: - Pending Download Persistence

    @Test func pendingDownload_roundTrips_throughUserDefaults() throws {
        let suiteName = "com.manifoldkit.e2e.test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let key = "testPendingDownloads"

        // Simulate saving a pending download.
        let model = DownloadableModel(
            repoID: "test-org/test-model",
            fileName: "model.gguf",
            displayName: "Test Model",
            modelType: .gguf,
            sizeBytes: 1_000_000
        )

        var pending: [String: [String: String]] = [:]
        pending[model.id] = [
            "repoID": model.repoID,
            "fileName": model.fileName,
            "displayName": model.displayName,
            "modelType": "gguf",
        ]
        defaults.set(pending, forKey: key)

        // Read it back.
        guard let restored = defaults.dictionary(forKey: key) as? [String: [String: String]] else {
            Issue.record("Failed to restore pending downloads from UserDefaults")
            return
        }

        #expect(restored.count == 1)
        let info = restored[model.id]
        #expect(info?["repoID"] == "test-org/test-model")
        #expect(info?["fileName"] == "model.gguf")
        #expect(info?["displayName"] == "Test Model")
        #expect(info?["modelType"] == "gguf")

        // Remove and verify cleanup.
        var mutable = restored
        mutable.removeValue(forKey: model.id)
        defaults.set(mutable, forKey: key)

        let afterRemoval = defaults.dictionary(forKey: key) as? [String: [String: String]]
        #expect(afterRemoval?.isEmpty == true)
    }
}
