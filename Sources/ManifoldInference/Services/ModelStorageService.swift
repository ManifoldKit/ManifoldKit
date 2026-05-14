import Foundation

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
    }

    /// Internal init for test isolation — lets tests supply a specific bundle
    /// identifier without touching the global `ManifoldConfiguration`.
    init(fileManager: FileManager = .default, baseDirectory: URL? = nil, bundleIdentifier: String? = nil) {
        self.fileManager = fileManager
        self.customDirectory = baseDirectory
        self.customBundleIdentifier = bundleIdentifier
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

    // MARK: - Discovery

    /// Scans the models directory for GGUF files and MLX model directories.
    ///
    /// Returns an empty array if the directory does not exist or contains no models.
    public func discoverModels() -> [ModelInfo] {
        let directory = modelsDirectory

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            Log.inference.warning("ModelStorageService: failed to read models directory: \(error, privacy: .private)")
            return []
        }

        var models: [ModelInfo] = []

        for url in contents {
            // Check for GGUF files.
            if url.pathExtension.lowercased() == "gguf",
               let model = ModelInfo(ggufURL: url) {
                models.append(model)
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

            if let model = ModelInfo(mlxDirectory: url) {
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
                      let model = ModelInfo(mlxDirectory: nestedURL, namespace: namespace) else {
                    continue
                }
                models.append(model)
            }
        }

        return models.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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
    @discardableResult
    public func importModel(from sourceURL: URL) throws -> URL {
        try ensureModelsDirectory()
        let destination = modelsDirectory.appendingPathComponent(sourceURL.lastPathComponent)

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: sourceURL, to: destination)
        Log.download.info("Imported model: \(sourceURL.lastPathComponent)")
        return destination
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
        return ImageModelInfo(
            id: manifest.id,
            name: manifest.displayName,
            directoryURL: directory,
            format: format,
            fileSize: packageSize(at: directory, files: manifest.files),
            huggingFaceRepoID: manifest.huggingFaceRepoID
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
