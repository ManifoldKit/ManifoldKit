import Foundation
import ManifoldHardware

/// Manages on-disk storage of model files (GGUF and MLX format).
///
/// Handles directory creation, model discovery, deletion, and storage accounting.
/// On iOS the models directory is excluded from iCloud backup.
public final class ModelStorageService: @unchecked Sendable {

    private let fileManager: FileManager
    /// Overrides the default Application-Support-relative directory. Used in tests.
    private let customDirectory: URL?
    /// Overrides the bundle identifier used in the default path. Used in tests.
    private let customBundleIdentifier: String?
    /// When `true`, ``discoverModels()`` also scans `~/Documents/Models` and
    /// surfaces any GGUFs / MLX directories it finds there. App-scoped storage
    /// always takes precedence — a model whose `id` is already discovered in
    /// the primary directory is not duplicated by the fallback scan. See #1468.
    private let includeUserDocumentsFallback: Bool
    /// Overrides the location of the `~/Documents/Models` fallback directory.
    /// Used in tests so the fallback scan never touches the developer's real
    /// `~/Documents`. `nil` in production means "use the resolved user
    /// `~/Documents/Models`".
    private let fallbackDirectoryOverride: URL?

    /// Creates a `ModelStorageService`.
    ///
    /// - Parameter baseDirectory: Explicit directory for model storage. Pass a
    ///   non-nil URL to share a single models directory across multiple BCK
    ///   apps (e.g. a multi-product setup that intentionally pools models).
    ///   When `nil`, the service derives a per-app path from
    ///   `ManifoldConfiguration.shared.bundleIdentifier`:
    ///   `<Application Support>/<bundleIdentifier>/<modelsDirectoryName>`.
    public init(fileManager: FileManager = .default, baseDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.customDirectory = baseDirectory
        self.customBundleIdentifier = nil
        // Default-on for the public init: SwiftUI hosts whose users follow the
        // CLI quickstart and drop a GGUF into `~/Documents/Models` should still
        // see it appear in the model-management sheet. App-scoped writes win;
        // the fallback only surfaces additional files. Hosts that want strict
        // app-scoped semantics can opt out via the internal init below.
        self.includeUserDocumentsFallback = true
        self.fallbackDirectoryOverride = nil
    }

    /// Package init for test isolation — lets tests supply a specific bundle
    /// identifier and override the `~/Documents/Models` fallback location so
    /// per-test scratch directories aren't polluted by ambient host state.
    package init(
        fileManager: FileManager = .default,
        baseDirectory: URL? = nil,
        bundleIdentifier: String? = nil,
        includeUserDocumentsFallback: Bool = false,
        fallbackDirectoryOverride: URL? = nil
    ) {
        self.fileManager = fileManager
        self.customDirectory = baseDirectory
        self.customBundleIdentifier = bundleIdentifier
        self.includeUserDocumentsFallback = includeUserDocumentsFallback
        self.fallbackDirectoryOverride = fallbackDirectoryOverride
    }

    // MARK: - Directory

