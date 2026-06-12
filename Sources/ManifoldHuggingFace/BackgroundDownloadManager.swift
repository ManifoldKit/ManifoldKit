import ManifoldInference
import Foundation
import os

/// Manages background downloads of model files using `URLSession` background transfers.
///
/// Handles disk space checks, download progress tracking, file validation (GGUF magic
/// bytes), and moving completed files into the models directory. Designed to survive
/// app suspension on iOS — `URLSessionConfiguration.background` ensures the system
/// continues downloads even when the app is not in the foreground.
///
/// This class is `@Observable` so the UI can bind to `activeDownloads` for live progress.
/// Because `URLSessionDownloadDelegate` callbacks arrive on the session's delegate queue
/// (not the main thread), state mutations are dispatched to `@MainActor`.
@Observable
@MainActor
public final class BackgroundDownloadManager: NSObject, @unchecked Sendable, BackgroundDownloadManaging {

    // MARK: - Constants

    /// The background URL session identifier (derived from ManifoldConfiguration).
    nonisolated public static var sessionIdentifier: String {
        ManifoldConfiguration.shared.downloadSessionIdentifier
    }

    /// Minimum free disk space buffer beyond the model size (500 MB).
    nonisolated private static let diskSpaceBuffer: UInt64 = 500_000_000

    /// Prefix applied to every temp file the manager creates in the process temp directory.
    ///
    /// Gives the launch-time sweep a safe fingerprint: only files the manager itself
    /// would have written are considered for removal, so cleanup cannot touch
    /// unrelated temp files produced by other subsystems.
    nonisolated internal static let tempFilePrefix = "manifoldkit-dl-"

    /// File extension used for temp files that hold the payload of an in-progress download.
    nonisolated internal static let tempFileExtension = "download"

    /// Minimum age at which an orphaned temp file becomes eligible for cleanup.
    ///
    /// 24 hours is short enough to reclaim leaked files promptly after a crash
    /// yet long enough that a background download suspended mid-transfer is not
    /// deleted out from under itself. The launch sweep skips files newer than
    /// this regardless of in-flight tracking, giving two independent layers of
    /// protection against deleting an active download.
    nonisolated internal static let staleTempFileAge: TimeInterval = 24 * 60 * 60

    // MARK: - Observable State

    /// Active and recently completed downloads, keyed by `DownloadableModel.id`.
    ///
    /// Setter is `internal` (not `private`) so tests can inject state via `@testable import`.
    public internal(set) var activeDownloads: [String: DownloadState] = [:]

    /// Whether any download is currently queued or actively transferring data.
    ///
    /// Returns `true` if at least one entry in ``activeDownloads`` has a status of
    /// `.queued` or `.downloading`. Completed, failed, and cancelled downloads are
    /// not counted.
    public var hasActiveDownloads: Bool {
        progressReporter.hasActiveDownloads(activeDownloads)
    }

    // MARK: - Private State

    /// Paths of temp files actively being processed by the download delegate.
    ///
    /// Registered immediately after `didFinishDownloadingTo` moves URLSession's
    /// ephemeral file to our named temp location, and unregistered once the file
    /// has been moved to its final destination (or deleted on failure).  The
    /// launch-time sweep reads this set and skips any path it finds here,
    /// preventing a concurrent cleanup from deleting a file that is mid-flight
    /// in the same process.
    private var activeTempPaths: Set<URL> = []

    // internal: required by BackgroundDownloadManager+URLSessionDelegate.swift
    internal typealias TaskContext = DownloadStateMachine.TaskContext

    @ObservationIgnored
    private var downloadStateMachine = DownloadStateMachine()

    /// Promoted to `internal` (from `private`) so `BackgroundDownloadManager+URLSessionDelegate.swift`
    /// can read `storageService.modelsDirectory` when moving completed downloads.
    internal let storageService: ModelStorageService

    /// Per-instance background session identifier.
    ///
    /// Stored rather than re-derived from `Self.sessionIdentifier` each time so that
    /// tests can inject a unique identifier per test run. Reusing the same identifier
    /// across two concurrent `BackgroundDownloadManager` instances causes the OS to
    /// deliver delegate callbacks to a deallocated object — a double-free crash.
    @ObservationIgnored
    private let _sessionIdentifier: String

    @ObservationIgnored
    private var _sessionCoordinator: BackgroundURLSessionCoordinator?

    private var sessionCoordinator: BackgroundURLSessionCoordinator {
        if let existing = _sessionCoordinator { return existing }
        let coordinator = BackgroundURLSessionCoordinator(
            sessionIdentifier: _sessionIdentifier,
            downloadDelegate: self
        )
        _sessionCoordinator = coordinator
        return coordinator
    }

    // MARK: - Persistence / Cleanup Collaborators

