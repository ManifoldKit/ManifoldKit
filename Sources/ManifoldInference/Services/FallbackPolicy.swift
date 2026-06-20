import Foundation

/// Configures how a ``FallbackBackend`` decides to advance from one backend to
/// the next when a generation attempt fails.
///
/// The two routing axes in ManifoldKit are deliberately separate:
///
/// - ``RouterBackend`` selects **one** child per request by *capability* and
///   never retries across children (see its doc-comment). That is a
///   capability-select axis.
/// - ``FallbackBackend`` (configured by this policy) advances across an ordered
///   list on *error*. That is an error-advance axis.
///
/// They compose: a ``FallbackBackend`` whose children are ``RouterBackend``s is
/// valid and routes on both axes.
public struct FallbackPolicy: Sendable {
    /// Predicate deciding whether a given error from one backend should cause
    /// the chain to advance to the next backend.
    ///
    /// The default advances only on errors that conform to ``BackendError`` and
    /// report `isRetryable == true` — the same transient-vs-terminal signal the
    /// per-backend ``withRetry(strategy:sleeper:operation:)`` path uses. This
    /// keeps fail-fast semantics: a non-retryable error (bad request, auth
    /// failure, quota exhausted, unsupported model) is *propagated*, not routed
    /// around, because trying the next backend would not change the outcome.
    public var shouldAdvance: @Sendable (any Error) -> Bool

    /// Whether to advance to the next backend even after the current backend has
    /// already emitted at least one *content* token (``GenerationEvent/token(_:)``
    /// or a thinking token).
    ///
    /// Defaults to `false`. Once the consumer has seen partial output, silently
    /// failing over and restarting on a different backend would duplicate or
    /// contradict already-delivered tokens. With the default, an error that
    /// arrives *after* the first token is always propagated regardless of
    /// ``shouldAdvance`` — fallback only fires on pre-first-token failures.
    ///
    /// Set to `true` only when the consumer is prepared to discard partial
    /// output and restart the turn on the next backend.
    public var advanceAfterFirstToken: Bool

    /// Number of in-backend retries to attempt (via
    /// ``withRetry(strategy:sleeper:operation:)``) *before* advancing to the
    /// next backend. Defaults to `0` — no per-backend retry, advance on the
    /// first failure.
    ///
    /// Per-backend retry (same backend, transient error) and cross-backend
    /// fallback (next backend) are orthogonal: this composes them so a chain can
    /// retry each backend N times before moving on.
    public var perBackendRetries: Int

    public init(
        shouldAdvance: @escaping @Sendable (any Error) -> Bool = FallbackPolicy.defaultShouldAdvance,
        advanceAfterFirstToken: Bool = false,
        perBackendRetries: Int = 0
    ) {
        self.shouldAdvance = shouldAdvance
        self.advanceAfterFirstToken = advanceAfterFirstToken
        self.perBackendRetries = perBackendRetries
    }

    /// Advances only on retryable ``BackendError``s. Non-`BackendError` errors
    /// and non-retryable backend errors do not advance (fail fast).
    public static let defaultShouldAdvance: @Sendable (any Error) -> Bool = { error in
        guard let backendError = error as? any BackendError else { return false }
        return backendError.isRetryable
    }

    /// The default policy: advance on retryable errors only, never after the
    /// first token, no per-backend retries.
    public static let `default` = FallbackPolicy()
}
