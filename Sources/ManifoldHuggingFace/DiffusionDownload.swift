#if HuggingFace
import ManifoldInference
import Foundation
import HuggingFace
import os

/// Progress signal emitted while a diffusion model is being downloaded.
///
/// The download streams multiple files (UNet, VAE, text encoder(s), tokenizer(s),
/// scheduler config); progress is summed across them so the host can render a
/// single bar.
public struct DiffusionDownloadProgress: Sendable, Hashable {
    /// Current file's relative path inside the snapshot
    /// (e.g. `"unet/diffusion_pytorch_model.safetensors"`).
    public let currentFile: String
    /// Bytes received across **all** files so far.
    public let totalBytesReceived: Int64
    /// Total bytes expected across all files (sum of `Content-Length`s when known).
    public let totalBytesExpected: Int64
    /// Index of the file currently being downloaded (1-based).
    public let currentFileIndex: Int
    /// Total number of files in the snapshot.
    public let totalFileCount: Int

    public init(
        currentFile: String,
        totalBytesReceived: Int64,
        totalBytesExpected: Int64,
        currentFileIndex: Int,
        totalFileCount: Int
    ) {
        self.currentFile = currentFile
        self.totalBytesReceived = totalBytesReceived
        self.totalBytesExpected = totalBytesExpected
        self.currentFileIndex = currentFileIndex
        self.totalFileCount = totalFileCount
    }

    /// Fractional completion in `[0, 1]`, or `0` when the total is unknown.
    public var fractionCompleted: Double {
        guard totalBytesExpected > 0 else { return 0 }
        return min(1.0, Double(totalBytesReceived) / Double(totalBytesExpected))
    }
}

public extension HuggingFaceService {

