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
    ///     `URLSession` configured with `MockURLProtocol`. When `nil`, a background
    ///     session is created via ``URLSessionFactory/background(identifier:additionalDownloadDelegate:)``
    ///     so downloads survive app suspension on iOS — the underlying
    ///     `HubClient`'s session is **not** reused. Pass an explicit session if
    ///     you need shared auth headers, a custom user-agent, or deterministic
    ///     test interception via `MockURLProtocol`.
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
        preferFP16: Bool = true,
        urlSession: URLSession? = nil,
        progress: @escaping @Sendable (DiffusionDownloadProgress) -> Void
    ) async throws -> ImageModelInfo {
        // When no session is provided (production path) use a background
        // URLSession so downloads survive app suspension on iOS.
        // Background sessions require a delegate — completion-handler tasks
        // are silently ignored by the OS on background configurations.
        //
        // When the caller injects a session (tests, custom auth headers) the
        // existing completion-handler path is kept intact so MockURLProtocol
        // continues to work without a wired-up session delegate.
        let delegate: DiffusionDownloadDelegate?
        let session: URLSession
        if let urlSession {
            delegate = nil
            session = urlSession
        } else {
            let d = DiffusionDownloadDelegate()
            delegate = d
            session = URLSessionFactory.background(
                identifier: ManifoldConfiguration.shared.downloadSessionIdentifier + ".diffusion",
                additionalDownloadDelegate: d
            )
        }
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
                preferFP16: preferFP16,
                using: session,
                delegate: delegate,
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
        preferFP16: Bool,
        using session: URLSession,
        delegate: DiffusionDownloadDelegate?,
        progress: @escaping @Sendable (DiffusionDownloadProgress) -> Void
    ) async throws -> ImageModelInfo {

        // Adopt Hub's `<root>/models/<org>/<name>` directory convention so
        // `HubApi.localRepoLocation` (used by mlx-swift-examples StableDiffusion)
        // resolves files without a bridging symlink. The package-readiness
        // manifest still lives at the staging/destination root — only the
        // snapshot files relocate.
        let hubLeafStaging = try Self.hubLeafDirectory(in: stagingDirectory, repoID: repoID)
        try FileManager.default.createDirectory(at: hubLeafStaging, withIntermediateDirectories: true)

        // 1. Fetch manifest.
        let manifestRemoteURL = downloadURL(repoID: repoID, filePath: "model_index.json")
        let manifestLocalURL = hubLeafStaging.appendingPathComponent("model_index.json")
        try await downloadFile(
            from: manifestRemoteURL,
            to: manifestLocalURL,
            using: session,
            delegate: delegate
        )
        try DownloadFileValidator.validate(manifestLocalURL, diffusionRole: .manifest, expectedSize: nil)

        // 2. Resolve submodules.
        let manifest = try parseDiffusionManifest(at: manifestLocalURL)

        // 3. Plan the file list. Probe fp16 availability first when the
        // caller hasn't opted out; the plan builder substitutes the
        // `.fp16.safetensors` filename per weight file when present and
        // records which variant was picked overall.
        let fp16Available: Set<String>
        if preferFP16 {
            fp16Available = await probeFP16Availability(
                repoID: repoID,
                candidates: Self.candidateWeightPaths(for: manifest),
                using: session
            )
        } else {
            fp16Available = []
        }
        // Plan items resolve their `localURL` against the Hub leaf so the
        // on-disk layout already matches what `HubApi.localRepoLocation`
        // expects. `relativePath` stays unprefixed (it's the HF-side
        // relative path used to fetch each file and to validate the
        // package); the package-manifest writer below adds the
        // `models/<repoID>/` prefix so the readiness check at discovery
        // time finds the files at the correct location.
        let plan = try buildDiffusionDownloadPlan(
            manifest: manifest,
            destinationDirectory: hubLeafStaging,
            fp16AvailablePaths: fp16Available
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

            Log.download.info("[\(index + 1)/\(plan.items.count)] starting: \(item.relativePath, privacy: .public)")
            try await downloadFile(
                from: remote,
                to: item.localURL,
                using: session,
                delegate: delegate,
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
            Log.download.info("[\(index + 1)/\(plan.items.count)] download done: \(item.relativePath, privacy: .public)")

            let actualSize = item.localURL.fileSize ?? 0
            totalBytes += actualSize

            Log.download.info("[\(index + 1)/\(plan.items.count)] validating: \(item.relativePath, privacy: .public)")
            try DownloadFileValidator.validate(
                item.localURL,
                diffusionRole: item.role,
                expectedSize: nil
            )
            Log.download.info("[\(index + 1)/\(plan.items.count)] validated: \(item.relativePath, privacy: .public)")

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

        // FLUX models have a `transformer` submodule; SD/SDXL models have `unet`.
        let format: ImageModelFormat = manifest.submodules.contains("transformer")
            ? .fluxSchnell : .mlxDiffusion

        // `directoryURL` points at the Hub leaf so backends that resolve
        // the parent for `HubApi(downloadBase:)` walk a stable three
        // components up (drop `<name>`, `<org>`, `models`). The package
        // manifest stays at the package root for discovery.
        let hubLeafURL = try Self.hubLeafDirectory(in: destinationDirectory, repoID: repoID)
        let info = ImageModelInfo(
            id: repoID,
            name: resolvedDisplayName,
            directoryURL: hubLeafURL,
            format: format,
            fileSize: totalBytes,
            huggingFaceRepoID: repoID,
            variant: plan.variant
        )

        Log.download.info("Writing package manifest (variant=\(info.variant.rawValue, privacy: .public))")
        let hubPrefix = "models/\(repoID)/"
        try writePackageManifest(
            for: info,
            files: ([ "model_index.json" ] + plan.items.map(\.relativePath))
                .map { hubPrefix + $0 },
            in: stagingDirectory
        )
        Log.download.info("Moving staging directory to destination")
        if FileManager.default.fileExists(atPath: destinationDirectory.path) {
            try FileManager.default.removeItem(at: destinationDirectory)
        }
        try FileManager.default.moveItem(at: stagingDirectory, to: destinationDirectory)
        Log.download.info("Install complete")
        return info
    }

    /// Resolves the `<root>/models/<org>/<name>` path that Hub's
    /// `localRepoLocation` produces for a given `org/name` repo ID.
    /// Validates each path component before joining so a hostile repo ID
    /// cannot escape `root`.
    internal static func hubLeafDirectory(in root: URL, repoID: String) throws -> URL {
        let parts = repoID.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "Repo ID must be in <org>/<name> form: \"\(repoID)\""
            )
        }
        var url = root.appendingPathComponent("models", isDirectory: true)
        for part in parts {
            if part.isEmpty || part == "." || part == ".." || part.contains("\\") || part.hasPrefix(".") {
                throw HuggingFaceError.invalidDownloadedFile(
                    reason: "Unsafe path component in repo ID: \"\(part)\""
                )
            }
            url = url.appendingPathComponent(part, isDirectory: true)
        }
        return url
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
            files: files.sorted(),
            variant: info.variant
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
        /// Variant chosen across the whole package. `.fp16` whenever **any**
        /// weight file was substituted with its `.fp16.safetensors` sibling
        /// — diffusion runtimes load the package as a unit, so the variant
        /// reported in metadata reflects the precision that's actually on
        /// disk for the bulk weights (UNet + VAE + text encoder(s)). A
        /// partial fp16 set still saves substantial bytes, so we report fp16
        /// rather than papering over the mix as full-precision.
        let variant: PrecisionVariant
    }

    /// Pure detection rule for fp16 vs full-precision selection.
    ///
    /// Returns `.fp16` if **any** of `weightPaths` has a `.fp16.safetensors`
    /// sibling in `fp16Available`. Otherwise `.fullPrecision`. The rule
    /// stays deliberately permissive: even a partial fp16 set (e.g. UNet
    /// only, no VAE fp16) is worth labelling as fp16 so consumers can see
    /// "this package isn't pure fp32" without re-walking the directory.
    internal static func selectVariant(
        weightPaths: [String],
        fp16Available: Set<String>
    ) -> PrecisionVariant {
        for path in weightPaths {
            if fp16Available.contains(fp16Path(for: path)) {
                return .fp16
            }
        }
        return .fullPrecision
    }

    /// Maps a full-precision weight path (`unet/diffusion_pytorch_model.safetensors`)
    /// to its fp16 sibling (`unet/diffusion_pytorch_model.fp16.safetensors`).
    /// Leaves the path unchanged if it doesn't end in `.safetensors` or
    /// already has the `.fp16` infix.
    internal static func fp16Path(for path: String) -> String {
        let suffix = ".safetensors"
        let fp16Suffix = ".fp16.safetensors"
        guard path.hasSuffix(suffix), !path.hasSuffix(fp16Suffix) else { return path }
        let base = String(path.dropLast(suffix.count))
        return base + fp16Suffix
    }

    /// Lists every full-precision weight path the planner would consider for
    /// a given manifest. Used both for fp16 HEAD-probing and as input to
    /// ``selectVariant(weightPaths:fp16Available:)`` in tests.
    internal static func candidateWeightPaths(for manifest: DiffusionManifest) -> [String] {
        var paths: [String] = []
        if manifest.submodules.contains("transformer") {
            paths.append("transformer/diffusion_pytorch_model.safetensors")
        }
        if manifest.submodules.contains("unet") {
            paths.append("unet/diffusion_pytorch_model.safetensors")
        }
        if manifest.submodules.contains("vae") {
            paths.append("vae/diffusion_pytorch_model.safetensors")
        }
        for name in ["text_encoder", "text_encoder_2"] where manifest.submodules.contains(name) {
            paths.append("\(name)/model.safetensors")
        }
        return paths
    }

    private func buildDiffusionDownloadPlan(
        manifest: DiffusionManifest,
        destinationDirectory: URL,
        fp16AvailablePaths: Set<String>
    ) throws -> DiffusionDownloadPlan {
        let isFlux = manifest.submodules.contains("transformer")
        // Require the denoiser submodule appropriate for each pipeline family,
        // plus VAE which every pipeline needs.
        let requiredDenoiser = isFlux ? "transformer" : "unet"
        for required in [requiredDenoiser, "vae"] where !manifest.submodules.contains(required) {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "Manifest is missing required submodule \"\(required)\""
            )
        }

        var items: [DiffusionDownloadItem] = []

        items.append(contentsOf: try plan(
            submodule: requiredDenoiser,
            weights: "diffusion_pytorch_model.safetensors",
            destinationDirectory: destinationDirectory,
            fp16AvailablePaths: fp16AvailablePaths
        ))

        items.append(contentsOf: try plan(
            submodule: "vae",
            weights: "diffusion_pytorch_model.safetensors",
            destinationDirectory: destinationDirectory,
            fp16AvailablePaths: fp16AvailablePaths
        ))

        // Text encoder(s).
        for name in ["text_encoder", "text_encoder_2"] where manifest.submodules.contains(name) {
            items.append(contentsOf: try plan(
                submodule: name,
                weights: "model.safetensors",
                destinationDirectory: destinationDirectory,
                fp16AvailablePaths: fp16AvailablePaths
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

        let variant = Self.selectVariant(
            weightPaths: Self.candidateWeightPaths(for: manifest),
            fp16Available: fp16AvailablePaths
        )
        return DiffusionDownloadPlan(items: items, variant: variant)
    }

    private func plan(
        submodule: String,
        weights: String,
        destinationDirectory: URL,
        fp16AvailablePaths: Set<String>
    ) throws -> [DiffusionDownloadItem] {
        try assertSafePathComponent(submodule)
        try assertSafePathComponent(weights)
        let dir = destinationDirectory.appendingPathComponent(submodule, isDirectory: true)
        let fullPrecisionRelative = "\(submodule)/\(weights)"
        let fp16Relative = Self.fp16Path(for: fullPrecisionRelative)
        let useFP16 = fp16Relative != fullPrecisionRelative
            && fp16AvailablePaths.contains(fp16Relative)
        let chosenRelative = useFP16 ? fp16Relative : fullPrecisionRelative
        let chosenFileName = (chosenRelative as NSString).lastPathComponent
        try assertSafePathComponent(chosenFileName)
        return [
            DiffusionDownloadItem(
                relativePath: "\(submodule)/config.json",
                localURL: dir.appendingPathComponent("config.json"),
                role: .submoduleConfig
            ),
            DiffusionDownloadItem(
                relativePath: chosenRelative,
                localURL: dir.appendingPathComponent(chosenFileName),
                role: .weights
            ),
        ]
    }

    /// HEAD-probes each candidate fp16 path in parallel and returns the set
    /// of paths the remote actually serves. A 200 means "fetch the fp16
    /// variant", anything else (404 / 403 / transport failure) falls back
    /// to full-precision for that file.
    ///
    /// Probing in parallel keeps the cost flat (one round-trip per request,
    /// concurrent over the same session) instead of additive on top of the
    /// download itself. Failures are absorbed silently — the variant
    /// selection is best-effort and we'd rather fall back to fp32 than
    /// abort the install over a network blip on a probe.
    private func probeFP16Availability(
        repoID: String,
        candidates: [String],
        using session: URLSession
    ) async -> Set<String> {
        guard !candidates.isEmpty else { return [] }
        return await withTaskGroup(of: String?.self) { group in
            for fullPath in candidates {
                let fp16Relative = Self.fp16Path(for: fullPath)
                guard fp16Relative != fullPath else { continue }
                let url = downloadURL(repoID: repoID, filePath: fp16Relative)
                group.addTask {
                    var request = URLRequest(url: url)
                    request.httpMethod = "HEAD"
                    do {
                        let (_, response) = try await session.data(for: request)
                        if let http = response as? HTTPURLResponse,
                           (200..<300).contains(http.statusCode) {
                            return fp16Relative
                        }
                    } catch {
                        Log.network.debug("fp16 probe failed for \(fp16Relative, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                    return nil
                }
            }
            var found: Set<String> = []
            for await result in group {
                if let path = result { found.insert(path) }
            }
            return found
        }
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

    // Two download paths depending on whether a DiffusionDownloadDelegate is provided:
    //
    // Delegate path (production — background URLSession):
    //   Uses downloadTask(with:) (no completion handler) and registers the
    //   continuation with the delegate. Background sessions REQUIRE this path —
    //   the completion-handler variant is silently ignored by the OS when a
    //   background configuration is active. Per-chunk progress fires via
    //   URLSessionDownloadDelegate.urlSession(_:downloadTask:didWriteData:...).
    //
    // Completion-handler path (injected sessions — tests, custom auth):
    //   Uses downloadTask(with:completionHandler:) exactly as before. This path
    //   keeps MockURLProtocol-backed test sessions working without a wired-up
    //   session delegate. Progress is reported via KVO on countOfBytesReceived
    //   (the original strategy).
    private func downloadFile(
        from remote: URL,
        to local: URL,
        using session: URLSession,
        delegate: DiffusionDownloadDelegate?,
        onChunk: (@Sendable (_ received: Int64, _ expected: Int64) -> Void)? = nil
    ) async throws {
        if let delegate {
            try await downloadFileViaDelegate(
                from: remote, to: local, using: session, delegate: delegate, onChunk: onChunk
            )
        } else {
            try await downloadFileViaCompletionHandler(
                from: remote, to: local, using: session, onChunk: onChunk
            )
        }
    }

    /// Delegate-based download path used with background URLSessions.
    ///
    /// Registers a ``CheckedContinuation`` with the ``DiffusionDownloadDelegate``
    /// before resuming the task. The delegate fires ``onChunk`` on every
    /// ``urlSession(_:downloadTask:didWriteData:...)`` callback and resumes the
    /// continuation when ``urlSession(_:downloadTask:didFinishDownloadingTo:)``
    /// fires (with the stable temp URL) or on error.
    private func downloadFileViaDelegate(
        from remote: URL,
        to local: URL,
        using session: URLSession,
        delegate: DiffusionDownloadDelegate,
        onChunk: (@Sendable (_ received: Int64, _ expected: Int64) -> Void)?
    ) async throws {
        final class CancelBox: @unchecked Sendable {
            private let lock = NSLock()
            private var _task: URLSessionDownloadTask?

            func store(_ task: URLSessionDownloadTask) {
                lock.lock(); defer { lock.unlock() }
                _task = task
            }
            func cancel() {
                lock.lock(); let t = _task; lock.unlock()
                t?.cancel()
            }
        }
        let box = CancelBox()
        let filename = remote.lastPathComponent

        let tempURL: URL = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let task = session.downloadTask(with: remote)
                delegate.register(taskID: task.taskIdentifier, continuation: continuation, onChunk: onChunk)
                box.store(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }

        // Move the stable temp file (copied synchronously in the delegate) to
        // its final destination. Check HTTP status via task response if available.
        Log.download.info("downloadTask complete for \(filename, privacy: .public), moving to destination")
        do {
            try FileManager.default.createDirectory(
                at: local.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: local.path) {
                try FileManager.default.removeItem(at: local)
            }
            try FileManager.default.moveItem(at: tempURL, to: local)
            Log.download.info("Move complete for \(filename, privacy: .public)")
        } catch {
            Log.download.error("Move failed for \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            // Best-effort cleanup of the stable temp copy. The file may already
            // be absent if a prior guard branch deleted it — ignore "not found".
            do {
                try FileManager.default.removeItem(at: tempURL)
            } catch let cleanupError {
                Log.download.warning("Failed to remove temp file after move failure: \(cleanupError.localizedDescription, privacy: .public)")
            }
            throw error
        }
    }

    /// Completion-handler download path for injected (non-background) sessions.
    ///
    /// Kept intact so test sessions configured with `MockURLProtocol` continue
    /// to work without a wired-up session delegate. Progress is reported via
    /// KVO on `countOfBytesReceived`.
    ///
    /// Background sessions silently ignore the completion handler — always use
    /// ``downloadFileViaDelegate(from:to:using:delegate:onChunk:)`` with a
    /// ``URLSessionFactory/background(identifier:additionalDownloadDelegate:)``
    /// session instead.
    private func downloadFileViaCompletionHandler(
        from remote: URL,
        to local: URL,
        using session: URLSession,
        onChunk: (@Sendable (_ received: Int64, _ expected: Int64) -> Void)?
    ) async throws {
        final class State: @unchecked Sendable {
            private let lock = NSLock()
            private var _task: URLSessionDownloadTask?
            private var _cancelled = false
            private var _progressObservation: NSKeyValueObservation?

            func store(_ task: URLSessionDownloadTask) {
                lock.lock(); defer { lock.unlock() }
                _task = task
                if _cancelled { task.cancel() }
            }

            func cancel() {
                lock.lock()
                _cancelled = true
                let t = _task
                lock.unlock()
                t?.cancel()
            }

            func setObservation(_ obs: NSKeyValueObservation?) {
                lock.lock(); defer { lock.unlock() }
                _progressObservation = obs
            }
        }
        let state = State()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let filename = remote.lastPathComponent
                let task = session.downloadTask(with: remote) { tempURL, response, error in
                    state.setObservation(nil)

                    if let error {
                        Log.download.error("downloadTask error for \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        continuation.resume(throwing: HuggingFaceError.downloadFailed(underlying: error))
                        return
                    }
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        Log.download.error("HTTP \(http.statusCode) for \(filename, privacy: .public)")
                        if let url = tempURL { try? FileManager.default.removeItem(at: url) }
                        continuation.resume(throwing: HuggingFaceError.downloadFailed(
                            underlying: NSError(
                                domain: "ManifoldHuggingFace",
                                code: http.statusCode,
                                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(remote.lastPathComponent)"]
                            )
                        ))
                        return
                    }
                    guard let tempURL else {
                        Log.download.error("downloadTask nil tempURL for \(filename, privacy: .public)")
                        continuation.resume(throwing: HuggingFaceError.downloadFailed(
                            underlying: ManifoldKitError.unknown(
                                underlyingDescription: "Download completed without a temporary file"
                            )
                        ))
                        return
                    }
                    Log.download.info("downloadTask complete for \(filename, privacy: .public), moving to destination")
                    do {
                        try FileManager.default.createDirectory(
                            at: local.deletingLastPathComponent(),
                            withIntermediateDirectories: true
                        )
                        if FileManager.default.fileExists(atPath: local.path) {
                            try FileManager.default.removeItem(at: local)
                        }
                        try FileManager.default.moveItem(at: tempURL, to: local)
                        Log.download.info("Move complete for \(filename, privacy: .public)")
                        continuation.resume()
                    } catch {
                        Log.download.error("Move failed for \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        continuation.resume(throwing: error)
                    }
                }

                if let onChunk {
                    // task.progress uses a 0-100 unit scale, not bytes.
                    // Observe countOfBytesReceived directly for real byte counts.
                    // KVO callbacks fire on URLSession's delegate queue, not the caller's
                    // actor, so the throttling counter needs a real lock (CLAUDE.md
                    // Swift-6 gotcha #2 — @unchecked Sendable is not a fix here).
                    let lastLoggedPct = OSAllocatedUnfairLock<Int>(initialState: -10)
                    state.setObservation(task.observe(\.countOfBytesReceived) { [weak task] _, _ in
                        guard let task else { return }
                        let received = task.countOfBytesReceived
                        let expected = task.countOfBytesExpectedToReceive
                        // countOfBytesExpectedToReceive is NSURLSessionTransferSizeUnknown (-1) when absent.
                        let safeExpected: Int64 = expected > 0 ? expected : 0
                        if safeExpected > 0 {
                            let pct = Int(Double(received) / Double(safeExpected) * 100)
                            let shouldLog = lastLoggedPct.withLock { current -> Bool in
                                guard pct >= current + 10 else { return false }
                                current = pct
                                return true
                            }
                            if shouldLog {
                                Log.download.debug("\(filename, privacy: .public): \(pct)% (\(received)/\(safeExpected) bytes)")
                            }
                        }
                        onChunk(received, safeExpected)
                    })
                }

                state.store(task)
                task.resume()
            }
        } onCancel: {
            state.cancel()
        }
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
