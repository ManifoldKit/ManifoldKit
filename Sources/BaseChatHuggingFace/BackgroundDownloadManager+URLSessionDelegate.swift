#if HuggingFace
import BaseChatInference
import Foundation
import os

// MARK: - URLSessionDownloadDelegate

extension BackgroundDownloadManager: URLSessionDownloadDelegate {

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let taskID = downloadTask.taskIdentifier
        let taskDescription = downloadTask.taskDescription

        Task { @MainActor [weak self] in
            guard let self,
                  let context = self.taskContext(for: taskID, taskDescription: taskDescription) else { return }
            if let relativePath = context.relativePath {
                self.updateSnapshotProgress(
                    modelID: context.modelID,
                    relativePath: relativePath,
                    bytesDownloaded: totalBytesWritten,
                    totalBytesExpected: totalBytesExpectedToWrite
                )
            } else {
                self.activeDownloads[context.modelID]?.updateProgress(
                    bytesDownloaded: totalBytesWritten,
                    totalBytes: totalBytesExpectedToWrite
                )
            }
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let taskID = downloadTask.taskIdentifier
        let taskDescription = downloadTask.taskDescription

        // Copy the file to a safe temporary location before this method returns,
        // since the system deletes the file at `location` immediately after.
        // The prefix + extension combination is the signature the launch-time
        // sweep uses to reclaim files leaked by a prior crash.
        // Retry up to three times with brief backoff to survive transient disk-jitter.
        let tempURL: URL
        do {
            let tempDir = FileManager.default.temporaryDirectory
            let fileName = "\(BackgroundDownloadManager.tempFilePrefix)\(UUID().uuidString).\(BackgroundDownloadManager.tempFileExtension)"
            tempURL = tempDir.appendingPathComponent(fileName)
            try moveItemWithRetry(from: location, to: tempURL)
        } catch {
            Log.download.error("Failed to preserve downloaded file: \(error.localizedDescription)")
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }

            // Track this path so the stale-file sweep does not race with us.
            self.registerActiveTempPath(tempURL)

            guard let context = self.taskContext(for: taskID, taskDescription: taskDescription) else {
                Log.download.error("Completed download has no model ID mapping (task \(taskID))")
                self.unregisterActiveTempPath(tempURL)
                return
            }

            guard let state = self.activeDownloads[context.modelID] else {
                Log.download.error("No DownloadState for completed download: \(context.modelID)")
                self.unregisterActiveTempPath(tempURL)
                return
            }

            let model = state.model

            do {
                if let relativePath = context.relativePath {
                    try self.completeSnapshotFile(
                        modelID: context.modelID,
                        relativePath: relativePath,
                        tempURL: tempURL
                    )
                } else {
                    try self.validateDownloadedFile(
                        at: tempURL,
                        modelType: model.modelType,
                        expectedChecksum: context.expectedChecksum
                    )
                    let destination = self.storageService.modelsDirectory.appendingPathComponent(model.fileName)
                    let resolvedDestination = destination.standardized
                    let resolvedModels = self.storageService.modelsDirectory.standardized
                    guard resolvedDestination.path.hasPrefix(resolvedModels.path + "/") else {
                        try? FileManager.default.removeItem(at: tempURL)
                        self.unregisterActiveTempPath(tempURL)
                        throw HuggingFaceError.invalidDownloadedFile(reason: "Model filename escapes models directory: \(model.fileName)")
                    }
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }

                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    Log.download.info("Download complete: \(model.displayName) → \(destination.lastPathComponent)")

                    self.activeDownloads[context.modelID]?.markCompleted(localURL: destination)
                    self.removePendingDownload(id: context.modelID)
                }
                self.unregisterActiveTempPath(tempURL)
                self.removeTaskTracking(taskID: taskID, modelID: context.modelID)
            } catch {
                Log.download.error("Post-download processing failed for \(context.modelID): \(error.localizedDescription)")
                if context.relativePath != nil {
                    self.failSnapshotDownload(
                        modelID: context.modelID,
                        error: error.localizedDescription,
                        cancelRemainingTasks: true
                    )
                } else {
                    self.activeDownloads[context.modelID]?.markFailed(error: error.localizedDescription)
                    self.removePendingDownload(id: context.modelID)
                }
                self.unregisterActiveTempPath(tempURL)
                self.removeTaskTracking(taskID: taskID, modelID: context.modelID)
                // Use try? — the file may already have been removed in a guard
                // block above (e.g. path-traversal rejection), so a "not found"
                // error here is expected and should not be logged as a failure.
                try? FileManager.default.removeItem(at: tempURL)
            }
        }
    }

    nonisolated public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }  // No error means success; handled in didFinishDownloadingTo.

        let taskID = task.taskIdentifier
        let taskDescription = task.taskDescription
        let nsError = error as NSError
        let errorDesc = error.localizedDescription

        // Capture resume data before the task object is released. Resume data is only
        // available on URLSessionDownloadTask failures (not snapshot/MLX partial files)
        // and only when the server did not cancel the request.
        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let context = self.taskContext(for: taskID, taskDescription: taskDescription) else { return }
            Log.download.error("Download failed for \(context.modelID): \(errorDesc)")

            if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
                if context.relativePath != nil {
                    if case .failed = self.activeDownloads[context.modelID]?.status {
                        self.removeTaskTracking(taskID: taskID, modelID: context.modelID)
                        return
                    }
                }
                self.activeDownloads[context.modelID]?.markCancelled()
                // Pending metadata is removed on cancellation — retryDownload is not
                // offered for cancelled downloads (only .failed shows a Retry button).
                self.removePendingDownload(id: context.modelID)
            } else {
                // Persist resume data for single-file downloads so retryDownload(id:) can
                // resume from where the download stopped rather than restarting from scratch.
                // MLX snapshot files are excluded — each file is small enough to restart.
                if context.relativePath == nil, let resumeData {
                    self.persistResumeData(resumeData, for: context.modelID)
                }

                if context.relativePath != nil {
                    // failSnapshotDownload calls removePendingDownload internally.
                    self.failSnapshotDownload(
                        modelID: context.modelID,
                        error: errorDesc,
                        cancelRemainingTasks: true
                    )
                } else {
                    // Keep pending metadata intact so retryDownload(id:) can reconstruct
                    // the model and reach the resume-data path. removePendingDownload is
                    // called only after a successful retry or a fresh-start retry begins.
                    self.activeDownloads[context.modelID]?.markFailed(error: errorDesc)
                }
            }
            self.removeTaskTracking(taskID: taskID, modelID: context.modelID)
        }
    }
}

// MARK: - Disk-jitter retry helper

private extension BackgroundDownloadManager {

    /// Moves a file from `source` to `destination`, retrying on transient errors.
    ///
    /// On macOS, disk I/O jitter can cause a single `moveItem` to fail with an
    /// `NSFileWriteUnknownError` or similar transient code even when the volume is
    /// healthy.  Three attempts with a short exponential backoff are enough to ride
    /// out brief bursts of I/O contention without delaying the happy path noticeably.
    ///
    /// - Parameters:
    ///   - source: The URL to move from.
    ///   - destination: The URL to move to.
    ///   - maxAttempts: Number of attempts before surfacing the last error.
    nonisolated func moveItemWithRetry(from source: URL, to destination: URL, maxAttempts: Int = 3) throws {
        var lastError: Error?
        for attempt in 1...maxAttempts {
            do {
                try FileManager.default.moveItem(at: source, to: destination)
                return
            } catch {
                lastError = error
                if attempt < maxAttempts {
                    Thread.sleep(forTimeInterval: 0.05 * Double(attempt))
                }
            }
        }
        throw lastError!
    }
}
#endif
