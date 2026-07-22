import ManifoldInference
import Foundation
import HuggingFace
import os

/// Concrete `HuggingFaceServiceProtocol` backed by the `swift-huggingface` SDK.
public final class HuggingFaceService: HuggingFaceServiceProtocol {
    private let hubClient: HubClient
    private let activityCenter: NetworkActivityCenter

    /// Creates a service backed by the given Hugging Face Hub client.
    ///
    /// - Parameters:
    ///   - hubClient: The Hub client used for API requests and repo operations.
    ///     Defaults to `.default`, which uses the shared Hub configuration.
    ///   - activityCenter: Center to notify on metadata fetch start/end so the
    ///     framework-wide network indicator reflects HF traffic even when the
    ///     SDK bypasses ``URLSessionFactory``. Defaults to ``NetworkActivityCenter/shared``.
    public init(
        hubClient: HubClient = .default,
        activityCenter: NetworkActivityCenter = .shared
    ) {
        self.hubClient = hubClient
        self.activityCenter = activityCenter
    }

    /// Wraps a `hubClient.*` call with begin/end on the activity center so
    /// consumer observers see metadata fetches alongside downloads.
    ///
    /// Hops to `@MainActor` for both the begin and the end — the center is
    /// `@MainActor`-isolated and SDK calls happen on whatever context the
    /// caller is on.
    private func trackingMetadataFetch<T>(
        host: String = "huggingface.co",
        _ body: () async throws -> T
    ) async rethrows -> T {
        let center = activityCenter
        let token = await MainActor.run { center.begin(kind: .metadata, host: host) }
        defer {
            // `Task { @MainActor }` is fire-and-forget — token release does
            // not need to block the caller's return.
            Task { @MainActor in center.end(token) }
        }
        return try await body()
    }

    public func searchModels(query: String, limit: Int = 40) async throws -> [DownloadableModel] {
        Log.network.info("Searching HuggingFace for: \(query, privacy: .private)")

        let response: PaginatedResponse<Model>
        do {
            response = try await trackingMetadataFetch {
                try await hubClient.listModels(
                    search: query,
                    sort: "downloads",
                    direction: .descending,
                    limit: limit,
                    full: true,
                    pipelineTag: "text-generation"
                )
            }
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
                        let detailed = try await self.trackingMetadataFetch {
                            try await self.hubClient.getModel(
                                model.id,
                                full: true,
                                filesMetadata: true
                            )
                        }
                        return await self.convertModelToDownloadables(detailed)
                    } catch {
                        Log.network.warning("Failed to fetch details for \(model.id): \(error)")
                        return await self.convertModelToDownloadables(model)
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
            model = try await trackingMetadataFetch {
                try await hubClient.getModel(
                    repoIdentifier,
                    full: true,
                    filesMetadata: true
                )
            }
        } catch {
            Log.network.error("Failed to fetch model \(repoID): \(error.localizedDescription)")
            throw HuggingFaceError.modelNotFound(repoID: repoID)
        }

        let downloadables = await convertModelToDownloadables(model)
        Log.network.info("Found \(downloadables.count) downloadable files in \(repoID)")
        return downloadables
    }

    public func downloadPlan(for model: DownloadableModel) async throws -> ModelDownloadPlan {
        switch model.modelType {
        case .gguf:
            // Forward `expectedSHA256` (when set) so the validator can enforce
            // the digest after download. For MLX snapshots, per-file checksums
            // are out of scope for Phase 1 — those entries stay unverified.
            let checksum = model.expectedSHA256.map {
                ModelFileChecksum(algorithm: .sha256, hexDigest: $0)
            }
            return .singleFile(url: downloadURL(for: model), expectedChecksum: checksum)
        case .mlx:
            guard let repoIdentifier = Repo.ID(rawValue: model.repoID) else {
                throw HuggingFaceError.invalidRepoID(model.repoID)
            }
            let detailed: Model
            do {
                detailed = try await trackingMetadataFetch {
                    try await hubClient.getModel(
                        repoIdentifier,
                        full: true,
                        filesMetadata: true
                    )
                }
            } catch {
                Log.network.error("Failed to fetch MLX snapshot for \(model.repoID): \(error.localizedDescription)")
                throw HuggingFaceError.modelNotFound(repoID: model.repoID)
            }
            let files = model.packageKind == .diffusion
                ? diffusionPackageFiles(from: detailed)
                : snapshotFiles(from: detailed)
            guard !files.isEmpty else {
                throw HuggingFaceError.invalidDownloadedFile(reason: "Repo has no package files to download")
            }
            return .snapshot(files: files)
        case .foundation:
            throw HuggingFaceError.invalidDownloadedFile(reason: "Foundation models cannot be downloaded")
        default:
            throw HuggingFaceError.invalidDownloadedFile(reason: "Unsupported model type '\(model.modelType.rawValue)' — no download plan is registered for it")
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

    internal func convertModelToDownloadables(_ model: Model) async -> [DownloadableModel] {
        guard let siblings = model.siblings else { return [] }

        let repoID = model.id.rawValue
        var results: [DownloadableModel] = []

        let ggufFiles = siblings.filter { $0.relativeFilename.lowercased().hasSuffix(".gguf") }
        // The Hub model-detail request already asks for blob metadata
        // (`getModel(..., filesMetadata: true)` → `blobs=true`), which the Hub
        // API answers with a `siblings[].lfs.oid` sha256 per LFS file — but
        // swift-huggingface's `Model.SiblingInfo` does not decode that field
        // (only `rfilename`/`size`), so it is silently discarded before it
        // ever reaches ManifoldKit. Recover it via `HubClient.getFile`, whose
        // `File.etag` is documented (`LocalDownloadFileMetadata.etag`) to be
        // the LFS sha256 for LFS-tracked files. One HEAD request per GGUF
        // file, run concurrently; best-effort — see `ggufChecksums(repoID:files:)`.
        let checksums = await ggufChecksums(repoID: model.id, files: ggufFiles)
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
                description: nil,
                expectedSHA256: checksums[fileName]
            ))
        }