    @ObservationIgnored
    private let pendingStore: PendingDownloadStore

    @ObservationIgnored
    private let tempScanDirectory: URL

    @ObservationIgnored
    private let progressReporter: DownloadProgressReporter

    // MARK: - Init

    public init(
        storageService: ModelStorageService = ModelStorageService(),
        sessionIdentifier: String? = nil,
        persistenceDirectory: URL? = nil,
        tempScanDirectory: URL? = nil,
        userDefaults: UserDefaults = .standard,
        activityCenter: NetworkActivityCenter = .shared
    ) {
        self.storageService = storageService
        self._sessionIdentifier = sessionIdentifier ?? Self.sessionIdentifier
        self.progressReporter = DownloadProgressReporter(activityCenter: activityCenter)
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let resolvedPersistenceDirectory = persistenceDirectory
            ?? caches.appendingPathComponent(
                "\(ManifoldConfiguration.shared.bundleIdentifier).downloads",
                isDirectory: true
            )
        self.pendingStore = PendingDownloadStore(
            persistenceDirectory: resolvedPersistenceDirectory,
            userDefaults: userDefaults
        )
        self.tempScanDirectory = tempScanDirectory ?? FileManager.default.temporaryDirectory
        super.init()
    }

    deinit {
        _sessionCoordinator?.invalidateAndCancel()
    }

    // MARK: - Public API

    /// Starts a background download for the given model.
    ///
    /// - Parameters:
    ///   - model: The model to download.
    ///   - downloadURL: The direct URL to download the file from.
    /// - Returns: The `DownloadState` that the UI should observe for progress.
    /// - Throws: `HuggingFaceError.insufficientDiskSpace` if there isn't enough room.
    @MainActor @discardableResult
    public func startDownload(_ model: DownloadableModel, downloadURL: URL) async throws -> DownloadState {
        // Promote `DownloadableModel.expectedSHA256` into the plan so the
        // post-download validator can enforce the digest. Callers that have
        // already resolved a richer `ModelDownloadPlan` (e.g. snapshot files
        // with per-file checksums) should use the plan-based overload instead.
        let checksum = model.expectedSHA256.map {
            ModelFileChecksum(algorithm: .sha256, hexDigest: $0)
        }
        return try await startDownload(model, plan: .singleFile(url: downloadURL, expectedChecksum: checksum))
    }

    /// Starts a background download using a resolved download plan.
    @MainActor @discardableResult
    public func startDownload(_ model: DownloadableModel, plan: ModelDownloadPlan) async throws -> DownloadState {
        // Layered defence: the URL-standardized prefix check below already blocks
        // path-traversal writes, but validating the filename at the boundary
        // catches malformed input before any disk operation runs.
        if model.packageKind == .diffusion {
            try DiffusionPackageValidator.validatePackageName(model.fileName)
        } else {
            try DownloadableModel.validate(fileName: model.fileName)
        }
        try await checkDiskSpace(requiredBytes: model.sizeBytes)
        try storageService.ensureModelsDirectory()

        let state = DownloadState(model: model)
        activeDownloads[model.id] = state
        beginActivityIfNeeded(modelID: model.id)

        switch plan {
        case .singleFile(let url, let expectedChecksum):
            Log.download.info("Starting single-file download for \(model.displayName) from \(url)")
            try startSingleFileDownload(model: model, url: url, expectedChecksum: expectedChecksum)
        case .snapshot(let files):
            Log.download.info("Starting snapshot download for \(model.displayName) with \(files.count) files")
            try startSnapshotDownload(model: model, files: files)
        }

        return state
    }