    /// The directory where model files are stored.
    ///
    /// Defaults to `<Application Support>/<bundleIdentifier>/<modelsDirectoryName>`,
    /// scoped to the host app's bundle identifier so multiple BCK-based apps
    /// on the same device each see only their own models.
    ///
    /// Override at init time via `baseDirectory:` when you intentionally want
    /// to share a models directory across apps (e.g. a multi-product suite).
    public var modelsDirectory: URL {
        if let custom = customDirectory { return custom }
        let config = ManifoldConfiguration.shared
        let bundleID = customBundleIdentifier ?? config.bundleIdentifier
        if bundleID == ManifoldConfiguration.frameworkDefaultBundleIdentifier {
            Log.inference.fault(
                "ModelStorageService is using the framework default bundle identifier (\(bundleID, privacy: .public)). Multiple apps sharing this default will collide on the same models directory. Set ManifoldConfiguration.shared = ManifoldConfiguration(bundleIdentifier: \"com.your-app\") at app launch."
            )
        }
        let base: URL
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            base = appSupport
        } else {
            Log.inference.fault("Application Support directory unavailable — falling back to temp directory")
            base = fileManager.temporaryDirectory
        }
        return base
            .appendingPathComponent(bundleID, isDirectory: true)
            .appendingPathComponent(config.modelsDirectoryName, isDirectory: true)
    }

    /// Creates the models directory if it does not already exist.
    ///
    /// On iOS the directory is marked as excluded from iCloud backup.
    public func ensureModelsDirectory() throws {
        let directory = modelsDirectory

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
            // Already exists — just ensure backup exclusion on iOS.
            try applyBackupExclusion(to: directory)
            return
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try applyBackupExclusion(to: directory)
    }

    /// Optional secondary scan location used by ``discoverModels()`` when
    /// ``includeUserDocumentsFallback`` is `true`.
    ///
    /// Resolves to `~/Documents/Models` on the user domain. The CLI quickstart
    /// documents this path; mirroring it from the SwiftUI sheet means a fresh
    /// user can follow either guide and still see their models. App-scoped
    /// storage always wins on a path collision (deduplicated by stable
    /// `ModelInfo.id`). See #1468.
    public var userDocumentsModelsDirectory: URL? {
        if let override = fallbackDirectoryOverride {
            return override
        }
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return documents.appendingPathComponent("Models", isDirectory: true)
    }

    // MARK: - Discovery

    /// Scans the models directory (and `~/Documents/Models` when the
    /// fallback is enabled) for GGUF files and MLX model directories.
    ///
    /// Returns an empty array if neither directory contains any models. Per-file
    /// failures during the scan are logged via ``ModelDiscoveryError`` but do
    /// not abort the surrounding scan — one corrupt GGUF cannot hide its
    /// healthy siblings.
    public func discoverModels() -> [ModelInfo] {
        discoverModels(reportingErrors: nil)
    }

    /// Scans the models directory and reports per-file failures through
    /// `errorHandler`. Designed for callers (typically `ModelManagementSheet`)
    /// that want to surface "file present but unreadable" / "file is not GGUF"
    /// to the user rather than swallow them in a log line.
    ///
    /// Precedence: the app-scoped ``modelsDirectory`` is scanned first.
    /// When the fallback is enabled and a `~/Documents/Models` directory
    /// exists, its contents are appended for any `ModelInfo` whose stable
    /// ID is not already present.
    public func discoverModels(reportingErrors errorHandler: ((ModelDiscoveryError) -> Void)?) -> [ModelInfo] {
        var models: [ModelInfo] = []
        var seenIDs: Set<UUID> = []

        scanDirectory(modelsDirectory, into: &models, seenIDs: &seenIDs, errorHandler: errorHandler)

        if includeUserDocumentsFallback,
           let fallback = userDocumentsModelsDirectory,
           fallback.resolvingSymlinksInPath().path != modelsDirectory.resolvingSymlinksInPath().path,
           fileManager.fileExists(atPath: fallback.path) {
            scanDirectory(fallback, into: &models, seenIDs: &seenIDs, errorHandler: errorHandler)
        }

        return models.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Off-main equivalent of ``discoverModels(reportingErrors:)`` for callers
    /// (notably `ModelManagementSheet`) that must not stall the main thread on
    /// the synchronous GGUF/MLX directory scan (~2s cold; #1774).
    ///
    /// Hops off the calling actor via `Task.detached` and runs the existing
    /// synchronous scan body, collecting per-file failures into a returned
    /// array rather than calling back through an escaping `@Sendable` closure —
    /// a tuple return sidesteps the Swift 6 non-isolated-async-helper trap (a
    /// sent closure that closes over `@MainActor` state). Both `ModelInfo` and
    /// `ModelDiscoveryError` are `Sendable`, so the result crosses the actor
    /// boundary cleanly.
    public func discoverModelsOffMain() async -> (models: [ModelInfo], errors: [ModelDiscoveryError]) {
        await Task.detached(priority: .userInitiated) { [self] in
            // The error handler fires only synchronously on this detached
            // task's own thread, so a plain local array needs no lock.
            var errors: [ModelDiscoveryError] = []
            let models = discoverModels(reportingErrors: { errors.append($0) })
            return (models: models, errors: errors)
        }.value
    }

    /// Per-directory scan used by both the public ``discoverModels()`` and
    /// the diagnostics-reporting overload.
    private func scanDirectory(
        _ directory: URL,
        into models: inout [ModelInfo],
        seenIDs: inout Set<UUID>,
        errorHandler: ((ModelDiscoveryError) -> Void)?
    ) {
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            Log.inference.warning("ModelStorageService: failed to read models directory at \(directory.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }

        for url in contents {
            // Check for GGUF files.
            if url.pathExtension.lowercased() == "gguf" {
                do {
                    let model = try ModelInfo.load(ggufURL: url)
                    if seenIDs.insert(model.id).inserted {
                        models.append(model)
                    }
                } catch let error as ModelDiscoveryError {
                    Log.inference.warning("ModelStorageService: skipping \(url.lastPathComponent, privacy: .public): \(error.errorDescription ?? "unknown reason", privacy: .public)")
                    errorHandler?(error)
                } catch {
                    Log.inference.warning("ModelStorageService: unexpected GGUF load error for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
                continue
            }

            // MLX layouts:
            //   1. Flat:       Models/<name>/config.json
            //   2. Namespaced: Models/<org>/<name>/config.json   (HF org/user prefix)
            // The download manager writes namespaced layouts for repos like
            // `mlx-community/gemma-4-…`, so a single-level scan misses them.
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            if isImagePackageDirectory(url) {
                continue
            }

            if let model = ModelInfo(mlxDirectory: url), seenIDs.insert(model.id).inserted {
                models.append(model)
                continue
            }

            // Treat a directory without its own config.json as a possible namespace
            // and look one level deeper. We only recurse one level — anything beyond
            // that is out of scope for this layout convention.
            let namespace = url.lastPathComponent
            let nestedContents: [URL]
            do {
                nestedContents = try fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                Log.inference.warning("ModelStorageService: failed to read namespace directory '\(namespace, privacy: .public)': \(error, privacy: .private)")
                continue
            }

            for nestedURL in nestedContents {
                var nestedIsDir: ObjCBool = false
                guard fileManager.fileExists(atPath: nestedURL.path, isDirectory: &nestedIsDir),
                      !isImagePackageDirectory(nestedURL),
                      nestedIsDir.boolValue,
                      let model = ModelInfo(mlxDirectory: nestedURL, namespace: namespace),
                      seenIDs.insert(model.id).inserted else {
                    continue
                }
                models.append(model)
            }
        }
    }

    /// Scans for atomically completed image model packages under `rootDirectory`.
    ///
    /// A package is surfaced only when its local readiness manifest exists and
    /// every component listed in that manifest is present. Staging directories or
    /// partially downloaded packages without the manifest are intentionally hidden.
    public func discoverImageModels(in rootDirectory: URL? = nil) -> [ImageModelInfo] {
        let root = rootDirectory ?? modelsDirectory

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            Log.inference.warning("ModelStorageService: failed to read image models directory: \(error, privacy: .private)")
            return []
        }

        let models = contents.compactMap { url -> ImageModelInfo? in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { return nil }
            return imageModelInfoIfReady(at: url)
        }

        return models.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: - Deletion

    /// Deletes the model file from disk.
    public func deleteModel(_ model: ModelInfo) throws {
        try fileManager.removeItem(at: model.url)
    }

    // MARK: - Storage Accounting

    /// Total bytes used by all model files in the models directory.
    public func modelStorageUsed() -> UInt64 {
        discoverModels().reduce(0) { $0 + $1.fileSize }
    }

    /// Human-readable total storage used (e.g. "4.7 GB").
    public var storageUsedFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(modelStorageUsed()), countStyle: .file)
    }

    // MARK: - Import

    /// Copies a model file into the models directory.
    ///
    /// Used for Mac drag-and-drop import. Returns the destination URL.
    ///
    /// Validates the filename and resolves symlinks before checking containment
    /// so a crafted symlink or path-traversal component cannot escape the models
    /// directory boundary.
    @discardableResult
    public func importModel(from sourceURL: URL) throws -> URL {
        let fileName = sourceURL.lastPathComponent
        guard !fileName.isEmpty else {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "Cannot import a URL with an empty last path component"
            )
        }
        try DownloadableModel.validate(fileName: fileName)
        try ensureModelsDirectory()
        let destination = modelsDirectory.appendingPathComponent(fileName)
        let resolvedDest = destination.resolvingSymlinksInPath()
        let resolvedBase = modelsDirectory.resolvingSymlinksInPath()
        guard resolvedDest.path.hasPrefix(resolvedBase.path + "/") else {
            throw HuggingFaceError.invalidDownloadedFile(
                reason: "Import path escapes models directory: \(fileName)"
            )
        }
        if fileManager.fileExists(atPath: resolvedDest.path) {
            try fileManager.removeItem(at: resolvedDest)
        }
        try fileManager.copyItem(at: sourceURL, to: resolvedDest)
        Log.download.info("Imported model: \(fileName, privacy: .public)")
        return resolvedDest
    }

    // MARK: - Disk Space

    /// Returns the available disk space in bytes.
    public func availableDiskSpace() -> UInt64 {
        do {
            let attrs = try fileManager.attributesOfFileSystem(forPath: NSHomeDirectory())
            return attrs[.systemFreeSize] as? UInt64 ?? 0
        } catch {
            Log.download.error("Failed to read disk space: \(error)")
            return 0
        }
    }

    // MARK: - Private

    /// Excludes the given URL from iCloud backup on iOS.
    private func applyBackupExclusion(to url: URL) throws {
        #if os(iOS)
        var resourceURL = url
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try resourceURL.setResourceValues(resourceValues)
        #endif
    }

    private func imageModelInfoIfReady(at directory: URL) -> ImageModelInfo? {
        let manifestURL = directory.appendingPathComponent(DownloadedModelPackageManifest.fileName)
        let manifest: DownloadedModelPackageManifest
        do {
            let data = try Data(contentsOf: manifestURL)
            manifest = try JSONDecoder().decode(DownloadedModelPackageManifest.self, from: data)
        } catch {
            return nil
        }
        guard manifest.packageKind == .diffusion,
              manifest.format == .mlxDiffusion || manifest.format == .fluxSchnell else {
            return nil
        }

        for relativePath in manifest.files {
            guard isSafeRelativePackagePath(relativePath) else { return nil }
            let fileURL = directory.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return nil
            }
        }

        guard let format = manifest.format else { return nil }
        // Diffusion packages adopt Hub's `<root>/models/<org>/<name>` layout
        // so backends can pass `HubApi(downloadBase:)` without a bridging
        // symlink. The package readiness manifest stays at the package
        // root; the `files` paths in it are stored with the
        // `models/<repoID>/` prefix and verified above. The loaded
        // `directoryURL` is the Hub leaf so loaders that probe `url/unet`
        // etc. still work.
        let directoryURL: URL
        if let hfRepoID = manifest.huggingFaceRepoID,
           manifest.files.allSatisfy({ $0.hasPrefix("models/\(hfRepoID)/") }) {
            directoryURL = directory
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent(hfRepoID, isDirectory: true)
        } else {
            // Pre-Hub-layout packages: `directoryURL` is the package root.
            // Kept for forward compatibility if a downstream consumer
            // writes a manifest without the `models/<repoID>/` prefix.
            directoryURL = directory
        }
        return ImageModelInfo(
            id: manifest.id,
            name: manifest.displayName,
            directoryURL: directoryURL,
            format: format,
            fileSize: packageSize(at: directory, files: manifest.files),
            huggingFaceRepoID: manifest.huggingFaceRepoID,
            variant: manifest.variant ?? .fullPrecision
        )
    }

    private func packageSize(at directory: URL, files: [String]) -> Int64 {
        files.reduce(Int64(0)) { total, relativePath in
            let url = directory.appendingPathComponent(relativePath)
            let size: Int64
            do {
                size = Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            } catch {
                size = 0
            }
            return total + size
        }
    }

    private func isImagePackageDirectory(_ directory: URL) -> Bool {
        let manifestURL = directory.appendingPathComponent(DownloadedModelPackageManifest.fileName)
        do {
            let data = try Data(contentsOf: manifestURL)
            let manifest = try JSONDecoder().decode(DownloadedModelPackageManifest.self, from: data)
            return manifest.packageKind == .diffusion
        } catch {
            return false
        }
    }

    private func isSafeRelativePackagePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\") else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component != "." && component != ".." && !component.hasPrefix(".")
        }
    }
}
