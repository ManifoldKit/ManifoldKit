import Foundation

/// The inference backend a model requires, determined by its file format.
public enum ModelType: Hashable, Sendable {
    /// A single `.gguf` file — uses the llama.cpp backend.
    case gguf
    /// A directory containing `config.json` + `.safetensors` weights — uses MLX.
    case mlx
    /// Apple on-device model, no file needed.
    case foundation
}

/// Represents a model available on disk (either a GGUF file or an MLX model directory).
///
/// Construct via one of the factory initializers:
/// - ``init(ggufURL:)`` for local `.gguf` files (reads size from disk).
/// - ``init(mlxDirectory:namespace:)`` for MLX model directories.
/// - ``init(huggingFaceRepoID:fileName:sizeBytes:localURL:modelType:)`` for completed
///   HuggingFace downloads (trusts caller-supplied size, skips disk attribute lookup).
public struct ModelInfo: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let name: String
    public let fileName: String
    public let url: URL
    public let fileSize: UInt64
    public let modelType: ModelType

    // MARK: - Multimodal

    /// URL of the mmproj (multimodal projector) companion file, when present alongside the main GGUF.
    ///
    /// Populated automatically by ``init(ggufURL:)`` when a `mmproj*.gguf` sibling is found in
    /// the same directory. Backends that conform to ``MultimodalProjectorConfigurable`` receive
    /// this URL from ``ModelLifecycleCoordinator`` before ``InferenceBackend/loadModel(from:plan:)``.
    ///
    /// `nil` for text-only models and for non-GGUF model types.
    public var mmprojURL: URL?

    // MARK: - GGUF Metadata (populated for .gguf models)

    /// The prompt template detected from GGUF metadata (chat template or architecture).
    public var detectedPromptTemplate: PromptTemplate?
    /// The context length read from the GGUF header (e.g. 4096, 8192).
    public var detectedContextLength: Int?
    /// The model architecture string from `general.architecture` (e.g. "llama", "phi").
    public var modelArchitecture: String?
    /// The raw Jinja chat template string from `tokenizer.chat_template`, if present.
    public var chatTemplateRaw: String?
    /// Best-effort KV-cache bytes-per-token estimate derived from GGUF metadata.
    public var estimatedKVBytesPerToken: UInt64?

    // MARK: - Capability

    /// Static capability tier for this model, derived from file size at init time.
    /// When `nil`, ``effectiveCapabilityTier`` falls back to a static estimate.
    public var capabilityTier: ModelCapabilityTier?

    /// The most recent benchmark result for this model, if one has been run.
    public var benchmarkResult: ModelBenchmarkResult?

    // MARK: - Provenance

    /// The HuggingFace repository this model was downloaded from, when known
    /// (e.g. `"bartowski/Llama-3.2-3B-Instruct-GGUF"`).
    ///
    /// Populated by ``init(huggingFaceRepoID:fileName:sizeBytes:localURL:modelType:)``.
    /// `nil` for locally-discovered files and built-in models.
    public var huggingFaceRepoID: String?

    /// Returns the benchmark-confirmed tier when one is available, otherwise falls back
    /// to the stored ``capabilityTier``, and finally to a static file-size estimate.
    public var effectiveCapabilityTier: ModelCapabilityTier {
        benchmarkResult?.tier ?? capabilityTier ?? ModelCapabilityTier.estimate(from: self)
    }

    /// Human-readable file size (e.g. "2.3 GB").
    public var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }

    /// Short label for the backend type.
    public var backendLabel: String {
        switch modelType {
        case .gguf: "GGUF"
        case .mlx: "MLX"
        case .foundation: "Apple"
        }
    }

    // MARK: - Built-in Foundation Model

    /// The built-in Apple Foundation Model (available on iOS 26+ / macOS 26+).
    /// This is not a file on disk — it's provided by the OS.
    public static let builtInFoundation = ModelInfo(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Apple Foundation Model",
        fileName: "Built-in",
        url: URL(fileURLWithPath: "/"),  // Unused for foundation models
        fileSize: 0,
        modelType: .foundation
    )

    // MARK: - GGUF Initializer

    /// Creates a ModelInfo from a `.gguf` file URL, reading its size from disk.
    ///
    /// Returns `nil` if the file's attributes cannot be read.
    public init?(ggufURL url: URL) {
        guard url.pathExtension.lowercased() == "gguf" else { return nil }

        // Reject files that don't carry the GGUF magic header — covers:
        //   - leaked test-fixture stubs (e.g. 15-byte ASCII placeholders, see
        //     `scripts/clean-leaked-test-artifacts.sh`)
        //   - downloads truncated before the first 4 bytes were written
        //   - companion files some HF repos ship with a .gguf extension but no
        //     header (rare, but cheap to filter)
        guard GGUFMetadataReader.isValidGGUF(at: url) else { return nil }

        let fileManager = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: url.path)
        } catch {
            Log.inference.warning("ModelInfo: failed to read file attributes for \(url.lastPathComponent, privacy: .public): \(error, privacy: .private)")
            return nil
        }
        guard let size = attributes[.size] as? UInt64 else {
            return nil
        }

        self.id = Self.stableID(for: url)
        self.fileName = url.lastPathComponent
        self.name = Self.displayName(from: url.lastPathComponent, strippingExtension: ".gguf")
        self.url = url
        self.fileSize = size
        self.modelType = .gguf
        self.benchmarkResult = nil

        // Attempt to read GGUF header metadata for template detection.
        do {
            let metadata = try GGUFMetadataReader.readMetadata(from: url)
            self.detectedPromptTemplate = PromptTemplateDetector.detect(from: metadata)
            self.detectedContextLength = metadata.contextLength
            self.modelArchitecture = metadata.generalArchitecture
            self.chatTemplateRaw = metadata.chatTemplate
            self.estimatedKVBytesPerToken = GGUFKVCacheEstimator.estimateBytesPerToken(from: metadata)
        } catch {
            Log.inference.warning("ModelInfo: failed to read GGUF metadata from \(url.lastPathComponent, privacy: .public): \(error, privacy: .private)")
        }

        // Static tier estimate; may be upgraded by a benchmark result later.
        self.capabilityTier = ModelCapabilityTier.estimate(from: self)

        // Auto-detect a companion mmproj file in the same directory.
        // Only scans when the model filename does not start with "mmproj" so
        // projector files don't try to find their own companion.
        if !url.lastPathComponent.lowercased().hasPrefix("mmproj") {
            let parentDir = url.deletingLastPathComponent()
            do {
                let candidates = try FileManager.default.contentsOfDirectory(
                    at: parentDir,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                )
                self.mmprojURL = candidates.first {
                    $0.lastPathComponent.lowercased().hasPrefix("mmproj") &&
                    $0.pathExtension.lowercased() == "gguf"
                }
            } catch {
                Log.inference.warning("ModelInfo: failed to scan for mmproj companion in \(parentDir.lastPathComponent, privacy: .public): \(error, privacy: .private)")
            }
        }
    }

    // MARK: - MLX Initializer

    /// Creates a ModelInfo from an MLX model directory containing `config.json`.
    ///
    /// Returns `nil` if the directory doesn't contain `config.json` or can't be read.
    ///
    /// - Parameter namespace: When the directory lives under a HuggingFace org/user
    ///   prefix (e.g. `mlx-community/gemma-4-…`), pass that prefix so the resulting
    ///   `fileName` is `"<namespace>/<lastPathComponent>"`. This matches the
    ///   `DownloadableModel.fileName` shape used by `isModelDownloaded`.
    public init?(mlxDirectory url: URL, namespace: String? = nil) {
        let fileManager = FileManager.default

        // Must be a directory containing config.json.
        let configURL = url.appendingPathComponent("config.json")
        guard fileManager.fileExists(atPath: configURL.path) else { return nil }

        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            Log.inference.warning("ModelInfo: failed to read MLX model directory \(url.lastPathComponent, privacy: .public): \(error, privacy: .private)")
            return nil
        }

        let allFiles = contents.flatMap { child -> [URL] in
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: child.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                return [child]
            }
            guard let enumerator = fileManager.enumerator(
                at: child,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else {
                return [child]
            }
            return enumerator.compactMap { $0 as? URL }
        }

        let totalSize = allFiles.reduce(UInt64(0)) { sum, fileURL in
            do {
                let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true else { return sum }
                return sum + UInt64(values.fileSize ?? 0)
            } catch {
                Log.inference.warning("ModelInfo: failed to read resource values for \(fileURL.lastPathComponent, privacy: .public): \(error, privacy: .private)")
                return sum
            }
        }
        let hasSafetensors = allFiles.contains { $0.pathExtension.lowercased() == "safetensors" }
        guard hasSafetensors else { return nil }

        self.id = Self.stableID(for: url)
        self.fileName = namespace.map { "\($0)/\(url.lastPathComponent)" } ?? url.lastPathComponent
        self.name = Self.displayName(from: url.lastPathComponent, strippingExtension: nil)
        self.url = url
        self.fileSize = totalSize
        self.modelType = .mlx
        self.benchmarkResult = nil

        // Static tier estimate; may be upgraded by a benchmark result later.
        self.capabilityTier = ModelCapabilityTier.estimate(from: self)
    }

    // MARK: - Memberwise

    /// Memberwise initializer for testing or manual construction.
    public init(
        id: UUID = UUID(),
        name: String,
        fileName: String,
        url: URL,
        fileSize: UInt64,
        modelType: ModelType,
        mmprojURL: URL? = nil,
        detectedPromptTemplate: PromptTemplate? = nil,
        detectedContextLength: Int? = nil,
        modelArchitecture: String? = nil,
        chatTemplateRaw: String? = nil,
        estimatedKVBytesPerToken: UInt64? = nil,
        capabilityTier: ModelCapabilityTier? = nil,
        benchmarkResult: ModelBenchmarkResult? = nil,
        huggingFaceRepoID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.fileName = fileName
        self.url = url
        self.fileSize = fileSize
        self.modelType = modelType
        self.mmprojURL = mmprojURL
        self.detectedPromptTemplate = detectedPromptTemplate
        self.detectedContextLength = detectedContextLength
        self.modelArchitecture = modelArchitecture
        self.chatTemplateRaw = chatTemplateRaw
        self.estimatedKVBytesPerToken = estimatedKVBytesPerToken
        self.capabilityTier = capabilityTier
        self.benchmarkResult = benchmarkResult
        self.huggingFaceRepoID = huggingFaceRepoID
    }

    // MARK: - Private

    /// Produces a stable UUID from a file URL so the same model file always gets the same ID.
    ///
    /// Uses UUID v5 (SHA-1 name-based) with the URL namespace to guarantee that
    /// `ModelInfo(ggufURL:)` and `ModelInfo(mlxDirectory:)` return the same `id`
    /// across multiple calls for the same path. This is critical for model selection
    /// persistence — sessions save `selectedModelID`, and `refreshModels()` must
    /// produce matching IDs so the selection survives a rescan.
    static func stableID(for url: URL) -> UUID {
        // UUID v5: SHA-1 hash of namespace UUID + name bytes, per RFC 4122 §4.3.
        // Using the URL namespace UUID (6ba7b811-9dad-11d1-80b4-00c04fd430c8).
        let namespace = UUID(uuidString: "6ba7b811-9dad-11d1-80b4-00c04fd430c8")!
        let name = url.standardizedFileURL.path
        return UUID.v5(namespace: namespace, name: name)
    }

    /// Derives a human-readable display name from a filename.
    private static func displayName(from fileName: String, strippingExtension ext: String?) -> String {
        var name = fileName
        if let ext, name.lowercased().hasSuffix(ext.lowercased()) {
            name = String(name.dropLast(ext.count))
        }
        name = name.replacingOccurrences(of: "-", with: " ")
        name = name.replacingOccurrences(of: "_", with: " ")
        return name
    }
}

