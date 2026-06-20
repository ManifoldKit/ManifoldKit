import Foundation

/// Thrown by ``FallbackBackend`` when every backend in the chain failed.
///
/// Aggregates the per-backend errors in attempt order so callers can inspect
/// the full failure chain rather than only the last error. Conforms to
/// ``BackendError`` with `isRetryable == false`: an *outer* ``FallbackBackend``
/// wrapping an inner exhausted chain will therefore not route around it (the
/// inner chain already tried everything it could).
public struct FallbackExhaustedError: BackendError {
    /// The error each backend produced, in the order the chain attempted them.
    public let perBackendErrors: [any Error]

    public init(perBackendErrors: [any Error]) {
        self.perBackendErrors = perBackendErrors
    }

    /// The error from the last backend tried — the most-relevant terminal cause.
    public var lastError: (any Error)? { perBackendErrors.last }

    public var isRetryable: Bool { false }

    public var errorDescription: String? {
        let detail = perBackendErrors
            .enumerated()
            .map { "[\($0.offset)] \($0.element.localizedDescription)" }
            .joined(separator: "; ")
        return "All \(perBackendErrors.count) fallback backend(s) failed: \(detail)"
    }
}

/// An ``InferenceBackend`` that wraps an ordered list of backends and advances
/// to the next one when an attempt fails with a routable error.
///
/// This is the error-advance counterpart to ``RouterBackend``'s capability-select
/// routing. The first backend in the list is tried first (place your cheapest /
/// lowest-latency / most-preferred backend first); on a routable failure
/// (per ``FallbackPolicy/shouldAdvance``) the chain advances to the next. The
/// first success wins. If every backend fails, the chain throws a
/// ``FallbackExhaustedError`` aggregating each backend's error in order.
///
/// ## Streaming semantics
///
/// Fallback can only fire *before the first content token reaches the consumer*.
/// Once a ``GenerationEvent/token(_:)`` (or ``GenerationEvent/thinkingToken(_:)``)
/// has been forwarded, the consumer has seen partial output, so a mid-stream
/// error is propagated rather than routed around — unless
/// ``FallbackPolicy/advanceAfterFirstToken`` is `true`, in which case partial
/// output is discarded and the turn restarts on the next backend.
///
/// ## Composition with `withRetry`
///
/// Per-backend retry (same backend, transient error) is orthogonal to
/// cross-backend fallback. Set ``FallbackPolicy/perBackendRetries`` to retry each
/// backend via ``withRetry(strategy:sleeper:operation:)`` before advancing.
///
/// ## Lifecycle delegation
///
/// `stopGeneration()`, `unloadModel()`, `resetConversation()`, and `secureWipe()`
/// fan out to every backend — the chain may have left state on more than one.
/// `loadModel(from:plan:)` is **not** routed: like ``RouterBackend``, picking and
/// loading a model is the host's job; load each backend before composing the
/// chain. `capabilities` is the union of every backend's capabilities (see
/// ``BackendCapabilities/union(_:)``).
public final class FallbackBackend: InferenceBackend, @unchecked Sendable {
    /// Backends in priority order. The first is tried first.
    public let backends: [any InferenceBackend]

    /// The policy governing when the chain advances.
    public let policy: FallbackPolicy

    /// Sleeper injected into ``withRetry(strategy:sleeper:operation:)`` for the
    /// per-backend retry path. Defaults to `Task.sleep`; tests inject a
    /// recording sleeper to assert delay bounds without real-time blocking.
    private let retrySleeper: @Sendable (Duration) async throws -> Void

    public init(
        backends: [any InferenceBackend],
        policy: FallbackPolicy = .default,
        retrySleeper: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        // An empty chain would fail every request with an empty
        // `FallbackExhaustedError` — surfacing the wiring mistake here, at the
        // call site that built the chain, is far easier to debug.
        precondition(
            !backends.isEmpty,
            "FallbackBackend requires at least one backend"
        )
        self.backends = backends
        self.policy = policy
        self.retrySleeper = retrySleeper
    }

    public var isModelLoaded: Bool {
        backends.contains { $0.isModelLoaded }
    }

    public var isGenerating: Bool {
        backends.contains { $0.isGenerating }
    }

    public var capabilities: BackendCapabilities {
        // Union semantics — "can the chain as a whole do X?". Reuses the shared
        // merge helper so this and RouterBackend stay byte-for-byte identical.
        BackendCapabilities.union(backends.map(\.capabilities))
    }

    public func loadModel(from url: URL, plan: ModelLoadPlan) async throws {
        // Loading is not a routing decision — the host owns model selection.
        throw InferenceError.inferenceFailure(
            "FallbackBackend does not load models — load each backend before composing the chain."
        )
    }

