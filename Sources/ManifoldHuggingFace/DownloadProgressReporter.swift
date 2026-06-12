import ManifoldInference

@MainActor
internal final class DownloadProgressReporter {
    private let activityCenter: NetworkActivityCenter
    private var activityTokens: [String: NetworkActivityToken] = [:]

    internal init(activityCenter: NetworkActivityCenter) {
        self.activityCenter = activityCenter
    }

    internal func hasActiveDownloads(_ activeDownloads: [String: DownloadState]) -> Bool {
        activeDownloads.values.contains { state in
            switch state.status {
            case .queued, .downloading:
                return true
            case .completed, .failed, .cancelled:
                return false
            }
        }
    }

    internal func beginActivityIfNeeded(modelID: String) {
        guard activityTokens[modelID] == nil else { return }
        activityTokens[modelID] = activityCenter.begin(
            kind: .download(modelID: modelID),
            host: "huggingface.co"
        )
    }

    internal func endActivityIfNeeded(modelID: String) {
        guard let token = activityTokens.removeValue(forKey: modelID) else { return }
        activityCenter.end(token)
    }

    internal func updateActivityProgress(
        modelID: String,
        bytesDownloaded: Int64,
        totalBytes: Int64
    ) {
        guard let token = activityTokens[modelID] else { return }
        activityCenter.updateDownload(
            token,
            bytesReceived: bytesDownloaded,
            totalBytes: totalBytes > 0 ? totalBytes : nil
        )
    }
}
