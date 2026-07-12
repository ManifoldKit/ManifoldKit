import Foundation
import Observation

/// Errors thrown by ``VideoGenerationService`` for caller-observable conditions.
public enum VideoGenerationServiceError: Error, Equatable, Sendable {
    /// `generate` was called while another generation is already in progress.
    case alreadyGenerating
}

// `VideoGenerationServiceError` is the concrete error type that escapes
// `VideoGenerationRuntime`'s public `AsyncThrowingStream<VideoGenerationEvent,
// Error>` event stream — a separate public boundary from the four chat-path
// surfaces `ErrorHandlingAtTheBoundary.md` documents (#2157). Conforming it to
// `BackendError` mirrors that spine.
extension VideoGenerationServiceError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .alreadyGenerating:
            return "A video generation is already in progress. Wait for it to finish, or cancel it, before starting another."
        }
    }
}

extension VideoGenerationServiceError: BackendError {
    /// A blind retry reproduces the same error while the in-flight generation
    /// is still running — the caller must wait for it to finish (or cancel
    /// it) rather than simply retrying.
    public var isRetryable: Bool { false }
}

/// Orchestrates a video-generation backend's lifecycle.
///
/// Sibling to ``ImageGenerationService`` for the video path. Unlike image
/// generation, video is inherently cloud-only — there is no `loadModel`
/// concept. The service is always "ready" and holds a backend directly from
/// construction time. State machine: `idle → generating → idle`.
///
/// ## Concurrency
///
/// `@MainActor`-isolated; all state transitions happen on the main actor.
/// The backend's `generate(prompt:config:)` is `async throws`, so the
/// service's own `generate` is also `async throws` — the submission
/// handshake (which may do a network round-trip) happens before the stream
/// is returned, so callers `await` the initial `generate` call and then
/// iterate the returned stream.
@MainActor
@Observable
public final class VideoGenerationService {

    // MARK: - State

    /// High-level lifecycle state. Transitions:
    ///
    /// `idle → generating → idle`
    ///
    /// Errors thrown from `generate` surface to the caller; the service
    /// itself does not enter a long-lived `.error` state — a failed
    /// generate returns to `.idle`.
    public enum State: Sendable, Equatable {
        case idle
        case generating
    }

    public private(set) var state: State = .idle

    // MARK: - Private

    private let backend: any VideoGenerationBackend

    // MARK: - Init

    /// Creates a service that drives the supplied backend directly.
    ///
    /// - Parameter backend: The cloud video-generation backend to use.
    ///   The backend is retained for the lifetime of the service.
    public init(backend: any VideoGenerationBackend) {
        self.backend = backend
    }

    // MARK: - Generate

    /// Submits a video-generation request to the backend and returns a
    /// stream of progress events.
    ///
    /// The state transitions to `.generating` before this method returns
    /// so a follow-up call from the same actor observes `.generating`
    /// deterministically. The submission handshake (which may involve a
    /// network round-trip to the cloud backend) happens inside this `async
    /// throws` call — callers `await` the initial submit, then iterate
    /// the returned stream for progress and the final `.completed` URL.
    ///
    /// - Parameters:
    ///   - prompt: User-supplied text prompt.
    ///   - config: Generation parameters (duration, aspect ratio, resolution,
    ///     optional source image for image-to-video).
    /// - Returns: A stream of ``VideoGenerationEvent`` values, finishing with
    ///   `.completed(URL)` on success or a thrown error on failure.
    /// - Throws: ``VideoGenerationServiceError/alreadyGenerating`` when a
    ///   generation is already in progress. Backend submission errors
    ///   (authentication, rate limit, network) are rethrown directly.
    public func generate(
        prompt: String,
        config: VideoGenerationConfig
    ) async throws -> AsyncThrowingStream<VideoGenerationEvent, Error> {
        guard state == .idle else {
            throw VideoGenerationServiceError.alreadyGenerating
        }

        state = .generating

        do {
            let upstream = try await backend.generate(prompt: prompt, config: config)

            return AsyncThrowingStream { continuation in
                // Strong-capture `self` for the lifetime of this detached task.
                // The state-restore (`restoreIdleState`) is must-complete cleanup:
                // if it were gated on a weak `self?` and the service deallocated
                // (or the consumer dropped the stream) before the task ran, the
                // restore would silently drop and the service would stay stuck in
                // `.generating`. A weak capture is the documented anti-pattern for
                // must-complete `Task.detached` work ("No [weak self] in
                // must-complete Task.detached — strong capture or work drops").
                // The temporary retain cycle (task → service) breaks the moment
                // the task completes, which it always does: the stream finishes,
                // throws, or is cancelled via `onTermination`.
                let task = Task.detached(priority: .userInitiated) {
                    do {
                        for try await event in upstream {
                            if Task.isCancelled {
                                await self.restoreIdleState()
                                continuation.finish()
                                return
                            }
                            continuation.yield(event)
                        }
                        await self.restoreIdleState()
                        continuation.finish()
                    } catch is CancellationError {
                        await self.restoreIdleState()
                        continuation.finish()
                    } catch {
                        if Task.isCancelled {
                            await self.restoreIdleState()
                            continuation.finish()
                        } else {
                            await self.restoreIdleState()
                            continuation.finish(throwing: error)
                        }
                    }
                }

                continuation.onTermination = { [weak self] termination in
                    task.cancel()
                    if case .cancelled = termination {
                        Task { @MainActor [weak self] in
                            await self?.backend.cancel()
                        }
                    }
                }
            }
        } catch {
            state = .idle
            throw error
        }
    }

    // MARK: - Private Helpers

    /// Returns the service to `.idle` after a generation finishes, but only
    /// if the currently-observed state is still `.generating`. If the caller
    /// somehow drove the service off `.generating`, the state has already
    /// moved on and we must not overwrite it.
    private func restoreIdleState() {
        if state == .generating {
            state = .idle
        }
    }
}
