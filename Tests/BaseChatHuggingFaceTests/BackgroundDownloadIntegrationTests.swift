@preconcurrency import XCTest
@testable import BaseChatInference
#if HuggingFace
@testable import BaseChatHuggingFace

/// Integration tests for BackgroundDownloadManager using real filesystem.
///
/// These tests exercise the actual persistence format (file-based JSON + binary resume files)
/// and file validation (filesystem) without mocking either subsystem. Tests that would
/// require creating a real background URLSession are avoided — they belong in
/// device-level E2E tests.
@MainActor
final class BackgroundDownloadIntegrationTests: XCTestCase {

    private var manager: BackgroundDownloadManager!
    private var tempDirectory: URL!

    // Unique per-test session identifier prevents OS-level URLSession collisions.
    //
    // URLSessionConfiguration.background sessions are keyed by identifier at the OS level.
    // When two BackgroundDownloadManager instances share the same identifier and one is being
    // torn down while the next test's manager is initialised, the OS can deliver delegate
    // callbacks to the already-deallocated instance — a double-free (SIGABRT). A UUID suffix
    // ensures each test gets a fresh, isolated session with no shared OS state.
    private var testSessionIdentifier: String!

    // Per-test persistence directory — a subdir of tempDirectory, unique per test run.
    // Passed to every BackgroundDownloadManager created in this suite so that parallel
    // runs never share pending-downloads.json or resume-data files.
    private var persistenceDir: URL!

    // Per-instance UserDefaults suite — prevents parallel test runs from racing on
    // the global `pendingDownloadsKey` in `UserDefaults.standard`.
    private var suiteName: String!
    private var testDefaults: UserDefaults!

    private var pendingMetadataURL: URL {
        persistenceDir.appendingPathComponent("pending-downloads.json")
    }

    override func setUp() async throws {
        try await super.setUp()
        testSessionIdentifier = "com.basechatkit.test.download.\(UUID().uuidString)"

        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackgroundDownloadIntegrationTests-\(UUID().uuidString)")
        persistenceDir = tempDirectory.appendingPathComponent("persistence")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        suiteName = "com.basechatkit.test.downloads.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!

        manager = BackgroundDownloadManager(
            sessionIdentifier: testSessionIdentifier,
            persistenceDirectory: persistenceDir,
            tempScanDirectory: tempDirectory,
            userDefaults: testDefaults
        )
    }

    override func tearDown() async throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        if let suiteName {
            testDefaults?.removePersistentDomain(forName: suiteName)
        }
        tempDirectory = nil
        persistenceDir = nil
        manager = nil
        testSessionIdentifier = nil
        testDefaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeModel(
        repoID: String = "test/repo",
        fileName: String = "model.gguf",
        displayName: String = "Test Model",
        modelType: ModelType = .gguf,
        sizeBytes: UInt64 = 1_000_000
    ) -> DownloadableModel {
        DownloadableModel(
            repoID: repoID,
            fileName: fileName,
            displayName: displayName,
            modelType: modelType,
            sizeBytes: sizeBytes
        )
    }

    /// Writes pending download data to the JSON metadata file using the same format
    /// BackgroundDownloadManager uses internally.
    private func writePendingDownload(_ model: DownloadableModel) throws {
        try FileManager.default.createDirectory(at: persistenceDir, withIntermediateDirectories: true)
        var pending: [String: [String: String]] = [:]
        if let existing = try? Data(contentsOf: pendingMetadataURL),
           let decoded = try? JSONDecoder().decode([String: [String: String]].self, from: existing) {
            pending = decoded
        }
        pending[model.id] = [
            "repoID": model.repoID,
            "fileName": model.fileName,
            "displayName": model.displayName,
            "modelType": model.modelType == .gguf ? "gguf" : "mlx",
        ]
        try JSONEncoder().encode(pending).write(to: pendingMetadataURL)
    }

    /// Reads pending downloads from the JSON metadata file.
    private func readPendingDownloads() -> [String: [String: String]]? {
        guard let data = try? Data(contentsOf: pendingMetadataURL) else { return nil }
        return try? JSONDecoder().decode([String: [String: String]].self, from: data)
    }

    // MARK: - Pending Download Persistence Format

