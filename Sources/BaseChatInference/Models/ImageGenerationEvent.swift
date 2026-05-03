import Foundation

/// Streaming event emitted by ``ImageGenerationBackend`` during a generation
/// run.
///
/// Mirrors the role ``GenerationEvent`` plays for text inference. Two cases
/// today: progress ticks during the denoising loop, and a single terminal
/// ``completed`` carrying a file URL pointing at the produced image.
///
/// ## Why `URL`, not `CGImage`?
///
/// Persisted image messages reference the image by file URL (see
/// ``ImageMessagePayload``); the binary lives on disk in the app container
/// rather than in SwiftData. Surfacing the file URL directly from the backend
/// keeps the inference layer free of CoreGraphics image-bridging concerns
/// and avoids a `CGImage → PNG → disk` re-encode in the persistence layer.
/// Backends are responsible for writing to a caller-controlled location and
/// emitting the URL once the file is fully on disk.
public enum ImageGenerationEvent: Sendable {

    /// Progress tick during the denoising loop.
    ///
    /// `step` is 1-indexed and monotonically increasing within a single
    /// generation; `total` matches the value the caller passed in
    /// ``ImageGenerationConfig/steps`` (after any backend-side clamping).
    case progress(step: Int, total: Int)

    /// Terminal event: generation finished and the image was written to
    /// `url`. The file at `url` is fully closed and safe to read.
    case completed(URL)
}
