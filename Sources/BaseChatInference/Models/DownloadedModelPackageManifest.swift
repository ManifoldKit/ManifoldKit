import Foundation

/// Narrow on-disk readiness marker for multi-file model packages.
///
/// This is deliberately local storage metadata, not the catalog/sidecar manifest
/// layer tracked by #977. Downloaders write it only after every component file has
/// been validated and moved into its final package directory, so discovery can
/// treat the package atomically.
public struct DownloadedModelPackageManifest: Codable, Hashable, Sendable {
    public static let fileName = ".basechatkit-package.json"

    public let packageKind: ModelPackageKind
    public let id: String
    public let displayName: String
    public let format: ImageModelFormat?
    public let huggingFaceRepoID: String?
    public let files: [String]

    public init(
        packageKind: ModelPackageKind,
        id: String,
        displayName: String,
        format: ImageModelFormat? = nil,
        huggingFaceRepoID: String? = nil,
        files: [String]
    ) {
        self.packageKind = packageKind
        self.id = id
        self.displayName = displayName
        self.format = format
        self.huggingFaceRepoID = huggingFaceRepoID
        self.files = files
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

