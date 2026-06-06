import Foundation

/// A coarse-grained, type-erased view of an inference or cloud backend error.
/// Use this when you need to make a routing decision (retry vs fail-fast vs
/// user-action-required) without switching on the concrete error type.
public enum InferenceErrorCategory: Sendable, Equatable {
    /// Network blip, 5xx, stream interrupted — a retry may succeed.
    case retryableTransient
    /// Provider throttled the request. The associated value is the
    /// recommended retry delay, if the provider supplied one.
    case rateLimited(retryAfter: TimeInterval?)
    /// Billing cap or quota exhausted. The user must take action.
    case quotaExceeded
    /// Provider is temporarily at capacity (Claude 529, etc.).
    /// Short exponential backoff is appropriate.
    case providerOverloaded(retryAfter: TimeInterval?)
    /// API key missing or invalid.
    case authenticationFailed
    /// Prompt + requested output exceeds the model's context window.
    case contextExceeded
    /// Provider's content policy rejected the request.
    case contentFiltered
    /// Capability mismatch — grammar, vision, tools not supported by this backend.
    case unsupportedRequest
    /// Permanent error — no retry will help.
    case nonRetryable
}

/// Implemented by ``InferenceError`` and ``CloudBackendError`` to expose a
/// uniform category view without changing the concrete enum type.
public protocol CategorizedError: Error {
    var category: InferenceErrorCategory { get }
}
