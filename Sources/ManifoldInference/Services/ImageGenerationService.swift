import Foundation
import Observation

/// Errors thrown by ``ImageGenerationService`` for caller-observable conditions.
///
/// Backend-internal errors (loader failures, denoising aborts) are surfaced as
/// thrown errors from the underlying ``ImageGenerationBackend``; the cases here
/// describe service-level pre-conditions only.
public enum ImageGenerationServiceError: Error, Equatable, Sendable {
    /// `loadModel` was called for a format with no registered factory. The host
    /// must call ``ImageGenerationService/registerBackendFactory(for:factory:)``
    /// for ``ImageModelInfo/format`` before loading.
    case noFactoryRegistered(format: ImageModelFormat)

    /// `generate` was called without a loaded model. Call
    /// ``ImageGenerationService/loadModel(_:)`` first.
    case notLoaded
}

/// Orchestrates an image-generation backend's lifecycle.
///
/// Sibling to ``InferenceService`` for the image path. Owns registration,
/// load / generate / unload, and the `@Observable` state machine that hosts
/// observe to drive UI. Image-side state is intentionally separate from the
/// text-side service: shipping a parallel type space is the umbrella-#1002
/// architectural decision, so `ModelType`'s exhaustive switches stay closed.
///
/// ## Decomposition (deferred)
///
/// Unlike ``InferenceService``, this service is a single class — no separate
/// lifecycle / generation coordinators. The text-side split happened *after*
/// `InferenceService` had grown into a 972-LOC god object; premature for a
/// stub-only image surface. Decompose when the surface warrants it.
///
/// ## Concurrency
///
/// `@MainActor`-isolated; all state transitions and the synchronous-throw
/// portion of every backend call (`generate(prompt:config:)`'s entrypoint,
/// `stopGeneration()`, `unloadModel()`, `isLoaded` / `isGenerating` reads)
/// happen on the main actor. The two operations that may do heavy work —
/// `loadModel(from:)` and the per-event iteration of a generation stream —
/// run off-actor on a detached task so the UI thread is never held across
/// them. Backends remain `AnyObject + Sendable` and protect their own
/// internals (NSLock per ``ImageGenerationBackend``'s contract). The service
/// itself does not hold a lock — main-actor isolation is sufficient for its
/// own state.
@MainActor
@Observable
public final class ImageGenerationService {

    /// Factory closure that produces a backend for a given image model.
    ///
    /// Registered per ``ImageModelFormat``. The closure is `async throws` so
    /// future backends that need to read configs off disk during construction
    /// (e.g. inspecting a diffusion model's `config.json` to choose a U-Net
    /// shape) can do so without blocking the caller's actor.
    public typealias BackendFactory = @MainActor (ImageModelInfo) async throws -> any ImageGenerationBackend

    // MARK: - State