    func test_pendingDownloadFormat_roundTrips() throws {
        let model = makeModel(repoID: "bartowski/Mistral-7B", fileName: "mistral-7b-q4.gguf", displayName: "Mistral 7B Q4")

        try writePendingDownload(model)

        let stored = readPendingDownloads()
        XCTAssertNotNil(stored, "Pending download should be stored in the JSON file")
        XCTAssertNotNil(stored?[model.id], "Should be keyed by model ID (\(model.id))")
        XCTAssertEqual(stored?[model.id]?["repoID"], "bartowski/Mistral-7B")
        XCTAssertEqual(stored?[model.id]?["fileName"], "mistral-7b-q4.gguf")
        XCTAssertEqual(stored?[model.id]?["displayName"], "Mistral 7B Q4")
        XCTAssertEqual(stored?[model.id]?["modelType"], "gguf")
    }

    func test_pendingDownloadFormat_MLXModel() throws {
        let model = makeModel(
            repoID: "mlx-community/Llama-3.2-3B",
            fileName: "llama-3.2-3b",
            displayName: "Llama 3.2 3B MLX",
            modelType: .mlx
        )

        try writePendingDownload(model)

        let stored = readPendingDownloads()
        XCTAssertNotNil(stored?[model.id])
        XCTAssertEqual(stored?[model.id]?["modelType"], "mlx")
    }

    func test_removePendingDownload_actuallyRemovesEntry() throws {
        let model1 = makeModel(repoID: "test/model1", fileName: "model1.gguf", displayName: "Model 1")
        let model2 = makeModel(repoID: "test/model2", fileName: "model2.gguf", displayName: "Model 2")

        try writePendingDownload(model1)
        try writePendingDownload(model2)

        var stored = readPendingDownloads()
        XCTAssertEqual(stored?.count, 2)

        // Remove one via the manager's internal method.
        manager.removePendingDownload(id: model1.id)

        let remaining = readPendingDownloads()
        XCTAssertEqual(remaining?.count, 1)
        XCTAssertNil(remaining?[model1.id])
        XCTAssertNotNil(remaining?[model2.id])

        // Clean up model2.
        stored?.removeValue(forKey: model2.id)
    }

    func test_pendingDownloadFormat_corruptEntry_missingFields() throws {
        // Verify format: the restore logic requires repoID, fileName, displayName, modelType.
        let pending: [String: [String: String]] = [
            "test/repo/valid.gguf": [
                "repoID": "test/repo",
                "fileName": "valid.gguf",
                "displayName": "Valid Model",
                "modelType": "gguf",
            ],
            "test/repo/invalid.gguf": [
                "repoID": "test/repo",
                // Missing fileName, displayName, modelType
            ],
        ]
        try FileManager.default.createDirectory(at: persistenceDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(pending).write(to: pendingMetadataURL)

        let stored = readPendingDownloads()
        XCTAssertNotNil(stored)

        let validEntry = stored?["test/repo/valid.gguf"]
        XCTAssertNotNil(validEntry?["repoID"])
        XCTAssertNotNil(validEntry?["fileName"])
        XCTAssertNotNil(validEntry?["displayName"])
        XCTAssertNotNil(validEntry?["modelType"])

        let invalidEntry = stored?["test/repo/invalid.gguf"]
        XCTAssertNil(invalidEntry?["fileName"])
    }

    // MARK: - hasActiveDownloads with Mixed States

    func test_hasActiveDownloads_withMixedStates() {
        let queuedModel = makeModel(repoID: "test/queued", fileName: "queued.gguf", displayName: "Queued")
        let completedModel = makeModel(repoID: "test/completed", fileName: "completed.gguf", displayName: "Completed")
        let failedModel = makeModel(repoID: "test/failed", fileName: "failed.gguf", displayName: "Failed")
        let cancelledModel = makeModel(repoID: "test/cancelled", fileName: "cancelled.gguf", displayName: "Cancelled")

        let queuedState = DownloadState(model: queuedModel)

        let completedState = DownloadState(model: completedModel)
        completedState.markCompleted(localURL: tempDirectory.appendingPathComponent("completed.gguf"))

        let failedState = DownloadState(model: failedModel)
        failedState.markFailed(error: "Network error")

        let cancelledState = DownloadState(model: cancelledModel)
        cancelledState.markCancelled()

        // Only terminal states — should be false.
        manager.activeDownloads[completedModel.id] = completedState
        manager.activeDownloads[failedModel.id] = failedState
        manager.activeDownloads[cancelledModel.id] = cancelledState
        XCTAssertFalse(manager.hasActiveDownloads)

        // Add queued — should become true.
        manager.activeDownloads[queuedModel.id] = queuedState
        XCTAssertTrue(manager.hasActiveDownloads)

        // Transition to downloading — still true.
        queuedState.updateProgress(bytesDownloaded: 500_000, totalBytes: 1_000_000)
        XCTAssertTrue(manager.hasActiveDownloads)

        // Complete — back to false.
        queuedState.markCompleted(localURL: tempDirectory.appendingPathComponent("queued.gguf"))
        XCTAssertFalse(manager.hasActiveDownloads)
    }

    // MARK: - GGUF File Validation

    func test_validateGGUFFile_validMagicAndSize_passes() throws {
        let fileURL = tempDirectory.appendingPathComponent("valid-model.gguf")
        var data = Data([0x47, 0x47, 0x55, 0x46])
        data.append(Data(repeating: 0xAA, count: 1_100_000))
        try data.write(to: fileURL)

        XCTAssertNoThrow(try manager.validateDownloadedFile(at: fileURL, modelType: .gguf))
    }

    func test_validateGGUFFile_wrongMagicBytes_fails() throws {
        let fileURL = tempDirectory.appendingPathComponent("wrong-magic.gguf")
        var data = Data([0x50, 0x4B, 0x03, 0x04])
        data.append(Data(repeating: 0x00, count: 1_100_000))
        try data.write(to: fileURL)

        XCTAssertThrowsError(try manager.validateDownloadedFile(at: fileURL, modelType: .gguf))
    }

    func test_validateGGUFFile_tinySize_fails() throws {
        let fileURL = tempDirectory.appendingPathComponent("tiny.gguf")
        var data = Data([0x47, 0x47, 0x55, 0x46])
        data.append(Data(repeating: 0x00, count: 100))
        try data.write(to: fileURL)

        XCTAssertThrowsError(try manager.validateDownloadedFile(at: fileURL, modelType: .gguf))
    }

    // MARK: - MLX Directory Validation

    func test_validateMLXDirectory_withConfigJson_passes() throws {
        let mlxDir = tempDirectory.appendingPathComponent("valid-mlx")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)
        try Data("{\"model_type\": \"llama\"}".utf8).write(to: mlxDir.appendingPathComponent("config.json"))
        try Data(repeating: 0x00, count: 1024).write(to: mlxDir.appendingPathComponent("model.safetensors"))

        XCTAssertNoThrow(try manager.validateDownloadedFile(at: mlxDir, modelType: .mlx))
    }

