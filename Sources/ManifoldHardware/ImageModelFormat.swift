import Foundation

/// The on-disk format / runtime an image-generation model uses.
///
/// Sibling to ``ModelType`` for text inference. Image models live in their own type
/// space — ``ModelType`` (an extensible struct since arch-plan 4.1 / Wave 2 B1) is
/// scoped to text-inference formats, and image-side code keys off this closed enum
/// instead rather than growing `ModelType` with image-only cases.
///
/// Additional cases (e.g. a `gguf` variant for `stable-diffusion.cpp`, or a `coreAI`
/// case once Apple's Core AI image-gen surface ships) land alongside their conformers
/// rather than as forward-declared placeholders.
public enum ImageModelFormat: String, Codable, Hashable, Sendable, CaseIterable {
    /// A directory containing UNet, VAE, and text-encoder weights in MLX-compatible
    /// safetensors form, plus the configs that describe their topology. Loaded by
    /// the MLX diffusion backend (e.g. via `mlx-swift-examples`'s `StableDiffusion`).
    case mlxDiffusion

    /// A directory containing FLUX.1 Schnell transformer, VAE, and text-encoder
    /// weights in MLX safetensors form. Loaded by `FluxDiffusionBackend` via
    /// `mzbac/flux.swift`. Supports both FP16 and flux.swift 4-bit quantized layouts.
    case fluxSchnell

    /// A cloud HTTP image-generation API (e.g. xAI Grok Imagine).
    /// The backend ignores `directoryURL` from `ImageModelInfo` and makes
    /// HTTP requests instead of loading a local model file.
    case cloudAPI
}
