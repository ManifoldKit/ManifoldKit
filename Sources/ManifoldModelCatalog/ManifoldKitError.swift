import Foundation

/// Unified, user-facing error rim for ManifoldKit.
///
/// Public ManifoldKit APIs used to leak raw `Foundation.URLError` to consumers,
/// surfacing strings like `kCFErrorDomainCFNetwork 6` in host UIs. This type
/// is the single rim that consumers branch on and present. Internally, domain
/// errors (``CloudBackendError``, ``HuggingFaceError``, ``KeychainError``)
/// still carry their structured information; their ``LocalizedError/errorDescription``
/// routes underlying network failures through ``ManifoldKitError/from(_:)`` so
/// the user-visible string is always one of the cases here.
///
/// The mapping logic is lifted from the original `HuggingFaceProbe.sanitise(urlError:)`
/// — see that file's history for the rationale. The probe helper is kept as a
/// thin shim for compatibility.
///
/// Stored values are restricted to `Sendable` primitives (`Int`, `String`).
/// Underlying errors are reduced to a string at construction time so the
/// rim itself is unconditionally `Sendable` without `@unchecked`.
public enum ManifoldKitError: Error, Sendable, LocalizedError, Equatable {
    /// The device reports no internet connectivity (radio off, airplane mode,
    /// captive portal pre-login).
    case notConnectedToInternet
    /// The request exceeded its wall-clock budget. Distinct from ``cancelled``
    /// — the user did not abort, the network simply stalled.
    case timedOut
    /// The request was cancelled cooperatively (user pressed stop, parent
    /// task cancelled, `URLError(.cancelled)` propagated up).
    case cancelled
    /// TLS handshake failed — bad certificate, pinning mismatch, untrusted
    /// root, or expired cert.
    case tlsFailure
    /// DNS lookup failed or returned no records. Distinct from
    /// ``serverError`` (which implies the host was reachable).
    case dnsFailure
    /// The server responded with an HTTP status outside the 2xx range, or
    /// returned a body that failed structural validation (non-HTTP response).
    /// `statusCode == 0` is used for the latter — the response did not parse
    /// as an `HTTPURLResponse` at all.
    case serverError(statusCode: Int, message: String?)
    /// Keychain operation failed because the device is locked, the
    /// entitlement is missing, or the keychain is otherwise unavailable.
    case keychainUnavailable
    /// JSON / data decoding failed at a trust boundary. The associated value
    /// is a short, PII-free description of where decoding failed (e.g.
    /// `"missing field: choices"`).
    case decodingFailure(String)
    /// No inference backend was compiled into the binary for the active trait /
    /// OS combination, so the assembled service can never generate. Raised at
    /// the assembly boundary (``ManifoldKit/ManifoldKit/quickStart(configuration:)``)
    /// as a fail-fast diagnostic rather than letting the app launch dead and
    /// throw on the first turn.
    case noBackendsRegistered

    /// Catch-all for errors that did not match any of the more specific cases.
    /// The underlying error is reduced to a string at construction time to
    /// keep the rim `Sendable`.
    case unknown(underlyingDescription: String)

    public var errorDescription: String? {
        switch self {
        case .notConnectedToInternet:
            return "Not connected to the internet."
        case .timedOut:
            return "The request timed out."
        case .cancelled:
            return "The request was cancelled."
        case .tlsFailure:
            return "Secure connection failed (TLS handshake)."
        case .dnsFailure:
            return "Couldn't reach the server (DNS lookup failed)."
        case .serverError(let statusCode, let message):
            if statusCode == 0 {
                if let message, !message.isEmpty {
                    return "Server returned an unexpected response: \(message)"
                }
                return "Server returned an unexpected response."
            }
            if let message, !message.isEmpty {
                return "Server error \(statusCode): \(message)"
            }
            return "Server error \(statusCode)."
        case .keychainUnavailable:
            return "Keychain is unavailable. Unlock the device and try again."
        case .decodingFailure(let detail):
            return "Couldn't read the server response: \(detail)"
        case .noBackendsRegistered:
            return "No inference backends are compiled into this build. quickStart() needs at least one backend trait enabled (MLX, Llama, CloudSaaS, Ollama, or Foundation). Check the package traits / build settings."
        case .unknown(let underlyingDescription):
            if underlyingDescription.isEmpty {
                return "An unexpected error occurred."
            }
            return "An unexpected error occurred: \(underlyingDescription)"
        }
    }

