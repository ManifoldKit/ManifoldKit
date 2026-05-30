import Foundation

/// Events emitted by a ``VideoGenerationBackend`` during generation.
public enum VideoGenerationEvent: Sendable {
    /// Request accepted and queued; generation not yet started.
    case queued
    /// Generation is in progress. `fractionComplete` is an estimate (0.0–1.0).
    case generating(fractionComplete: Double)
    /// Generation finished. `url` is a local file URL on disk.
    case completed(URL)
}