    /// High-level lifecycle state. Transitions:
    ///
    /// `idle → loading → loaded → generating → loaded → unloading → idle`
    ///
    /// Errors thrown from `loadModel` / `generate` surface to the caller; the
    /// service itself does not enter a long-lived `.error` state — a failed
    /// load returns to `.idle`, a failed generate returns to `.loaded`.
    public enum State: Sendable, Equatable {
        case idle
        case loading(ImageModelInfo)
        case loaded(ImageModelInfo)
        case generating(ImageModelInfo)
        case unloading

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.unloading, .unloading): return true
            case (.loading(let a), .loading(let b)): return a == b
            case (.loaded(let a), .loaded(let b)): return a == b
            case (.generating(let a), .generating(let b)): return a == b
            default: return false
            }
        }
    }

    public private(set) var state: State = .idle
    public private(set) var loadedModel: ImageModelInfo?

    // MARK: - Private

    private var factories: [ImageModelFormat: BackendFactory] = [:]
    private var backend: (any ImageGenerationBackend)?

    // MARK: - Init

    public init() {}

    // MARK: - Registration

    /// Registers a backend factory for the given format.
    ///
    /// A second registration for the same format replaces the prior factory —
    /// matches how a host might swap a stub backend for the real conformer at
    /// runtime (e.g. tests overriding the production registration).
    public func registerBackendFactory(
        for format: ImageModelFormat,
        factory: @escaping BackendFactory
    ) {
        factories[format] = factory
    }

    // MARK: - Lifecycle

    /// Loads `info`'s model via the factory registered for its format.
    ///
    /// Latest-wins: if a model is already loaded (or loading), it is unloaded
    /// first. Mirrors ``ModelLifecycleCoordinator``'s handoff pattern at the
    /// shape level — full token-based stale-suppression isn't needed yet
    /// because the image service has no enqueue / retry path.
    ///
    /// - Throws: ``ImageGenerationServiceError/noFactoryRegistered(format:)``
    ///   when no factory is registered for `info.format`. Any error thrown by
    ///   the factory or the backend's `loadModel(from:)` is rethrown after
    ///   the service returns to `.idle`.
    public func loadModel(_ info: ImageModelInfo) async throws {
        // Tear down any prior backend before swapping in a new one. Mirrors
        // the text-side coordinator's `unloadModel()` call at the top of
        // `loadModel`.
        if backend != nil {
            await unload()
        }

        guard let factory = factories[info.format] else {
            throw ImageGenerationServiceError.noFactoryRegistered(format: info.format)
        }

        state = .loading(info)
        do {
            let newBackend = try await factory(info)
            // Hop the backend's `loadModel` call onto a detached task so any
            // synchronous heavy lifting inside the backend (model file reads,
            // Metal shader compile, weight unpack) cannot block the main
            // actor and the UI. Mirrors `ModelLifecycleCoordinator`'s
            // `Task.detached(priority: .userInitiated)` dispatch on the text
            // path. State commits below stay on MainActor.
            let url = info.directoryURL
            try await Task.detached(priority: .userInitiated) {
                try await newBackend.loadModel(from: url)
            }.value
            backend = newBackend
            loadedModel = info
            state = .loaded(info)
        } catch {
            // Failed load returns the service to a clean idle so the next
            // attempt starts from a known-good baseline. We do not retain a
            // reference to a partially-loaded backend.
            backend = nil
            loadedModel = nil
            state = .idle
            throw error
        }
    }

    /// Streams events from the loaded backend's `generate(prompt:config:)`.
    ///
    /// The returned stream is the backend's own stream wrapped to drive
    /// service state transitions: `.loaded → .generating` synchronously on
    /// the main actor (after the backend's `generate` synchronous-throw
    /// entrypoint returns), `.generating → .loaded` when the stream finishes
    /// (normally or via thrown error). Cancellation is treated as a normal
    /// finish: the wrapper task is cancelled and `backend.stopGeneration()`
    /// is invoked, but no `CancellationError` propagates to the consumer.
    ///
    /// - Returns: a stream that finishes with
    ///   ``ImageGenerationServiceError/notLoaded`` when no model is loaded
    ///   (or when state has moved off `.loaded` between the entry check and
    ///   the backend `generate` call). All other errors come from the
    ///   underlying backend.
    public func generate(
        prompt: String,
        config: ImageGenerationConfig
    ) -> AsyncThrowingStream<ImageGenerationEvent, Error> {
        guard let backend, let info = loadedModel else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ImageGenerationServiceError.notLoaded)
            }
        }

        return AsyncThrowingStream { continuation in
            // Start the backend stream and commit `.generating` synchronously
            // on the main actor. Doing it here (rather than inside the
            // detached task below) means a follow-up `loadModel` /
            // `unload` issued from the same actor cannot interleave between
            // the load check and the state write — the next operation
            // observes `.generating(info)` deterministically.
            //
            // We also gate the transition on the current state being
            // `.loaded(info)`. If the caller raced an `unload()` /
            // `loadModel(other)` in before reaching here, we must not stomp
            // the newer state by writing `.generating(info)` for a model
            // that's no longer current.
            let upstream: AsyncThrowingStream<ImageGenerationEvent, Error>
            do {
                upstream = try backend.generate(prompt: prompt, config: config)
            } catch {
                continuation.finish(throwing: error)
                return
            }

            guard case .loaded(let active) = state, active == info else {
                // State moved on between the `loadedModel` snapshot above
                // and this point (callers can drive lifecycle from the same
                // actor between awaits). Treat exactly like `.notLoaded` —
                // do not start a generation against a model the service no
                // longer considers active.
                continuation.finish(throwing: ImageGenerationServiceError.notLoaded)
                return
            }
            state = .generating(info)

            // Iteration of the upstream stream is the only off-actor work.
            // The detached task forwards events; all state writes still hop
            // back to MainActor. Cancellation is treated as a normal finish
            // (matches GenerationStream's policy).
            //
            // We must check `Task.isCancelled` per-iteration because
            // `AsyncThrowingStream` does not auto-propagate Task cancellation
            // into the producer — without the check, a backend that yields
            // events on a timer keeps feeding the wrapper even after the
            // downstream consumer dropped its iterator.
            // Strong-capture `self` for the lifetime of this detached task.
            // The state-restore (`restoreLoadedState`) is must-complete cleanup:
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
                            await self.restoreLoadedState(for: info)
                            continuation.finish()
                            return
                        }
                        continuation.yield(event)
                    }
                    await self.restoreLoadedState(for: info)
                    continuation.finish()
                } catch is CancellationError {
                    await self.restoreLoadedState(for: info)
                    continuation.finish()
                } catch {
                    if Task.isCancelled {
                        await self.restoreLoadedState(for: info)
                        continuation.finish()
                    } else {
                        await self.restoreLoadedState(for: info)
                        continuation.finish(throwing: error)
                    }
                }
            }

            continuation.onTermination = { [weak self] termination in
                // On cancellation, also tell the backend to stop — otherwise
                // the denoising loop can keep running even though no one is
                // reading the stream. `.finished` paths already had the
                // upstream exit cleanly; only `.cancelled` needs the nudge.
                task.cancel()
                if case .cancelled = termination {
                    Task { @MainActor [weak self] in
                        self?.backend?.stopGeneration()
                    }
                }
            }
        }
    }

    /// Returns the service to `.loaded(info)` after a generation finishes,
    /// but only if the currently-observed state is still
    /// `.generating(info)`. If the caller unloaded mid-stream or a newer
    /// load is in flight, the state has already moved on and we must not
    /// overwrite it.
    private func restoreLoadedState(for info: ImageModelInfo) {
        if case .generating(let active) = state, active == info {
            state = .loaded(info)
        }
    }

    /// Unloads the active backend and returns to `.idle`.
    ///
    /// Safe to call when no model is loaded — no-op in that case. Calls the
    /// backend's `stopGeneration()` first so any in-flight generation is
    /// cancelled before `unloadModel()` tears down resources.
    public func unload() async {
        guard let backend else {
            state = .idle
            loadedModel = nil
            return
        }

        state = .unloading
        backend.stopGeneration()
        backend.unloadModel()
        self.backend = nil
        self.loadedModel = nil
        state = .idle
    }
}
