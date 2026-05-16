import Foundation

/// Numeric precision of the tensor weights actually fetched for a model package.
///
/// Diffusion repos on the Hugging Face Hub commonly ship two parallel weight
/// sets: the full-precision `*.safetensors` files and `*.fp16.safetensors`
/// half-precision counterparts. The fp16 variant is roughly half the disk
/// footprint and the right default for inference on Apple Silicon, so the
/// downloader prefers it when available. This enum records what was actually
/// pulled so consumers (UI, loaders) don't have to re-derive it from filenames.
///
/// Defaults to ``fullPrecision`` for back-compat: packages downloaded before
/// fp16 detection shipped have no `variant` field in their on-disk manifest,
/// and the decoder treats absence as full-precision.
public enum PrecisionVariant: String, Codable, Hashable, Sendable {
    /// Full-precision weights — the plain `*.safetensors` file set
    /// (typically fp32 in the on-disk tensor metadata, but the runtime may
    /// up- or down-cast at load time).
    case fullPrecision
    /// Half-precision weights — the `*.fp16.safetensors` file set.
    case fp16
}
