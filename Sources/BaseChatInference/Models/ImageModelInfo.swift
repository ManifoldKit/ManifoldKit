import Foundation

/// Identity for an image-generation model on disk.
///
/// Sibling to ``ModelInfo`` for text inference: same shape (identity + path + format
/// + size + optional HuggingFace provenance), narrowed to what every image format
/// needs. Format-specific topology — which file holds the UNet, where the VAE
/// weights live, how many text encoders are present — is the loader's concern,
/// resolved relative to ``directoryURL`` at load time.
///
/// The diffusion-shaped fields were validated against `mlx-swift-examples`'s
/// `StableDiffusion.Configuration.FileKey` enum (UNet config + weights, VAE
/// config + weights, one or two text encoders, scheduler config, tokenizer
/// vocab/merges). Putting individual file URLs on the value type would bloat
/// it and make adding non-MLX formats (e.g. `stable-diffusion.cpp`, future
/// Core AI surfaces) painful — `directoryURL + format` is enough for a loader
/// that knows the topology of its own format. If a later PR's runtime needs
/// richer identity (e.g. cached UNet bytes, target resolution range), those
/// fields are additive at that point.
public struct ImageModelInfo: Codable, Hashable, Identifiable, Sendable {
    /// Stable identifier — typically the HuggingFace repo ID
    /// (e.g. `"stabilityai/sdxl-turbo"`) for downloaded models, or a path-derived
    /// identifier for locally-discovered ones.
    public let id: String

    /// Human-readable display name (e.g. `"SDXL Turbo"`).
    public let name: String

    /// Root directory on disk. Format-specific loaders resolve their files
    /// (UNet, VAE, text encoder(s), tokenizer, scheduler config) within this
    /// directory using the conventions of ``format``.
    public let directoryURL: URL

    /// The format/runtime this model uses.
    public let format: ImageModelFormat

    /// Total size of the model's files on disk, in bytes.
    public let fileSize: Int64

    /// Source HuggingFace repository, when known
    /// (e.g. `"stabilityai/sdxl-turbo"`). `nil` for locally-discovered models
    /// or those distributed outside HuggingFace. Used by the redownload /
    /// update flow.
    public let huggingFaceRepoID: String?

    public init(
        id: String,
        name: String,
        directoryURL: URL,
        format: ImageModelFormat,
        fileSize: Int64,
        huggingFaceRepoID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.directoryURL = directoryURL
        self.format = format
        self.fileSize = fileSize
        self.huggingFaceRepoID = huggingFaceRepoID
    }

    /// Human-readable file size (e.g. `"4.2 GB"`).
    public var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}