    /// Downloads a diffusion model from a HuggingFace repository.
    ///
    /// Resolves the manifest (`model_index.json`) to determine which submodules
    /// the snapshot carries (UNet, VAE, one or two text encoders, tokenizer(s),
    /// scheduler), then sequentially downloads each required file using the
    /// `urlSession` argument (or a freshly created ephemeral session when nil).
    /// Each file is validated via
    /// ``DownloadFileValidator/validate(_:diffusionRole:expectedSize:)`` before
    /// the next one starts; a failure aborts the whole download.
    ///
    /// Sequential downloads keep the implementation small and let the validator
    /// surface a corrupt file before consuming bandwidth on the rest. The runtime
    /// can layer concurrency on top later if it matters in practice.
    ///
    /// On failure, files written before the error are left in place — callers
    /// that need atomicity should download into a staging directory and only
    /// move on success. The returned ``ImageModelInfo`` carries the total
    /// on-disk byte count summed across every fetched file.
    ///
    /// - Parameters:
    ///   - repoID: HuggingFace repository ID (e.g. `"stabilityai/sdxl-turbo"`).
    ///   - destinationDirectory: Directory the snapshot should be written into.
    ///     Created if it does not exist.
    ///   - displayName: Human-readable name for the resulting `ImageModelInfo`.
    ///     Defaults to the last path component of `repoID`.
    ///   - urlSession: URL session used for the file downloads. Tests inject a
    ///     `URLSession` configured with `MockURLProtocol`. When `nil`, a fresh
    ///     ephemeral session is created for this call (the underlying
    ///     `HubClient`'s session is **not** reused — manifest fetching shares
    ///     `HubClient`, but file streaming runs through this dedicated session
    ///     so per-call cancellation is straightforward). Pass an explicit
    ///     session if you need shared auth headers or a custom user-agent.
    ///   - progress: Called with cumulative progress as bytes arrive.
    /// - Returns: An `ImageModelInfo` whose `format == .mlxDiffusion` and whose
    ///   `huggingFaceRepoID == repoID`.
    /// - Throws: `HuggingFaceError.invalidDownloadedFile` for manifest-parse,
    ///   path-traversal, and validation failures; `HuggingFaceError.downloadFailed`
    ///   for transport errors.
    func downloadDiffusionModel(
        from repoID: String,
        to destinationDirectory: URL,
        displayName: String? = nil,
        urlSession: URLSession? = nil,
        progress: @escaping @Sendable (DiffusionDownloadProgress) -> Void
    ) async throws -> ImageModelInfo {
        // Route through the centralised factory so the redirect guard is
        // installed on every fallback session. HuggingFace ↔ CDN redirects
        // are common and benign; an attacker-controlled redirect into IMDS
        // or a LAN IP would otherwise be followed silently.
        let session = urlSession ?? URLSessionFactory.ephemeral()
        let resolvedDisplayName = displayName ?? repoID.split(separator: "/").last.map(String.init) ?? repoID

        let parentDirectory = destinationDirectory.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
        let stagingDirectory = parentDirectory.appendingPathComponent(
            ".staging-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)

        do {
            return try await downloadDiffusionModelAtomically(
                from: repoID,
                to: destinationDirectory,
                stagingDirectory: stagingDirectory,
                displayName: resolvedDisplayName,
                using: session,
                progress: progress
            )
        } catch {
            do {
                try FileManager.default.removeItem(at: stagingDirectory)
            } catch {
                Log.download.warning("Failed to remove diffusion staging directory: \(error.localizedDescription)")
            }
            throw error
        }
    }

    private func downloadDiffusionModelAtomically(
        from repoID: String,
        to destinationDirectory: URL,
        stagingDirectory: URL,
        displayName resolvedDisplayName: String,
        using session: URLSession,
        progress: @escaping @Sendable (DiffusionDownloadProgress) -> Void
    ) async throws -> ImageModelInfo {

        // 1. Fetch manifest.
        let manifestRemoteURL = downloadURL(repoID: repoID, filePath: "model_index.json")
        let manifestLocalURL = stagingDirectory.appendingPathComponent("model_index.json")
        try await downloadFile(
            from: manifestRemoteURL,
            to: manifestLocalURL,
            using: session
        )
        try DownloadFileValidator.validate(manifestLocalURL, diffusionRole: .manifest, expectedSize: nil)

        // 2. Resolve submodules.
        let manifest = try parseDiffusionManifest(at: manifestLocalURL)

        // 3. Plan the file list.
        let plan = try buildDiffusionDownloadPlan(
            manifest: manifest,
            destinationDirectory: stagingDirectory
        )

        // 4. Download each file sequentially with summed progress.
        var totalBytes: Int64 = manifestLocalURL.fileSize ?? 0
        // Manifest already counted in plan.totalExpectedBytes? It isn't — the
        // manifest is fetched before planning, so add its bytes directly.
        // Plan's totalExpectedBytes is unknown until we fetch (HEAD-less impl).
        for (index, item) in plan.items.enumerated() {
            let remote = downloadURL(repoID: repoID, filePath: item.relativePath)
            try FileManager.default.createDirectory(
                at: item.localURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Snapshot for the @Sendable closure — we want a stable baseline
            // for this file's progress reports; running totals belong to the
            // outer loop.
            let baseline = totalBytes
            let totalCount = plan.items.count
            let relativePath = item.relativePath
            try await downloadFile(
                from: remote,
                to: item.localURL,
                using: session,
                onChunk: { received, expected in
                    let cumulative = baseline + received
                    // When `Content-Length` is unknown (often `-1`), keep
                    // `totalBytesExpected` at `0` so `fractionCompleted`
                    // reports as indeterminate rather than spuriously ~1.0.
                    let total: Int64 = expected > 0 ? baseline + expected : 0
                    progress(DiffusionDownloadProgress(
                        currentFile: relativePath,
                        totalBytesReceived: cumulative,
                        totalBytesExpected: total,
                        currentFileIndex: index + 1,
                        totalFileCount: totalCount
                    ))
                }
            )
            let actualSize = item.localURL.fileSize ?? 0
            totalBytes += actualSize
            try DownloadFileValidator.validate(
                item.localURL,
                diffusionRole: item.role,
                expectedSize: nil
            )
            // Final per-file emission so progress reflects the completed file
            // even when the transport never reported an intermediate chunk.
            progress(DiffusionDownloadProgress(
                currentFile: item.relativePath,
                totalBytesReceived: totalBytes,
                totalBytesExpected: totalBytes,
                currentFileIndex: index + 1,
                totalFileCount: plan.items.count
            ))
        }

        Log.download.info(
            "Diffusion download complete: \(repoID, privacy: .private) (\(plan.items.count) files, \(totalBytes) bytes)"
        )

        let info = ImageModelInfo(
            id: repoID,
            name: resolvedDisplayName,
            directoryURL: destinationDirectory,
            format: .mlxDiffusion,
            fileSize: totalBytes,
            huggingFaceRepoID: repoID
        )

        try writePackageManifest(
            for: info,
            files: ["model_index.json"] + plan.items.map(\.relativePath),
            in: stagingDirectory
        )
        if FileManager.default.fileExists(atPath: destinationDirectory.path) {
            try FileManager.default.removeItem(at: destinationDirectory)
        }
        try FileManager.default.moveItem(at: stagingDirectory, to: destinationDirectory)
        return info
    }

    private func writePackageManifest(
        for info: ImageModelInfo,
        files: [String],
        in directory: URL
    ) throws {
        let manifest = DownloadedModelPackageManifest(
            packageKind: .diffusion,
            id: info.id,
            displayName: info.name,
            format: info.format,
            huggingFaceRepoID: info.huggingFaceRepoID,
            files: files.sorted()
        )
        let data = try JSONEncoder().encode(manifest)
        try data.write(
            to: directory.appendingPathComponent(DownloadedModelPackageManifest.fileName),
            options: .atomic
        )
    }

    // MARK: - Manifest

    /// Parsed representation of a `model_index.json` manifest.
    struct DiffusionManifest: Sendable {
        /// Submodule names listed in the manifest (e.g. `"unet"`, `"vae"`,
        /// `"text_encoder"`, `"text_encoder_2"`, `"scheduler"`,
        /// `"tokenizer"`, `"tokenizer_2"`).
        let submodules: Set<String>
    }

    private func parseDiffusionManifest(at url: URL) throws -> DiffusionManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Cannot read manifest: \(error.localizedDescription)")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Manifest JSON parse failed: \(error.localizedDescription)")
        }
        guard let dict = object as? [String: Any] else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Manifest is not a JSON object")
        }
        // Diffusers manifests list submodules as `[class_name, module_name]`
        // pairs under their submodule key. Treat every key whose value is a
        // 2-element array as a submodule we need to fetch. Reject any key
        // that contains path-traversal characters before downloading anything.
        var submodules: Set<String> = []
        for (key, value) in dict {
            guard value is [Any] else { continue }
            try assertSafePathComponent(key)
            submodules.insert(key)
        }
        return DiffusionManifest(submodules: submodules)
    }

    // MARK: - Download plan

    struct DiffusionDownloadItem: Sendable {
        let relativePath: String
        let localURL: URL
        let role: DownloadFileValidator.DiffusionFileRole
    }

    struct DiffusionDownloadPlan: Sendable {
        let items: [DiffusionDownloadItem]
    }

    private func buildDiffusionDownloadPlan(
        manifest: DiffusionManifest,
        destinationDirectory: URL
    ) throws -> DiffusionDownloadPlan {
        // UNet + VAE are required for every diffusers pipeline we support.
        // Surface a clear error here rather than letting the loader trip later
        // on a missing submodule.
        for required in ["unet", "vae"] where !manifest.submodules.contains(required) {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "Manifest is missing required submodule \"\(required)\""
            )
        }

        var items: [DiffusionDownloadItem] = []

        items.append(contentsOf: try plan(
            submodule: "unet",
            weights: "diffusion_pytorch_model.safetensors",
            destinationDirectory: destinationDirectory
        ))

        items.append(contentsOf: try plan(
            submodule: "vae",
            weights: "diffusion_pytorch_model.safetensors",
            destinationDirectory: destinationDirectory
        ))

        // Text encoder(s).
        for name in ["text_encoder", "text_encoder_2"] where manifest.submodules.contains(name) {
            items.append(contentsOf: try plan(
                submodule: name,
                weights: "model.safetensors",
                destinationDirectory: destinationDirectory
            ))
        }

        // Tokenizer(s).
        for name in ["tokenizer", "tokenizer_2"] where manifest.submodules.contains(name) {
            try assertSafePathComponent(name)
            let dir = destinationDirectory.appendingPathComponent(name, isDirectory: true)
            items.append(DiffusionDownloadItem(
                relativePath: "\(name)/vocab.json",
                localURL: dir.appendingPathComponent("vocab.json"),
                role: .tokenizerVocab
            ))
            items.append(DiffusionDownloadItem(
                relativePath: "\(name)/merges.txt",
                localURL: dir.appendingPathComponent("merges.txt"),
                role: .tokenizerMerges
            ))
        }

        // Scheduler config.
        if manifest.submodules.contains("scheduler") {
            try assertSafePathComponent("scheduler")
            items.append(DiffusionDownloadItem(
                relativePath: "scheduler/scheduler_config.json",
                localURL: destinationDirectory
                    .appendingPathComponent("scheduler", isDirectory: true)
                    .appendingPathComponent("scheduler_config.json"),
                role: .submoduleConfig
            ))
        }

        return DiffusionDownloadPlan(items: items)
    }

    private func plan(
        submodule: String,
        weights: String,
        destinationDirectory: URL
    ) throws -> [DiffusionDownloadItem] {
        try assertSafePathComponent(submodule)
        try assertSafePathComponent(weights)
        let dir = destinationDirectory.appendingPathComponent(submodule, isDirectory: true)
        return [
            DiffusionDownloadItem(
                relativePath: "\(submodule)/config.json",
                localURL: dir.appendingPathComponent("config.json"),
                role: .submoduleConfig
            ),
            DiffusionDownloadItem(
                relativePath: "\(submodule)/\(weights)",
                localURL: dir.appendingPathComponent(weights),
                role: .weights
            ),
        ]
    }

    // MARK: - Path-traversal hygiene

    /// Rejects any submodule or file name that could escape the destination
    /// directory. The validator runs **before** any HTTP request goes out, so
    /// a hostile manifest cannot trick us into writing somewhere unexpected.
    private func assertSafePathComponent(_ component: String) throws {
        if component.isEmpty
            || component == "."
            || component == ".."
            || component.contains("/")
            || component.contains("\\")
            || component.hasPrefix(".") {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "Unsafe path component in manifest: \"\(component)\""
            )
        }
    }

    // MARK: - File download

    /// Downloads a single file to disk using `URLSession.bytes(for:)`, reporting
    /// progress periodically.
    private func downloadFile(
        from remote: URL,
        to local: URL,
        using session: URLSession,
        onChunk: (@Sendable (_ received: Int64, _ expected: Int64) -> Void)? = nil
    ) async throws {
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(from: remote)
        } catch {
            throw HuggingFaceError.downloadFailed(underlying: error)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HuggingFaceError.downloadFailed(
                underlying: NSError(
                    domain: "ManifoldHuggingFace",
                    code: http.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(remote.lastPathComponent)"]
                )
            )
        }

        // Ensure parent directory exists (caller may have created it; idempotent).
        try FileManager.default.createDirectory(
            at: local.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Explicitly remove any leftover from a previous attempt so a partial
        // file's tail can't survive into the new download. `createFile(...)`
        // is documented to overwrite, but a stale file could otherwise pass
        // size/header validation if the new write is short.
        if FileManager.default.fileExists(atPath: local.path) {
            try? FileManager.default.removeItem(at: local)
        }
        FileManager.default.createFile(atPath: local.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: local) else {
            throw HuggingFaceError.invalidDownloadedFile(reason: "Cannot open file for writing: \(local.lastPathComponent)")
        }
        defer { try? handle.close() }

        let expected = response.expectedContentLength
        let flushAt = 64 * 1024
        let reportEvery: Int64 = 256 * 1024 // emit progress every 256 KB
        var buffer = Data()
        buffer.reserveCapacity(flushAt)
        var received: Int64 = 0
        var lastReported: Int64 = 0

        // `AsyncBytes` yields one byte at a time but the runtime buffers
        // upstream — accumulating into `buffer` and flushing in 64 KB chunks
        // amortises the FileHandle.write cost without an extra wrapping API.
        do {
            for try await byte in bytes {
                buffer.append(byte)
                received += 1
                if buffer.count >= flushAt {
                    try handle.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
                if received - lastReported >= reportEvery {
                    onChunk?(received, expected)
                    lastReported = received
                }
            }
        } catch {
            throw HuggingFaceError.downloadFailed(underlying: error)
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        onChunk?(received, expected)
    }
}

// MARK: - URL size helper

private extension URL {
    /// On-disk size of the file at this URL, or `nil` when unavailable.
    var fileSize: Int64? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? Int64)
    }
}
#endif
