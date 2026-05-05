#if HuggingFace
import BaseChatInference
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

    /// The background URL session identifier (derived from BaseChatConfiguration).
    nonisolated public static var sessionIdentifier: String {
        BaseChatConfiguration.shared.downloadSessionIdentifier
    }

    /// Minimum free disk space buffer beyond the model size (500 MB).
    nonisolated private static let diskSpaceBuffer: UInt64 = 500_000_000

    /// Prefix applied to every temp file the manager creates in the process temp directory.
    ///
    /// Gives the launch-time sweep a safe fingerprint: only files the manager itself
    /// would have written are considered for removal, so cleanup cannot touch
    /// unrelated temp files produced by other subsystems.
    nonisolated internal static let tempFilePrefix = "basechatkit-dl-"

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
        activeDownloads.values.contains { state in
            switch state.status {
            case .queued, .downloading:
                return true
            case .completed, .failed, .cancelled:
                return false
            }
        }
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
    internal struct TaskContext: Codable, Sendable {
        let modelID: String
        let relativePath: String?
        let expectedBytes: Int64
        let expectedChecksum: ModelFileChecksum?
    }

    private struct SnapshotFileMetadata: Codable, Sendable {
        let relativePath: String
        let sizeBytes: UInt64
        let expectedChecksum: ModelFileChecksum?
    }

    private struct SnapshotProgress: Sendable {
        var bytesDownloaded: Int64
        var expectedBytes: Int64
    }

    private struct SnapshotDownloadContext: Sendable {
        let stagingDirectory: URL
        let files: [String: SnapshotFileMetadata]
        let totalBytes: Int64
        var progressByFile: [String: SnapshotProgress]
        var completedFiles: Set<String>
        var taskIDs: Set<Int>
        /// Set to true when a cancellation is in progress; lets delegate callbacks
        /// drain without racing into .failed state before all tasks have reported back.
        var isCancelling: Bool = false
    }

    /// Maps `URLSessionTask.taskIdentifier` to task metadata for delegate routing.
    private var taskContexts: [Int: TaskContext] = [:]

    /// Tracks multi-file MLX downloads by logical model ID.
    private var snapshotDownloads: [String: SnapshotDownloadContext] = [:]

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

    /// Backing store for the lazily created background URL session.
    ///
    /// Kept as an optional so `deinit` can skip invalidation when the session
    /// was never created (e.g. in unit tests that never start a download).
    /// Accessing `backgroundSession` during `deinit` before the object has fully
    /// initialised its memory is unsafe and causes a SIGSEGV.
    @ObservationIgnored
    private var _backgroundSession: URLSession?

    /// Lazily created background URL session.
    ///
    /// Marked `@ObservationIgnored` because `@Observable` does not support stored
    /// computed-like properties that hold references.
    @ObservationIgnored
    private var backgroundSession: URLSession {
        if let existing = _backgroundSession { return existing }
        let config = URLSessionConfiguration.background(withIdentifier: _sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        // Allow cellular for user-initiated downloads.
        config.allowsCellularAccess = true
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        _backgroundSession = session
        return session
    }

    // MARK: - File-based Persistence

    /// Directory where the pending-downloads JSON and per-download resume-data files live.
    ///
    /// Defaults to `Caches/<bundleID>.downloads` so the OS can reclaim space under
    /// pressure — a missing resume file causes a fresh download, not a crash.
    /// Tests inject a per-test temporary directory to prevent parallel suites from
    /// sharing the same JSON file.
    @ObservationIgnored
    private let persistenceDirectory: URL

    /// Directory scanned by ``cleanupStaleTempFiles()`` for orphaned temp files.
    ///
    /// Defaults to `FileManager.default.temporaryDirectory`. Tests inject a unique
    /// subdirectory so parallel cleanup calls from different manager instances cannot
    /// race on each other's files.
    @ObservationIgnored
    private let tempScanDirectory: URL

    /// `UserDefaults` instance used for the one-time legacy migration.
    ///
    /// Defaults to `.standard` so production behaviour is unchanged. Tests inject a
    /// unique-per-instance suite (`UserDefaults(suiteName:)`) so that two managers
    /// running in `swift test --parallel` cannot race on the same key — the legacy
    /// pending-downloads key is a single global string that previously caused a
    /// flake in `test_migrateFromUserDefaults_keepsUserDefaultsKeyOnWriteFailure`
    /// when one suite's `set` interleaved with another's `removeObject`.
    @ObservationIgnored
    private let userDefaults: UserDefaults

    /// URL of the single JSON file that stores all pending-download metadata.
    private var pendingMetadataFileURL: URL {
        persistenceDirectory.appendingPathComponent("pending-downloads.json")
    }

    /// URL of the resume-data binary file for a given download ID.
    private func resumeDataFileURL(for id: String) -> URL {
        // URL-encode the ID so that slash-separated repo paths (e.g. "user/repo/file.gguf")
        // don't create subdirectories inside the persistence directory.
        let safeID = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
        return persistenceDirectory.appendingPathComponent("resume-\(safeID).bin")
    }

    /// Ensures the persistence directory exists, creating it if necessary.
    private func ensurePersistenceDirectory() throws {
        try FileManager.default.createDirectory(
            at: persistenceDirectory,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Init

    /// Creates a new download manager.
    ///
    /// - Parameters:
    ///   - storageService: Provides the models directory path. Defaults to a standard service.
    ///   - sessionIdentifier: Background `URLSession` identifier. Defaults to the framework's
    ///     canonical identifier derived from `BaseChatConfiguration`. Pass a unique value in
    ///     tests to prevent OS-level session collisions between manager instances — reusing the
    ///     same identifier while a previous instance is still being torn down causes the OS to
    ///     deliver callbacks to a deallocated delegate, resulting in a double-free crash.
    ///   - persistenceDirectory: Directory for the pending-downloads JSON and resume-data
    ///     binary files. Tests inject a per-instance temporary directory.
    ///   - tempScanDirectory: Directory scanned by the launch-time stale-temp sweep. Tests
    ///     inject a per-instance temporary directory.
    ///   - userDefaults: `UserDefaults` instance used for the one-time legacy migration.
    ///     Defaults to `.standard`. Tests inject a per-instance suite so that parallel test
    ///     runs cannot race on the shared `pendingDownloadsKey`.
    public init(
        storageService: ModelStorageService = ModelStorageService(),
        sessionIdentifier: String? = nil,
        persistenceDirectory: URL? = nil,
        tempScanDirectory: URL? = nil,
        userDefaults: UserDefaults = .standard
    ) {
        self.storageService = storageService
        self._sessionIdentifier = sessionIdentifier ?? Self.sessionIdentifier
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        self.persistenceDirectory = persistenceDirectory
            ?? caches.appendingPathComponent(
                "\(BaseChatConfiguration.shared.bundleIdentifier).downloads",
                isDirectory: true
            )
        self.tempScanDirectory = tempScanDirectory ?? FileManager.default.temporaryDirectory
        self.userDefaults = userDefaults
        super.init()
    }

    deinit {
        _backgroundSession?.invalidateAndCancel()
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
            try validatePackageName(model.fileName)
        } else {
            try DownloadableModel.validate(fileName: model.fileName)
        }
        try await checkDiskSpace(requiredBytes: model.sizeBytes)
        try storageService.ensureModelsDirectory()

        let state = DownloadState(model: model)
        activeDownloads[model.id] = state

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
                try validatePackageName(fileName)
            } else {
                try DownloadableModel.validate(fileName: fileName)
            }
        } catch {
            Log.download.error("Refusing to retry \(id): persisted fileName failed validation: \(error.localizedDescription)")
            activeDownloads[id]?.markFailed(error: "Download metadata is invalid; please re-add the model.")
            removePendingDownload(id: id)
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

        // Consume any persisted resume data. Clean it up regardless of outcome so
        // we never retry with stale data on a subsequent failure.
        let resumeData = consumeResumeData(for: id)

        if let resumeData {
            Log.download.info("Retrying download \(id) with resume data (\(resumeData.count) bytes)")
            let task = backgroundSession.downloadTask(withResumeData: resumeData)
            let context = TaskContext(
                modelID: model.id,
                relativePath: nil,
                expectedBytes: Int64(sizeBytes),
                expectedChecksum: nil
            )
            task.taskDescription = encodeTaskDescription(context)
            taskContexts[task.taskIdentifier] = context
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

    /// Starts a fresh single-file download for a model from its HuggingFace URL.
    ///
    /// Used as the fallback when resume data is absent or rejected by the server.
    @MainActor private func retryWithFreshDownload(model: DownloadableModel) async {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        let segments = ([model.repoID, "resolve", "main"] + model.fileName.components(separatedBy: "/"))
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
        components.percentEncodedPath = "/" + segments.joined(separator: "/")
        guard let url = components.url else {
            Log.download.error("Failed to build retry URL for \(model.id)")
            activeDownloads[model.id]?.markFailed(error: "Could not construct download URL for retry")
            return
        }
        do {
            try startSingleFileDownload(model: model, url: url, expectedChecksum: nil)
        } catch {
            Log.download.error("Failed to start fresh retry download for \(model.id): \(error.localizedDescription)")
            activeDownloads[model.id]?.markFailed(error: error.localizedDescription)
        }
    }

    /// Cancels an in-progress download.
    ///
    /// - Parameter id: The `DownloadableModel.id` of the download to cancel.
    @MainActor public func cancelDownload(id: String) {
        Log.download.info("Cancelling download: \(id)")

        // getAllTasks delivers its callback on the URLSession delegate queue (a background
        // thread). Reading taskContexts — which is written from @MainActor — on that queue
        // is a data race. We hop back to @MainActor for the dictionary read, match tasks
        // by model ID, and then cancel them. URLSessionTask.cancel() is thread-safe.
        backgroundSession.getAllTasks { [weak self] tasks in
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
                // Mark the snapshot as cancelling rather than removing it immediately.
                // URLSession delegate callbacks can still arrive after task.cancel() is
                // called; deferring cleanup here prevents a cancelled download from
                // transitioning to .failed due to a "missing snapshot context" error.
                if self.snapshotDownloads[id] != nil {
                    self.snapshotDownloads[id]?.isCancelling = true
                }
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
        _ = backgroundSession

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

    // MARK: - Download Coordination

    @MainActor
    private func startSingleFileDownload(
        model: DownloadableModel,
        url: URL,
        expectedChecksum: ModelFileChecksum?
    ) throws {
        let task = backgroundSession.downloadTask(with: url)
        let context = TaskContext(
            modelID: model.id,
            relativePath: nil,
            expectedBytes: Int64(model.sizeBytes),
            expectedChecksum: expectedChecksum
        )
        task.taskDescription = encodeTaskDescription(context)
        taskContexts[task.taskIdentifier] = context
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
        let metadataFiles = files.map {
            SnapshotFileMetadata(
                relativePath: $0.relativePath,
                sizeBytes: $0.sizeBytes,
                expectedChecksum: $0.expectedChecksum
            )
        }
        snapshotDownloads[model.id] = SnapshotDownloadContext(
            stagingDirectory: stagingDirectory,
            files: Dictionary(uniqueKeysWithValues: metadataFiles.map { ($0.relativePath, $0) }),
            totalBytes: Int64(model.sizeBytes),
            progressByFile: Dictionary(uniqueKeysWithValues: metadataFiles.map {
                ($0.relativePath, SnapshotProgress(bytesDownloaded: 0, expectedBytes: Int64($0.sizeBytes)))
            }),
            completedFiles: [],
            taskIDs: []
        )
    }

    @MainActor
    private func startSnapshotDownload(model: DownloadableModel, files: [ModelDownloadFile]) throws {
        let stagingDirectory = try makeSnapshotStagingDirectory()
        prepareSnapshotDownload(model: model, files: files, stagingDirectory: stagingDirectory)
        guard var context = snapshotDownloads[model.id] else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Failed to create MLX snapshot context")
        }

        // Create all tasks and register context before persisting and resuming,
        // so reconnect metadata is written before any task can complete.
        var tasks: [(URLSessionDownloadTask, TaskContext)] = []
        for file in files {
            let task = backgroundSession.downloadTask(with: file.url)
            let taskContext = TaskContext(
                modelID: model.id,
                relativePath: file.relativePath,
                expectedBytes: Int64(file.sizeBytes),
                expectedChecksum: file.expectedChecksum
            )
            task.taskDescription = encodeTaskDescription(taskContext)
            taskContexts[task.taskIdentifier] = taskContext
            context.taskIDs.insert(task.taskIdentifier)
            tasks.append((task, taskContext))
        }

        snapshotDownloads[model.id] = context
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
        for (task, _) in tasks {
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
        do {
            let data = try JSONEncoder().encode(context)
            guard let string = String(data: data, encoding: .utf8) else {
                Log.download.error("Failed to encode task description for \(context.modelID)")
                return context.modelID
            }
            return string
        } catch {
            Log.download.error("Failed to encode task description for \(context.modelID): \(error.localizedDescription)")
            return context.modelID
        }
    }

    // internal: required by BackgroundDownloadManager+URLSessionDelegate.swift
    internal func taskContext(for taskID: Int, taskDescription: String?) -> TaskContext? {
        if let context = taskContexts[taskID] {
            return context
        }
        guard let taskDescription else { return nil }
        let trimmed = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        // JSON-encoded TaskContext (new format) — detect by braces and decode strictly.
        if trimmed.hasPrefix("{") && trimmed.hasSuffix("}") {
            guard let data = taskDescription.data(using: .utf8) else {
                Log.download.error("Failed to UTF-8 encode task description for task \(taskID)")
                return nil
            }
            do {
                return try JSONDecoder().decode(TaskContext.self, from: data)
            } catch {
                Log.download.error("Failed to decode task description for task \(taskID): \(error.localizedDescription)")
                return nil
            }
        }
        // Legacy plain model-ID format (pre-JSON task descriptions).
        return TaskContext(modelID: taskDescription, relativePath: nil, expectedBytes: 0, expectedChecksum: nil)
    }

    // internal: required by BackgroundDownloadManager+URLSessionDelegate.swift
    @MainActor
    internal func removeTaskTracking(taskID: Int, modelID: String) {
        taskContexts.removeValue(forKey: taskID)
        guard var snapshot = snapshotDownloads[modelID] else { return }
        snapshot.taskIDs.remove(taskID)
        // When all tasks have drained after a cancellation, clean up staging.
        if snapshot.isCancelling && snapshot.taskIDs.isEmpty {
            snapshotDownloads.removeValue(forKey: modelID)
            do {
                try FileManager.default.removeItem(at: snapshot.stagingDirectory)
            } catch {
                Log.download.error("Failed to remove snapshot staging directory: \(error.localizedDescription)")
            }
            return
        }
        snapshotDownloads[modelID] = snapshot
    }

    @MainActor
    internal func updateSnapshotProgress(
        modelID: String,
        relativePath: String,
        bytesDownloaded: Int64,
        totalBytesExpected: Int64
    ) {
        guard var snapshot = snapshotDownloads[modelID] else { return }
        let fallbackExpected = snapshot.files[relativePath].map { Int64($0.sizeBytes) } ?? 0
        let expectedBytes = totalBytesExpected > 0 ? totalBytesExpected : fallbackExpected
        snapshot.progressByFile[relativePath] = SnapshotProgress(
            bytesDownloaded: bytesDownloaded,
            expectedBytes: expectedBytes
        )
        snapshotDownloads[modelID] = snapshot

        let totalDownloaded = snapshot.progressByFile.values.reduce(0) { $0 + $1.bytesDownloaded }
        let totalExpected: Int64
        if snapshot.totalBytes > 0 {
            totalExpected = snapshot.totalBytes
        } else {
            totalExpected = snapshot.progressByFile.values.reduce(0) { $0 + $1.expectedBytes }
        }
        activeDownloads[modelID]?.updateProgress(
            bytesDownloaded: totalDownloaded,
            totalBytes: totalExpected
        )
    }

    @MainActor
    internal func completeSnapshotFile(
        modelID: String,
        relativePath: String,
        tempURL: URL
    ) throws {
        guard var snapshot = snapshotDownloads[modelID] else {
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
        let resolvedDestination = destination.standardized
        let resolvedStaging = snapshot.stagingDirectory.standardized
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
            try validateDiffusionComponent(at: resolvedDestination, relativePath: relativePath)
        } else {
            try DownloadFileValidator().validateChecksum(
                at: resolvedDestination,
                expectedChecksum: snapshot.files[relativePath]?.expectedChecksum
            )
        }

        let fileSize = (try FileManager.default.attributesOfItem(atPath: resolvedDestination.path)[.size] as? NSNumber)?.int64Value ?? snapshot.progressByFile[relativePath]?.expectedBytes ?? 0
        snapshot.completedFiles.insert(relativePath)
        snapshot.progressByFile[relativePath] = SnapshotProgress(
            bytesDownloaded: fileSize,
            expectedBytes: snapshot.progressByFile[relativePath]?.expectedBytes ?? fileSize
        )
        snapshotDownloads[modelID] = snapshot

        let totalDownloaded = snapshot.progressByFile.values.reduce(0) { $0 + $1.bytesDownloaded }
        let totalExpected = snapshot.totalBytes > 0
            ? snapshot.totalBytes
            : snapshot.progressByFile.values.reduce(0) { $0 + $1.expectedBytes }
        activeDownloads[modelID]?.updateProgress(
            bytesDownloaded: totalDownloaded,
            totalBytes: totalExpected
        )

        guard snapshot.completedFiles.count == snapshot.files.count else { return }

        let packageModel = activeDownloads[modelID]?.model
        if packageModel?.packageKind == .diffusion {
            try validateDiffusionPackage(at: snapshot.stagingDirectory, files: Array(snapshot.files.keys))
        } else {
            try validateDownloadedFile(at: snapshot.stagingDirectory, modelType: .mlx)
        }
        let finalFileName = packageModel?.fileName ?? snapshot.stagingDirectory.lastPathComponent
        let finalURL = storageService.modelsDirectory.appendingPathComponent(finalFileName)
        let resolvedFinalURL = finalURL.standardized
        let resolvedModelsDir = storageService.modelsDirectory.standardized
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
            try writePackageManifest(for: packageModel, files: Array(snapshot.files.keys), in: snapshot.stagingDirectory)
        }
        try FileManager.default.moveItem(at: snapshot.stagingDirectory, to: finalURL)
        activeDownloads[modelID]?.markCompleted(localURL: finalURL)
        removePendingDownload(id: modelID)
        snapshotDownloads.removeValue(forKey: modelID)
    }

    private func validatePackageName(_ packageName: String) throws {
        guard !packageName.isEmpty,
              packageName.count < 255,
              !packageName.contains("/"),
              !packageName.contains("\\"),
              packageName != ".",
              packageName != "..",
              !packageName.hasPrefix(".") else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Invalid package directory name: \(packageName)")
        }
        guard packageName.unicodeScalars.allSatisfy({ scalar in
            let v = scalar.value
            return v >= 0x20 && v != 0x7F && !(0x80...0x9F).contains(v)
        }) else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Package directory name contains control characters")
        }
    }

    private func validateDiffusionComponent(at url: URL, relativePath: String) throws {
        guard let role = diffusionRole(for: relativePath) else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Unsupported diffusion package component: \(relativePath)")
        }
        try DownloadFileValidator.validate(url, diffusionRole: role)
    }

    private func validateDiffusionPackage(at directory: URL, files: [String]) throws {
        let fileSet = Set(files)
        for required in [
            "model_index.json",
            "vae/config.json",
            "vae/diffusion_pytorch_model.safetensors",
        ] where !fileSet.contains(required) {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Diffusion package is missing required component: \(required)")
        }
        let hasDenoiser = fileSet.contains("unet/diffusion_pytorch_model.safetensors")
            || fileSet.contains("transformer/diffusion_pytorch_model.safetensors")
            || fileSet.contains("transformer/model.safetensors")
        guard hasDenoiser else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Diffusion package is missing transformer/UNet weights")
        }
        for relativePath in files {
            try validateDiffusionComponent(at: directory.appendingPathComponent(relativePath), relativePath: relativePath)
        }
    }

    private func diffusionRole(for relativePath: String) -> DownloadFileValidator.DiffusionFileRole? {
        switch relativePath {
        case "model_index.json":
            return .manifest
        case let path where path.hasSuffix("/config.json") || path.hasSuffix("/scheduler_config.json"):
            return .submoduleConfig
        case let path where path.hasSuffix(".safetensors"):
            return .weights
        case let path where path.hasSuffix("/vocab.json"):
            return .tokenizerVocab
        case let path where path.hasSuffix("/merges.txt"):
            return .tokenizerMerges
        default:
            return nil
        }
    }

    private func writePackageManifest(
        for model: DownloadableModel,
        files: [String],
        in directory: URL
    ) throws {
        let manifest = DownloadedModelPackageManifest(
            packageKind: .diffusion,
            id: model.repoID,
            displayName: model.displayName,
            format: .mlxDiffusion,
            huggingFaceRepoID: model.repoID,
            files: files.sorted()
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(
            to: directory.appendingPathComponent(DownloadedModelPackageManifest.fileName),
            options: .atomic
        )
    }

    // internal: required by BackgroundDownloadManager+URLSessionDelegate.swift
    @MainActor
    internal func failSnapshotDownload(modelID: String, error: String, cancelRemainingTasks: Bool) {
        guard let snapshot = snapshotDownloads[modelID] else {
            if case .failed = activeDownloads[modelID]?.status {
                return
            }
            activeDownloads[modelID]?.markFailed(error: error)
            removePendingDownload(id: modelID)
            return
        }

        // When cancellation is in progress, don't overwrite .cancelled with .failed.
        // Staging cleanup is deferred to removeTaskTracking once all tasks have drained.
        if snapshot.isCancelling { return }

        if cancelRemainingTasks {
            let activeTaskIDs = snapshot.taskIDs
            backgroundSession.getAllTasks { tasks in
                for task in tasks where activeTaskIDs.contains(task.taskIdentifier) {
                    task.cancel()
                }
            }
        }

        activeDownloads[modelID]?.markFailed(error: error)
        removePendingDownload(id: modelID)
        snapshotDownloads.removeValue(forKey: modelID)
        do {
            try FileManager.default.removeItem(at: snapshot.stagingDirectory)
        } catch {
            Log.download.error("Failed to remove snapshot staging directory: \(error.localizedDescription)")
        }
    }

    // MARK: - Persistence (Resume Data)

    /// Persists resume data to a binary file in the caches directory so it survives app restarts.
    ///
    /// Large partial-download blobs are kept out of UserDefaults to avoid bloating
    /// the app's plist and delaying app launch.
    ///
    /// Called by the delegate when a non-cancelled single-file download fails.
    internal func persistResumeData(_ data: Data, for id: String) {
        do {
            try ensurePersistenceDirectory()
            try data.write(to: resumeDataFileURL(for: id), options: .atomic)
            Log.download.info("Persisted \(data.count) bytes of resume data for \(id)")
        } catch {
            Log.download.error("Failed to persist resume data for \(id): \(error.localizedDescription)")
        }
    }

    /// Reads and removes the resume-data file (one-shot consumption).
    ///
    /// Removing immediately prevents stale data from being used on a subsequent failure.
    @MainActor internal func consumeResumeData(for id: String) -> Data? {
        let url = resumeDataFileURL(for: id)
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.removeItem(at: url)
        return data
    }

    // MARK: - Persistence (Pending Downloads)

    /// Loads the pending-downloads JSON from disk, returning nil if the file is absent or unreadable.
    private func loadPendingMetadata() -> [String: [String: String]]? {
        guard let data = try? Data(contentsOf: pendingMetadataFileURL) else { return nil }
        return try? JSONDecoder().decode([String: [String: String]].self, from: data)
    }

    /// Writes the pending-downloads dictionary atomically (write to temp file, then atomic swap).
    ///
    /// Uses `replaceItemAt(_:withItemAt:backupItemName:options:)` which does the swap in a single
    /// kernel operation — there is never a moment where the destination file is absent.
    private func writePendingMetadata(_ pending: [String: [String: String]]) throws {
        try ensurePersistenceDirectory()
        let data = try JSONEncoder().encode(pending)
        let tempURL = pendingMetadataFileURL.deletingLastPathComponent()
            .appendingPathComponent("pending-downloads-\(UUID().uuidString).tmp")
        try data.write(to: tempURL, options: .atomic)
        if FileManager.default.fileExists(atPath: pendingMetadataFileURL.path) {
            // replaceItemAt atomically swaps tempURL into the destination, removing tempURL.
            // The returned URL is the final destination (always pendingMetadataFileURL here);
            // we discard it because we already know the path.
            _ = try FileManager.default.replaceItemAt(
                pendingMetadataFileURL,
                withItemAt: tempURL,
                backupItemName: nil,
                options: []
            )
        } else {
            // Destination doesn't exist yet; a plain move is sufficient.
            try FileManager.default.moveItem(at: tempURL, to: pendingMetadataFileURL)
        }
    }

    private func savePendingDownload(
        model: DownloadableModel,
        snapshotFiles: [SnapshotFileMetadata] = [],
        stagingDirectoryName: String? = nil
    ) throws {
        var pending = loadPendingMetadata() ?? [:]
        var entry = [
            "repoID": model.repoID,
            "fileName": model.fileName,
            "displayName": model.displayName,
            "modelType": model.modelType == .gguf ? "gguf" : "mlx",
            "sizeBytes": String(model.sizeBytes),
        ]
        if let packageKind = model.packageKind {
            entry["packageKind"] = packageKind.rawValue
        }
        if !snapshotFiles.isEmpty {
            let data = try JSONEncoder().encode(snapshotFiles)
            guard let json = String(data: data, encoding: .utf8) else {
                throw HuggingFaceError.invalidDownloadedFile(reason: "Failed to encode pending snapshot metadata")
            }
            entry["snapshotFiles"] = json
        }
        if let stagingDirectoryName {
            entry["stagingDirectoryName"] = stagingDirectoryName
        }
        pending[model.id] = entry
        try writePendingMetadata(pending)
    }

    // internal: required by BackgroundDownloadManager+URLSessionDelegate.swift
    internal func removePendingDownload(id: String) {
        var pending = loadPendingMetadata() ?? [:]
        pending.removeValue(forKey: id)
        do {
            try writePendingMetadata(pending)
        } catch {
            Log.download.error("Failed to remove pending download for \(id): \(error.localizedDescription)")
        }
        // Remove the resume-data file for this ID now that the download is done.
        try? FileManager.default.removeItem(at: resumeDataFileURL(for: id))
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
                    try validatePackageName(fileName)
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
                    snapshotDownloads[id] = SnapshotDownloadContext(
                        stagingDirectory: storageService.modelsDirectory.appendingPathComponent(
                            stagingDirectoryName,
                            isDirectory: true
                        ),
                        files: Dictionary(uniqueKeysWithValues: files.map { ($0.relativePath, $0) }),
                        totalBytes: Int64(model.sizeBytes),
                        progressByFile: Dictionary(uniqueKeysWithValues: files.map {
                            ($0.relativePath, SnapshotProgress(
                                bytesDownloaded: 0,
                                expectedBytes: Int64($0.sizeBytes)
                            ))
                        }),
                        completedFiles: [],
                        taskIDs: []
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
    ///
    /// ### What the sweep deletes
    /// A file in `FileManager.default.temporaryDirectory` is removed iff **all** of:
    /// 1. Filename starts with ``tempFilePrefix`` (`"basechatkit-dl-"`).
    /// 2. Extension equals ``tempFileExtension`` (`"download"`).
    /// 3. It is a regular file (not a directory, symlink, or special file).
    /// 4. Its modification date is older than ``staleTempFileAge`` (24 hours).
    ///
    /// ### What the sweep preserves
    /// Any file missing even one of the four properties above. Notably:
    /// - Temp files written by other subsystems (wrong prefix or extension).
    /// - Files currently being processed by the delegate in this process
    ///   (tracked in ``activeTempPaths`` — registered/unregistered around
    ///   the temp→final move in `didFinishDownloadingTo`).
    /// - Files newer than 24 hours — secondary guard for files handed off from
    ///   the system's background transfer service before the delegate registers them.
    /// - Files whose attributes cannot be read (logged and skipped).
    ///
    /// Runs on launch from ``reconnectBackgroundSession()``.
    @MainActor public func cleanupStaleTempFiles() {
        cleanupStaleTempFiles(now: Date(), excluding: activeTempPaths)
    }

    /// Time-injectable companion to ``cleanupStaleTempFiles()`` used by tests.
    ///
    /// Kept `internal` so the time-injection seam does not appear in the public
    /// API surface of the framework. Production callers should use the no-arg
    /// overload above.
    ///
    /// - Parameters:
    ///   - now: The reference time for the age-threshold comparison.
    ///   - excluded: Temp-file paths to skip regardless of age — typically the set
    ///     of files currently being processed by the delegate in this process.
    @discardableResult
    internal func cleanupStaleTempFiles(
        now: Date,
        excluding excluded: Set<URL> = []
    ) -> (removed: Int, bytesReclaimed: Int64) {
        let tempDir = tempScanDirectory
        let contents: [URL]
        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: tempDir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            Log.download.warning("Temp-file sweep skipped: could not list \(tempDir.path): \(error.localizedDescription)")
            return (0, 0)
        }

        let threshold = now.addingTimeInterval(-Self.staleTempFileAge)
        var removed = 0
        var bytesReclaimed: Int64 = 0
        for fileURL in contents {
            // Filename signature check — only files we could have written.
            let name = fileURL.lastPathComponent
            guard name.hasPrefix(Self.tempFilePrefix), fileURL.pathExtension == Self.tempFileExtension else {
                continue
            }
            // Skip any path that is actively being processed by the delegate so the
            // sweep never races with an in-flight move in the same process.
            // Resolve symlinks before the set lookup — `contentsOfDirectory` resolves
            // them (e.g. /var/folders → /private/var/folders on macOS) and the
            // registered paths are stored resolved, so both sides must match.
            guard !excluded.contains(fileURL.resolvingSymlinksInPath()) else { continue }
            let resourceKeys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
            let values: URLResourceValues
            do {
                values = try fileURL.resourceValues(forKeys: resourceKeys)
            } catch {
                Log.download.warning("Temp-file sweep: failed to read attributes of \(name): \(error.localizedDescription)")
                continue
            }
            guard values.isRegularFile == true,
                  let modified = values.contentModificationDate else {
                continue
            }
            guard modified < threshold else { continue }
            let size = Int64(values.fileSize ?? 0)
            do {
                try FileManager.default.removeItem(at: fileURL)
                removed += 1
                bytesReclaimed += size
            } catch {
                Log.download.warning("Failed to remove stale temp file \(name): \(error.localizedDescription)")
            }
        }
        // Always log the outcome — a silent zero-count result is indistinguishable
        // from a sweep that never ran when a user reports "my download vanished".
        // The log line gives that trail without leaking sensitive paths.
        Log.download.info("Temp-file sweep: reclaimed \(removed) file(s), \(bytesReclaimed) byte(s)")
        return (removed, bytesReclaimed)
    }

    /// Deletes resume-data files for download IDs not present in the current pending-metadata
    /// list. These orphans accumulate when a download crashes without the normal teardown path.
    // internal (not private) so unit tests can call it directly with @testable import.
    internal func deleteOrphanedResumeDataFiles(knownIDs: Set<String>) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: persistenceDirectory,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        for fileURL in contents where fileURL.lastPathComponent.hasPrefix("resume-") && fileURL.pathExtension == "bin" {
            let filename = fileURL.deletingPathExtension().lastPathComponent   // "resume-<encoded-id>"
            let encodedID = String(filename.dropFirst("resume-".count))
            let decodedID = encodedID.removingPercentEncoding ?? encodedID
            if !knownIDs.contains(decodedID) {
                do {
                    try FileManager.default.removeItem(at: fileURL)
                    Log.download.info("Removed orphaned resume-data file: \(fileURL.lastPathComponent)")
                } catch {
                    Log.download.error("Failed to remove orphaned resume-data file \(fileURL.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - One-time UserDefaults Migration

    /// Migrates resume data and pending-download metadata from the legacy UserDefaults
    /// storage to the new file-based persistence, then deletes the old keys.
    ///
    /// Runs once on first launch after the upgrade. Subsequent launches skip it because
    /// the old keys are no longer present.
    ///
    /// UserDefaults keys are only removed after the corresponding file write succeeds, so
    /// a failed write leaves the data intact for the next launch to retry.
    // internal (not private) so unit tests can call it directly with @testable import.
    internal func migrateFromUserDefaults() {
        let defaults = self.userDefaults
        let pendingKey = BaseChatConfiguration.shared.pendingDownloadsKey

        // Migrate pending metadata — only when the new file doesn't already exist.
        if !FileManager.default.fileExists(atPath: pendingMetadataFileURL.path),
           let legacy = defaults.dictionary(forKey: pendingKey) as? [String: [String: String]],
           !legacy.isEmpty {
            do {
                try writePendingMetadata(legacy)
                // Only clear the key once the file write has confirmed success.
                defaults.removeObject(forKey: pendingKey)
                Log.download.info("Migrated \(legacy.count) pending-download(s) from UserDefaults to file")
            } catch {
                Log.download.error("Failed to migrate pending downloads from UserDefaults: \(error.localizedDescription)")
                // Leave the UserDefaults key intact so the next launch can retry.
            }
        } else {
            // No legacy data to migrate — remove the (now-empty or absent) key.
            defaults.removeObject(forKey: pendingKey)
        }

        // Migrate any resume-data blobs stored under the legacy "resumeData.<id>" keys.
        let allKeys = defaults.dictionaryRepresentation().keys
        for key in allKeys where key.hasPrefix("resumeData.") {
            let id = String(key.dropFirst("resumeData.".count))
            if let data = defaults.data(forKey: key) {
                do {
                    try ensurePersistenceDirectory()
                    try data.write(to: resumeDataFileURL(for: id), options: .atomic)
                    // Only clear the key once the file has been written successfully.
                    defaults.removeObject(forKey: key)
                    Log.download.info("Migrated resume data for \(id) from UserDefaults to file")
                } catch {
                    Log.download.error("Failed to migrate resume data for \(id): \(error.localizedDescription)")
                    // Leave the UserDefaults key intact so the next launch can retry.
                }
            } else {
                // No data blob — remove the dangling key.
                defaults.removeObject(forKey: key)
            }
        }
    }
}
#endif
