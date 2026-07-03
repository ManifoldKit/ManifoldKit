import Foundation

// MARK: - Error Body Decoder
//
// This is the one witness from the original "shape" design (removed in the
// v0.64 inert-surface sweep — see docs/CHANGELOG for the removal notice)
// that a real call site reads: `SSECloudBackend.checkStatusCode` consults
// `CloudAdapterRouting.errorBodyDecoder` to surface provider-shaped errors
// without per-provider branches. The tool-call / image-input /
// structured-output / tool-result / prompt-cache "shape" protocols and
// their concrete witness structs were deleted — every adapter constructed
// one, but nothing ever read `.toolCallShape`, `.imageInputShape`,
// `.structuredOutputShape`, `.toolResultEncoding`, or `.promptCacheShape`
// back to make an encoding decision. The wire-encoding logic those
// properties were meant to eventually front still lives directly in each
// backend's `buildRequest`/payload-handler pair.

/// Maps an upstream HTTP error response body to a human-readable error
/// message. Adapters compose one so `SSECloudBackend.checkStatusCode`
/// surfaces provider-shaped errors without per-provider branches.
public protocol ErrorBodyDecoder: Sendable {
    /// Extract a user-facing error message from a JSON / text error body.
    /// Returns `nil` when the body doesn't match a known shape; the caller
    /// falls back to the raw body (sanitized).
    func extractMessage(from body: String) -> String?
}

/// Default decoder: handles `{error:{message:…}}`, flat `{message:…}`, and
/// `{detail:…}` shapes used by OpenAI, Anthropic, and most compat servers.
public struct DefaultErrorBodyDecoder: ErrorBodyDecoder {
    public init() {}
    public func extractMessage(from body: String) -> String? {
        parseCloudErrorMessage(from: body)
    }
}
