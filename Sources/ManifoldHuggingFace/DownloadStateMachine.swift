import Foundation
import ManifoldInference
import os

internal struct DownloadStateMachine: Sendable {
    internal struct TaskContext: Codable, Sendable {
        let modelID: String
        let relativePath: String?
        let expectedBytes: Int64
        let expectedChecksum: ModelFileChecksum?
    }

    internal struct SnapshotProgress: Sendable {
        var bytesDownloaded: Int64
        var expectedBytes: Int64
    }

    internal struct SnapshotDownloadContext: Sendable {
        let stagingDirectory: URL
        let files: [String: SnapshotFileMetadata]
        let totalBytes: Int64
        var progressByFile: [String: SnapshotProgress]
        var completedFiles: Set<String>
        var taskIDs: Set<Int>
        var isCancelling: Bool = false
    }

    private var taskContexts: [Int: TaskContext] = [:]
    private var snapshotDownloads: [String: SnapshotDownloadContext] = [:]

    internal init() {}

    internal func encodeTaskDescription(_ context: TaskContext) -> String {
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

    internal mutating func registerTask(taskID: Int, context: TaskContext) {
        taskContexts[taskID] = context
    }

    internal func taskContext(for taskID: Int, taskDescription: String?) -> TaskContext? {
        if let context = taskContexts[taskID] {
            return context
        }
        guard let taskDescription else { return nil }
        let trimmed = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)
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
        return TaskContext(modelID: taskDescription, relativePath: nil, expectedBytes: 0, expectedChecksum: nil)
    }

    internal mutating func removeTaskTracking(taskID: Int, modelID: String) -> URL? {
        taskContexts.removeValue(forKey: taskID)
        guard var snapshot = snapshotDownloads[modelID] else { return nil }
        snapshot.taskIDs.remove(taskID)
        if snapshot.isCancelling && snapshot.taskIDs.isEmpty {
            snapshotDownloads.removeValue(forKey: modelID)
            return snapshot.stagingDirectory
        }
        snapshotDownloads[modelID] = snapshot
        return nil
    }

    internal mutating func prepareSnapshotDownload(
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

    internal func snapshotDownload(modelID: String) -> SnapshotDownloadContext? {
        snapshotDownloads[modelID]
    }

    internal mutating func registerSnapshotTasks(modelID: String, taskIDs: Set<Int>) {
        guard var snapshot = snapshotDownloads[modelID] else { return }
        snapshot.taskIDs.formUnion(taskIDs)
        snapshotDownloads[modelID] = snapshot
    }

    /// Reconciles per-snapshot task-ID sets with a background session's actual
    /// live tasks after a relaunch.
    ///
    /// `restoreSnapshotDownload(modelID:model:files:stagingDirectory:)` only
    /// restores snapshot *metadata* from the persisted pending-downloads JSON —
    /// it has no live `URLSessionTask` objects, so a snapshot restored that way
    /// starts with an empty `taskIDs` set. Without this reconciliation,
    /// `failSnapshotDownload(cancelRemainingTasks: true)` would find nothing to
    /// cancel for a snapshot download resumed across a relaunch, leaving sibling
    /// files downloading after one file fails (finding 27).
    ///
    /// Each entry's `taskDescription` is expected to be the same encoded
    /// `TaskContext` JSON `startSnapshotDownload` wrote at task-creation time —
    /// the OS persists it on the task across relaunch — so `taskContext(for:)`
    /// can decode the owning `modelID` purely from what the live session reports,
    /// with no dependency on this process's (empty, post-relaunch) in-memory
    /// `taskContexts` dictionary.
    internal mutating func reconcileSnapshotTasks(
        liveTasks: [(taskID: Int, taskDescription: String?)]
    ) {
        var taskIDsByModel: [String: Set<Int>] = [:]
        for (taskID, description) in liveTasks {
            guard let context = taskContext(for: taskID, taskDescription: description) else { continue }
            taskIDsByModel[context.modelID, default: []].insert(taskID)
        }
        for (modelID, taskIDs) in taskIDsByModel {
            registerSnapshotTasks(modelID: modelID, taskIDs: taskIDs)
        }
    }

    internal mutating func updateSnapshotProgress(
        modelID: String,
        relativePath: String,
        bytesDownloaded: Int64,
        totalBytesExpected: Int64
    ) -> (bytesDownloaded: Int64, totalBytes: Int64)? {
        guard var snapshot = snapshotDownloads[modelID] else { return nil }
        let fallbackExpected = snapshot.files[relativePath].map { Int64($0.sizeBytes) } ?? 0
        let expectedBytes = totalBytesExpected > 0 ? totalBytesExpected : fallbackExpected
        snapshot.progressByFile[relativePath] = SnapshotProgress(
            bytesDownloaded: bytesDownloaded,
            expectedBytes: expectedBytes
        )
        snapshotDownloads[modelID] = snapshot
        return totals(for: snapshot)
    }

    internal mutating func markSnapshotFileCompleted(
        modelID: String,
        relativePath: String,
        fileSize: Int64
    ) -> (bytesDownloaded: Int64, totalBytes: Int64, isComplete: Bool)? {
        guard var snapshot = snapshotDownloads[modelID] else { return nil }
        snapshot.completedFiles.insert(relativePath)
        snapshot.progressByFile[relativePath] = SnapshotProgress(
            bytesDownloaded: fileSize,
            expectedBytes: snapshot.progressByFile[relativePath]?.expectedBytes ?? fileSize
        )
        snapshotDownloads[modelID] = snapshot
        let progress = totals(for: snapshot)
        return (progress.bytesDownloaded, progress.totalBytes, snapshot.completedFiles.count == snapshot.files.count)
    }

    internal mutating func markSnapshotCancelling(modelID: String) {
        guard var snapshot = snapshotDownloads[modelID] else { return }
        snapshot.isCancelling = true
        snapshotDownloads[modelID] = snapshot
    }

    internal func snapshotTaskIDs(modelID: String) -> Set<Int> {
        snapshotDownloads[modelID]?.taskIDs ?? []
    }

    internal mutating func removeSnapshotDownload(modelID: String) -> URL? {
        snapshotDownloads.removeValue(forKey: modelID)?.stagingDirectory
    }

    internal mutating func restoreSnapshotDownload(
        modelID: String,
        model: DownloadableModel,
        files: [SnapshotFileMetadata],
        stagingDirectory: URL
    ) {
        snapshotDownloads[modelID] = SnapshotDownloadContext(
            stagingDirectory: stagingDirectory,
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
    }

    private func totals(for snapshot: SnapshotDownloadContext) -> (bytesDownloaded: Int64, totalBytes: Int64) {
        let totalDownloaded = snapshot.progressByFile.values.reduce(0) { $0 + $1.bytesDownloaded }
        let totalExpected: Int64
        if snapshot.totalBytes > 0 {
            totalExpected = snapshot.totalBytes
        } else {
            totalExpected = snapshot.progressByFile.values.reduce(0) { $0 + $1.expectedBytes }
        }
        return (totalDownloaded, totalExpected)
    }
}
