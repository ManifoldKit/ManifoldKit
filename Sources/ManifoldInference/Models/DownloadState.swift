import Foundation

/// The status of a model download.
public enum DownloadStatus: Sendable {
    case queued
    case downloading(progress: Double, bytesDownloaded: Int64, totalBytes: Int64)
    case completed(localURL: URL)
    case failed(error: String)
    case cancelled
}

/// Observable state for an active or completed download.
///
/// Created by `BackgroundDownloadManager` when a download starts. The UI
/// observes this to show progress indicators and status badges.
@Observable
public final class DownloadState: Identifiable {
    /// Matches the `DownloadableModel.id` this download is for.
    public let id: String
    /// The model being downloaded.
    public let model: DownloadableModel
    /// Current download status.
    public private(set) var status: DownloadStatus
    /// When the download was initiated.
    public let startedAt: Date

    public init(model: DownloadableModel) {
        self.id = model.id
        self.model = model
        self.status = .queued
        self.startedAt = Date()
    }

    // MARK: - State Transitions (called by DownloadManager)

    public func updateProgress(bytesDownloaded: Int64, totalBytes: Int64) {
        let fraction = totalBytes > 0 ? min(1.0, Double(bytesDownloaded) / Double(totalBytes)) : 0
        status = .downloading(progress: fraction, bytesDownloaded: bytesDownloaded, totalBytes: totalBytes)
    }

    public func markCompleted(localURL: URL) {
        status = .completed(localURL: localURL)
    }

    public func markFailed(error: String) {
        status = .failed(error: error)
    }

    public func markCancelled() {
        status = .cancelled
    }
}
