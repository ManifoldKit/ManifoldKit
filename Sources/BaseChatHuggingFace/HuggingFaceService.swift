#if HuggingFace
import BaseChatInference
import Foundation
import HuggingFace
import os

/// Concrete `HuggingFaceServiceProtocol` backed by the `swift-huggingface` SDK.
public final class HuggingFaceService: HuggingFaceServiceProtocol {
    private let hubClient: HubClient

    /// Creates a service backed by the given Hugging Face Hub client.
    ///
    /// - Parameter hubClient: The Hub client used for API requests and repo operations.
    ///   Defaults to `.default`, which uses the shared Hub configuration.
    public init(hubClient: HubClient = .default) {
        self.hubClient = hubClient
    }

    public func searchModels(query: String, limit: Int = 40) async throws -> [DownloadableModel] {
        Log.network.info("Searching HuggingFace for: \(query, privacy: .private)")

        let response: PaginatedResponse<Model>
        do {
            response = try await hubClient.listModels(
                search: query,
                sort: "downloads",
                direction: .descending,
                limit: limit,
                full: true,
                pipelineTag: "text-generation"
            )
        } catch {
            Log.network.error("HuggingFace search failed: \(error.localizedDescription)")
            throw HuggingFaceError.searchFailed(underlying: error)
        }

        let downloadableRepos = response.items.filter(isDownloadableRepo)

        var allModels: [DownloadableModel] = []
        await withTaskGroup(of: [DownloadableModel].self) { group in
            for model in downloadableRepos {
                group.addTask {
                    do {
                        let detailed = try await self.hubClient.getModel(
                            model.id,
                            full: true,
                            filesMetadata: true
                        )
                        return self.convertModelToDownloadables(detailed)
                    } catch {
                        Log.network.warning("Failed to fetch details for \(model.id): \(error)")
                        return self.convertModelToDownloadables(model)
                    }
                }
            }
            for await models in group {
                allModels.append(contentsOf: models)
            }
        }

        Log.network.info("Search returned \(allModels.count) downloadable files from \(downloadableRepos.count) repos")
        return allModels
    }

    public func curatedModels(for recommendation: ModelSizeRecommendation) -> [DownloadableModel] {
        CuratedModel.all
            .filter { $0.recommendedFor.contains(recommendation) }
            .map(DownloadableModel.init(from:))
    }

    public func getModelFiles(repoID: String) async throws -> [DownloadableModel] {
        Log.network.info("Fetching files for repo: \(repoID)")

        guard let repoIdentifier = Repo.ID(rawValue: repoID) else {
            throw HuggingFaceError.invalidRepoID(repoID)
        }

        let model: Model
        do {
            model = try await hubClient.getModel(
                repoIdentifier,
                full: true,
                filesMetadata: true
            )
        } catch {
            Log.network.error("Failed to fetch model \(repoID): \(error.localizedDescription)")
            throw HuggingFaceError.modelNotFound(repoID: repoID)
        }

        let downloadables = convertModelToDownloadables(model)
        Log.network.info("Found \(downloadables.count) downloadable files in \(repoID)")
        return downloadables
    }

    public func downloadPlan(for model: DownloadableModel) async throws -> ModelDownloadPlan {
        switch model.modelType {
        case .gguf:
            return .singleFile(url: downloadURL(for: model))
        case .mlx:
            guard let repoIdentifier = Repo.ID(rawValue: model.repoID) else {
                throw HuggingFaceError.invalidRepoID(model.repoID)
            }
            let detailed: Model
            do {
                detailed = try await hubClient.getModel(
                    repoIdentifier,
                    full: true,
                    filesMetadata: true
                )
            } catch {
                Log.network.error("Failed to fetch MLX snapshot for \(model.repoID): \(error.localizedDescription)")
                throw HuggingFaceError.modelNotFound(repoID: model.repoID)
            }
            let files = snapshotFiles(from: detailed)
            guard !files.isEmpty else {
                throw HuggingFaceError.invalidDownloadedFile(reason: "MLX repo has no snapshot files to download")
            }
            return .snapshot(files: files)
        case .foundation:
            throw HuggingFaceError.invalidDownloadedFile(reason: "Foundation models cannot be downloaded")
        }
    }

