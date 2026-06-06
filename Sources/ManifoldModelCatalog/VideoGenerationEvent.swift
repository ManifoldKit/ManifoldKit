import Foundation

/// Events emitted by a ``VideoGenerationBackend`` during generation.
public enum VideoGenerationEvent: Sendable, Codable {
    /// Request accepted and queued; generation not yet started.
    case queued
    /// Generation is in progress. `fractionComplete` is a backend-estimated
    /// value in 0.0–1.0; callers must clamp before display.
    case generating(fractionComplete: Double)
    /// Generation finished and the video has been downloaded to disk.
    /// `url` is a local file URL. If download fails after generation
    /// completes, the stream terminates with a thrown error instead.
    case completed(URL)
}
