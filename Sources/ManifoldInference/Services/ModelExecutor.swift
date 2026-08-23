import Foundation
import ManifoldContract

/// Identity key for a pooled model executor.
///
/// Two executors are the "same model" iff their ``ModelExecutorKey`` compare
/// equal. Hosts derive the key from whatever uniquely names a loadable model
/// in their world — typically `ModelInfo.id` for on-disk models or an endpoint
/// record UUID for cloud backends.
public struct ModelExecutorKey: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(_ id: UUID) { self.rawValue = id.uuidString }
}

/// A clock that arms the wedge watchdog for a generation.
///
/// Extracted as a seam so wedge-detection tests are deterministic: production
/// uses ``RealWedgeWatchdog`` (a real `Task.sleep`), while tests inject a
/// manual watchdog they trip explicitly — no wall-clock sleeping, no flakes
/// from racing `Task.yield` against a timer.
public protocol WedgeWatchdog: Sendable {
    /// Suspends until the wedge budget elapses, then returns. The executor
    /// races this against the first generation event; whichever wins decides
    /// whether the turn is healthy or wedged. Honour cancellation — when the
    /// generation produces an event first, the executor cancels this task.
    func awaitWedgeBudget() async
}

/// Production watchdog: sleeps for a fixed budget using the continuous clock.
public struct RealWedgeWatchdog: WedgeWatchdog {
    public let budget: Duration
    public init(budget: Duration) { self.budget = budget }

    public func awaitWedgeBudget() async {
        // Cooperative: cancellation makes the sleep return early. The caller
        // must distinguish that return from an elapsed budget before it reports
        // a wedge. `try? await Task.sleep` is the codebase's sanctioned idiom
        // for this best-effort suspension (SilentCatchAudit).
        try? await Task.sleep(for: budget)
    }
}

