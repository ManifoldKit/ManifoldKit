import Foundation
import Observation

/// Errors thrown by ``AudioGenerationService`` for caller-observable conditions.
public enum AudioGenerationServiceError: Error, Equatable, Sendable {
    /// `generate` was called while another generation is already in progress.
    case alreadyGenerating
}

/// Orchestrates an audio-generation (TTS) backend's lifecycle.
///
/// Sibling to ``ImageGenerationService`` / ``VideoGenerationService`` for the
/// audio path. Like the video service — and unlike the image service — there is
/// no `loadModel` concept: the reference backend (`AVSpeechSynthesizer`) has its
/// voices always resident, so the service holds a backend directly from
/// construction and is always "ready". State machine: `idle → generating → idle`.
///
/// Like the image service — and unlike the video service — the backend's
/// `generate(config:)` is *synchronous-throw* (a local synth, no network
/// submit handshake), so the service's `generate` is synchronous and returns
/// the wrapped stream directly.
///
/// ## Concurrency
///
/// `@MainActor`-isolated; all state transitions happen on the main actor. The
/// per-event iteration of the backend stream is the only off-actor work and
/// runs on a detached task so the UI thread is never held across the render.
@MainActor
@Observable
public final class AudioGenerationService {

    // MARK: - State

    /// High-level lifecycle state. Transitions:
    ///
    /// `idle → generating → idle`
    public enum State: Sendable, Equatable {
        case idle
        case generating
    }

    public private(set) var state: State = .idle

    // MARK: - Private

    private let backend: any AudioGenerationBackend

    // MARK: - Init

    /// Creates a service that drives the supplied backend directly.
    ///
    /// - Parameter backend: The audio-generation backend to use. The backend
    ///   is retained for the lifetime of the service. Defaults to
    ///   ``AppleTTSBackend`` — the zero-dependency in-core reference backend.
    public init(backend: any AudioGenerationBackend = AppleTTSBackend()) {
        self.backend = backend
    }

    // MARK: - Generate

    /// Streams events from the backend's `generate(config:)`.
    ///
    /// The state transitions to `.generating` before this method returns so a
    /// follow-up call from the same actor observes `.generating`
    /// deterministically. The returned stream is the backend's own stream
    /// wrapped to drive service state transitions: `.generating → .idle` when
    /// the stream finishes (normally or via thrown error). Cancellation is
    /// treated as a normal finish.
    ///
    /// - Returns: a stream that finishes with
    ///   ``AudioGenerationServiceError/alreadyGenerating`` when a generation is
    ///   already in progress. All other errors come from the underlying backend.
    public func generate(
        config: SpeechGenerationConfig
    ) -> AsyncThrowingStream<AudioGenerationEvent, Error> {
        guard state == .idle else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: AudioGenerationServiceError.alreadyGenerating)
            }
        }

        return AsyncThrowingStream { continuation in
            let upstream: AsyncThrowingStream<AudioGenerationEvent, Error>
            do {
                upstream = try backend.generate(config: config)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            // Commit `.generating` synchronously on the main actor after the
            // backend's synchronous-throw entrypoint returns, so a follow-up
            // call from the same actor observes the transition deterministically.
            state = .generating

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
                        self?.backend.stopGeneration()
                    }
                }
            }
        }
    }

    // MARK: - Private Helpers

    /// Returns the service to `.idle` after a generation finishes, but only if
    /// the currently-observed state is still `.generating`.
    private func restoreIdleState() {
        if state == .generating {
            state = .idle
        }
    }
}
