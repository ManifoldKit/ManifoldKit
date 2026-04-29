import Foundation

/// Protocol surface consumed by the stock model-management UI.
///
/// `BaseChatHuggingFace` provides the concrete `BackgroundDownloadManager`
/// implementation. Keeping this protocol in `BaseChatInference` lets consumers
/// opt out of the HuggingFace target without breaking compilation in shared UI
/// code that only needs dependency injection.
@MainActor
public protocol BackgroundDownloadManaging: AnyObject {
    var activeDownloads: [String: DownloadState] { get }
    func reconnectBackgroundSession()
    func startDownload(_ model: DownloadableModel, plan: ModelDownloadPlan) async throws -> DownloadState
    func retryDownload(id: String) async
    func cancelDownload(id: String)
}