    public func generate(
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig
    ) throws -> GenerationStream {
        let backends = self.backends
        let policy = self.policy
        let retrySleeper = self.retrySleeper

        let stream = AsyncThrowingStream<GenerationEvent, Error> { continuation in
            let task = Task {
                var perBackendErrors: [any Error] = []
                // Once any content token has been forwarded to the consumer we
                // can no longer transparently fail over (the partial output is
                // already visible). Tracked across the whole chain.
                var forwardedContentToken = false

                for backend in backends {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    let tokenSeen = TokenSeenBox()
                    do {
                        try await Self.runAttempt(
                            backend: backend,
                            prompt: prompt,
                            systemPrompt: systemPrompt,
                            config: config,
                            policy: policy,
                            retrySleeper: retrySleeper,
                            tokenSeen: tokenSeen,
                            forward: { continuation.yield($0) }
                        )
                        // Success — the attempt forwarded the full stream.
                        continuation.finish()
                        return
                    } catch is CancellationError {
                        continuation.finish(throwing: CancellationError())
                        return
                    } catch {
                        perBackendErrors.append(error)
                        if tokenSeen.seen { forwardedContentToken = true }

                        // If the consumer already saw a content token and we are
                        // not allowed to restart, the error is terminal for this
                        // turn — propagate it, never advance.
                        if forwardedContentToken && !policy.advanceAfterFirstToken {
                            continuation.finish(throwing: error)
                            return
                        }

                        // Fail fast on non-routable errors (auth, bad request,
                        // quota, unsupported) — the next backend would not help.
                        guard policy.shouldAdvance(error) else {
                            continuation.finish(throwing: error)
                            return
                        }

                        Log.inference.warning(
                            "Fallback advancing past backend after routable error: \(error)"
                        )
                        // advanceAfterFirstToken: discard partial output and
                        // restart on the next backend. Reset the flag so the
                        // next backend's pre-first-token errors can advance too.
                        forwardedContentToken = false
                        continue
                    }
                }

                // Every backend failed.
                continuation.finish(
                    throwing: FallbackExhaustedError(perBackendErrors: perBackendErrors)
                )
            }

            continuation.onTermination = { _ in task.cancel() }
        }

        return GenerationStream(stream)
    }

    /// Runs a single backend attempt (with optional per-backend retry), draining
    /// its event stream and forwarding events. Records into `tokenSeen` once the
    /// first content token is forwarded. Throws on failure.
    private static func runAttempt(
        backend: any InferenceBackend,
        prompt: String,
        systemPrompt: String?,
        config: GenerationConfig,
        policy: FallbackPolicy,
        retrySleeper: @escaping @Sendable (Duration) async throws -> Void,
        tokenSeen: TokenSeenBox,
        forward: @escaping @Sendable (GenerationEvent) -> Void
    ) async throws {
        // `tokenSeen` is a Sendable box so the drain closure (which is @Sendable
        // and may run across suspension points / multiple withRetry attempts)
        // can record whether a content token was forwarded. The fallback driver
        // reads it after the attempt to enforce the no-restart-after-token rule.
        let drain: () async throws -> Void = {
            let genStream = try backend.generate(
                prompt: prompt,
                systemPrompt: systemPrompt,
                config: config
            )
            for try await event in genStream.events {
                if Self.isContentToken(event) {
                    tokenSeen.markSeen()
                }
                forward(event)
            }
        }

        guard policy.perBackendRetries > 0 else {
            try await drain()
            return
        }

        do {
            try await withRetry(
                strategy: ExponentialBackoffStrategy(maxRetries: policy.perBackendRetries),
                sleeper: retrySleeper,
                operation: drain
            )
        } catch let exhausted as RetryExhaustedError {
            // `withRetry` wraps the terminal error in `RetryExhaustedError` once
            // it gives up. Unwrap it so the fallback driver advances based on the
            // *underlying* error's retryability (and `RetryExhaustedError` — not
            // a `BackendError` — doesn't dead-end the chain at the first backend).
            throw exhausted.lastError
        }
    }

    /// Content tokens are the events whose appearance means the consumer has
    /// seen partial output and a transparent fail-over is no longer possible.
    private static func isContentToken(_ event: GenerationEvent) -> Bool {
        switch event {
        case .token, .thinkingToken:
            return true
        default:
            return false
        }
    }

    public func stopGeneration() {
        for backend in backends { backend.stopGeneration() }
    }

    public func unloadModel() {
        for backend in backends { backend.unloadModel() }
    }

    public func resetConversation() {
        for backend in backends { backend.resetConversation() }
    }

    public func secureWipe() {
        for backend in backends { backend.secureWipe() }
    }
}

/// Thread-safe one-shot flag recording whether a content token was forwarded
/// during a backend attempt. The drain closure handed to
/// ``withRetry(strategy:sleeper:operation:)`` is `@Sendable` and may run across
/// suspension points, so a bare `Bool` capture would race under strict
/// concurrency; this box localizes the synchronization.
private final class TokenSeenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _seen = false

    var seen: Bool {
        lock.lock(); defer { lock.unlock() }
        return _seen
    }

    func markSeen() {
        lock.lock(); defer { lock.unlock() }
        _seen = true
    }
}

// MARK: - Ergonomic builder

extension InferenceBackend {
    /// Composes `self` with `others` into a ``FallbackBackend`` chain, in order
    /// (`self` first). Ergonomic parity with LangChain's `with_fallbacks` /
    /// pydantic's `FallbackModel`.
    ///
    /// ```swift
    /// let backend = primary.withFallbacks([secondary, tertiary])
    /// ```
    public func withFallbacks(
        _ others: [any InferenceBackend],
        policy: FallbackPolicy = .default
    ) -> FallbackBackend {
        FallbackBackend(backends: [self] + others, policy: policy)
    }
}

/// Free-function builder for an explicit ordered list. Mirrors
/// `with_fallbacks([...])` for callers who prefer a flat list over the
/// method form.
public func withFallbacks(
    _ backends: [any InferenceBackend],
    policy: FallbackPolicy = .default
) -> FallbackBackend {
    FallbackBackend(backends: backends, policy: policy)
}
