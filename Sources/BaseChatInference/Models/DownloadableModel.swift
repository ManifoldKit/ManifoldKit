import Foundation

/// A model available for download from HuggingFace.
///
/// Created from either the curated list or HuggingFace search results.
/// Separate from `ModelInfo` (which represents an on-disk model) to keep
/// download-time concerns (repo ID, download count) apart from runtime
/// concerns (loaded state, inference backend).
public struct DownloadableModel: Identifiable, Sendable, Hashable {
    /// Unique identifier: `repoID/fileName`.
    public let id: String
    /// HuggingFace repository ID (e.g., "bartowski/Mistral-7B-Instruct-v0.3-GGUF").
    public let repoID: String
    /// File to download (GGUF filename or MLX directory name).
    public let fileName: String
    /// Human-readable name for display.
    public let displayName: String
    /// Which backend this model requires.
    public let modelType: ModelType
    /// Approximate download size in bytes.
    public let sizeBytes: UInt64
    /// HuggingFace download count, for sorting/display.
    public let downloads: Int?
    /// Whether this came from the curated list (vs search).
    public let isCurated: Bool
    /// Known prompt template, if any.
    public let promptTemplate: PromptTemplate?
    /// One-line description for UI.
    public let description: String?

    /// Human-readable size (e.g., "4.1 GB").
    public var sizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
    }

    /// Quantization tag extracted from the filename (e.g., "Q4_K_M", "Q8_0"), or nil.
    public var quantization: String? {
        guard modelType == .gguf else { return nil }
        // Match common GGUF quant patterns: Q4_K_M, Q8_0, IQ2_XS, F16, etc.
        // Bound the trailing `_SEGMENT` repetition to {0,5}: real quant tags top out at
        // two suffix components (e.g. Q4_K_M, IQ2_XXS); five is generous and prevents
        // catastrophic backtracking on crafted filenames like `_Q4_AAA_AAA..._AAAX.gguf`.
        let pattern = #"[_\-\.]((?:Q|IQ|F|BF)\d+(?:_[A-Z0-9]+){0,5})\."#
        // Cap input length before regex evaluation. Any legitimate HuggingFace filename
        // fits well under 128 characters; longer input is assumed hostile and clipped
        // to keep the regex engine in a bounded work envelope.
        let boundedName = String(fileName.prefix(128))
        guard let range = boundedName.range(of: pattern, options: .regularExpression) else { return nil }
        let match = boundedName[range].dropFirst().dropLast() // strip leading separator and trailing dot
        return String(match)
    }

    // MARK: - Factory from CuratedModel

    public init(from curated: CuratedModel) {
        self.id = "\(curated.repoID)/\(curated.fileName)"
        self.repoID = curated.repoID
        self.fileName = curated.fileName
        self.displayName = curated.displayName
        self.modelType = curated.modelType
        self.sizeBytes = curated.approximateSizeBytes
        self.downloads = nil
        self.isCurated = true
        self.promptTemplate = curated.promptTemplate
        self.description = curated.description
    }

    // MARK: - Memberwise

    public init(
        repoID: String,
        fileName: String,
        displayName: String,
        modelType: ModelType,
        sizeBytes: UInt64,
        downloads: Int? = nil,
        isCurated: Bool = false,
        promptTemplate: PromptTemplate? = nil,
        description: String? = nil
    ) {
        self.id = "\(repoID)/\(fileName)"
        self.repoID = repoID
        self.fileName = fileName
        self.displayName = displayName
        self.modelType = modelType
        self.sizeBytes = sizeBytes
        self.downloads = downloads
        self.isCurated = isCurated
        self.promptTemplate = promptTemplate
        self.description = description
    }
}

// MARK: - File Name Validation

/// Errors raised by ``DownloadableModel/validate(fileName:)``.
///
/// Kept `internal` deliberately: host apps should catch plain `Error` from
/// `validate(fileName:)` and surface `localizedDescription`. Pinning the
/// concrete cases as public API would freeze the category list and force
/// downstream switches to change every time a new rejection rule is added.
enum FileNameError: LocalizedError, Equatable {
    case empty
    /// `..` or `.` component — classic path traversal.
    case pathTraversal
    /// Backslash anywhere in the input. Never legitimate on Apple platforms.
    case backslash
    /// Empty path component — either a leading `/`, trailing `/`, or `//` in the middle.
    case emptyComponent
    /// The filename contains more than one `/`. Only a single namespace/name
    /// split is legitimate for curated MLX snapshot filenames; `a/b/c` is not
    /// a HuggingFace filename pattern BaseChatKit honours.
    case tooManyComponents
    /// Any component begins with `.` — hides the file and collides with
    /// system metadata (`.DS_Store`, `.git`, etc.).
    case hidden
    case tooLong
    case controlCharacter

