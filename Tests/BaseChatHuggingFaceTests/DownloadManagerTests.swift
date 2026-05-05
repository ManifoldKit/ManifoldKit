@preconcurrency import XCTest
@testable import BaseChatInference
#if HuggingFace
@testable import BaseChatHuggingFace

@MainActor
final class DownloadManagerTests: XCTestCase {

    private var manager: BackgroundDownloadManager!
    private var tempDirectory: URL!

    /// Per-instance UserDefaults suite — prevents parallel test runs from racing
    /// on the global `pendingDownloadsKey` in `UserDefaults.standard`.
    private var suiteName: String!
    private var testDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadManagerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        suiteName = "com.basechatkit.test.downloads.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        manager = BackgroundDownloadManager(
            storageService: ModelStorageService(baseDirectory: tempDirectory),
            sessionIdentifier: "com.basechatkit.test.download.\(UUID().uuidString)",
            userDefaults: testDefaults
        )
    }

    override func tearDown() async throws {
        // Clean up temp files.
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        if let suiteName {
            testDefaults?.removePersistentDomain(forName: suiteName)
        }
        tempDirectory = nil
        manager = nil
        testDefaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    private func makeSnapshotFiles() -> [ModelDownloadFile] {
        [
            ModelDownloadFile(
                relativePath: "config.json",
                url: URL(string: "https://example.com/config.json")!,
                sizeBytes: 100
            ),
            ModelDownloadFile(
                relativePath: "weights/model.safetensors",
                url: URL(string: "https://example.com/weights/model.safetensors")!,
                sizeBytes: 900
            ),
        ]
    }

    private func makeDiffusionPackageFiles() -> [ModelDownloadFile] {
        [
            "model_index.json",
            "unet/config.json",
            "unet/diffusion_pytorch_model.safetensors",
            "vae/config.json",
            "vae/diffusion_pytorch_model.safetensors",
            "text_encoder/config.json",
            "text_encoder/model.safetensors",
            "scheduler/scheduler_config.json",
        ].enumerated().map { index, path in
            ModelDownloadFile(
                relativePath: path,
                url: URL(string: "https://example.com/component-\(index)")!,
                sizeBytes: 100
            )
        }
    }

    private func makeSafetensorsBlob(payloadByteCount: Int = 4) -> Data {
        let headerJSON = #"{"x":{"dtype":"F16","shape":[2],"data_offsets":[0,4]}}"#
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

    private func fixtureData(forDiffusionRelativePath relativePath: String) -> Data {
        if relativePath.hasSuffix(".safetensors") {
            return makeSafetensorsBlob()
        }
        if relativePath.hasSuffix("merges.txt") {
            return Data("#version: 0.2\na b\n".utf8)
        }
        return Data(#"{"ok": true}"#.utf8)
    }

    // MARK: - Disk Space

    func test_diskSpaceCheck_sufficientSpace() async {
        // A tiny model size should always pass the disk space check on a dev machine.
        do {
            try await manager.checkDiskSpace(requiredBytes: 1024)
        } catch {
            XCTFail("1 KB model should pass disk space check on any reasonable system, got: \(error)")
        }
    }

    func test_diskSpaceCheck_insufficientSpace() async {
        // Request an absurdly large amount of space that no system has.
        let absurdSize: UInt64 = UInt64.max / 2

        do {
            try await manager.checkDiskSpace(requiredBytes: absurdSize)
            XCTFail("Expected insufficientDiskSpace error")
        } catch {
            guard case HuggingFaceError.insufficientDiskSpace = error else {
                XCTFail("Expected insufficientDiskSpace error, got: \(error)")
                return
            }
        }
    }

    // MARK: - GGUF Validation

    func test_validateChecksum_expectedDigestMatches_passes() throws {
        let fileURL = tempDirectory.appendingPathComponent("checksum-pass.bin")
        try Data("hello".utf8).write(to: fileURL)

        let expected = ModelFileChecksum(
            algorithm: .sha256,
            hexDigest: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        )
        XCTAssertNoThrow(try DownloadFileValidator().validateChecksum(at: fileURL, expectedChecksum: expected))
    }

    func test_validateChecksum_expectedDigestMismatch_throws() throws {
        let fileURL = tempDirectory.appendingPathComponent("checksum-fail.bin")
        try Data("hello".utf8).write(to: fileURL)

        let expected = ModelFileChecksum(
            algorithm: .sha256,
            hexDigest: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        )
        XCTAssertThrowsError(
            try DownloadFileValidator().validateChecksum(at: fileURL, expectedChecksum: expected)
        ) { error in
            guard case HuggingFaceError.invalidDownloadedFile(let reason) = error else {
                return XCTFail("Expected invalidDownloadedFile for checksum mismatch, got: \(error)")
            }
            XCTAssertTrue(reason.contains("Checksum mismatch"), "Expected mismatch error, got: \(reason)")
        }
    }

    func test_validateChecksum_missingExpectedDigest_skipsVerification() throws {
        let fileURL = tempDirectory.appendingPathComponent("checksum-optional.bin")
        try Data("tiny".utf8).write(to: fileURL)
        XCTAssertNoThrow(try DownloadFileValidator().validateChecksum(at: fileURL, expectedChecksum: nil))
    }

    func test_validateGGUFFile_validMagic() throws {
        // Create a temp file with valid GGUF magic bytes and realistic size (>1MB).
        let fileURL = tempDirectory.appendingPathComponent("valid.gguf")
        var data = Data([0x47, 0x47, 0x55, 0x46])  // "GGUF"
        data.append(Data(repeating: 0x00, count: 1_100_000))
        try data.write(to: fileURL)

        XCTAssertNoThrow(
            try manager.validateDownloadedFile(at: fileURL, modelType: .gguf),
            "File with valid GGUF magic bytes should pass validation"
        )
    }

    func test_validateGGUFFile_invalidMagic() throws {
        // Create a temp file with wrong magic bytes.
        let fileURL = tempDirectory.appendingPathComponent("invalid.gguf")
        let data = Data([0x00, 0x01, 0x02, 0x03, 0x04, 0x05])
        try data.write(to: fileURL)

        XCTAssertThrowsError(
            try manager.validateDownloadedFile(at: fileURL, modelType: .gguf)
        ) { error in
            guard case HuggingFaceError.invalidDownloadedFile(let reason) = error else {
                XCTFail("Expected invalidDownloadedFile error, got: \(error)")
                return
            }
            XCTAssertTrue(
                reason.contains("magic bytes"),
                "Error reason should mention magic bytes, got: \(reason)"
            )
        }
    }

    func test_validateGGUFFile_tooSmall() throws {
        // Create a file with fewer than 4 bytes.
        let fileURL = tempDirectory.appendingPathComponent("tiny.gguf")
        let data = Data([0x47, 0x47])  // Only 2 bytes
        try data.write(to: fileURL)

        XCTAssertThrowsError(
            try manager.validateDownloadedFile(at: fileURL, modelType: .gguf)
        ) { error in
            guard case HuggingFaceError.invalidDownloadedFile = error else {
                XCTFail("Expected invalidDownloadedFile error, got: \(error)")
                return
            }
        }
    }

    func test_validateGGUFFile_nonexistentFile() {
        let fileURL = tempDirectory.appendingPathComponent("does-not-exist.gguf")

        XCTAssertThrowsError(
            try manager.validateDownloadedFile(at: fileURL, modelType: .gguf)
        ) { error in
            guard case HuggingFaceError.invalidDownloadedFile = error else {
                XCTFail("Expected invalidDownloadedFile error, got: \(error)")
                return
            }
        }
    }

    // MARK: - Active Downloads State

    func test_hasActiveDownloads_reflectsState() {
        // Initially no active downloads.
        XCTAssertFalse(manager.hasActiveDownloads, "Should have no active downloads initially")

        // Manually inject a queued download state to test the computed property.
        let model = DownloadableModel(
            repoID: "test/model",
            fileName: "test.gguf",
            displayName: "Test Model",
            modelType: .gguf,
            sizeBytes: 1000
        )
        let state = DownloadState(model: model)
        manager.activeDownloads[model.id] = state

        XCTAssertTrue(
            manager.hasActiveDownloads,
            "Should report active downloads when a queued state exists"
        )

        // Mark it completed.
        let dummyURL = tempDirectory.appendingPathComponent("test.gguf")
        state.markCompleted(localURL: dummyURL)

        XCTAssertFalse(
            manager.hasActiveDownloads,
            "Should not report active downloads when all are completed"
        )
    }

    func test_hasActiveDownloads_failedDoesNotCount() {
        let model = DownloadableModel(
            repoID: "test/model",
            fileName: "test.gguf",
            displayName: "Test Model",
            modelType: .gguf,
            sizeBytes: 1000
        )
        let state = DownloadState(model: model)
        state.markFailed(error: "Test error")
        manager.activeDownloads[model.id] = state

        XCTAssertFalse(
            manager.hasActiveDownloads,
            "Failed downloads should not count as active"
        )
    }

    func test_hasActiveDownloads_cancelledDoesNotCount() {
        let model = DownloadableModel(
            repoID: "test/model",
            fileName: "test.gguf",
            displayName: "Test Model",
            modelType: .gguf,
            sizeBytes: 1000
        )
        let state = DownloadState(model: model)
        state.markCancelled()
        manager.activeDownloads[model.id] = state

        XCTAssertFalse(
            manager.hasActiveDownloads,
            "Cancelled downloads should not count as active"
        )
    }

    // MARK: - Active Downloads Initial State

    func test_activeDownloads_initiallyEmpty() {
        let freshManager = BackgroundDownloadManager(
            sessionIdentifier: "com.basechatkit.test.download.\(UUID().uuidString)",
            userDefaults: testDefaults
        )
        XCTAssertTrue(
            freshManager.activeDownloads.isEmpty,
            "A freshly created manager should have no active downloads"
        )
    }

    // MARK: - DownloadState Transitions

    func test_downloadState_progressUpdates() {
        let model = DownloadableModel(
            repoID: "test/model",
            fileName: "test.gguf",
            displayName: "Test Model",
            modelType: .gguf,
            sizeBytes: 10_000_000
        )
        let state = DownloadState(model: model)

        // Starts as queued.
        if case .queued = state.status { } else {
            XCTFail("Initial status should be .queued, got: \(state.status)")
        }

        // Update progress.
        state.updateProgress(bytesDownloaded: 5_000_000, totalBytes: 10_000_000)

        if case .downloading(let progress, let bytesDownloaded, let totalBytes) = state.status {
            XCTAssertEqual(progress, 0.5, accuracy: 0.001)
            XCTAssertEqual(bytesDownloaded, 5_000_000)
            XCTAssertEqual(totalBytes, 10_000_000)
        } else {
            XCTFail("After updateProgress, status should be .downloading, got: \(state.status)")
        }
    }

    func test_downloadState_transitionSequence() {
        let model = DownloadableModel(
            repoID: "test/model",
            fileName: "test.gguf",
            displayName: "Test Model",
            modelType: .gguf,
            sizeBytes: 10_000_000
        )
        let state = DownloadState(model: model)

        // queued → downloading
        state.updateProgress(bytesDownloaded: 1_000, totalBytes: 10_000_000)
        if case .downloading = state.status { } else {
            XCTFail("Expected .downloading after updateProgress, got: \(state.status)")
        }

        // downloading → completed
        let dummyURL = tempDirectory.appendingPathComponent("test.gguf")
        state.markCompleted(localURL: dummyURL)
        if case .completed(let url) = state.status {
            XCTAssertEqual(url, dummyURL)
        } else {
            XCTFail("Expected .completed after markCompleted, got: \(state.status)")
        }
    }

    func test_downloadState_failedTransition() {
        let model = DownloadableModel(
            repoID: "test/model",
            fileName: "test.gguf",
            displayName: "Test Model",
            modelType: .gguf,
            sizeBytes: 10_000_000
        )
        let state = DownloadState(model: model)

        // queued → failed
        state.markFailed(error: "Network timeout")
        if case .failed(let error) = state.status {
            XCTAssertEqual(error, "Network timeout")
        } else {
            XCTFail("Expected .failed after markFailed, got: \(state.status)")
        }
    }

    func test_downloadState_cancelledTransition() {
        let model = DownloadableModel(
            repoID: "test/model",
            fileName: "test.gguf",
            displayName: "Test Model",
            modelType: .gguf,
            sizeBytes: 10_000_000
        )
        let state = DownloadState(model: model)

        // queued → cancelled
        state.markCancelled()
        if case .cancelled = state.status { } else {
            XCTFail("Expected .cancelled after markCancelled, got: \(state.status)")
        }
    }

    // MARK: - MLX Snapshot Coordination

    func test_updateSnapshotProgress_aggregatesAcrossFiles() {
        let model = DownloadableModel(
            repoID: "mlx-community/Test-4bit",
            fileName: "Test-4bit",
            displayName: "Test 4bit",
            modelType: .mlx,
            sizeBytes: 1_000
        )
        let state = DownloadState(model: model)
        manager.activeDownloads[model.id] = state

        let stagingDirectory = tempDirectory.appendingPathComponent(".staging-progress", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        manager.prepareSnapshotDownload(model: model, files: makeSnapshotFiles(), stagingDirectory: stagingDirectory)

        manager.updateSnapshotProgress(
            modelID: model.id,
            relativePath: "config.json",
            bytesDownloaded: 100,
            totalBytesExpected: 100
        )
        manager.updateSnapshotProgress(
            modelID: model.id,
            relativePath: "weights/model.safetensors",
            bytesDownloaded: 450,
            totalBytesExpected: 900
        )

        guard case .downloading(let progress, let bytesDownloaded, let totalBytes) = state.status else {
            return XCTFail("Expected aggregate snapshot progress to be reflected in DownloadState")
        }
        XCTAssertEqual(bytesDownloaded, 550)
        XCTAssertEqual(totalBytes, 1_000)
        XCTAssertEqual(progress, 0.55, accuracy: 0.001)
    }

    func test_updateSnapshotProgress_aggregatesDiffusionPackageAsSingleDownload() {
        let model = DownloadableModel(
            repoID: "stabilityai/sdxl-test",
            fileName: "stabilityai__sdxl-test",
            displayName: "SDXL Test",
            modelType: .mlx,
            sizeBytes: 800,
            packageKind: .diffusion
        )
        let state = DownloadState(model: model)
        manager.activeDownloads[model.id] = state

        let stagingDirectory = tempDirectory.appendingPathComponent(".staging-diffusion-progress", isDirectory: true)
        try? FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        manager.prepareSnapshotDownload(model: model, files: makeDiffusionPackageFiles(), stagingDirectory: stagingDirectory)

        manager.updateSnapshotProgress(
            modelID: model.id,
            relativePath: "unet/diffusion_pytorch_model.safetensors",
            bytesDownloaded: 250,
            totalBytesExpected: 400
        )
        manager.updateSnapshotProgress(
            modelID: model.id,
            relativePath: "vae/diffusion_pytorch_model.safetensors",
            bytesDownloaded: 150,
            totalBytesExpected: 400
        )

        guard case .downloading(let progress, let bytesDownloaded, let totalBytes) = state.status else {
            return XCTFail("Expected diffusion package progress to be aggregated in one DownloadState")
        }
        XCTAssertEqual(bytesDownloaded, 400)
        XCTAssertEqual(totalBytes, 800)
        XCTAssertEqual(progress, 0.5, accuracy: 0.001)
    }

    func test_completeSnapshotFile_finalizesDirectoryAfterLastFile() throws {
        let model = DownloadableModel(
            repoID: "mlx-community/Test-4bit",
            fileName: "Test-4bit",
            displayName: "Test 4bit",
            modelType: .mlx,
            sizeBytes: 1_000
        )
        let state = DownloadState(model: model)
        manager.activeDownloads[model.id] = state

        let stagingDirectory = tempDirectory.appendingPathComponent(".staging-finalize", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        manager.prepareSnapshotDownload(model: model, files: makeSnapshotFiles(), stagingDirectory: stagingDirectory)

        let configTemp = tempDirectory.appendingPathComponent("config.download")
        try Data("{}".utf8).write(to: configTemp)
        try manager.completeSnapshotFile(
            modelID: model.id,
            relativePath: "config.json",
            tempURL: configTemp
        )

        if case .completed = state.status {
            return XCTFail("Snapshot should not complete until every file is present")
        }

        let weightsTemp = tempDirectory.appendingPathComponent("weights.download")
        try Data(repeating: 0xAB, count: 900).write(to: weightsTemp)
        try manager.completeSnapshotFile(
            modelID: model.id,
            relativePath: "weights/model.safetensors",
            tempURL: weightsTemp
        )

        let finalURL = tempDirectory.appendingPathComponent("Test-4bit", isDirectory: true)
        guard case .completed(let localURL) = state.status else {
            return XCTFail("Snapshot should complete after the last file is staged")
        }
        XCTAssertEqual(localURL.standardizedFileURL.path, finalURL.standardizedFileURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.appendingPathComponent("config.json").path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: finalURL.appendingPathComponent("weights/model.safetensors").path
            )
        )
    }

    func test_completeSnapshotFile_writesReadinessManifestForDiffusionPackage() throws {
        let model = DownloadableModel(
            repoID: "stabilityai/sdxl-test",
            fileName: "stabilityai__sdxl-test",
            displayName: "SDXL Test",
            modelType: .mlx,
            sizeBytes: 800,
            packageKind: .diffusion
        )
        let state = DownloadState(model: model)
        manager.activeDownloads[model.id] = state

        let stagingDirectory = tempDirectory.appendingPathComponent(".staging-diffusion-finalize", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let files = makeDiffusionPackageFiles()
        manager.prepareSnapshotDownload(model: model, files: files, stagingDirectory: stagingDirectory)

        for file in files {
            let tempURL = tempDirectory.appendingPathComponent(UUID().uuidString)
            try fixtureData(forDiffusionRelativePath: file.relativePath).write(to: tempURL)
            try manager.completeSnapshotFile(modelID: model.id, relativePath: file.relativePath, tempURL: tempURL)
        }

        let finalURL = tempDirectory.appendingPathComponent("stabilityai__sdxl-test", isDirectory: true)
        guard case .completed(let localURL) = state.status else {
            return XCTFail("Diffusion package should complete after every component is validated")
        }
        XCTAssertEqual(localURL.standardizedFileURL.path, finalURL.standardizedFileURL.path)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: finalURL.appendingPathComponent(DownloadedModelPackageManifest.fileName).path
            ),
            "Completed diffusion packages need a local readiness manifest for atomic discovery"
        )
    }

    // MARK: - Disk Space Edge Cases

    func test_diskSpaceCheck_exactlyAtLimit() async {
        // Get the actual free space on the system.
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        guard let freeSpace = attrs?[.systemFreeSize] as? UInt64 else {
            XCTFail("Could not read free disk space")
            return
        }

        // Request freeSpace - buffer - 100 MB. A 1-byte margin is too tight when
        // parallel tests are writing files and shrinking available space between
        // the time we read freeSpace here and checkDiskSpace reads it inside.
        let buffer: UInt64 = 500_000_000
        let margin: UInt64 = 100_000_000
        guard freeSpace > buffer + margin else {
            // System has less than the buffer; skip this test gracefully.
            return
        }
        let requestSize = freeSpace - buffer - margin

        do {
            try await manager.checkDiskSpace(requiredBytes: requestSize)
        } catch {
            XCTFail("Requesting just under free space minus buffer should pass, got: \(error)")
        }
    }

    func test_diskSpaceCheck_zeroRequired_passes() async {
        do {
            try await manager.checkDiskSpace(requiredBytes: 0)
        } catch {
            XCTFail("Requesting 0 bytes should always pass the disk space check, got: \(error)")
        }
    }

    // MARK: - MLX Directory Validation

    func test_validateMLXDirectory_valid() throws {
        // Create a valid MLX model directory structure.
        let mlxDir = tempDirectory.appendingPathComponent("valid-mlx-model")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)

        // Add config.json.
        let configData = Data("{\"model_type\": \"llama\"}".utf8)
        try configData.write(to: mlxDir.appendingPathComponent("config.json"))

        // Add a .safetensors file.
        let safetensorsData = Data(repeating: 0x00, count: 1024)
        try safetensorsData.write(to: mlxDir.appendingPathComponent("model.safetensors"))

        XCTAssertNoThrow(
            try manager.validateDownloadedFile(at: mlxDir, modelType: .mlx),
            "A directory with config.json and .safetensors should pass MLX validation"
        )
    }

    func test_validateMLXDirectory_missingConfig() throws {
        // Create an MLX directory without config.json.
        let mlxDir = tempDirectory.appendingPathComponent("no-config-mlx")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)

        // Only add a .safetensors file (no config.json).
        let safetensorsData = Data(repeating: 0x00, count: 1024)
        try safetensorsData.write(to: mlxDir.appendingPathComponent("model.safetensors"))

        XCTAssertThrowsError(
            try manager.validateDownloadedFile(at: mlxDir, modelType: .mlx)
        ) { error in
            guard case HuggingFaceError.invalidDownloadedFile(let reason) = error else {
                XCTFail("Expected invalidDownloadedFile error, got: \(error)")
                return
            }
            XCTAssertTrue(
                reason.contains("config.json"),
                "Error reason should mention missing config.json, got: \(reason)"
            )
        }
    }

    func test_validateMLXDirectory_missingSafetensors() throws {
        // Create an MLX directory with config.json but no .safetensors.
        let mlxDir = tempDirectory.appendingPathComponent("no-safetensors-mlx")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)

        // Only add config.json (no .safetensors).
        let configData = Data("{\"model_type\": \"llama\"}".utf8)
        try configData.write(to: mlxDir.appendingPathComponent("config.json"))

        XCTAssertThrowsError(
            try manager.validateDownloadedFile(at: mlxDir, modelType: .mlx)
        ) { error in
            guard case HuggingFaceError.invalidDownloadedFile(let reason) = error else {
                XCTFail("Expected invalidDownloadedFile error, got: \(error)")
                return
            }
            XCTAssertTrue(
                reason.contains(".safetensors"),
                "Error reason should mention missing .safetensors files, got: \(reason)"
            )
        }
    }

    func test_validateFoundationModel_throws() {
        let dummyURL = tempDirectory.appendingPathComponent("dummy")

        XCTAssertThrowsError(
            try manager.validateDownloadedFile(at: dummyURL, modelType: .foundation)
        ) { error in
            guard case HuggingFaceError.invalidDownloadedFile(let reason) = error else {
                XCTFail("Expected invalidDownloadedFile error, got: \(error)")
                return
            }
            XCTAssertTrue(
                reason.contains("Foundation") || reason.contains("cannot be downloaded"),
                "Error reason should mention foundation models cannot be downloaded, got: \(reason)"
            )
        }
    }

    // MARK: - File Name Validation at Boundary

    func test_startDownload_rejectsParentTraversalFileName() async {
        // Build the struct directly — the validator must run at startDownload,
        // not at DownloadableModel construction (existing init is non-throwing).
        let malicious = DownloadableModel(
            repoID: "attacker/repo",
            fileName: "../../etc/passwd",
            displayName: "Exploit",
            modelType: .gguf,
            sizeBytes: 1_024
        )
        let downloadURL = URL(string: "http://localhost/evil")!

        do {
            _ = try await manager.startDownload(malicious, downloadURL: downloadURL)
            XCTFail("startDownload must reject a filename containing \"..\"")
        } catch let error as FileNameError {
            XCTAssertEqual(error, .pathTraversal)
        } catch {
            XCTFail("Expected FileNameError.pathTraversal, got: \(error)")
        }

        XCTAssertNil(
            manager.activeDownloads[malicious.id],
            "Rejected download must not leak into activeDownloads"
        )
    }

    func test_startDownload_rejectsBackslashFileName() async {
        let malicious = DownloadableModel(
            repoID: "attacker/repo",
            fileName: "foo\\bar.gguf",
            displayName: "Exploit",
            modelType: .gguf,
            sizeBytes: 1_024
        )
        let downloadURL = URL(string: "http://localhost/evil")!

        do {
            _ = try await manager.startDownload(malicious, downloadURL: downloadURL)
            XCTFail("startDownload must reject a filename containing a backslash")
        } catch let error as FileNameError {
            XCTAssertEqual(error, .backslash)
        } catch {
            XCTFail("Expected FileNameError.backslash, got: \(error)")
        }
    }

    func test_startDownload_acceptsLegitimateMLXNamespacedName() async {
        // Curated MLX models use "<namespace>/<name>" — validator must still accept.
        // We don't actually complete the download here; we only assert that
        // validation did not raise and that the state row was created. A real
        // URLSession call would fail against `localhost` in unit tests, so we
        // inspect state directly.
        let legitimate = DownloadableModel(
            repoID: "mlx-community/Phi-4-mini-instruct-4bit",
            fileName: "mlx-community/Phi-4-mini-instruct-4bit",
            displayName: "Phi-4 Mini",
            modelType: .gguf, // use .gguf to avoid triggering snapshot staging side effects
            sizeBytes: 1_024
        )
        let downloadURL = URL(string: "http://localhost/legit")!

        do {
            _ = try await manager.startDownload(legitimate, downloadURL: downloadURL)
        } catch is FileNameError {
            return XCTFail("Legit namespace/name filename must not be rejected by the validator")
        } catch {
            // Other errors (network, disk) are acceptable — we only care that the
            // validator did not raise on a known-good input.
        }

        XCTAssertNotNil(
            manager.activeDownloads[legitimate.id],
            "Valid filename should reach activeDownloads tracking"
        )
    }
}
#endif
