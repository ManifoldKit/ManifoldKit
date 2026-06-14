import Foundation
// @_spi(BackendInternals): GGUFKVCacheEstimator was promoted from `package`
// to SPI-public in v0.48 (PR C2) for the manifold-llama companion package.
@_spi(BackendInternals) import ManifoldHardware

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

    /// Approximate quantized bytes streamed per decode token-pass — the active
    /// experts plus always-on weights. For dense models this equals the total
    /// weight size; `nil` means dense-or-unknown, and callers fall back to total
    /// size. Used only to rank MoE decode speed, never for memory-fit (all
    /// experts must be resident).
    ///
    // Left `nil` on every GGUF path for now: the header-only GGUFMetadataReader
    // never sums per-tensor bytes (it deliberately skips the tensor section), so
    // a sound active-byte estimate from expert_count/feed_forward_length alone is
    // not derivable here without inventing numbers. Reserved for curated/manifest
    // population, which carries trustworthy active-weight sizes.
    public var activeParameterBytes: UInt64?

    // MARK: - Capability

    /// Static capability tier for this model, derived from file size at init time.
    /// When `nil`, ``effectiveCapabilityTier`` falls back to a static estimate.
    public var capabilityTier: ModelCapabilityTier?

    // MARK: - Capability flags (override-over-detected)

    // Each capability flag is modelled as two layers so consumers stop
    // re-deriving what the catalog can compute *honestly*:
    //
    //   • `detected*` — what ManifoldKit inferred from durable signals
    //     (HF `config.json` + README front-matter via ``ModelCapabilityProbe``,
    //     or ``CloudModelManifestTable`` for cloud reasoning). `nil` means "no
    //     detection ran / no signal" — NOT "false". GGUF single files carry no
    //     `config.json`, so their detected code/multilingual stay `nil`.
    //
    //   • `curated*` — an explicit override a host app's ``CuratedModel`` list
    //     (or any curation seam) can set to assert a capability the probe
    //     cannot see. Non-nil always wins over detection.
    //
    // The public ``supportsCode`` / ``supportsMultilingual`` / ``supportsReasoning``
    // accessors resolve `curated ?? detected ?? false`, so the default is an
    // honest `false` with no silent over-reporting and an explicit override seam.

    /// Curation override for code-generation capability. `nil` defers to detection.
    public var curatedSupportsCode: Bool?
    /// Auto-detected code-generation capability (HF `config.json` / README).
    /// `nil` when no probe ran or no signal was found (e.g. GGUF single files).
    public var detectedSupportsCode: Bool?

    /// Curation override for multilingual capability. `nil` defers to detection.
    public var curatedSupportsMultilingual: Bool?
    /// Auto-detected multilingual capability (HF `config.json` / README).
    /// `nil` when no probe ran or no signal was found (e.g. GGUF single files).
    public var detectedSupportsMultilingual: Bool?

    /// Curation override for reasoning/extended-thinking capability.
    /// `nil` defers to detection.
    public var curatedSupportsReasoning: Bool?
    /// Auto-detected reasoning capability. Sourced from
    /// ``CloudModelManifestTable`` for cloud models; `nil` for local models
    /// (GGUF/MLX/Foundation), which ManifoldKit cannot honestly probe for
    /// reasoning support — so ``supportsReasoning`` is `false` for local models
    /// unless curated. See the `Capabilities` DocC article for the routing footgun.
    public var detectedSupportsReasoning: Bool?

    /// Resolved code-generation capability: `curated ?? detected ?? false`.
    public var supportsCode: Bool {
        curatedSupportsCode ?? detectedSupportsCode ?? false
    }

    /// Resolved multilingual capability: `curated ?? detected ?? false`.
    public var supportsMultilingual: Bool {
        curatedSupportsMultilingual ?? detectedSupportsMultilingual ?? false
    }

    /// Resolved reasoning capability: `curated ?? detected ?? false`.
    ///
    /// Honest-`false` for local models unless curated — there is no reliable
    /// local-model reasoning signal. A routing snippet that branches on this
    /// silently takes the `false` branch for every uncurated local model.
    public var supportsReasoning: Bool {
        curatedSupportsReasoning ?? detectedSupportsReasoning ?? false
    }

    /// Applies a curation override, copying the three capability flags from a
    /// ``CuratedModelCapabilities`` value. Only non-nil fields override; `nil`
    /// leaves the existing detected/curated layer untouched. This is the
    /// explicit seam for a host's curated list to assert capabilities the probe
    /// cannot derive — notably for GGUF single files (no `config.json`) and for
    /// local-model reasoning.
    public mutating func applyCuratedCapabilities(_ caps: CuratedModelCapabilities) {
        if let code = caps.supportsCode { curatedSupportsCode = code }
        if let multilingual = caps.supportsMultilingual { curatedSupportsMultilingual = multilingual }
        if let reasoning = caps.supportsReasoning { curatedSupportsReasoning = reasoning }
    }

    /// Populates the detected code/multilingual layers from a HF/MLX model
    /// directory using ``ModelCapabilityProbe``.
    ///
    /// **GGUF limit:** single-file GGUF models have no sibling `config.json`,
    /// so the probe throws ``ModelCapabilityProbeError/configNotFound``. That is
    /// treated here as "no detection" (leaves the detected layers `nil`), NOT a
    /// fatal error — GGUF code/multilingual ship honest-`false` unless a host's
    /// curated list overrides them via ``applyCuratedCapabilities(_:)``.
    /// Reasoning is never sourced from a config probe; it stays `nil` for local
    /// models. See the `Capabilities` DocC article.
    public mutating func detectCapabilities(fromModelDirectory directory: URL) {
        do {
            let caps = try ModelCapabilityProbe.probe(modelDirectory: directory)
            detectedSupportsCode = caps.supportsCodeGeneration
            detectedSupportsMultilingual = caps.supportsMultilingual
        } catch ModelCapabilityProbeError.configNotFound {
            // Expected for GGUF single files and snapshots that strip config.json.
            // No signal → leave detected layers nil so resolution falls to
            // curated-or-false rather than a misleading hard `false`.
            Log.inference.debug("ModelInfo: no config.json for capability probe at \(directory.lastPathComponent, privacy: .public); code/multilingual stay curated-or-false")
        } catch {
            Log.inference.warning("ModelInfo: capability probe failed at \(directory.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

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
        benchmarkResult?.tier ?? capabilityTier ?? ModelCapabilityTier.estimate(fileSize: fileSize, modelType: modelType)
    }

    /// Human-readable file size (e.g. "2.3 GB").
    public var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(fileSize), countStyle: .file)
    }

    /// Quantization tag parsed from the GGUF filename (e.g. "Q4_K_M", "Q8_0"), or
    /// `nil` for non-GGUF models and filenames that carry no recognisable tag.
    ///
    /// Mirrors ``DownloadableModel/quantization`` so an on-disk model and its
    /// downloadable twin resolve to the same tag — the fit scorer reads this to
    /// derive the quality dimension's quantization-width factor.
    public var quantization: String? {
        guard modelType == .gguf else { return nil }
        // Match common GGUF quant patterns: Q4_K_M, Q8_0, IQ2_XS, F16, etc.
        // The trailing `_SEGMENT` repetition is bounded to {0,5} to prevent
        // catastrophic backtracking on crafted filenames; input is clipped to
        // 128 chars (any legitimate HuggingFace filename fits well under that).
        let pattern = #"[_\-\.]((?:Q|IQ|F|BF)\d+(?:_[A-Z0-9]+){0,5})\."#
        let boundedName = String(fileName.prefix(128))
        guard let range = boundedName.range(of: pattern, options: .regularExpression) else { return nil }
        return String(boundedName[range].dropFirst().dropLast())
    }

    /// Short label for the backend type.
    public var backendLabel: String {
        BackendDescriptorRegistry.shared.descriptor(for: modelType)?.backendLabel
            ?? String(describing: modelType)
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
        self.capabilityTier = ModelCapabilityTier.estimate(fileSize: fileSize, modelType: modelType)

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

    // MARK: - GGUF Throwing Loader

    /// Loads a `ModelInfo` from a `.gguf` file URL, throwing a typed
    /// ``ModelDiscoveryError`` when the load fails.
    ///
    /// Use this when the caller needs to surface *why* a local GGUF could not
    /// be turned into a `ModelInfo` (e.g. the model-management sheet wants to
    /// show "file missing" vs "not a GGUF" vs "header could not be parsed").
    /// The optional ``init(ggufURL:)`` initialiser remains the lower-friction
    /// best-effort entry point used by directory scans.
    ///
    /// Header metadata parse failures are treated as **non-fatal**: a
    /// `ModelInfo` is still returned (so the user can still try to load the
    /// model and see the real backend error), but with empty template /
    /// context-length fields. Callers that want to react to the metadata
    /// failure can inspect the returned ``ModelInfo/detectedPromptTemplate``
    /// being `nil`.
    ///
    /// - Parameter mmprojURL: An already-resolved companion projector URL.
    ///   When a directory scan enumerates the parent directory once and threads
    ///   the resolved candidate in (see `ModelStorageService.scanDirectory`),
    ///   the per-file self-enumeration is skipped — turning an O(K²) scan into
    ///   O(K) (#1787). Pass `nil` from the standalone entry point to keep the
    ///   self-enumerating fallback.
    public static func load(ggufURL url: URL, mmprojURL: URL? = nil) throws -> ModelInfo {
        let path = url.path

        guard url.pathExtension.lowercased() == "gguf" else {
            throw ModelDiscoveryError.notGGUF(path: path)
        }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw ModelDiscoveryError.fileMissing(path: path)
        }
        if isDirectory.boolValue {
            throw ModelDiscoveryError.unexpectedFileKind(path: path, detail: "expected .gguf file, found directory")
        }
        guard fileManager.isReadableFile(atPath: path) else {
            throw ModelDiscoveryError.notReadable(path: path, reason: "file is not readable by this process")
        }
        guard GGUFMetadataReader.isValidGGUF(at: url) else {
            throw ModelDiscoveryError.notGGUF(path: path)
        }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: path)
        } catch {
            throw ModelDiscoveryError.notReadable(path: path, reason: error.localizedDescription)
        }
        guard let size = attributes[.size] as? UInt64 else {
            throw ModelDiscoveryError.notReadable(path: path, reason: "missing file size attribute")
        }

        // At this point the file is a real GGUF on disk. Parse header metadata —
        // failures are surfaced as a non-fatal warning so the caller can still
        // build a `ModelInfo` (matching the optional initialiser's behaviour)
        // but discovery code that wants to log the actual reason can catch
        // ``ModelDiscoveryError/metadataReadFailed`` if it switches to the
        // alternate `loadStrict` later.
        var detectedTemplate: PromptTemplate?
        var detectedContextLength: Int?
        var modelArchitecture: String?
        var chatTemplateRaw: String?
        var estimatedKVBytesPerToken: UInt64?
        do {
            let metadata = try GGUFMetadataReader.readMetadata(from: url)
            detectedTemplate = PromptTemplateDetector.detect(from: metadata)
            detectedContextLength = metadata.contextLength
            modelArchitecture = metadata.generalArchitecture
            chatTemplateRaw = metadata.chatTemplate
            estimatedKVBytesPerToken = GGUFKVCacheEstimator.estimateBytesPerToken(from: metadata)
        } catch {
            Log.inference.warning("ModelInfo.load: GGUF metadata parse failed for \(url.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        var info = ModelInfo(
            id: Self.stableID(for: url),
            name: Self.displayName(from: url.lastPathComponent, strippingExtension: ".gguf"),
            fileName: url.lastPathComponent,
            url: url,
            fileSize: size,
            modelType: .gguf,
            detectedPromptTemplate: detectedTemplate,
            detectedContextLength: detectedContextLength,
            modelArchitecture: modelArchitecture,
            chatTemplateRaw: chatTemplateRaw,
            estimatedKVBytesPerToken: estimatedKVBytesPerToken
        )

        // Mirror the optional initialiser's static-tier estimate so the throwing
        // and optional paths produce equivalent ModelInfo values for the same file.
        info.capabilityTier = ModelCapabilityTier.estimate(fileSize: info.fileSize, modelType: info.modelType)

        // Auto-detect a companion mmproj file in the same directory. A model that
        // is itself an mmproj projector never carries a companion.
        if !url.lastPathComponent.lowercased().hasPrefix("mmproj") {
            if let mmprojURL {
                // Directory scan already enumerated the parent once and resolved
                // the candidate — no per-file re-enumeration (#1787).
                info.mmprojURL = mmprojURL
            } else {
                // Standalone entry point (e.g. drag-and-drop import): fall back to
                // self-enumerating the parent directory.
                let parentDir = url.deletingLastPathComponent()
                do {
                    let candidates = try fileManager.contentsOfDirectory(
                        at: parentDir,
                        includingPropertiesForKeys: nil,
                        options: [.skipsHiddenFiles]
                    )
                    info.mmprojURL = candidates.first {
                        $0.lastPathComponent.lowercased().hasPrefix("mmproj") &&
                        $0.pathExtension.lowercased() == "gguf"
                    }
                } catch {
                    Log.inference.warning("ModelInfo.load: mmproj companion scan failed in \(parentDir.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        return info
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
        self.capabilityTier = ModelCapabilityTier.estimate(fileSize: fileSize, modelType: modelType)
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
        activeParameterBytes: UInt64? = nil,
        capabilityTier: ModelCapabilityTier? = nil,
        benchmarkResult: ModelBenchmarkResult? = nil,
        huggingFaceRepoID: String? = nil,
        curatedSupportsCode: Bool? = nil,
        detectedSupportsCode: Bool? = nil,
        curatedSupportsMultilingual: Bool? = nil,
        detectedSupportsMultilingual: Bool? = nil,
        curatedSupportsReasoning: Bool? = nil,
        detectedSupportsReasoning: Bool? = nil
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
        self.activeParameterBytes = activeParameterBytes
        self.capabilityTier = capabilityTier
        self.benchmarkResult = benchmarkResult
        self.huggingFaceRepoID = huggingFaceRepoID
        self.curatedSupportsCode = curatedSupportsCode
        self.detectedSupportsCode = detectedSupportsCode
        self.curatedSupportsMultilingual = curatedSupportsMultilingual
        self.detectedSupportsMultilingual = detectedSupportsMultilingual
        self.curatedSupportsReasoning = curatedSupportsReasoning
        self.detectedSupportsReasoning = detectedSupportsReasoning
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

// MARK: - Curated capability override

/// A curation override for the three resolvable capability flags on
/// ``ModelInfo``.
///
/// Each field is `Bool?`: a non-nil value asserts (or denies) a capability the
/// auto-detection path cannot derive, while `nil` defers to detection. This is
/// the seam a host app's curated list uses to mark, for example, a GGUF coder
/// model `supportsCode = true` even though its single-file format carries no
/// `config.json` for ``ModelCapabilityProbe`` to read.
public struct CuratedModelCapabilities: Sendable, Hashable {
    public var supportsCode: Bool?
    public var supportsMultilingual: Bool?
    public var supportsReasoning: Bool?

    public init(
        supportsCode: Bool? = nil,
        supportsMultilingual: Bool? = nil,
        supportsReasoning: Bool? = nil
    ) {
        self.supportsCode = supportsCode
        self.supportsMultilingual = supportsMultilingual
        self.supportsReasoning = supportsReasoning
    }
}

// MARK: - Cloud reasoning detection

public extension ModelInfo {
    /// Sets ``detectedSupportsReasoning`` from ``CloudModelManifestTable`` for a
    /// cloud model identified by `modelName`.
    ///
    /// Cloud is the one place ManifoldKit can honestly detect reasoning: the
    /// vendored manifest table already tracks which families expose extended
    /// thinking. Pass the producer so the correct table is consulted. Local
    /// models have no equivalent signal — ``supportsReasoning`` stays `false`
    /// for them unless curated.
    mutating func detectCloudReasoning(modelName: String, producer: CloudReasoningProducer) {
        let manifest: ModelManifest
        switch producer {
        case .openAI:
            manifest = CloudModelManifestTable.openAI(modelName: modelName)
        case .anthropic:
            manifest = CloudModelManifestTable.claude(modelName: modelName)
        }
        detectedSupportsReasoning = manifest.supportsThinking
    }

    /// Cloud producer whose manifest table sources reasoning detection.
    enum CloudReasoningProducer: Sendable {
        case openAI
        case anthropic
    }
}

// MARK: - Ownership

public extension ModelInfo {
    /// `true` when this model is provided by the OS / framework and cannot be
    /// deleted by the user. Consumer UI hides destructive affordances and
    /// excludes built-ins from storage accounting.
    ///
    /// Currently equivalent to `modelType == .foundation`, but the semantic
    /// ("the user does not own this file") is the contract consumers should
    /// branch on, not the format.
    var isBuiltIn: Bool {
        modelType == .foundation
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
        self.capabilityTier = ModelCapabilityTier.estimate(fileSize: fileSize, modelType: modelType)
    }
}