    /// Reduces any thrown `Error` to the closest matching ``ManifoldKitError``
    /// case. The mapping is exhaustive across `URLError` codes that the
    /// inference / cloud / HF stacks can produce; unknown errors fall through
    /// to ``unknown(underlyingDescription:)`` with the localized description
    /// captured as a string.
    ///
    /// If passed an existing ``ManifoldKitError`` this returns it unchanged so
    /// `from(_:)` is idempotent and safe to call at any layer.
    public static func from(_ error: Error) -> ManifoldKitError {
        if let already = error as? ManifoldKitError {
            return already
        }

        if error is CancellationError {
            return .cancelled
        }

        if let urlError = error as? URLError {
            return fromURLError(urlError)
        }

        // `NSURLErrorDomain` is the bridged form of `URLError`. Background
        // download delegate callbacks deliver errors as `NSError` rather than
        // `URLError`, so we cover that surface too.
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            if let urlError = URLError(_nsError: nsError) as URLError? {
                return fromURLError(urlError)
            }
        }

        if let decoding = error as? DecodingError {
            return .decodingFailure(decodingDetail(decoding))
        }

        // KeychainError lives in this module — pattern-match by string to
        // avoid pulling Security into the rim's exhaustive surface. The
        // Equatable conformance + osStatus accessor would be nicer, but
        // tying the rim to KeychainError's case shape is not worth the
        // brittleness.
        let typeName = String(reflecting: type(of: error))
        if typeName.contains("KeychainError") {
            return .keychainUnavailable
        }

        return .unknown(underlyingDescription: error.localizedDescription)
    }

    private static func fromURLError(_ urlError: URLError) -> ManifoldKitError {
        switch urlError.code {
        case .timedOut:
            return .timedOut
        case .cancelled:
            return .cancelled
        case .notConnectedToInternet, .networkConnectionLost,
             .dataNotAllowed, .internationalRoamingOff:
            return .notConnectedToInternet
        case .cannotFindHost, .dnsLookupFailed:
            return .dnsFailure
        case .cannotConnectToHost:
            // No host to connect to is closer to a DNS-shape failure than a
            // server error — keep this in the DNS bucket so user messaging
            // points at connectivity rather than the remote service.
            return .dnsFailure
        case .secureConnectionFailed,
             .serverCertificateUntrusted,
             .serverCertificateHasBadDate,
             .serverCertificateNotYetValid,
             .serverCertificateHasUnknownRoot,
             .clientCertificateRejected,
             .clientCertificateRequired,
             .appTransportSecurityRequiresSecureConnection:
            return .tlsFailure
        case .badServerResponse, .zeroByteResource, .cannotParseResponse:
            return .serverError(statusCode: 0, message: "Malformed server response")
        case .httpTooManyRedirects, .redirectToNonExistentLocation:
            return .serverError(statusCode: 0, message: "Too many redirects")
        case .unsupportedURL, .badURL:
            return .serverError(statusCode: 0, message: "Invalid URL")
        default:
            // `URLError.localizedDescription` is generally PII-free (it does
            // not contain the URL itself for most codes), so it is safe to
            // forward as the unknown description.
            return .unknown(underlyingDescription: urlError.localizedDescription)
        }
    }

    private static func decodingDetail(_ error: DecodingError) -> String {
        switch error {
        case .keyNotFound(let key, _):
            return "missing field: \(key.stringValue)"
        case .typeMismatch(_, let context):
            return "type mismatch at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .valueNotFound(_, let context):
            return "missing value at \(context.codingPath.map(\.stringValue).joined(separator: "."))"
        case .dataCorrupted(let context):
            return context.debugDescription
        @unknown default:
            return "decoding failed"
        }
    }
}
