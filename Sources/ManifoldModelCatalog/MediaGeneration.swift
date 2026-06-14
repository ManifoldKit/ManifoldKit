import Foundation

/// Streaming event emitted by a one-shot media generation backend.
///
/// Generic mirror of the existing ``ImageGenerationEvent`` shape, parameterised
/// over the preview payload type so each modality can carry the cheapest
/// in-memory preview representation (encoded image `Data` for images, raw PCM
/// for audio, etc.). One-shot lifecycle only: progress ticks, optional
/// previews, then a single terminal ``completed``.
///
/// ## Invariant: not a `GenerationEvent`
///
/// This type is deliberately *off* the text ``GenerationEvent`` path. The text
/// event enum stays closed to media (audit:
/// `GenerationEventClosedAuditTest`). Media generation is a separate seam with
/// its own event stream.
public enum MediaGenerationEvent<Preview: Sendable>: Sendable {

    /// Progress tick. `step` is 1-indexed and monotonically increasing within a
    /// single generation; `total` matches the caller-requested step count
    /// (after any backend-side clamping).
    case progress(step: Int, total: Int)

    /// Intermediate preview of the in-progress generation at step `step` of
    /// `total`. Opt-in — backends only emit this when previews are requested.
    /// The preview payload is in-memory and is *not* persisted by the runtime.
    case preview(step: Int, total: Int, preview: Preview)

    /// Terminal event: generation finished and the artifact was written to
    /// `url`. The file at `url` is fully closed and safe to read.
    case completed(URL)
}

/// Generic one-shot media generation seam.
///
/// Namespaces the per-modality value types (config, event, preview) so a
/// modality is described by a single `MediaGeneration<Output>` specialisation
/// rather than a fan-out of loosely-related top-level types. Additive: the
/// existing `ImageGenerationConfig` / `ImageGenerationEvent` pipeline is
/// untouched (that migration is deferred to the manifold-mlx lockstep
/// release). Out-of-tree consumers can declare their own
/// `MediaGeneration<MyOutput>` to add a modality without touching core.
///
/// `Output` is the per-modality runtime config the caller hands a backend
/// (e.g. ``ImageGenerationConfig``, ``VideoGenerationConfig``,
/// ``SpeechGenerationConfig``).
public enum MediaGeneration<Output: Sendable> {
    /// The runtime configuration type for this modality.
    public typealias Config = Output
}

/// Image one-shot media generation, configured by ``ImageGenerationConfig``.
public typealias ImageGeneration = MediaGeneration<ImageGenerationConfig>

/// Video one-shot media generation, configured by ``VideoGenerationConfig``.
public typealias VideoGeneration = MediaGeneration<VideoGenerationConfig>

/// Audio one-shot media generation (text-to-speech), configured by
/// ``SpeechGenerationConfig``. Music generation is a consumer/companion
/// extension, not a core modality.
public typealias AudioGeneration = MediaGeneration<SpeechGenerationConfig>
