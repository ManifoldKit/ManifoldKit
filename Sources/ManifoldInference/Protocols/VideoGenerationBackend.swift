import Foundation

/// Common interface for cloud video-generation backends.
///
/// Unlike ``ImageGenerationBackend``, video generation is inherently
/// asynchronous — requests are queued and polled. `generate` makes an
/// initial HTTP request to submit the job (which may throw on auth or
/// rate-limit errors), then returns a stream that yields progress events
/// while polling and emits ``VideoGenerationEvent/completed(_:)`` with a
/// local file URL once the video has been downloaded to disk.
///
/// Conformers must be `AnyObject` because they hold a running poll task
/// and a URLSession — reference semantics are required for shared mutable
/// state across the async poll loop.
public protocol VideoGenerationBackend: AnyObject, Sendable {
    /// Submits the video generation request and begins polling.
    ///
    /// Throws on submission failure (authentication, rate limit, network
    /// error) before any stream events are emitted. If the server-side
    /// generation succeeds but the local download fails, the stream
    /// terminates with a thrown error.
    func generate(
        prompt: String,
        config: VideoGenerationConfig
    ) async throws -> AsyncThrowingStream<VideoGenerationEvent, Error>

    /// Cancels an in-flight generation request.
    ///
    /// Implementations send the backend cancellation signal (e.g. an HTTP
    /// DELETE) and stop the poll loop. Awaiting this method ensures the
    /// poll task has exited before the caller proceeds.
    func cancel() async
}
