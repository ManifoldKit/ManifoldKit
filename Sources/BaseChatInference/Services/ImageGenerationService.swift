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
/// `@MainActor`-isolated; all state transitions and backend method calls
/// happen on the main actor. Backends remain `AnyObject + Sendable` and are
/// expected to protect their own internals (NSLock per
/// ``ImageGenerationBackend``'s contract). The service itself does not hold a
/// lock — main-actor isolation is sufficient.
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
            try await newBackend.loadModel(from: info.directoryURL)
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
    /// service state transitions: `.loaded → .generating` when the first
    /// event arrives, `.generating → .loaded` when the stream finishes
    /// (normally or via thrown error).
    ///
    /// - Returns: a stream that finishes with
    ///   ``ImageGenerationServiceError/notLoaded`` when no model is loaded.
    ///   All other errors come from the underlying backend.
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
            // Detached: backend `generate` is synchronous-throw to start the
            // stream; the per-event consumption then awaits. Wrapping in a
            // detached task lets us hop back to MainActor for state writes
            // without blocking the caller.
            let task = Task {
                do {
                    let upstream = try backend.generate(prompt: prompt, config: config)
                    await MainActor.run {
                        self.state = .generating(info)
                    }
                    for try await event in upstream {
                        continuation.yield(event)
                    }
                    await MainActor.run {
                        // Only reset to .loaded when our generation is the
                        // one currently observed. If the caller unloaded
                        // mid-stream the state will already be .idle and we
                        // must not overwrite it.
                        if case .generating(let active) = self.state, active == info {
                            self.state = .loaded(info)
                        }
                    }
                    continuation.finish()
                } catch {
                    await MainActor.run {
                        if case .generating(let active) = self.state, active == info {
                            self.state = .loaded(info)
                        }
                    }
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
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
