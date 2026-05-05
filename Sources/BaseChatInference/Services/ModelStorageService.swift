import Foundation

/// Manages on-disk storage of model files (GGUF and MLX format).
///
/// Handles directory creation, model discovery, deletion, and storage accounting.
/// On iOS the models directory is excluded from iCloud backup.
public final class ModelStorageService {

    private let fileManager: FileManager
    /// Overrides the default Documents-relative directory. Used in tests.
    private let customDirectory: URL?

    public init(fileManager: FileManager = .default, baseDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.customDirectory = baseDirectory
    }

    // MARK: - Directory

    /// The directory where model files are stored.
    ///
    /// Defaults to `<Documents>/<modelsDirectoryName>` on both iOS and macOS,
    /// where the directory name comes from `BaseChatConfiguration.shared.modelsDirectoryName`.
    /// Can be overridden via `baseDirectory` at init time (used in tests).
    public var modelsDirectory: URL {
        if let custom = customDirectory { return custom }
        let base: URL
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            base = documents
        } else {
            Log.inference.fault("Documents directory unavailable — falling back to temp directory")
            base = fileManager.temporaryDirectory
        }
        return base.appendingPathComponent(
            BaseChatConfiguration.shared.modelsDirectoryName,
            isDirectory: true
        )
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

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
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
            guard let nestedContents = try? fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

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

        guard let contents = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
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
              manifest.format == .mlxDiffusion else {
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

        return ImageModelInfo(
            id: manifest.id,
            name: manifest.displayName,
            directoryURL: directory,
            format: .mlxDiffusion,
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
