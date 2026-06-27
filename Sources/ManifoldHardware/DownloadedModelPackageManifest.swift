import Foundation

/// Narrow on-disk readiness marker for multi-file model packages.
///
/// This is deliberately local storage metadata, not the catalog/sidecar manifest
/// layer tracked by #977. Downloaders write it only after every component file has
/// been validated and moved into its final package directory, so discovery can
/// treat the package atomically.
public struct DownloadedModelPackageManifest: Codable, Hashable, Sendable {
    public static let fileName = ".manifoldkit-package.json"

    public let packageKind: ModelPackageKind
    public let id: String
    public let displayName: String
    public let format: ImageModelFormat?
    public let huggingFaceRepoID: String?
    public let files: [String]
    /// Numeric precision of the on-disk weights for diffusion packages. Optional
    /// so pre-fp16-detection manifests still decode; missing → consumers should
    /// treat as full-precision.
    public let variant: PrecisionVariant?

    /// SHA-256 (lowercase hex) of the GGUF-embedded chat template captured when
    /// this package was written. Optional so manifests produced before #1932 —
    /// and packages with no chat template — still decode. The load path compares
    /// this against the freshly-loaded template's digest to detect a template
    /// that changed underneath a cached selection; a mismatch warns, never gates.
    public let chatTemplateSHA256: String?

    public init(
        packageKind: ModelPackageKind,
        id: String,
        displayName: String,
        format: ImageModelFormat? = nil,
        huggingFaceRepoID: String? = nil,
        files: [String],
        variant: PrecisionVariant? = nil,
        chatTemplateSHA256: String? = nil
    ) {
        self.packageKind = packageKind
        self.id = id
        self.displayName = displayName
        self.format = format
        self.huggingFaceRepoID = huggingFaceRepoID
        self.files = files
        self.variant = variant
        self.chatTemplateSHA256 = chatTemplateSHA256
    }
}

/// Logical package kinds that share the multi-component download machinery.
public enum ModelPackageKind: String, Codable, Hashable, Sendable {
    /// Existing text MLX snapshot layout (`config.json` + safetensors).
    case mlxSnapshot
    /// Diffusers-style image package (`model_index.json`, transformer/UNet, VAE,
    /// text encoder, tokenizer, and scheduler components).
    case diffusion
}

