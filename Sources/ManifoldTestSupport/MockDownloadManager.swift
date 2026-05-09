import ManifoldInference
import Foundation

@MainActor
public final class MockDownloadManager: BackgroundDownloadManaging {
    public var activeDownloads: [String: DownloadState]
    public var reconnectCallCount = 0
    public var startedModels: [DownloadableModel] = []
    public var startedPlans: [ModelDownloadPlan] = []
    public var retriedIDs: [String] = []
    public var cancelledIDs: [String] = []
    public var startDownloadError: Error?

    public init(activeDownloads: [String: DownloadState] = [:]) {
        self.activeDownloads = activeDownloads
    }

    public func reconnectBackgroundSession() {
        reconnectCallCount += 1
    }

    public func startDownload(_ model: DownloadableModel, plan: ModelDownloadPlan) async throws -> DownloadState {
        if let startDownloadError {
            throw startDownloadError
        }
        startedModels.append(model)
        startedPlans.append(plan)
        let state = activeDownloads[model.id] ?? DownloadState(model: model)
        activeDownloads[model.id] = state
        return state
    }

    public func retryDownload(id: String) async {
        retriedIDs.append(id)
    }

    public func cancelDownload(id: String) {
        cancelledIDs.append(id)
    }
}