/// Owns a single model's backend and serializes that model's generation,
/// isolating it from every other model's work.
///
/// ## Why an actor
///
/// Backends are single-per-model and `@MainActor`-or-`@unchecked Sendable`
/// with internal locks. Wrapping each in its own `actor` gives two things the
/// flat `InferenceService` path cannot:
///
/// 1. **Concurrency isolation** — one model's slow turn no longer blocks
///    another model's queue. The `@MainActor` ``InferenceService`` runs a
///    single global FIFO; a pool of executors runs one FIFO *per model* and
///    those FIFOs make progress concurrently.
/// 2. **Logical fault isolation** — a thrown or timed-out turn is contained to
///    one executor; ``recover()`` tears down and reloads just that model's
///    backend without touching the runtime or sibling executors.
///
/// ## What this is NOT
///
/// This is *logical* isolation, not memory-fault isolation. A segfault or a
/// wedged Metal kernel in the underlying C runtime still crashes the process —
/// true crash isolation needs an out-of-process (XPC) backend, an explicit
/// non-goal here. ``ExecutorState/wedged`` means "no event within budget",
/// which is the realistic in-process failure we *can* detect and recover.
///
/// ## Serialization
///
/// Actor isolation already serializes calls into the executor, but a
/// generation streams events *after* `generate()` returns. We therefore gate
/// on ``state``: a second `generate()` while `.generating` throws
/// `alreadyGenerating`, matching the single-backend contract. The pool fans
/// concurrent requests across *different* executors, never the same one.
public actor ModelExecutor {

    /// Stable identity for pool keying.
    public let key: ModelExecutorKey

    /// Human-readable backend label, surfaced in status snapshots.
    public let backendName: String

    /// Reloads the backend after a wedge (or for the very first load).
    ///
    /// Returns a freshly-loaded backend. Injected rather than holding a
    /// `BackendFactory` directly so the executor stays agnostic to *how* a
    /// model is loaded (on-disk URL + plan, endpoint record, or a pre-built
    /// mock) — the pool supplies the closure that knows.
    private let loader: @Sendable () async throws -> any InferenceBackend

    /// Builds the per-generation wedge watchdog. Defaults to a real sleep;
    /// tests inject a manual one they trip deterministically.
    private let makeWatchdog: @Sendable () -> any WedgeWatchdog

    private var backend: (any InferenceBackend)?
    private var _state: ExecutorState = .unloaded

    /// When the model finished loading, for residency/idle accounting.
    private(set) var loadedAt: Date?

    /// Most recent generation activity, for idle eviction by the pool.
    private(set) var lastActivityAt: Date

    public init(
        key: ModelExecutorKey,
        backendName: String,
        loader: @escaping @Sendable () async throws -> any InferenceBackend,
        makeWatchdog: @escaping @Sendable () -> any WedgeWatchdog = { RealWedgeWatchdog(budget: .seconds(120)) }
    ) {
        self.key = key
        self.backendName = backendName
        self.loader = loader
        self.makeWatchdog = makeWatchdog
        self.lastActivityAt = Date()
    }

    public var state: ExecutorState { _state }

    /// The live backend, or `nil` before load / after unload. Package-visible
    /// so the pool can forward host-level configuration (token providers, etc.)
    /// without widening the backend past the executor boundary elsewhere.
    package var currentBackend: (any InferenceBackend)? { backend }

    // MARK: - Lifecycle

    /// Loads the model. Idempotent for an already-`.ready` executor.
    public func load() async throws {
        if _state == .ready || _state == .generating { return }
        _state = .loading
        do {
            let loaded = try await loader()
            backend = loaded
            loadedAt = Date()
            lastActivityAt = Date()
            _state = .ready
        } catch {
            _state = .unloaded
            backend = nil
            throw error
        }
    }

    /// Tears down the backend and frees its memory. Terminal for this instance.
    ///
    /// Mirrors the single-backend unload contract: stop any in-flight stream,
    /// then unload. We do NOT block here — the backend's own `unloadModel()`
    /// is synchronous and the retain/detach/release pattern for async C cleanup
    /// lives inside the concrete backend (e.g. LlamaBackend), not at this seam.
    public func unload() {
        backend?.stopGeneration()
        backend?.unloadModel()
        backend = nil
        loadedAt = nil
        _state = .unloaded
    }

    // MARK: - Generation

    /// Runs one generation on this model's backend, fenced by a wedge watchdog.
    ///
    /// The returned ``GenerationStream`` is a re-published copy: we tee the
    /// backend's events through a fresh stream so we can observe the *first*
    /// event (proving the turn is alive) and race it against the watchdog. If
    /// the watchdog wins, the executor flips to ``ExecutorState/wedged`` and the
    /// re-published stream finishes with ``InferenceError/idleTimeout(_:)`` so
    /// the caller is unblocked.
    ///
    /// - Throws: ``InferenceError/inferenceFailure`` if no model is loaded,
    ///   ``InferenceError/alreadyGenerating`` if a turn is already in flight,
    ///   or whatever the backend throws synchronously from `generate`.
    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        hints: GenerationRuntimeHints
    ) throws -> GenerationStream {
        guard let backend else {
            throw InferenceError.inferenceFailure("No model loaded in executor \(key.rawValue)")
        }
        guard _state == .ready else {
            if _state == .generating { throw InferenceError.alreadyGenerating }
            throw InferenceError.inferenceFailure("Executor \(key.rawValue) not ready (state: \(_state))")
        }

        let upstream = try backend.generateEnforcingCapabilities(
            prompt: prompt,
            systemPrompt: systemPrompt,
            config: config,
            hints: hints
        )

        _state = .generating
        lastActivityAt = Date()

        let watchdog = makeWatchdog()
        let teed = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            // Watchdog task: if it returns before the generation signals
            // liveness, the turn is wedged.
            let liveness = LivenessSignal()
            let watchdogTask = Task { [weak self] in
                await watchdog.awaitWedgeBudget()
                guard !Task.isCancelled else { return }
                if await liveness.isAlive { return }   // event already arrived
                guard !Task.isCancelled else { return }
                // No event within budget → wedge this executor.
                await self?.markWedged()
                continuation.finish(throwing: InferenceError.idleTimeout(.seconds(0)))
            }

            let pumpTask = Task { [weak self] in
                do {
                    for try await event in upstream.events {
                        await liveness.markAlive()
                        watchdogTask.cancel()
                        continuation.yield(event)
                    }
                    await liveness.markAlive()
                    watchdogTask.cancel()
                    await self?.markTurnComplete()
                    continuation.finish()
                } catch {
                    await liveness.markAlive()
                    watchdogTask.cancel()
                    await self?.markTurnComplete()
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                watchdogTask.cancel()
                pumpTask.cancel()
            }
        }

        return GenerationStream(teed)
    }

    /// Requests the backend stop the current turn and returns the executor to
    /// `.ready` (matching the single-backend stop contract: ready for reuse).
    public func stopGeneration() {
        backend?.stopGeneration()
        if _state == .generating {
            _state = .ready
            lastActivityAt = Date()
        }
    }

    // MARK: - Wedge Recovery

    /// Detects-then-recovers a wedged executor: tears down the stuck backend
    /// and reloads a fresh one for the *same* model, leaving every sibling
    /// executor untouched. After a successful recovery the executor is
    /// `.ready` again.
    ///
    /// Calling `recover()` on a non-wedged executor is a no-op (logged) — the
    /// pool only calls it after observing ``ExecutorState/wedged``.
    public func recover() async throws {
        guard _state == .wedged else {
            Log.inference.warning(
                "recover() called on non-wedged executor \(self.key.rawValue, privacy: .public) (state: \(String(describing: self._state), privacy: .public)) — ignoring"
            )
            return
        }
        // Tear the wedged backend down. We cannot trust its stop/unload to
        // return promptly if the C runtime is genuinely stuck, but the best we
        // can do in-process is drop our reference and reload; a truly hung
        // kernel is the segfault-class failure XPC isolation (non-goal) covers.
        backend?.stopGeneration()
        backend?.unloadModel()
        backend = nil
        _state = .unloaded
        try await load()
    }

    // MARK: - Private state transitions

    private func markWedged() {
        // Only a generating turn can wedge; a turn that completed first wins
        // the race and we must not stomp `.ready`.
        if _state == .generating {
            _state = .wedged
            Log.inference.warning(
                "executor \(self.key.rawValue, privacy: .public) wedged — no generation event within budget"
            )
        }
    }

    private func markTurnComplete() {
        lastActivityAt = Date()
        if _state == .generating {
            _state = .ready
        }
    }
}

/// Cross-task liveness flag for the wedge race. An `actor` rather than an
/// `@unchecked Sendable` box because the pump task and watchdog task read/write
/// it from different tasks (gotcha #2: a mutable box is not a race fix).
private actor LivenessSignal {
    private(set) var isAlive = false
    func markAlive() { isAlive = true }
}