    /// Retries a failed download, resuming from where it left off when possible.
    ///
    /// If resume data was persisted when the previous attempt failed, the download
    /// restarts from the byte offset that was already transferred. When the server
    /// rejects stale resume data the method transparently falls back to a fresh
    /// download from the original URL.
    ///
    /// - Parameter id: The `DownloadableModel.id` of the failed download to retry.
    @MainActor public func retryDownload(id: String) async {
        // Retrieve the persisted model metadata needed to restart the download.
        guard let pending = loadPendingMetadata(),
              let info = pending[id],
              let repoID = info["repoID"],
              let fileName = info["fileName"],
              let displayName = info["displayName"],
              let typeStr = info["modelType"] else {
            // Fall back to the existing failed state's model when metadata is absent.
            // This should be rare — pending metadata is now kept alive until a successful
            // retry or explicit removal. The guard covers true edge cases (e.g. corrupt
            // pending metadata file, or the model was deleted between failure and retry tap).
            guard let existingState = activeDownloads[id] else {
                Log.download.error("retryDownload called for unknown download ID: \(id)")
                return
            }
            let model = existingState.model
            // Reset state so the UI transitions away from .failed immediately.
            activeDownloads[model.id] = DownloadState(model: model)
            // Consume any stale resume data so it doesn't accumulate on disk.
            _ = consumeResumeData(for: id)
            await retryWithFreshDownload(model: model)
            return
        }

        // Reject retries with a corrupted persisted filename — the metadata file lives
        // in Caches and a malicious or damaged entry must not be allowed to escape the
        // models directory on resume.
        let packageKind = info["packageKind"].flatMap(ModelPackageKind.init(rawValue:))
        do {
            if packageKind == .diffusion {
                try DiffusionPackageValidator.validatePackageName(fileName)
            } else {
                try DownloadableModel.validate(fileName: fileName)
            }
        } catch {
            Log.download.error("Refusing to retry \(id): persisted fileName failed validation: \(error.localizedDescription)")
            activeDownloads[id]?.markFailed(error: "Download metadata is invalid; please re-add the model.")
            removePendingDownload(id: id)
            endActivityIfNeeded(modelID: id)
            return
        }

        let modelType: ModelType = typeStr == "gguf" ? .gguf : .mlx
        let sizeBytes = UInt64(info["sizeBytes"] ?? "") ?? 0
        let model = DownloadableModel(
            repoID: repoID,
            fileName: fileName,
            displayName: displayName,
            modelType: modelType,
            sizeBytes: sizeBytes,
            packageKind: packageKind
        )

        // Reset to queued so the UI reflects that a new attempt is underway.
        let state = DownloadState(model: model)
        activeDownloads[model.id] = state
        beginActivityIfNeeded(modelID: model.id)

        let snapshotFiles = decodePendingSnapshotFiles(info["snapshotFiles"], repoID: repoID)

        // Snapshot downloads are retried file-by-file from the persisted package
        // plan. URLSession resume blobs are only valid for single-file tasks.
        if let snapshotFiles, !snapshotFiles.isEmpty {
            _ = consumeResumeData(for: id)
            do {
                try startSnapshotDownload(model: model, files: snapshotFiles)
            } catch {
                Log.download.error("Failed to restart snapshot download for \(id): \(error.localizedDescription)")
                activeDownloads[model.id]?.markFailed(error: error.localizedDescription)
                endActivityIfNeeded(modelID: model.id)
            }
            return
        }

        // Consume any persisted resume data. Clean it up regardless of outcome so
        // we never retry with stale data on a subsequent failure.
        let resumeData = consumeResumeData(for: id)

        if let resumeData {
            Log.download.info("Retrying download \(id) with resume data (\(resumeData.count) bytes)")
            let task = sessionCoordinator.downloadTask(withResumeData: resumeData)
            let context = TaskContext(
                modelID: model.id,
                relativePath: nil,
                expectedBytes: Int64(sizeBytes),
                expectedChecksum: nil
            )
            task.taskDescription = encodeTaskDescription(context)
            downloadStateMachine.registerTask(taskID: task.taskIdentifier, context: context)
            do {
                try savePendingDownload(model: model)
            } catch {
                Log.download.error("Failed to persist retry download for \(id): \(error.localizedDescription)")
            }
            task.resume()
        } else {
            Log.download.info("Retrying download \(id) from scratch (no resume data)")
            await retryWithFreshDownload(model: model)
        }
    }

