import Foundation

/// Streaming event emitted by an ``AudioGenerationBackend`` during a one-shot
/// text-to-speech (TTS) generation run.
///
/// Sibling to ``ImageGenerationEvent`` / ``VideoGenerationEvent`` for the audio
/// modality. Two cases: progress ticks while the synthesiser renders, and a
/// single terminal ``completed`` carrying a file URL pointing at the produced
/// audio artifact.
///
/// ## Why `URL`, not raw samples?
///
/// Persisted audio messages reference the artifact by file URL (see
/// ``GeneratedMediaPayload`` with ``MediaKind/audio``); the binary lives on
/// disk in the app container rather than in SwiftData. Surfacing the file URL
/// directly from the backend keeps the inference layer free of audio-buffer
/// bridging concerns and avoids a `PCM → encode → disk` re-encode in the
/// persistence layer. Backends are responsible for writing to a
/// caller-controlled location and emitting the URL once the file is fully on
/// disk.
///
/// ## One-shot only — no preview
///
/// Unlike ``ImageGenerationEvent``, audio generation has no `preview` case: a
/// TTS render produces its artifact in one pass, so there is no
/// progressively-refining intermediate to surface. Realtime/duplex speech is a
/// different surface (#1415) and out of scope.
public enum AudioGenerationEvent: Sendable {

    /// Progress tick while the synthesiser renders.
    ///
    /// `step` is 1-indexed and monotonically increasing within a single
    /// generation; `total` is the backend's estimate of the total number of
    /// ticks (e.g. one per rendered buffer) after any backend-side clamping.
    /// Backends that cannot estimate a total may report `total == step` on the
    /// final tick — consumers must clamp before display.
    case progress(step: Int, total: Int)

    /// Terminal event: generation finished and the audio was written to
    /// `url`. The file at `url` is fully closed and safe to read.
    ///
    /// The directory portion of `url` is determined by
    /// ``SpeechGenerationConfig/outputDirectory``: when set, the backend MUST
    /// write under it; when `nil`, the backend picks its own location
    /// (typically `FileManager.default.temporaryDirectory`).
    case completed(URL)
}