    var errorDescription: String? {
        switch self {
        case .empty:
            return "Model filename is empty."
        case .pathTraversal:
            return "Model filename contains a path-traversal component (\".\" or \"..\")."
        case .backslash:
            return "Model filename contains a backslash, which is not a valid path separator on Apple platforms."
        case .emptyComponent:
            return "Model filename contains an empty path component (leading, trailing, or consecutive \"/\")."
        case .tooManyComponents:
            return "Model filename contains more than one \"/\"; only <namespace>/<name> is permitted."
        case .hidden:
            return "Model filename contains a component that starts with a dot, which is not permitted."
        case .tooLong:
            return "Model filename exceeds the 255-character limit."
        case .controlCharacter:
            return "Model filename contains control characters."
        }
    }
}

extension DownloadableModel {

    /// Maximum permitted length for the entire filename string and each component.
    ///
    /// 255 is the POSIX `NAME_MAX` on HFS+/APFS; longer names cannot be written
    /// to disk regardless of other checks.
    static let maxFileNameLength = 255

    /// Validates that a filename is safe to append to a base directory URL.
    ///
    /// This is a belt-and-suspenders check layered on top of the URL-standardized
    /// `hasPrefix` guards used by `BackgroundDownloadManager` when moving files
    /// into the models directory. The validator runs at the earliest point a
    /// filename is accepted from external input (manifests, Hub search results)
    /// so malformed input is rejected before it reaches any filesystem operation.
    ///
    /// ### Accepted shapes
    ///
    /// - `model.Q4_K_M.gguf` — a plain GGUF filename.
    /// - `mlx-community/Phi-4-mini-instruct-4bit` — a single-slash namespace /
    ///   repo pair used by curated MLX snapshot models.
    ///
    /// ### Rejected shapes
    ///
    /// - Empty or `>= 255` chars.
    /// - Backslash anywhere (Windows-style or filesystem-confusion payloads).
    /// - Any C0/C1 control character or DEL (can truncate at the C boundary).
    /// - Any `..` or `.` component — classic path traversal.
    /// - A leading, trailing, or consecutive `/` (empty component).
    /// - More than one `/` — `a/b/c` is not a HuggingFace filename pattern we
    ///   honour, so reject it rather than silently accepting a sub-path write.
    /// - Any component that begins with `.` — hides the file and can collide
    ///   with system metadata (`.DS_Store`, `.git`, …).
    ///
    /// - Parameter fileName: The untrusted filename string.
    /// - Throws: A `FileNameError` (caught as `Error` by public callers)
    ///   describing the first rule the input violates.
    public static func validate(fileName: String) throws {
        guard !fileName.isEmpty else { throw FileNameError.empty }
        guard fileName.count < maxFileNameLength else { throw FileNameError.tooLong }
        // Backslashes are never legitimate on Apple platforms and are always a
        // sign of Windows-style traversal or filesystem confusion attacks.
        guard !fileName.contains("\\") else { throw FileNameError.backslash }
        // Reject null bytes, C0 controls (0x00–0x1F), DEL (0x7F), and the C1
        // range (0x80–0x9F). Beyond obvious truncation hazards (null byte),
        // C1 contains U+0085 NEXT LINE which renders invisibly and would
        // confuse log output and shell tooling.
        guard fileName.unicodeScalars.allSatisfy({ scalar in
            let v = scalar.value
            return v >= 0x20 && v != 0x7F && !(0x80...0x9F).contains(v)
        }) else {
            throw FileNameError.controlCharacter
        }

        // Inspect each forward-slash-separated segment. Legitimate MLX filenames
        // contain one slash (namespace/name); traversal payloads contain "..".
        // We classify components *before* counting them so that a deep payload
        // like "../../etc/passwd" surfaces `.pathTraversal` (actionable) rather
        // than `.tooManyComponents` (an architectural rejection).
        let components = fileName.split(separator: "/", omittingEmptySubsequences: false)
        for component in components {
            guard component != ".." else { throw FileNameError.pathTraversal }
            guard component != "." else { throw FileNameError.pathTraversal }
        }
        // More than two components = more than one slash = not a shape we honour.
        guard components.count <= 2 else { throw FileNameError.tooManyComponents }
        for component in components {
            // Empty component means "//" or a leading/trailing "/" — always malformed.
            guard !component.isEmpty else { throw FileNameError.emptyComponent }
            // A leading dot on any component hides the file and can collide
            // with system metadata (.DS_Store, .git, etc.).
            guard !component.hasPrefix(".") else { throw FileNameError.hidden }
            guard component.count < maxFileNameLength else { throw FileNameError.tooLong }
        }
    }
}

