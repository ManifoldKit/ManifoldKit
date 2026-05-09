#if Server
import Foundation
import HTTPTypes
import Hummingbird

/// A request inspected by `RequestAuthMiddleware`.
///
/// Captures the data needed to authenticate without coupling the middleware
/// to Hummingbird's request type — host apps can write tests against
/// `AuthRequest` directly.
internal struct AuthRequest: Sendable {
    internal let headers: [String: String]
    internal let path: String
    internal let method: String
    internal let remoteAddress: String?

    internal init(
        headers: [String: String],
        path: String,
        method: String,
        remoteAddress: String? = nil
    ) {
        self.headers = headers
        self.path = path
        self.method = method
        self.remoteAddress = remoteAddress
    }
}

/// Opaque authenticated identity returned by `RequestAuthMiddleware`.
///
/// `id` is host-defined (token fingerprint, user-id, etc.). `scopes` is a
/// host-defined capability set — kept as free-form strings for flexibility.
/// Endpoints that need scope checks compare against this set.
internal struct AuthPrincipal: Sendable, Hashable {
    internal let id: String
    internal let scopes: Set<String>

    internal init(id: String, scopes: Set<String> = []) {
        self.id = id
        self.scopes = scopes
    }

    /// The principal returned for explicitly anonymous (unauthenticated)
    /// access. Hosts that opt in via `AnonymousAuthMiddleware` see this.
    internal static let anonymous = AuthPrincipal(id: "anonymous", scopes: [])
}

/// Reasons a `RequestAuthMiddleware` can reject a request.
///
/// Conforms to `Error` so middleware can `throw` directly. The HTTP layer
/// translates these to `401 Unauthorized` envelopes.
internal enum AuthError: Error, Equatable, Sendable {
    /// No credential was supplied (e.g. missing `Authorization` header).
    case missingCredential
    /// A credential was supplied but did not match expected format
    /// (e.g. wrong scheme, empty token).
    case malformedCredential
    /// A well-formed credential was supplied but is not valid (wrong token,
    /// revoked, expired).
    case invalidCredential
}

/// Authenticates an inbound HTTP request, returning an `AuthPrincipal` or
/// throwing `AuthError`.
///
/// Implementations should fail closed: when no credential / invalid credential
/// is presented, throw. Only return a principal (anonymous or otherwise) when
/// the host has explicitly opted in to that behavior.
internal protocol RequestAuthMiddleware: Sendable {
    func authenticate(_ request: AuthRequest) async throws -> AuthPrincipal
}

/// Default no-op middleware: every request authenticates as `.anonymous`.
///
/// This is the default for `ServerConfiguration`, so the existing behavior
/// (no auth) is preserved for hosts that don't opt in.
internal struct AnonymousAuthMiddleware: RequestAuthMiddleware {
    internal init() {}

    internal func authenticate(_ request: AuthRequest) async throws -> AuthPrincipal {
        AuthPrincipal.anonymous
    }
}

/// Validates `Authorization: Bearer <token>` against a fixed token.
///
/// Compares in constant time to avoid leaking match-prefix information through
/// timing. The principal returned uses a stable id (`"bearer"`) so hosts can
/// use it as a sentinel; richer identity belongs in a host-specific impl.
internal struct BearerTokenMiddleware: RequestAuthMiddleware {
    internal let token: String
    internal let scopes: Set<String>

    internal init(token: String, scopes: Set<String> = []) {
        self.token = token
        self.scopes = scopes
    }

    internal func authenticate(_ request: AuthRequest) async throws -> AuthPrincipal {
        // Headers are case-insensitive per RFC 9110 §5.1; lookup must match either casing.
        let header = request.headers["Authorization"]
            ?? request.headers["authorization"]
        guard let header, !header.isEmpty else {
            throw AuthError.missingCredential
        }
        let prefix = "Bearer "
        guard header.hasPrefix(prefix) else {
            throw AuthError.malformedCredential
        }
        let supplied = String(header.dropFirst(prefix.count))
        guard !supplied.isEmpty else {
            throw AuthError.malformedCredential
        }
        guard Self.constantTimeEqual(supplied, token) else {
            throw AuthError.invalidCredential
        }
        return AuthPrincipal(id: "bearer", scopes: scopes)
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        return zip(aBytes, bBytes).reduce(0 as UInt8) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

extension AuthRequest {
    /// Builds an `AuthRequest` from the Hummingbird request types used by
    /// `ServerApp`. Lives here so the protocol stays Hummingbird-free for
    /// host tests.
    internal static func from(_ request: Request) -> AuthRequest {
        var headers: [String: String] = [:]
        for field in request.headers {
            headers[field.name.canonicalName] = field.value
        }
        return AuthRequest(
            headers: headers,
            path: request.uri.path,
            method: request.method.rawValue,
            remoteAddress: nil
        )
    }
}

#endif