    public func downloadURL(for model: DownloadableModel) -> URL {
        downloadURL(repoID: model.repoID, filePath: model.fileName)
    }

    func downloadURL(repoID: String, filePath: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        let segments = ([repoID, "resolve", "main"] + filePath.components(separatedBy: "/"))
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
        components.percentEncodedPath = "/" + segments.joined(separator: "/")
        guard let url = components.url else {
            Log.network.error("Failed to build download URL for \(repoID)/\(filePath)")
            return URL(string: "https://huggingface.co")!
        }
        return url
    }

    internal func convertModelToDownloadables(_ model: Model) -> [DownloadableModel] {
        guard let siblings = model.siblings else { return [] }

        let repoID = model.id.rawValue
        var results: [DownloadableModel] = []

        let ggufFiles = siblings.filter { $0.relativeFilename.lowercased().hasSuffix(".gguf") }
        for file in ggufFiles {
            let sizeBytes = UInt64(file.size ?? 0)
            let fileName = file.relativeFilename
            let quantName = Self.cleanDisplayName(from: String(fileName.dropLast(5)))
            results.append(DownloadableModel(
                repoID: repoID,
                fileName: fileName,
                displayName: quantName,
                modelType: .gguf,
                sizeBytes: sizeBytes,
                downloads: model.downloads,
                isCurated: false,
                promptTemplate: nil,
                description: nil
            ))
        }

        let snapshotFiles = snapshotFiles(from: model)
        if !snapshotFiles.isEmpty {
            let repoName = model.id.name
            results.append(DownloadableModel(
                repoID: repoID,
                fileName: repoName,
                displayName: Self.cleanDisplayName(from: repoName),
                modelType: .mlx,
                sizeBytes: snapshotFiles.reduce(0) { $0 + $1.sizeBytes },
                downloads: model.downloads,
                isCurated: false,
                promptTemplate: nil,
                description: nil
            ))
        }

        return results
    }

    private func isDownloadableRepo(_ model: Model) -> Bool {
        guard let siblings = model.siblings else { return false }
        return hasGGUFFiles(in: siblings) || isMLXSnapshot(model)
    }

    private func hasGGUFFiles(in siblings: [Model.SiblingInfo]) -> Bool {
        siblings.contains { $0.relativeFilename.lowercased().hasSuffix(".gguf") }
    }

    private func isMLXSnapshot(_ model: Model) -> Bool {
        guard let siblings = model.siblings else { return false }
        let lowercasedNames = siblings.map { $0.relativeFilename.lowercased() }
        let hasConfig = lowercasedNames.contains("config.json")
        let hasSafetensors = lowercasedNames.contains { $0.hasSuffix(".safetensors") }
        return hasConfig && hasSafetensors && hasMLXRepoMarker(model.id.rawValue)
    }

    private func hasMLXRepoMarker(_ repoID: String) -> Bool {
        let lower = repoID.lowercased()
        if lower.hasPrefix("mlx-community/") { return true }
        let tokens = lower.components(separatedBy: CharacterSet(charactersIn: "/-_ .")).filter { !$0.isEmpty }
        return tokens.contains("mlx")
    }

    private func snapshotFiles(from model: Model) -> [ModelDownloadFile] {
        guard let siblings = model.siblings, isMLXSnapshot(model) else { return [] }
        return siblings.map { file in
            ModelDownloadFile(
                relativePath: file.relativeFilename,
                url: downloadURL(repoID: model.id.rawValue, filePath: file.relativeFilename),
                sizeBytes: UInt64(file.size ?? 0)
            )
        }
    }

    private static func cleanDisplayName(from name: String) -> String {
        name
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}
#endif