// MARK: - Grouped Models

/// Groups multiple downloadable variants (quant levels) under one repo.
public struct DownloadableModelGroup: Identifiable {
    public let id: String  // repoID
    public let repoID: String
    public let displayName: String
    public let downloads: Int?
    public let variants: [DownloadableModel]

    /// Human-readable size range (e.g., "1.6 GB – 7.7 GB"), or nil if all sizes are zero.
    public var sizeRange: String? {
        let sizes = variants.map(\.sizeBytes).filter { $0 > 0 }
        guard let minSize = sizes.min(), let maxSize = sizes.max() else { return nil }
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        if minSize == maxSize {
            return fmt.string(fromByteCount: Int64(minSize))
        }
        return "\(fmt.string(fromByteCount: Int64(minSize))) – \(fmt.string(fromByteCount: Int64(maxSize)))"
    }

    /// Groups a flat list of downloadable models by their `repoID`.
    ///
    /// When `sortKey` is provided, groups are sorted by that key first (ascending),
    /// then by HuggingFace download count (descending) within the same key value.
    /// Without a sort key, groups are sorted by download count only.
    public static func group(
        _ models: [DownloadableModel],
        sortKey: ((DownloadableModelGroup) -> Int)? = nil
    ) -> [DownloadableModelGroup] {
        let grouped = Dictionary(grouping: models, by: \.repoID)
        let groups = grouped.map { repoID, variants in
            // Use the shortest display name as the group name (avoids quant suffix).
            let baseName = variants
                .map(\.displayName)
                .min(by: { $0.count < $1.count }) ?? repoID
            // Clean up common suffixes from the group name.
            let cleanName = Self.cleanGroupName(baseName)
            return DownloadableModelGroup(
                id: repoID,
                repoID: repoID,
                displayName: cleanName,
                downloads: variants.first?.downloads,
                variants: variants.sorted { $0.sizeBytes < $1.sizeBytes }
            )
        }

        if let sortKey {
            return groups.sorted {
                let keyA = sortKey($0)
                let keyB = sortKey($1)
                if keyA != keyB { return keyA < keyB }
                return ($0.downloads ?? 0) > ($1.downloads ?? 0)
            }
        }

        return groups.sorted { ($0.downloads ?? 0) > ($1.downloads ?? 0) }
    }

    /// Returns the recommended variant for the given device capability.
    ///
    /// The recommended variant is the largest quantization (by `sizeBytes`) that still
    /// passes `ModelLoadPlan.canRunModel`. When no variant fits, returns the smallest
    /// variant (the most likely to succeed at runtime).
    public func recommendedVariant(for deviceCapability: DeviceCapabilityService) -> DownloadableModel? {
        guard !variants.isEmpty else { return nil }

        let physical = deviceCapability.physicalMemory
        // Variants are already sorted ascending by sizeBytes (see group()).
        // The largest fitting variant is the last one that passes the check.
        let fittingVariants = variants.filter {
            $0.sizeBytes > 0 && ModelLoadPlan.canRunModel(sizeBytes: $0.sizeBytes, physicalMemoryBytes: physical)
        }

        if let best = fittingVariants.last {
            return best
        }

        // No variant fits — return the smallest as a fallback.
        return variants.first
    }

    private static func cleanGroupName(_ name: String) -> String {
        // Remove trailing quant identifiers like "Q4 K M", "IQ2 XS", etc.
        let pattern = #"\s+(?:Q|IQ|F|BF)\d+.*$"#
        guard let range = name.range(of: pattern, options: .regularExpression) else { return name }
        let cleaned = String(name[..<range.lowerBound])
        return cleaned.isEmpty ? name : cleaned
    }
}