    private func decodePendingSnapshotFiles(_ json: String?, repoID: String) -> [ModelDownloadFile]? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        do {
            let metadata = try JSONDecoder().decode([SnapshotFileMetadata].self, from: data)
            return metadata.map { file in
                ModelDownloadFile(
                    relativePath: file.relativePath,
                    url: huggingFaceDownloadURL(repoID: repoID, filePath: file.relativePath),
                    sizeBytes: file.sizeBytes,
                    expectedChecksum: file.expectedChecksum
                )
            }
        } catch {
            Log.download.error("Failed to decode pending snapshot metadata for \(repoID): \(error.localizedDescription)")
            return nil
        }
    }

    /// Starts a fresh single-file download for a model from its HuggingFace URL.
    ///
    /// Used as the fallback when resume data is absent or rejected by the server.
    @MainActor private func retryWithFreshDownload(model: DownloadableModel) async {
        guard model.modelType != .mlx || model.packageKind == nil else {
            Log.download.error("Cannot retry snapshot download \(model.id) without persisted package metadata")
            activeDownloads[model.id]?.markFailed(error: "Download metadata is incomplete; please re-add the model.")
            endActivityIfNeeded(modelID: model.id)
            return
        }
        let url = huggingFaceDownloadURL(repoID: model.repoID, filePath: model.fileName)
        guard url.host == "huggingface.co" else {
            Log.download.error("Failed to build retry URL for \(model.id)")
            activeDownloads[model.id]?.markFailed(error: "Could not construct download URL for retry")
            endActivityIfNeeded(modelID: model.id)
            return
        }
        do {
            try startSingleFileDownload(model: model, url: url, expectedChecksum: nil)
        } catch {
            Log.download.error("Failed to start fresh retry download for \(model.id): \(error.localizedDescription)")
            activeDownloads[model.id]?.markFailed(error: error.localizedDescription)
            endActivityIfNeeded(modelID: model.id)
        }
    }

    private func huggingFaceDownloadURL(repoID: String, filePath: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        let segments = ([repoID, "resolve", "main"] + filePath.components(separatedBy: "/"))
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
        components.percentEncodedPath = "/" + segments.joined(separator: "/")
        guard let url = components.url else {
            Log.download.error("Failed to build download URL for \(repoID)/\(filePath)")
            return URL(string: "https://huggingface.co")!
        }
        return url
    }

    /// Cancels an in-progress download.
    ///
    /// - Parameter id: The `DownloadableModel.id` of the download to cancel.
    @MainActor public func cancelDownload(id: String) {
        Log.download.info("Cancelling download: \(id)")

        // getAllTasks delivers its callback on the URLSession delegate queue (a background
        // thread). Reading task context state — which is written from @MainActor — on that queue
        // is a data race. We hop back to @MainActor for the dictionary read, match tasks
        // by model ID, and then cancel them. URLSessionTask.cancel() is thread-safe.
        sessionCoordinator.getAllTasks { [weak self] tasks in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for task in tasks {
                    let context = self.taskContext(
                        for: task.taskIdentifier,
                        taskDescription: task.taskDescription
                    )
                    if context?.modelID == id {
                        task.cancel()
                    }
                }
                self.activeDownloads[id]?.markCancelled()
                self.removePendingDownload(id: id)
                self.endActivityIfNeeded(modelID: id)
                // Mark the snapshot as cancelling rather than removing it immediately.
                // URLSession delegate callbacks can still arrive after task.cancel() is
                // called; deferring cleanup here prevents a cancelled download from
                // transitioning to .failed due to a "missing snapshot context" error.
                self.downloadStateMachine.markSnapshotCancelling(modelID: id)
            }
        }
    }

    /// Re-creates the background session to pick up any downloads that completed
    /// while the app was suspended or terminated.
    ///
    /// Call this on app launch (e.g., from the `App` struct's `init`). The call also
    /// sweeps any stale temp-download files left behind by a prior process that
    /// crashed or was force-killed between `moveItem` and the move-into-models-dir.
    @MainActor public func reconnectBackgroundSession() {
        Log.download.info("Reconnecting background session")
        // Simply accessing the lazy session property re-creates it, which causes
        // the system to deliver any pending delegate callbacks.
        sessionCoordinator.reconnect()

        // Re-populate activeDownloads from persisted pending downloads.
        restorePendingDownloads()

        // Reclaim disk from any temp files leaked by a prior crash. Capture the
        // active-path snapshot here on @MainActor, then run the filesystem scan
        // in a low-priority task so it does not delay the session reconnect path.
        let excluded = activeTempPaths
        Task(priority: .utility) { [weak self] in
            self?.cleanupStaleTempFiles(now: Date(), excluding: excluded)
        }
    }

    // MARK: - Active Temp Path Tracking

    /// Records a temp-file path so the stale-file sweep ignores it while the
    /// download is being processed.
    ///
    /// Must be called on `@MainActor` — called from `BackgroundDownloadManager+URLSessionDelegate.swift`
    /// inside the `Task { @MainActor }` block that handles completion.
    ///
    /// Stores the symlink-resolved path so it matches the paths returned by
    /// `FileManager.contentsOfDirectory`, which resolves symlinks on macOS
    /// (e.g. `/var/folders/…` → `/private/var/folders/…`).
    @MainActor
    internal func registerActiveTempPath(_ url: URL) {
        activeTempPaths.insert(url.resolvingSymlinksInPath())
    }

    /// Removes a previously registered temp-file path.
    ///
    /// Must be called on `@MainActor` after the file has been moved to its final
    /// destination or deleted on failure.
    @MainActor
    internal func unregisterActiveTempPath(_ url: URL) {
        activeTempPaths.remove(url.resolvingSymlinksInPath())
    }

    // MARK: - Disk Space

    /// Checks that there is enough free disk space for the download plus a safety buffer.
    ///
    /// Performs the filesystem query on a background thread to avoid blocking the main thread.
    public func checkDiskSpace(requiredBytes: UInt64) async throws {
        let (freeSpace, needed) = try await Task.detached {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            let free = attrs[.systemFreeSize] as? UInt64 ?? 0
            return (free, requiredBytes + Self.diskSpaceBuffer)
        }.value

        guard freeSpace > needed else {
            Log.download.error(
                "Insufficient disk space: need \(needed) bytes, have \(freeSpace)"
            )
            throw HuggingFaceError.insufficientDiskSpace(
                required: needed,
                available: freeSpace
            )
        }
    }

    // MARK: - File Validation

    /// Validates that a downloaded file has the correct format.
    ///
    /// Delegates to ``DownloadFileValidator`` which contains the format-specific logic.
    ///
    /// - Parameters:
    ///   - fileURL: The temporary file location from URLSession.
    ///   - modelType: The expected model type.
    /// - Throws: `HuggingFaceError.invalidDownloadedFile` if validation fails.
    public func validateDownloadedFile(
        at fileURL: URL,
        modelType: ModelType,
        expectedChecksum: ModelFileChecksum? = nil
    ) throws {
        try DownloadFileValidator().validate(
            at: fileURL,
            modelType: modelType,
            expectedChecksum: expectedChecksum
        )
    }

    // MARK: - GGUF Manifest Verification

    /// Verifier used after a GGUF download completes to check an optional sidecar
    /// manifest. Exposed as `internal` so tests can inject an accepting verifier.
    @ObservationIgnored
    internal var ggufManifestVerifier: GGUFSignedManifestVerifier = GGUFSignedManifestVerifier()

    /// Checks for a sidecar manifest alongside a freshly-downloaded GGUF file.
    ///
    /// The sidecar convention: if `<file>.manifest.json` exists next to the
    /// downloaded GGUF, its contents are treated as a ``GGUFSignedManifest`` and
    /// the file digest is verified against it. Missing manifests are silently
    /// skipped so existing downloads without a manifest continue to work.
    ///
    /// Call this *after* the GGUF file has been moved to its final destination
    /// so the file hash is computed against the canonical on-disk bytes.
    ///
    /// - Parameter fileURL: Final on-disk URL of the downloaded GGUF.
    /// - Throws: ``GGUFSignedManifestVerificationError`` when a manifest is present
    ///   but verification fails (unsigned, signature rejected, digest mismatch, …).
    internal func verifyGGUFManifestIfPresent(at fileURL: URL) throws {
        let manifestURL = fileURL.appendingPathExtension("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            // No sidecar manifest — skip verification without logging noise.
            return
        }
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL)
        } catch {
            Log.download.error("Failed to read GGUF manifest at \(manifestURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            throw error
        }
        try ggufManifestVerifier.verify(fileURL: fileURL, manifestData: manifestData)
    }

    // MARK: - Download Coordination

    @MainActor
    private func startSingleFileDownload(
        model: DownloadableModel,
        url: URL,
        expectedChecksum: ModelFileChecksum?
    ) throws {
        let task = sessionCoordinator.downloadTask(with: url)
        let context = TaskContext(
            modelID: model.id,
            relativePath: nil,
            expectedBytes: Int64(model.sizeBytes),
            expectedChecksum: expectedChecksum
        )
        task.taskDescription = encodeTaskDescription(context)
        downloadStateMachine.registerTask(taskID: task.taskIdentifier, context: context)
        try savePendingDownload(model: model)
        task.resume()
        Log.download.info("Download task \(task.taskIdentifier) started for \(model.id)")
    }

    @MainActor
    internal func prepareSnapshotDownload(
        model: DownloadableModel,
        files: [ModelDownloadFile],
        stagingDirectory: URL
    ) {
        downloadStateMachine.prepareSnapshotDownload(
            model: model,
            files: files,
            stagingDirectory: stagingDirectory
        )
    }

    @MainActor
    private func startSnapshotDownload(model: DownloadableModel, files: [ModelDownloadFile]) throws {
        let stagingDirectory = try makeSnapshotStagingDirectory()
        prepareSnapshotDownload(model: model, files: files, stagingDirectory: stagingDirectory)
        guard downloadStateMachine.snapshotDownload(modelID: model.id) != nil else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Failed to create MLX snapshot context")
        }

        // Create all tasks and register context before persisting and resuming,
        // so reconnect metadata is written before any task can complete.
        var tasks: [URLSessionDownloadTask] = []
        var taskIDs: Set<Int> = []
        for file in files {
            let task = sessionCoordinator.downloadTask(with: file.url)
            let taskContext = TaskContext(
                modelID: model.id,
                relativePath: file.relativePath,
                expectedBytes: Int64(file.sizeBytes),
                expectedChecksum: file.expectedChecksum
            )
            task.taskDescription = encodeTaskDescription(taskContext)
            downloadStateMachine.registerTask(taskID: task.taskIdentifier, context: taskContext)
            taskIDs.insert(task.taskIdentifier)
            tasks.append(task)
        }

        downloadStateMachine.registerSnapshotTasks(modelID: model.id, taskIDs: taskIDs)
        // Persist before resuming so reconnect metadata is always in place.
        try savePendingDownload(
            model: model,
            snapshotFiles: files.map {
                SnapshotFileMetadata(
                    relativePath: $0.relativePath,
                    sizeBytes: $0.sizeBytes,
                    expectedChecksum: $0.expectedChecksum
                )
            },
            stagingDirectoryName: stagingDirectory.lastPathComponent
        )
        for task in tasks {
            task.resume()
        }
    }

    private func makeSnapshotStagingDirectory() throws -> URL {
        let url = storageService.modelsDirectory
            .appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func encodeTaskDescription(_ context: TaskContext) -> String {
        downloadStateMachine.encodeTaskDescription(context)
    }

    // internal: required by BackgroundDownloadManager+URLSessionDelegate.swift
    internal func taskContext(for taskID: Int, taskDescription: String?) -> TaskContext? {
        downloadStateMachine.taskContext(for: taskID, taskDescription: taskDescription)
    }

    // internal: required by BackgroundDownloadManager+URLSessionDelegate.swift
    @MainActor
    internal func removeTaskTracking(taskID: Int, modelID: String) {
        if let stagingDirectory = downloadStateMachine.removeTaskTracking(taskID: taskID, modelID: modelID) {
            do {
                try FileManager.default.removeItem(at: stagingDirectory)
            } catch {
                Log.download.error("Failed to remove snapshot staging directory: \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    internal func updateSnapshotProgress(
        modelID: String,
        relativePath: String,
        bytesDownloaded: Int64,
        totalBytesExpected: Int64
    ) {
        guard let progress = downloadStateMachine.updateSnapshotProgress(
            modelID: modelID,
            relativePath: relativePath,
            bytesDownloaded: bytesDownloaded,
            totalBytesExpected: totalBytesExpected
        ) else { return }
        activeDownloads[modelID]?.updateProgress(
            bytesDownloaded: progress.bytesDownloaded,
            totalBytes: progress.totalBytes
        )
        updateActivityProgress(
            modelID: modelID,
            bytesDownloaded: progress.bytesDownloaded,
            totalBytes: progress.totalBytes
        )
    }

    @MainActor
    internal func completeSnapshotFile(
        modelID: String,
        relativePath: String,
        tempURL: URL
    ) throws {
        guard let snapshot = downloadStateMachine.snapshotDownload(modelID: modelID) else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Missing snapshot context for MLX download")
        }

        // The download was cancelled; discard the file without transitioning to .failed.
        // Staging cleanup happens in removeTaskTracking once all tasks have drained.
        if snapshot.isCancelling {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }

        // Validate that the resolved destination stays within the staging directory to
        // prevent path-traversal attacks via crafted relative paths from remote metadata.
        let destination = snapshot.stagingDirectory.appendingPathComponent(relativePath)
        let resolvedDestination = destination.resolvingSymlinksInPath()
        let resolvedStaging = snapshot.stagingDirectory.resolvingSymlinksInPath()
        guard resolvedDestination.path.hasPrefix(resolvedStaging.path + "/") else {
            try? FileManager.default.removeItem(at: tempURL)
            throw HuggingFaceError.invalidDownloadedFile(reason: "Snapshot file path escapes staging directory: \(relativePath)")
        }
        try FileManager.default.createDirectory(
            at: resolvedDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: resolvedDestination.path) {
            try FileManager.default.removeItem(at: resolvedDestination)
        }
        try FileManager.default.moveItem(at: tempURL, to: resolvedDestination)
        if activeDownloads[modelID]?.model.packageKind == .diffusion {
            try DiffusionPackageValidator.validateComponent(at: resolvedDestination, relativePath: relativePath)
        } else {
            try DownloadFileValidator().validateChecksum(
                at: resolvedDestination,
                expectedChecksum: snapshot.files[relativePath]?.expectedChecksum
            )
        }

        let fileSize = (try FileManager.default.attributesOfItem(atPath: resolvedDestination.path)[.size] as? NSNumber)?.int64Value ?? snapshot.progressByFile[relativePath]?.expectedBytes ?? 0
        guard let progress = downloadStateMachine.markSnapshotFileCompleted(
            modelID: modelID,
            relativePath: relativePath,
            fileSize: fileSize
        ) else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Missing snapshot context for MLX download")
        }
        activeDownloads[modelID]?.updateProgress(
            bytesDownloaded: progress.bytesDownloaded,
            totalBytes: progress.totalBytes
        )

        guard progress.isComplete else { return }

        let packageModel = activeDownloads[modelID]?.model
        if packageModel?.packageKind == .diffusion {
            try DiffusionPackageValidator.validatePackage(at: snapshot.stagingDirectory, files: Array(snapshot.files.keys))
        } else {
            try validateDownloadedFile(at: snapshot.stagingDirectory, modelType: .mlx)
        }
        let finalFileName = packageModel?.fileName ?? snapshot.stagingDirectory.lastPathComponent
        let finalURL = storageService.modelsDirectory.appendingPathComponent(finalFileName)
        let resolvedFinalURL = finalURL.resolvingSymlinksInPath()
        let resolvedModelsDir = storageService.modelsDirectory.resolvingSymlinksInPath()
        guard resolvedFinalURL.path.hasPrefix(resolvedModelsDir.path + "/") else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Model filename escapes models directory: \(finalFileName)")
        }
        try FileManager.default.createDirectory(
            at: finalURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: finalURL.path) {
            try FileManager.default.removeItem(at: finalURL)
        }
        if packageModel?.packageKind == .diffusion, let packageModel {
            try DiffusionPackageValidator.writePackageManifest(for: packageModel, files: Array(snapshot.files.keys), in: snapshot.stagingDirectory)
        }
        try FileManager.default.moveItem(at: snapshot.stagingDirectory, to: finalURL)
        // Harden the at-rest snapshot package on iOS once it reaches its final
        // location. Best-effort: never fails the completed download.
        DownloadedFileProtection.protect(finalURL)
        activeDownloads[modelID]?.markCompleted(localURL: finalURL)
        removePendingDownload(id: modelID)
        _ = downloadStateMachine.removeSnapshotDownload(modelID: modelID)
        endActivityIfNeeded(modelID: modelID)
    }

    // internal: required by BackgroundDownloadManager+URLSessionDelegate.swift
    @MainActor
    internal func failSnapshotDownload(modelID: String, error: String, cancelRemainingTasks: Bool) {
        guard let snapshot = downloadStateMachine.snapshotDownload(modelID: modelID) else {
            if case .failed = activeDownloads[modelID]?.status {
                return
            }
            activeDownloads[modelID]?.markFailed(error: error)
            endActivityIfNeeded(modelID: modelID)
            return
        }

        // When cancellation is in progress, don't overwrite .cancelled with .failed.
        // Staging cleanup is deferred to removeTaskTracking once all tasks have drained.
        if snapshot.isCancelling { return }

        if cancelRemainingTasks {
            let activeTaskIDs = downloadStateMachine.snapshotTaskIDs(modelID: modelID)
            sessionCoordinator.getAllTasks { tasks in
                for task in tasks where activeTaskIDs.contains(task.taskIdentifier) {
                    task.cancel()
                }
            }
        }

        activeDownloads[modelID]?.markFailed(error: error)
        endActivityIfNeeded(modelID: modelID)
        let stagingDirectory = downloadStateMachine.removeSnapshotDownload(modelID: modelID)
        do {
            try FileManager.default.removeItem(at: stagingDirectory ?? snapshot.stagingDirectory)
        } catch {
            Log.download.error("Failed to remove snapshot staging directory: \(error.localizedDescription)")
        }
    }

    @MainActor private func restorePendingDownloads() {
        migrateFromUserDefaults()

        guard let pending = loadPendingMetadata() else { return }

        // Collect all known IDs so we can delete orphaned resume-data files below.
        let knownIDs = Set(pending.keys)
        deleteOrphanedResumeDataFiles(knownIDs: knownIDs)

        for (id, info) in pending {
            // Only restore if we don't already have a state for this download.
            guard activeDownloads[id] == nil else { continue }
            guard let repoID = info["repoID"],
                  let fileName = info["fileName"],
                  let displayName = info["displayName"],
                  let typeStr = info["modelType"] else { continue }

            // Drop entries whose persisted filename fails validation rather than
            // restoring them into UI state. A corrupted filename here would later
            // be written to disk via startDownload / completeSnapshotFile and the
            // URL-standardized prefix check would reject it — skip early so the
            // stale entry is also pruned from the pending-downloads JSON.
            do {
                if info["packageKind"] == ModelPackageKind.diffusion.rawValue {
                    try DiffusionPackageValidator.validatePackageName(fileName)
                } else {
                    try DownloadableModel.validate(fileName: fileName)
                }
            } catch {
                Log.download.warning("Dropping pending download \(id) with invalid fileName: \(error.localizedDescription)")
                removePendingDownload(id: id)
                continue
            }

            let modelType: ModelType = typeStr == "gguf" ? .gguf : .mlx
            let model = DownloadableModel(
                repoID: repoID,
                fileName: fileName,
                displayName: displayName,
                modelType: modelType,
                sizeBytes: UInt64(info["sizeBytes"] ?? "") ?? 0,
                packageKind: info["packageKind"].flatMap(ModelPackageKind.init(rawValue:))
            )
            let state = DownloadState(model: model)
            activeDownloads[id] = state
            if modelType == .mlx,
               let stagingDirectoryName = info["stagingDirectoryName"],
               let snapshotJSON = info["snapshotFiles"],
               let snapshotData = snapshotJSON.data(using: .utf8) {
                do {
                    let files = try JSONDecoder().decode([SnapshotFileMetadata].self, from: snapshotData)
                    downloadStateMachine.restoreSnapshotDownload(
                        modelID: id,
                        model: model,
                        files: files,
                        stagingDirectory: storageService.modelsDirectory.appendingPathComponent(
                            stagingDirectoryName,
                            isDirectory: true
                        )
                    )
                } catch {
                    Log.download.error("Failed to restore snapshot metadata for \(id): \(error.localizedDescription)")
                }
            }
            Log.download.info("Restored pending download state for \(id)")
        }
    }

    // MARK: - Cleanup Sweep

    /// Removes temp-download files left behind by a previous process that crashed
    /// or was force-killed between receiving the download and moving it into the
    /// models directory.
    @MainActor public func cleanupStaleTempFiles() {
        cleanupStaleTempFiles(now: Date(), excluding: activeTempPaths)
    }

    /// Time-injectable companion to ``cleanupStaleTempFiles()`` used by tests.
    @discardableResult
    internal func cleanupStaleTempFiles(
        now: Date,
        excluding excluded: Set<URL> = []
    ) -> (removed: Int, bytesReclaimed: Int64) {
        DownloadHygieneJanitor(
            tempScanDirectory: tempScanDirectory,
            tempFilePrefix: Self.tempFilePrefix,
            tempFileExtension: Self.tempFileExtension,
            staleTempFileAge: Self.staleTempFileAge
        ).cleanupStaleTempFiles(now: now, excluding: excluded)
    }

    /// Deletes resume-data files for download IDs not present in the current pending-metadata list.
    internal func deleteOrphanedResumeDataFiles(knownIDs: Set<String>) {
        DownloadHygieneJanitor.deleteOrphanedResumeDataFiles(
            in: pendingStore.persistenceDirectory,
            knownIDs: knownIDs
        )
    }

    // MARK: - Persistence Facade

    private func loadPendingMetadata() -> [String: [String: String]]? {
        pendingStore.loadPendingMetadata()
    }

    private func savePendingDownload(
        model: DownloadableModel,
        snapshotFiles: [SnapshotFileMetadata] = [],
        stagingDirectoryName: String? = nil
    ) throws {
        try pendingStore.savePendingDownload(
            model: model,
            snapshotFiles: snapshotFiles,
            stagingDirectoryName: stagingDirectoryName
        )
    }

    internal func removePendingDownload(id: String) {
        pendingStore.removePendingDownload(id: id)
    }

    internal func persistResumeData(_ data: Data, for id: String) {
        pendingStore.persistResumeData(data, for: id)
    }

    @MainActor internal func consumeResumeData(for id: String) -> Data? {
        pendingStore.consumeResumeData(for: id)
    }

    // MARK: - NetworkActivityCenter integration

    /// Issues an activity token for `modelID` if one isn't already in flight.
    /// Idempotent so retries / snapshot fan-out don't double-register.
    @MainActor
    internal func beginActivityIfNeeded(modelID: String) {
        progressReporter.beginActivityIfNeeded(modelID: modelID)
    }

    /// Closes the activity token for `modelID` if one is outstanding. Safe
    /// to call from every mark-* terminal state — extra calls are no-ops.
    @MainActor
    internal func endActivityIfNeeded(modelID: String) {
        progressReporter.endActivityIfNeeded(modelID: modelID)
    }

    /// Forwards progress to the activity center so the public observable
    /// reports rich download bytes / throughput, not just "data flowing".
    @MainActor
    internal func updateActivityProgress(
        modelID: String,
        bytesDownloaded: Int64,
        totalBytes: Int64
    ) {
        progressReporter.updateActivityProgress(
            modelID: modelID,
            bytesDownloaded: bytesDownloaded,
            totalBytes: totalBytes
        )
    }

    internal func migrateFromUserDefaults() {
        pendingStore.migrateFromUserDefaults()
    }

    internal static let resumeHMACKeychainAccount: String = PendingDownloadStore.resumeHMACKeychainAccount

    static func computeResumeHMACTag(for data: Data) throws -> Data {
        try PendingDownloadStore.computeResumeHMACTag(for: data)
    }

    static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        PendingDownloadStore.constantTimeEqual(lhs, rhs)
    }

    internal static func _resetResumeHMACKeyCacheForTesting() {
        PendingDownloadStore._resetResumeHMACKeyCacheForTesting()
    }

}
