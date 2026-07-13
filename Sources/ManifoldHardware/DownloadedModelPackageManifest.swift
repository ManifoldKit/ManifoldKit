import Foundation

/// Narrow on-disk readiness marker for multi-file model packages.
///
/// This is deliberately local storage metadata, not the catalog/sidecar manifest
/// layer tracked by #977. Downloaders write it only after every component file has
/// been validated and moved into its final package directory, so discovery can
/// treat the package atomically.
package struct DownloadedModelPackageManifest: Codable, Hashable, Sendable {
    package static let fileName = ".manifoldkit-package.json"

    package let packageKind: ModelPackageKind
    package let id: String
    package let displayName: String
    package let format: ImageModelFormat?
    package let huggingFaceRepoID: String?
    package let files: [String]
    /// Numeric precision of the on-disk weights for diffusion packages. Optional
    /// so pre-fp16-detection manifests still decode; missing → consumers should
    /// treat as full-precision.
    package let variant: PrecisionVariant?

    /// SHA-256 (lowercase hex) of the package's embedded chat template, for
    /// chat-template drift detection (#1932). Optional so manifests produced
    /// before #1932 — and packages with no chat template — still decode.
    ///
    /// This is the **multi-file/package** recording home. Single-file GGUFs
    /// instead use the per-file `ChatTemplateIntegritySidecar` (they have no
    /// package directory). The load path reads the per-file sidecar first and
    /// falls back to this field; a mismatch warns and proceeds, never gates.
    /// Currently unwritten in core — multi-file/MLX coverage is a documented
    /// follow-up (those types carry no load-time `chatTemplateRaw` without
    /// altering rendering); kept so that coverage is an additive write.
    package let chatTemplateSHA256: String?

    package init(
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

