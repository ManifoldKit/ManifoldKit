import Foundation

// MARK: - Protocol

/// Provides HuggingFace Hub API operations (search, model info, URL construction).
///
/// Concrete implementations live in `ManifoldHuggingFace`, letting chat-only
/// builds compile against the protocol surface without pulling the downloader in.
public protocol HuggingFaceServiceProtocol: Sendable {
    /// Searches HuggingFace for text-generation models matching the query.
    ///
    /// Results include one `DownloadableModel` per downloadable file (each GGUF
    /// quant variant is a separate row; MLX repos produce a single row).
    ///
    /// - Parameters:
    ///   - query: The search string sent to the HuggingFace API.
    ///   - limit: Maximum number of repos to fetch from the API before filtering. Defaults to 40.
    func searchModels(query: String, limit: Int) async throws -> [DownloadableModel]

    /// Returns curated models appropriate for the given device size recommendation.
    func curatedModels(for recommendation: ModelSizeRecommendation) -> [DownloadableModel]

    /// Fetches all downloadable files (GGUF + MLX) for a specific HuggingFace repo.
    func getModelFiles(repoID: String) async throws -> [DownloadableModel]

    /// Resolves the concrete file download plan for a model.
    func downloadPlan(for model: DownloadableModel) async throws -> ModelDownloadPlan

    /// Constructs the direct download URL for a model file on HuggingFace.
    func downloadURL(for model: DownloadableModel) -> URL
}

public extension HuggingFaceServiceProtocol {
    /// Searches HuggingFace using the default limit of 40 repos.
    func searchModels(query: String) async throws -> [DownloadableModel] {
        try await searchModels(query: query, limit: 40)
    }
}
