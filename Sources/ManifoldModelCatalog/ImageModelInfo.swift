import Foundation
import ManifoldHardware

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

    /// Numeric precision of the weights actually on disk. Set by the
    /// downloader when it picks an fp16 vs full-precision variant for a
    /// diffusion package; defaults to ``PrecisionVariant/fullPrecision``
    /// for locally-discovered models and any package whose manifest
    /// pre-dates fp16 detection.
    public let variant: PrecisionVariant

    public init(
        id: String,
        name: String,
        directoryURL: URL,
        format: ImageModelFormat,
        fileSize: Int64,
        huggingFaceRepoID: String? = nil,
        variant: PrecisionVariant = .fullPrecision
    ) {
        self.id = id
        self.name = name
        self.directoryURL = directoryURL
        self.format = format
        self.fileSize = fileSize
        self.huggingFaceRepoID = huggingFaceRepoID
        self.variant = variant
    }

    // Custom decoder so packages downloaded before fp16 detection (no
    // `variant` key on disk) continue to decode as `.fullPrecision`.
    private enum CodingKeys: String, CodingKey {
        case id, name, directoryURL, format, fileSize, huggingFaceRepoID, variant
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.directoryURL = try container.decode(URL.self, forKey: .directoryURL)
        self.format = try container.decode(ImageModelFormat.self, forKey: .format)
        self.fileSize = try container.decode(Int64.self, forKey: .fileSize)
        self.huggingFaceRepoID = try container.decodeIfPresent(String.self, forKey: .huggingFaceRepoID)
        self.variant = try container.decodeIfPresent(PrecisionVariant.self, forKey: .variant) ?? .fullPrecision
    }

    /// Human-readable file size (e.g. `"4.2 GB"`).
    public var fileSizeFormatted: String {
        ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
    }
}
