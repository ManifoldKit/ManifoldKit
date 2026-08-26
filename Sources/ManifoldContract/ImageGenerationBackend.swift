import Foundation

/// Common interface for on-device image generation backends.
///
/// Mirrors ``InferenceBackend`` in shape and rationale. Each conformer wraps
/// a different image-gen engine (MLX diffusion, Core ML / Stable Diffusion,
/// stable-diffusion.cpp via GGUF, or a future Apple-provided system API) and
/// exposes the same async streaming API.
///
/// ## Why `AnyObject + Sendable`, not `Actor`
///
/// Diffusion inference looks like text inference under the hood: a long-
/// running synchronous C / Metal call across the denoising loop. Modeling the
/// protocol as an `Actor` would hold isolation across that 6–10s loop and
/// block ``isLoaded`` / ``stopGeneration()`` / ``unloadModel()`` from the
/// UI. ``InferenceBackend`` solved this with reference semantics + fine-
/// grained `NSLock`; this protocol follows the same pattern so both
/// backend protocols share one isolation strategy.
///
/// Conformers protect mutable state with `NSLock` (or `@unchecked Sendable`
/// actor isolation) per the existing pattern; ``stopGeneration()`` and
/// ``unloadModel()`` may arrive concurrently from the main actor while
/// generation runs on a detached task and must remain synchronous.
public protocol ImageGenerationBackend: AnyObject, Sendable {

    /// Whether a model is currently resident in memory and ready to serve
    /// `generate()` calls without an additional ``loadModel(from:)``.
    var isLoaded: Bool { get }

    /// Whether a `generate()` call is currently in flight. Mirrors
    /// ``InferenceBackend/isGenerating`` so callers can synchronously check
    /// that ``stopGeneration()`` took effect.
    var isGenerating: Bool { get }

    /// Loads a diffusion model from the given URL.
    ///
    /// Concrete URL semantics are backend-specific:
    /// - GGUF backends: a single `.gguf` file.
    /// - MLX backends: a directory containing `config.json` + safetensors.
    /// - Core ML backends: a `.mlpackage` or compiled `.mlmodelc` directory.
    /// - System backends (e.g. a future Core AI image API): a URL agreed
    ///   on with that backend.
    func loadModel(from url: URL) async throws

    /// Generates an image from a prompt, streaming events as the denoising
    /// loop progresses.
    ///
    /// Errors during generation are thrown into the stream; callers iterate
    /// the returned `AsyncThrowingStream` and observe ``ImageGenerationEvent``
    /// values until either ``ImageGenerationEvent/completed(_:)`` or a
    /// thrown error terminates it.
    ///
    /// ## Output destination contract
    ///
    /// Backends MUST honour ``ImageGenerationConfig/outputDirectory`` when
    /// it is non-`nil`: the URL surfaced in
    /// ``ImageGenerationEvent/completed(_:)`` must resolve under that
    /// directory. When `outputDirectory` is `nil` the backend picks its
    /// own location (typically `FileManager.default.temporaryDirectory`).
    /// Either way, the file at the emitted URL must be fully written and
    /// closed before the event is yielded.
    ///
    /// ## Step-count resolution contract
    ///
    /// When ``ImageGenerationConfig/steps`` is `nil` the backend MUST resolve
    /// its own loaded model's preset default (e.g. ~2 for a distilled model
    /// like SDXL Turbo, 20–50 for full-precision diffusion) rather than
    /// substituting a fixed constant that fits no model in particular. When
    /// `steps` is non-`nil` the backend uses that value, clamped to whatever
    /// range it supports.
    ///
    /// Either way, every ``ImageGenerationEvent/progress(step:total:)`` (and
    /// ``ImageGenerationEvent/preview(step:total:image:)``) the backend emits
    /// MUST carry the actually-resolved step count in `total` — including the
    /// very first tick. A backend that reports `total: 0` while it figures
    /// out the real count leaves UI consumers (e.g.
    /// `GeneratedMediaProgressCardView`) stuck showing a zero-width progress
    /// bar and a "Starting…" label for the entire run, because nothing ever
    /// corrects `total` afterward. Resolve the count before yielding the
    /// first `.progress`/`.preview` event, not lazily on some later tick.
    func generate(
        prompt: String,
        config: ImageGenerationConfig
    ) throws -> AsyncThrowingStream<ImageGenerationEvent, Error>

    /// Requests that the current generation stop as soon as possible.
    ///
    /// After return, the backend MUST satisfy: in-flight generation is
    /// cancelled, the backend accepts a new ``generate(prompt:config:)`` call
    /// without ``loadModel(from:)`` first, and ``isGenerating`` reads
    /// `false`. No-op when no generation is in progress. Mirrors
    /// ``InferenceBackend/stopGeneration()``.
    func stopGeneration()

    /// Unloads the model and frees all associated memory.
    func unloadModel()
}