        // Diffusion and MLX-snapshot entries below deliberately leave
        // expectedSHA256 nil: `fileName` here names a whole package directory
        // (many underlying files), not a single downloaded artifact, so there
        // is no single sha256 that could describe it. Per-file verification
        // for these package kinds is out of scope (mirrors the existing note
        // on `downloadPlan(for:)` above).
        let diffusionFiles = diffusionPackageFiles(from: model)
        if !diffusionFiles.isEmpty {
            let repoName = model.id.name
            results.append(DownloadableModel(
                repoID: repoID,
                fileName: packageDirectoryName(for: repoID),
                displayName: Self.cleanDisplayName(from: repoName),
                modelType: .mlx,
                sizeBytes: diffusionFiles.reduce(0) { $0 + $1.sizeBytes },
                downloads: model.downloads,
                isCurated: false,
                promptTemplate: nil,
                description: nil,
                packageKind: .diffusion
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
                description: nil,
                packageKind: .mlxSnapshot
            ))
        }

        return results
    }

    /// Fetches the LFS content sha256 for each GGUF sibling via one HEAD
    /// request per file (`HubClient.getFile`). Runs the HEAD requests
    /// concurrently. Best-effort: a failed request, a non-LFS file, or an
    /// `etag` that doesn't look like a sha256 hex digest is dropped rather
    /// than surfaced as an error — `DownloadableModel.expectedSHA256` is
    /// documented to skip verification when `nil`, so an unresolved checksum
    /// degrades to "unverified" rather than blocking the search/listing.
    private func ggufChecksums(repoID: Repo.ID, files: [Model.SiblingInfo]) async -> [String: String] {
        guard !files.isEmpty else { return [:] }
        var results: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for file in files {
                group.addTask {
                    do {
                        let info = try await self.hubClient.getFile(at: file.relativeFilename, in: repoID)
                        guard info.isLFS, let etag = info.etag, Self.isSHA256Hex(etag) else {
                            return (file.relativeFilename, nil)
                        }
                        return (file.relativeFilename, etag)
                    } catch {
                        Log.network.warning("Failed to fetch LFS checksum for \(repoID.rawValue)/\(file.relativeFilename): \(error.localizedDescription)")
                        return (file.relativeFilename, nil)
                    }
                }
            }
            for await (fileName, checksum) in group {
                if let checksum {
                    results[fileName] = checksum
                }
            }
        }
        return results
    }

    private static func isSHA256Hex(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy(\.isHexDigit)
    }

    private func isDownloadableRepo(_ model: Model) -> Bool {
        guard let siblings = model.siblings else { return false }
        return hasGGUFFiles(in: siblings) || isMLXSnapshot(model) || isDiffusionPackage(model)
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

    private func isDiffusionPackage(_ model: Model) -> Bool {
        guard let siblings = model.siblings else { return false }
        let names = Set(siblings.map { $0.relativeFilename.lowercased() })
        let hasManifest = names.contains("model_index.json")
        let hasVAE = names.contains("vae/config.json")
            && names.contains("vae/diffusion_pytorch_model.safetensors")
        let hasDenoiser = names.contains("unet/diffusion_pytorch_model.safetensors")
            || names.contains("transformer/diffusion_pytorch_model.safetensors")
            || names.contains("transformer/model.safetensors")
        let hasTextEncoder = names.contains("text_encoder/model.safetensors")
            || names.contains("text_encoder_2/model.safetensors")
        let hasScheduler = names.contains("scheduler/scheduler_config.json")
        return hasManifest && hasVAE && hasDenoiser && hasTextEncoder && hasScheduler
    }

    private func diffusionPackageFiles(from model: Model) -> [ModelDownloadFile] {
        guard let siblings = model.siblings, isDiffusionPackage(model) else { return [] }
        let allowed: (String) -> Bool = { name in
            name == "model_index.json"
                || name.hasSuffix("/config.json")
                || name.hasSuffix("/scheduler_config.json")
                || name.hasSuffix(".safetensors")
                || name.hasSuffix("/vocab.json")
                || name.hasSuffix("/merges.txt")
        }
        return siblings
            .filter { allowed($0.relativeFilename.lowercased()) }
            .map { file in
                ModelDownloadFile(
                    relativePath: file.relativeFilename,
                    url: downloadURL(repoID: model.id.rawValue, filePath: file.relativeFilename),
                    sizeBytes: UInt64(file.size ?? 0)
                )
            }
    }

    private func packageDirectoryName(for repoID: String) -> String {
        repoID.replacingOccurrences(of: "/", with: "__")
    }

    private static func cleanDisplayName(from name: String) -> String {
        name
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }
}