    func test_validateMLXDirectory_withoutConfigJson_fails() throws {
        let mlxDir = tempDirectory.appendingPathComponent("no-config-mlx")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)
        try Data(repeating: 0x00, count: 1024).write(to: mlxDir.appendingPathComponent("model.safetensors"))

        XCTAssertThrowsError(try manager.validateDownloadedFile(at: mlxDir, modelType: .mlx))
    }

    // MARK: - startDownload State Management

    func test_startDownload_addsToActiveDownloads() async throws {
        let model = makeModel(
            repoID: "test/start-download",
            fileName: "start-download.gguf",
            displayName: "Start Download Test"
        )
        let downloadURL = URL(string: "http://localhost/test.gguf")!

        // The download will fail immediately (no server), but activeDownloads is
        // populated synchronously before task.resume(), so it should be present.
        _ = try await manager.startDownload(model, downloadURL: downloadURL)

        XCTAssertNotNil(
            manager.activeDownloads[model.id],
            "startDownload should add the model to activeDownloads"
        )

        let state = manager.activeDownloads[model.id]
        if let status = state?.status {
            switch status {
            case .queued, .downloading:
                break  // Expected initial states.
            case .completed, .failed, .cancelled:
                // A fast failure is acceptable — the state was set and then transitioned.
                break
            }
        } else {
            XCTFail("activeDownloads[\(model.id)] should not be nil after startDownload")
        }

        // Clean up.
        try? FileManager.default.removeItem(at: pendingMetadataURL)
    }

    func test_startDownload_duplicateModel_doesNotAddTwice() async throws {
        let model = makeModel(
            repoID: "test/duplicate",
            fileName: "duplicate.gguf",
            displayName: "Duplicate Test"
        )
        let downloadURL = URL(string: "http://localhost/duplicate.gguf")!

        _ = try await manager.startDownload(model, downloadURL: downloadURL)
        let countAfterFirst = manager.activeDownloads.count

        // Starting the same model a second time should not add a second entry.
        // The manager overwrites the existing entry (same key), so count stays the same.
        _ = try await manager.startDownload(model, downloadURL: downloadURL)

        XCTAssertEqual(
            manager.activeDownloads.count,
            countAfterFirst,
            "Starting the same model twice should not create duplicate activeDownloads entries"
        )

        // Clean up.
        try? FileManager.default.removeItem(at: pendingMetadataURL)
    }

    func test_cancelDownload_removesFromActive() async throws {
        let model = makeModel(
            repoID: "test/cancel",
            fileName: "cancel.gguf",
            displayName: "Cancel Test"
        )
        let downloadURL = URL(string: "http://localhost/cancel.gguf")!

        _ = try await manager.startDownload(model, downloadURL: downloadURL)

        XCTAssertNotNil(
            manager.activeDownloads[model.id],
            "Model should be in activeDownloads after startDownload"
        )

        manager.cancelDownload(id: model.id)

        // cancelDownload goes through getAllTasks (async callback) then Task { @MainActor in },
        // so poll until the pending entry is removed, with a 2-second timeout.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            let pending = readPendingDownloads()
            if pending?[model.id] == nil { break }
            await Task.yield()
        }

        let pending = readPendingDownloads()
        XCTAssertNil(
            pending?[model.id],
            "cancelDownload should remove the entry from the pending-downloads JSON file"
        )

        // Clean up any remaining file.
        try? FileManager.default.removeItem(at: pendingMetadataURL)
    }

    // MARK: - Session Reconnection / Pending Download Persistence

    func test_reconnectBackgroundSession_restoresPendingDownloads() throws {
        let model = makeModel(
            repoID: "test/reconnect",
            fileName: "reconnect.gguf",
            displayName: "Reconnect Test"
        )

        // Write pending download data using the same format as the real code.
        try writePendingDownload(model)

        // A fresh manager starts with no active downloads.
        // Use a unique session identifier to avoid OS-level URLSession collisions with setUp's manager.
        // Share the per-test UserDefaults suite so the second manager doesn't escape the isolation.
        let freshManager = BackgroundDownloadManager(
            sessionIdentifier: "com.basechatkit.test.download.\(UUID().uuidString)",
            persistenceDirectory: persistenceDir,
            tempScanDirectory: tempDirectory,
            userDefaults: testDefaults
        )
        XCTAssertNil(freshManager.activeDownloads[model.id], "No active downloads before reconnect")

        // reconnectBackgroundSession calls restorePendingDownloads internally.
        freshManager.reconnectBackgroundSession()

        XCTAssertNotNil(
            freshManager.activeDownloads[model.id],
            "reconnectBackgroundSession should restore pending downloads into activeDownloads"
        )
    }

    func test_reconnectBackgroundSession_restoresPendingMLXSnapshotMetadata() throws {
        // Use a unique session identifier to avoid OS-level URLSession collisions with setUp's manager.
        // Share the per-test UserDefaults suite so the second manager doesn't escape the isolation.
        let manager = BackgroundDownloadManager(
            storageService: ModelStorageService(baseDirectory: tempDirectory),
            sessionIdentifier: "com.basechatkit.test.download.\(UUID().uuidString)",
            persistenceDirectory: persistenceDir,
            tempScanDirectory: tempDirectory,
            userDefaults: testDefaults
        )
        let model = makeModel(
            repoID: "mlx-community/Test-4bit",
            fileName: "Test-4bit",
            displayName: "Test 4bit",
            modelType: .mlx,
            sizeBytes: 1_000
        )

        // Write the pending JSON in the format the real code produces.
        try FileManager.default.createDirectory(at: persistenceDir, withIntermediateDirectories: true)
        let snapshotFilesJSON = "[{\"relativePath\":\"config.json\",\"sizeBytes\":100},{\"relativePath\":\"weights/model.safetensors\",\"sizeBytes\":900}]"
        let pending: [String: [String: String]] = [
            model.id: [
                "repoID": model.repoID,
                "fileName": model.fileName,
                "displayName": model.displayName,
                "modelType": "mlx",
                "sizeBytes": "1000",
                "stagingDirectoryName": ".staging-test-mlx",
                "snapshotFiles": snapshotFilesJSON,
            ]
        ]
        try JSONEncoder().encode(pending).write(to: pendingMetadataURL)

        manager.reconnectBackgroundSession()

        let restored = try XCTUnwrap(manager.activeDownloads[model.id])
        XCTAssertEqual(restored.model.modelType, .mlx)
        XCTAssertEqual(restored.model.sizeBytes, 1_000)

        let configTemp = tempDirectory.appendingPathComponent("config.restore")
        try Data("{}".utf8).write(to: configTemp)
        try manager.completeSnapshotFile(
            modelID: model.id,
            relativePath: "config.json",
            tempURL: configTemp
        )

        let weightsTemp = tempDirectory.appendingPathComponent("weights.restore")
        try Data(repeating: 0xAB, count: 900).write(to: weightsTemp)
        try manager.completeSnapshotFile(
            modelID: model.id,
            relativePath: "weights/model.safetensors",
            tempURL: weightsTemp
        )

        guard case .completed(let localURL) = restored.status else {
            return XCTFail("Restored MLX snapshot should still be completable after reconnect")
        }
        XCTAssertEqual(
            localURL.standardizedFileURL.path,
            tempDirectory.appendingPathComponent("Test-4bit").standardizedFileURL.path
        )
    }

    func test_pendingDownload_removedOnCancellation() async throws {
        let model = makeModel(
            repoID: "test/pending-removal",
            fileName: "pending-removal.gguf",
            displayName: "Pending Removal Test"
        )
        let downloadURL = URL(string: "http://localhost/pending-removal.gguf")!

        // Start a download — this writes to the pending-downloads JSON file.
        _ = try await manager.startDownload(model, downloadURL: downloadURL)

        let pendingAfterStart = readPendingDownloads()
        XCTAssertNotNil(
            pendingAfterStart?[model.id],
            "startDownload should write the model to the pending-downloads JSON file"
        )

        // Cancel it — this should remove from the pending-downloads file.
        manager.cancelDownload(id: model.id)

        // cancelDownload routes through getAllTasks (async callback) then a Task { @MainActor in },
        // so two yields are not enough. Poll until the entry disappears, with a timeout.
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if readPendingDownloads()?[model.id] == nil { break }
            await Task.yield()
        }

        XCTAssertNil(
            readPendingDownloads()?[model.id],
            "cancelDownload should remove the model from the pending-downloads JSON file"
        )

        // Clean up any remaining file.
        try? FileManager.default.removeItem(at: pendingMetadataURL)
    }

    // MARK: - Validation (named variants)

    func test_validateDownloadedFile_gguf_validFile_passes() throws {
        // Write a temp file with valid GGUF magic bytes and realistic size (>1 MB).
        let fileURL = tempDirectory.appendingPathComponent("named-valid.gguf")
        var data = Data([0x47, 0x47, 0x55, 0x46])  // "GGUF" magic
        data.append(Data(repeating: 0xBB, count: 1_100_000))
        try data.write(to: fileURL)

        XCTAssertNoThrow(
            try manager.validateDownloadedFile(at: fileURL, modelType: .gguf),
            "A file with valid GGUF magic bytes and size >1 MB should pass validation"
        )
    }

    func test_validateDownloadedFile_mlx_validDirectory_passes() throws {
        // Create a temp directory with the required MLX structure.
        let mlxDir = tempDirectory.appendingPathComponent("named-valid-mlx")
        try FileManager.default.createDirectory(at: mlxDir, withIntermediateDirectories: true)
        try Data("{\"model_type\": \"llama\"}".utf8).write(to: mlxDir.appendingPathComponent("config.json"))
        try Data(repeating: 0x00, count: 1024).write(to: mlxDir.appendingPathComponent("weights.safetensors"))

        XCTAssertNoThrow(
            try manager.validateDownloadedFile(at: mlxDir, modelType: .mlx),
            "A directory with config.json and a .safetensors file should pass MLX validation"
        )
    }

    // MARK: - No UserDefaults contamination

    /// startDownload must not write anything to UserDefaults under the pending downloads key.
    ///
    /// Asserts against the per-suite `testDefaults` (the instance injected into the SUT)
    /// rather than `UserDefaults.standard` — bare `.standard` reads race across parallel
    /// XCTest worker processes (issue #910). The SUT writes through the injected defaults,
    /// so this is the honest contract surface for the assertion.
    func test_startDownload_doesNotWriteToUserDefaults() async throws {
        let model = makeModel(
            repoID: "test/no-defaults",
            fileName: "no-defaults.gguf",
            displayName: "No Defaults Test"
        )
        let legacyKey = BaseChatConfiguration.shared.pendingDownloadsKey
        let beforeValue = testDefaults.dictionary(forKey: legacyKey)

        _ = try await manager.startDownload(model, downloadURL: URL(string: "http://localhost/x.gguf")!)

        let afterValue = testDefaults.dictionary(forKey: legacyKey)
        XCTAssertEqual(
            NSDictionary(dictionary: beforeValue ?? [:]),
            NSDictionary(dictionary: afterValue ?? [:]),
            "startDownload must not modify the legacy UserDefaults pending-downloads key"
        )

        // Clean up.
        try? FileManager.default.removeItem(at: pendingMetadataURL)
    }
}
#endif
