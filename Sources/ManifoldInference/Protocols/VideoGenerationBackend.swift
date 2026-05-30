import Foundation

/// Common interface for cloud video-generation backends.
///
/// Unlike ``ImageGenerationBackend``, video generation is inherently
/// asynchronous — requests are queued and polled. The `generate` method
/// returns a stream that yields progress events while polling and emits
/// ``VideoGenerationEvent/completed(_:)`` with a local file URL once the
/// video is downloaded to disk.
///
/// Conformers must be `AnyObject & Sendable` and protect mutable state
/// with a lock or actor.
public protocol VideoGenerationBackend: AnyObject, Sendable {
    func generate(
        prompt: String,
        config: VideoGenerationConfig
    ) -> AsyncThrowingStream<VideoGenerationEvent, Error>

    func cancel()
}