// MARK: - HuggingFace Factory

extension ModelInfo {
    /// Creates a ModelInfo from a completed HuggingFace download.
    ///
    /// Unlike ``init(ggufURL:)``, this factory trusts caller-supplied size metadata
    /// (typically derived from the HuggingFace manifest) and skips the on-disk
    /// `attributesOfItem` lookup. The GGUF header is still read for prompt-template
    /// detection, context length, and KV-cache estimation.
    ///
    /// Returns `nil` if `localURL` does not have a `.gguf` extension or fails the
    /// GGUF magic-byte check.
    ///
    /// - Parameters:
    ///   - huggingFaceRepoID: The source repo (e.g. `"bartowski/Llama-3.2-3B-Instruct-GGUF"`).
    ///   - fileName: The file name as known to the download flow. Used directly,
    ///     not derived from `localURL`, because HuggingFace flows pre-compute it.
    ///   - sizeBytes: Trusted size from the HuggingFace manifest.
    ///   - localURL: On-disk location of the downloaded `.gguf` file.
    ///   - modelType: Defaults to `.gguf` — currently the only supported HuggingFace
    ///     download path through this factory.
    public init?(
        huggingFaceRepoID: String,
        fileName: String,
        sizeBytes: UInt64,
        localURL: URL,
        modelType: ModelType = .gguf
    ) {
        guard localURL.pathExtension.lowercased() == "gguf" else { return nil }
        guard GGUFMetadataReader.isValidGGUF(at: localURL) else { return nil }

        self.id = Self.stableID(for: localURL)
        self.fileName = fileName
        self.name = Self.displayName(from: fileName, strippingExtension: ".gguf")
        self.url = localURL
        self.fileSize = sizeBytes
        self.modelType = modelType
        self.huggingFaceRepoID = huggingFaceRepoID
        self.benchmarkResult = nil

        // Read GGUF header metadata for template detection. mmproj companion scan
        // is skipped — HuggingFace downloads flow file-by-file, not directory-wide.
        do {
            let metadata = try GGUFMetadataReader.readMetadata(from: localURL)
            self.detectedPromptTemplate = PromptTemplateDetector.detect(from: metadata)
            self.detectedContextLength = metadata.contextLength
            self.modelArchitecture = metadata.generalArchitecture
            self.chatTemplateRaw = metadata.chatTemplate
            self.estimatedKVBytesPerToken = GGUFKVCacheEstimator.estimateBytesPerToken(from: metadata)
        } catch {
            Log.inference.warning("ModelInfo: failed to read GGUF metadata from \(localURL.lastPathComponent, privacy: .public): \(error, privacy: .private)")
        }

        // Static tier estimate; may be upgraded by a benchmark result later.
        self.capabilityTier = ModelCapabilityTier.estimate(from: self)
    }
}
