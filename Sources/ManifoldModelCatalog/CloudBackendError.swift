import Foundation
import ManifoldHardware

/// Errors from cloud API backends (OpenAI-compatible and Claude).
///
/// ## Vocabulary growth (1.x)
///
/// New cases are added as new provider-specific failure modes are
/// identified — `quotaExceeded`, `providerOverloaded`, `contentFiltered`,
/// `blockedAddress`, `unpinnedCredentialedHost`, and `missingRequiredOverride`
/// all landed after this type's original ship. This is source-breaking for
/// an exhaustive `switch` outside this package; add a `default:` arm (or an
/// explicit case for each you handle) to stay resilient to a future case —
/// see `docs/MIGRATION-cloudbackenderror-missingRequiredOverride.md` for the
/// concrete example. Cross-cutting properties (`errorDescription`,
/// `isRetryable`, `category`) are updated in the same PR that adds a case,
/// so generic error handling (logging, retry policy, user-facing message)
/// never needs the switch to be exhaustive in the first place.
public enum CloudBackendError: LocalizedError, CategorizedError {
    case invalidURL(String)
    case authenticationFailed(provider: String)
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(statusCode: Int, message: String)
    case networkError(underlying: Error)
    case parseError(String)
    case missingAPIKey
    /// The SSE or NDJSON stream was interrupted by a network failure.
    case streamInterrupted
    /// The backend object was deallocated while a stream was in flight.
    /// Not retryable — the backend no longer exists.
    case backendDeallocated
    /// The endpoint's hostname resolved to a private, link-local, or reserved
    /// IP address at connect time, indicating a potential DNS rebinding attack.
    /// The associated value describes which address triggered the block.
    case blockedAddress(String)
    /// A credentialed request targeted a non-loopback host that has no SPKI pins
    /// configured, and ``ManifoldConfiguration/allowUnpinnedCredentialedHosts``
    /// is `false`. Fail closed so Authorization material is not sent under
    /// platform trust alone (residual DNS-rebinding risk if TLS were to succeed
    /// against a rebound private address).
    case unpinnedCredentialedHost(String)
    /// The runtime kill-switch ``URLSessionProvider/networkDisabled`` was
    /// `true` when a cloud backend tried to obtain a `URLSession`. Belt-and-
    /// suspenders mitigation for regulated runtimes that need to lock the
    /// network even in a `full`-trait build. Not retryable.
    case networkDisabled
    /// HTTP 429 where the provider signals a billing cap or quota exhaustion
    /// (distinct from throttle-based rate limiting). Not retryable within the
    /// same billing period — the user must take action (increase quota, add
    /// credits, or switch endpoint).
    case quotaExceeded(provider: String)
    /// HTTP 529 or provider-specific "overloaded" response (e.g. Claude 529).
    /// The provider is temporarily at capacity. A short exponential backoff
    /// helps; it is not a permanent error.
    case providerOverloaded(provider: String, retryAfter: TimeInterval?)
    /// The request was rejected by the provider's content filter.
    /// Not retryable — the content must change.
    case contentFiltered(provider: String, reason: String?)
    /// An `open` subclass hook on `SSECloudBackend` (or a future similar
    /// base class) that a concrete subclass was required to override was
    /// never overridden. This is a programmer/integration error — the
    /// associated value names the missing hook — surfaced as a catchable
    /// error on the call that needed it instead of a `fatalError`, so a
    /// third-party subclass with a wiring mistake fails the one request
    /// instead of crashing the host process. Not retryable: retrying the
    /// same call hits the same missing override every time.
    case missingRequiredOverride(String)

    // MARK: - CategorizedError

    package var category: InferenceErrorCategory {
        switch self {
        case .rateLimited(let retryAfter):
            return .rateLimited(retryAfter: retryAfter)
        case .quotaExceeded:
            return .quotaExceeded
        case .providerOverloaded(_, let retryAfter):
            return .providerOverloaded(retryAfter: retryAfter)
        case .authenticationFailed, .missingAPIKey:
            return .authenticationFailed
        case .contentFiltered:
            return .contentFiltered
        case .networkError, .streamInterrupted:
            return .retryableTransient
        case .serverError(let code, _) where code >= 500:
            return .retryableTransient
        case .invalidURL, .parseError, .backendDeallocated,
             .blockedAddress, .unpinnedCredentialedHost, .networkDisabled, .serverError,
             .missingRequiredOverride:
            return .nonRetryable
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidURL(let url):
            return "Invalid server URL: \(url)"
        case .authenticationFailed(let provider):
            return "\(provider) authentication failed. Check your API key."
        case .rateLimited(let retryAfter):
            if let seconds = retryAfter {
                return "Rate limited. Try again in \(Int(seconds)) seconds."
            }
            return "Rate limited. Please wait before retrying."
        case .serverError(let code, let message):
            return "Server error (\(code)): \(message)"
        case .networkError(let underlying):
            // Route through the unified rim so consumers see user-readable
            // strings ("Not connected to the internet.") rather than the raw
            // `URLError.localizedDescription` ("kCFErrorDomainCFNetwork -1009").
            return ManifoldKitError.from(underlying).errorDescription
                ?? "Network error: \(underlying.localizedDescription)"
        case .parseError(let detail):
            return "Failed to parse response: \(detail)"
        case .missingAPIKey:
            return "No API key configured. Add one in Settings."
        case .streamInterrupted:
            return "Response stream was interrupted."
        case .backendDeallocated:
            return "Backend was deallocated during generation."
        case .blockedAddress(let detail):
            return "Connection blocked: the endpoint resolved to a private or reserved address. \(detail)"
        case .unpinnedCredentialedHost(let host):
            return "Credentialed request to unpinned host '\(host)' rejected. Add SPKI pins via PinnedSessionDelegate.pinnedHosts, or set ManifoldConfiguration.shared.allowUnpinnedCredentialedHosts = true only if you accept residual DNS-rebinding risk."
        case .networkDisabled:
            return "Network access is disabled by the runtime kill-switch (URLSessionProvider.networkDisabled)."
        case .quotaExceeded(let provider):
            return "\(provider) quota exceeded. Check your billing plan or add credits to continue."
        case .providerOverloaded(let provider, let retryAfter):
            if let seconds = retryAfter {
                return "\(provider) is temporarily at capacity. Try again in \(Int(seconds)) seconds."
            }
            return "\(provider) is temporarily at capacity. Try again shortly."
        case .contentFiltered(let provider, let reason):
            if let reason {
                return "\(provider) rejected the request due to content policy: \(reason)"
            }
            return "\(provider) rejected the request due to content policy."
        case .missingRequiredOverride(let detail):
            return "Internal error: \(detail)"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .networkError, .streamInterrupted, .providerOverloaded:
            return true
        case .serverError(let statusCode, _):
            return statusCode >= 500
        case .invalidURL, .authenticationFailed, .parseError, .missingAPIKey,
             .backendDeallocated, .blockedAddress, .unpinnedCredentialedHost,
             .networkDisabled, .quotaExceeded, .contentFiltered,
             .missingRequiredOverride:
            return false
        }
    }
}
