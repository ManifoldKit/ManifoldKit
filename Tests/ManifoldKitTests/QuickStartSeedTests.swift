// QuickStartSeedTests.swift
//
// Exercises the opt-in seed-model path: `quickStart(seed:)` and
// `_performSeedDownload`. Uses `MockDownloadManager` and isolated scratch
// `ModelStorageService` instances (no real network activity, no touching
// ~/Documents/Models or the on-disk Application Support store).
//
// NOTE: ModelStorageService has a package-visible init that accepts
// `includeUserDocumentsFallback: false` so tests don't pick up ambient GGUFs
// the developer has in ~/Documents/Models. Always use that init here.

import XCTest
import Foundation
@testable import ManifoldKit
import ManifoldInference
import ManifoldTestSupport

@MainActor
final class QuickStartSeedTests: XCTestCase {

    // MARK: - Helpers

    /// Creates an isolated temp directory for each test and removes it on teardown.
    private var tempDir: URL = URL(fileURLWithPath: "/tmp")

    override func setUpWithError() throws {
        try super.setUpWithError()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("seedTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    /// Returns a storage service scoped to `tempDir` with no fallback scanning.
    private var isolatedStorage: ModelStorageService {
        ModelStorageService(
            baseDirectory: tempDir,
            includeUserDocumentsFallback: false
        )
    }

    /// Plants a minimal valid GGUF file in `tempDir` so `discoverModels()` is non-empty.
    private func plantFakeGGUF(name: String = "existing.gguf") throws -> URL {
        let dest = tempDir.appendingPathComponent(name)
        // GGUF magic bytes + padding — satisfies the file-size check.
        var data = Data([0x47, 0x47, 0x55, 0x46]) // "GGUF"
        data.append(Data(count: 256))
        try data.write(to: dest)
        return dest
    }

    // MARK: - QuickStartSeed construction

    func test_recommendedSmallModel_hasExpectedFields() {
        let seed = QuickStartSeed.recommendedSmallModel()
        XCTAssertEqual(seed.repoID, "bartowski/Qwen_Qwen3-0.6B-GGUF")
        XCTAssertEqual(seed.fileName, "Qwen_Qwen3-0.6B-Q4_K_M.gguf")
        XCTAssertEqual(seed.modelType, .gguf)
        XCTAssertGreaterThan(seed.sizeBytes, 0)
        XCTAssertNil(seed.onProgress)
    }

    func test_recommendedSmallModel_withProgress_storesCallback() {
        var received: Double? = nil
        let seed = QuickStartSeed.recommendedSmallModel { p in received = p }
        XCTAssertNotNil(seed.onProgress,
            "onProgress should be stored when a closure is supplied")
        // Fire it directly to verify the reference is live.
        seed.onProgress?(0.5)
        XCTAssertEqual(received, 0.5, "onProgress closure must forward the value")
    }

    // MARK: - _performSeedDownload: skip when models present

    /// When the storage service already has models, `_performSeedDownload`
    /// returns `false` without calling `startDownload`.
    func test_performSeedDownload_skipsSeed_whenModelsAlreadyOnDisk() async throws {
        // Plant a fake GGUF.
        _ = try plantFakeGGUF()

        let storageService = isolatedStorage
        let manager = MockDownloadManager()
        let seed = QuickStartSeed.recommendedSmallModel()

        // Precondition: discoverModels is non-empty.
        XCTAssertFalse(storageService.discoverModels().isEmpty,
            "Precondition: a model file must be on disk for this test")

        let result = await _performSeedDownload(
            seed: seed,
            storageService: storageService,
            downloadManager: manager
        )

        XCTAssertFalse(result, "Should skip (return false) when a model is already on disk")
        XCTAssertTrue(manager.startedModels.isEmpty,
            "startDownload must NOT be called when a model is already on disk")
    }

    // MARK: - _performSeedDownload: download start failure

    /// When `startDownload` throws, `_performSeedDownload` returns `false`
    /// without crashing — the app must launch regardless of a network failure.
    func test_performSeedDownload_returnsFalse_onDownloadStartFailure() async throws {
        let manager = MockDownloadManager()
        struct NetworkError: Error {}
        manager.startDownloadError = NetworkError()

        let seed = QuickStartSeed.recommendedSmallModel()
        let result = await _performSeedDownload(
            seed: seed,
            storageService: isolatedStorage,
            downloadManager: manager
        )

        XCTAssertFalse(result, "A download start failure must not propagate — return false silently")
    }

    // MARK: - _performSeedDownload: terminal states from MockDownloadManager

    /// Helpers that pre-populate the mock with a terminal state before the call,
    /// so the poll loop exits immediately. MockDownloadManager.startDownload
    /// returns the pre-seeded state from activeDownloads when it exists.
    private func makeModel(for seed: QuickStartSeed) -> DownloadableModel {
        DownloadableModel(
            repoID: seed.repoID,
            fileName: seed.fileName,
            displayName: seed.displayName,
            modelType: seed.modelType,
            sizeBytes: seed.sizeBytes
        )
    }

    func test_performSeedDownload_returnsTrue_onCompletedDownload() async throws {
        let seed = QuickStartSeed.recommendedSmallModel()
        let manager = MockDownloadManager()

        let model = makeModel(for: seed)
        let completedState = DownloadState(model: model)
        completedState.markCompleted(localURL: tempDir.appendingPathComponent(seed.fileName))
        // Pre-seed so startDownload returns this already-completed state.
        manager.activeDownloads[model.id] = completedState

        let result = await _performSeedDownload(
            seed: seed,
            storageService: isolatedStorage,
            downloadManager: manager
        )

        XCTAssertTrue(result, "Should return true when download completes")
    }

    func test_performSeedDownload_returnsFalse_onDownloadFailedState() async throws {
        let seed = QuickStartSeed.recommendedSmallModel()
        let manager = MockDownloadManager()

        let model = makeModel(for: seed)
        let failedState = DownloadState(model: model)
        failedState.markFailed(error: "Simulated failure")
        manager.activeDownloads[model.id] = failedState

        let result = await _performSeedDownload(
            seed: seed,
            storageService: isolatedStorage,
            downloadManager: manager
        )

        XCTAssertFalse(result, "A failed download state must return false silently")
    }

    func test_performSeedDownload_returnsFalse_onCancelledState() async throws {
        let seed = QuickStartSeed.recommendedSmallModel()
        let manager = MockDownloadManager()

        let model = makeModel(for: seed)
        let cancelledState = DownloadState(model: model)
        cancelledState.markCancelled()
        manager.activeDownloads[model.id] = cancelledState

        let result = await _performSeedDownload(
            seed: seed,
            storageService: isolatedStorage,
            downloadManager: manager
        )

        XCTAssertFalse(result, "A cancelled download must return false")
    }

    // MARK: - _performSeedDownload: progress callback

    /// Progress closure must be called with values in [0, 1] while the download
    /// is in `.downloading` state.
    func test_performSeedDownload_firesProgressCallback_duringDownload() async throws {
        let seed = QuickStartSeed.recommendedSmallModel()
        let manager = MockDownloadManager()

        var progressValues: [Double] = []
        let seedWithProgress = QuickStartSeed.recommendedSmallModel { p in
            progressValues.append(p)
        }

        let model = makeModel(for: seed)
        // Start in downloading state.
        let progressState = DownloadState(model: model)
        progressState.updateProgress(bytesDownloaded: 100_000, totalBytes: 484_220_320)
        manager.activeDownloads[model.id] = progressState

        // Flip to completed after a short delay on the main actor so the poll
        // loop observes the downloading state first.
        Task { @MainActor in
            // Yield twice to give the poll loop a chance to see .downloading
            // before we flip to .completed.
            await Task.yield()
            await Task.yield()
            progressState.markCompleted(localURL: self.tempDir.appendingPathComponent(seed.fileName))
        }

        let result = await _performSeedDownload(
            seed: seedWithProgress,
            storageService: isolatedStorage,
            downloadManager: manager
        )

        XCTAssertTrue(result, "Progress test: download should complete successfully")
        // At least one progress value must have been received.
        XCTAssertFalse(progressValues.isEmpty,
            "Progress callback must fire at least once during a downloading state")
        for value in progressValues {
            XCTAssertGreaterThanOrEqual(value, 0.0)
            XCTAssertLessThanOrEqual(value, 1.0)
        }
    }

    // MARK: - quickStart(seed:) integration

    /// When `quickStart(seed:)` is called with a seed and a mock download
    /// manager that immediately completes, the selection policy must find the
    /// downloaded model.
    func test_quickStartWithSeed_selectsModelAfterSuccessfulDownload() async throws {
        let seed = QuickStartSeed.recommendedSmallModel()

        // Plant a GGUF so the policy's discoverModels() finds it.
        let fakeModel = try plantFakeGGUF(name: seed.fileName)

        // MockDownloadManager configured to return a completed state.
        let manager = MockDownloadManager()
        let model = makeModel(for: seed)
        let completedState = DownloadState(model: model)
        completedState.markCompleted(localURL: fakeModel)
        manager.activeDownloads[model.id] = completedState

        // tempDir reference for capturing in closure (self is @MainActor,
        // closure needs @Sendable — capture value not self).
        let capturedTempDir = tempDir

        let result = try await ManifoldKit._quickStart(
            configuration: .default,
            // The seed gate is runtime-registration-based (#1749): inject a
            // GGUF-capable registrar so the download path is reachable under
            // --disable-default-traits builds too.
            backends: [MockGGUFBackends.self],
            seed: seed,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() },
            downloadManagerOverride: manager,
            selectionPolicy: { registry in
                // Scan our isolated temp dir rather than the real app-support dir.
                let svc = ModelStorageService(
                    baseDirectory: capturedTempDir,
                    includeUserDocumentsFallback: false
                )
                // Suppress Foundation availability so this test is
                // deterministic regardless of the test-runner OS.
                registry.foundationModelProvider = { false }
                let found = svc.discoverModels()
                registry.availableModels = found
                return found.first
            }
        )

        XCTAssertNotNil(
            result.viewModel.modelRegistry.selectedModel,
            "After seed download completes, the selection policy must pick up the model"
        )
        XCTAssertEqual(
            result.viewModel.modelRegistry.selectedModel?.fileName,
            seed.fileName,
            "Selected model's fileName must match the seeded model"
        )
    }

    /// When `quickStart(seed:)` is called and `startDownload` throws (network
    /// failure), the call must still succeed — the app launches in empty state.
    func test_quickStartWithSeed_succeedsEvenWhenDownloadFails() async throws {
        let seed = QuickStartSeed.recommendedSmallModel()

        struct SimulatedNetworkFailure: Error {}
        let manager = MockDownloadManager()
        manager.startDownloadError = SimulatedNetworkFailure()

        // Must not throw — network failure during seed is non-fatal.
        // We use a nil-returning policy so that "no model selected" is
        // deterministic regardless of the test-runner OS (macOS 26 hosts have
        // a Foundation model that would otherwise win the selection race).
        let result = try await ManifoldKit._quickStart(
            configuration: .default,
            // See above: keep the download path reachable in trait-less builds.
            backends: [MockGGUFBackends.self],
            seed: seed,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() },
            downloadManagerOverride: manager,
            selectionPolicy: { _ in nil }
        )

        // Chat surface is usable (session active) even without a model.
        XCTAssertNotNil(
            result.viewModel.activeSession,
            "quickStart must produce an active session even when seeding fails"
        )
        // No model is selected — expected when the download fails.
        XCTAssertNil(
            result.viewModel.modelRegistry.selectedModel,
            "When seed download fails, selectedModel must remain nil (no crash)"
        )
    }

    /// Passing `seed: nil` behaves identically to calling `quickStart(configuration:)`
    /// — no download is attempted.
    func test_quickStartWithNilSeed_doesNotAttemptDownload() async throws {
        let manager = MockDownloadManager()

        _ = try await ManifoldKit._quickStart(
            configuration: .default,
            seed: nil,
            makeModelContainer: { try ModelContainerFactory.makeInMemoryContainer() },
            downloadManagerOverride: manager
        )

        XCTAssertTrue(
            manager.startedModels.isEmpty,
            "When seed is nil, startDownload must never be called"
        )
    }

    // MARK: - SeedModelError
    //
    // The type is gone. It had a single case, unreachable since v0.48, that
    // nothing ever threw — see docs/MIGRATION-deprecation-shims-deleted.md.
    // Its test was removed in v0.48; there is nothing left to construct.
}
