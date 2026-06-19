import Foundation

/// Common interface for on-device, one-shot text-to-speech (TTS) backends.
///
/// Sibling to ``ImageGenerationBackend`` for the audio modality. Each conformer
/// wraps a different speech engine (Apple `AVSpeechSynthesizer` in core, Kokoro
/// / CSM via the mlx-audio companion, or a cloud TTS provider) and exposes the
/// same async streaming API: render a text prompt into a single audio artifact
/// on disk, streaming ``AudioGenerationEvent`` progress ticks until the terminal
/// ``AudioGenerationEvent/completed(_:)``.
///
/// ## Why no `loadModel`
///
/// Unlike ``ImageGenerationBackend``, the reference TTS backend
/// (`AVSpeechSynthesizer`) needs no model download or weight unpack — the
/// system voices are always resident. The protocol therefore omits a
/// `loadModel(from:)` / `isLoaded` lifecycle: a conformer is ready to
/// `generate` from construction. A companion backend that *does* need to load
/// weights manages that internally (e.g. lazily on first `generate`) rather
/// than widening this contract; keeping the seam minimal is the point.
///
/// ## Why `AnyObject + Sendable`, not `Actor`
///
/// TTS rendering looks like image inference under the hood: a synchronous
/// render call (here, `AVSpeechSynthesizer.write(_:toBufferCallback:)`) driven
/// from a background context. Modeling the protocol as an `Actor` would hold
/// isolation across that render and block ``isGenerating`` / ``stopGeneration()``
/// from the UI. ``ImageGenerationBackend`` solved this with reference semantics
/// + a fine-grained lock; this protocol follows the same pattern so both
/// backend protocols share one isolation strategy. Conformers protect mutable
/// state with `NSLock` (or `OSAllocatedUnfairLock`); ``stopGeneration()`` may
/// arrive concurrently from the main actor while generation runs on a detached
/// task and must remain synchronous.
public protocol AudioGenerationBackend: AnyObject, Sendable {

    /// Whether a `generate()` call is currently in flight. Mirrors
    /// ``ImageGenerationBackend/isGenerating`` so callers can synchronously
    /// check that ``stopGeneration()`` took effect.
    var isGenerating: Bool { get }

    /// Renders `config.text` into a single audio artifact, streaming progress
    /// events as the render proceeds.
    ///
    /// Errors during generation are thrown into the stream; callers iterate the
    /// returned `AsyncThrowingStream` and observe ``AudioGenerationEvent``
    /// values until either ``AudioGenerationEvent/completed(_:)`` or a thrown
    /// error terminates it.
    ///
    /// ## Output destination contract
    ///
    /// Backends MUST honour ``SpeechGenerationConfig/outputDirectory`` when it
    /// is non-`nil`: the URL surfaced in ``AudioGenerationEvent/completed(_:)``
    /// must resolve under that directory. When `outputDirectory` is `nil` the
    /// backend picks its own location (typically
    /// `FileManager.default.temporaryDirectory`). Either way, the file at the
    /// emitted URL must be fully written and closed before the event is
    /// yielded.
    ///
    /// Backends honour the ``SpeechGenerationConfig`` knobs they support
    /// (`voice`, `rate`, `pitch`) and silently ignore the rest, matching the
    /// ``ImageGenerationBackend`` convention.
    func generate(
        config: SpeechGenerationConfig
    ) throws -> AsyncThrowingStream<AudioGenerationEvent, Error>

    /// Requests that the current generation stop as soon as possible.
    ///
    /// After return, the backend MUST satisfy: in-flight generation is
    /// cancelled, the backend accepts a new ``generate(config:)`` call, and
    /// ``isGenerating`` reads `false`. No-op when no generation is in progress.
    /// Mirrors ``ImageGenerationBackend/stopGeneration()``.
    func stopGeneration()
}
