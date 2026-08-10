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
    /// generation. `total` is the backend's *actually-resolved* step count:
    /// the caller's ``ImageGenerationConfig/steps`` when it was non-`nil`
    /// (after any backend-side clamping), or — when the caller left `steps`
    /// `nil` — the loaded model's own preset default (see the "Step-count
    /// resolution contract" on ``ImageGenerationBackend/generate(prompt:config:)``).
    /// Conforming backends MUST report the real resolved count starting with
    /// the first `.progress` event, never `0` as a placeholder.
    case progress(step: Int, total: Int)

    /// Intermediate preview of the in-progress denoise at step `step` of
    /// `total`.
    ///
    /// Opt-in: backends only emit this when the caller sets
    /// ``ImageGenerationConfig/previewStride`` (nil disables previews
    /// entirely, preserving today's `progress` + terminal-`completed`
    /// shape). When enabled, a preview is emitted every `previewStride`
    /// steps so hosts can render a progressively-refining thumbnail before
    /// the terminal ``completed(_:)``.
    ///
    /// ## Why `Data`, not `URL`?
    ///
    /// Unlike ``completed(_:)`` — which references a single fully-written
    /// file on disk — previews fire repeatedly during the denoise loop.
    /// Routing each tick through a disk write (`CGImage → encode → file`)
    /// just to hand back a `URL` the host immediately re-reads would add a
    /// per-tick filesystem round-trip on the hot path. Carrying the encoded
    /// image bytes in-memory (`Data`, the same representation
    /// ``ImagePlaceholderHash`` already consumes at this layer) keeps the
    /// preview channel allocation-light and avoids littering the output
    /// directory with transient intermediates. `image` holds the encoded
    /// bytes (e.g. PNG/JPEG); it is *not* persisted by the runtime.
    case preview(step: Int, total: Int, image: Data)

    /// Terminal event: generation finished and the image was written to
    /// `url`. The file at `url` is fully closed and safe to read.
    ///
    /// The directory portion of `url` is determined by
    /// ``ImageGenerationConfig/outputDirectory``: when set, the backend
    /// MUST write under it; when `nil`, the backend picks its own location
    /// (typically `FileManager.default.temporaryDirectory`).
    case completed(URL)
}
