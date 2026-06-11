import Foundation
import Darwin
import Security
import CryptoKit
import ManifoldInference

// MARK: - PKCE Verifier (D7)

/// A PKCE code verifier that expires after 5 minutes and zeroes its storage on demand.
struct PKCEVerifier {
    private(set) var verifierData: Data
    let createdAt: Date

    init(data: Data, createdAt: Date = Date()) {
        self.verifierData = data
        self.createdAt = createdAt
    }

    /// True when more than 5 minutes have elapsed since creation.
    var isExpired: Bool { Date().timeIntervalSince(createdAt) > 300 }

    /// UTF-8 string view of the verifier bytes.
    var stringValue: String { String(data: verifierData, encoding: .utf8) ?? "" }

    /// Overwrites the verifier bytes in place.
    /// `memset_s` is not elided by optimising compilers because it carries a
    /// conformance obligation in the C standard.
    mutating func zero() {
        verifierData.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress, ptr.count > 0 else { return }
            _ = memset_s(base, ptr.count, 0, ptr.count)
        }
    }
}

// MARK: - Redirect-cap delegate (D6 — Gap B)

/// Limits redirect chains to at most one hop to prevent SSRF-via-redirect attacks,
/// and closes the DNS-rebinding TOCTOU (Gap C) by pinning the address URLSession
/// actually connected to.
///
/// ## Gap C — DNS-rebinding TOCTOU
///
/// `MCPSSRFPolicy.validateResolvedHostNotBlocked` resolves the hostname with its
/// own `getaddrinfo` query at check time, but `URLSession.bytes(for:)` /
/// `data(for:)` re-resolve the hostname at connect time with a *separate* query.
/// An attacker controlling DNS can return a public IP to the guard's query, then
/// serve a private IP (loopback, RFC1918, `169.254.169.254`, etc.) to URLSession's
/// query — reaching internal services despite the pre-flight check passing.
///
/// This delegate closes the window by inspecting the address URLSession *actually*
/// connected to (`URLSessionTaskTransactionMetrics.remoteAddress`) and cancelling
/// the task if any connected address classifies as private/reserved per
/// ``PrivateIPClassifier``. The caller reads ``blockedConnectedURL`` after the
/// request returns (or after the stream errors) and surfaces ``MCPError/ssrfBlocked``.
///
/// Localhost literals (`localhost`, `127.0.0.1`, `::1`) bypass the connected-address
/// check — they are explicitly configured local servers, mirroring the bypass in
/// ``MCPSSRFPolicy``.
///
/// - Note: This mirrors the connect-time pinning shape that `ManifoldCloudCore`'s
///   `DNSRebindingGuard` *omits* — the cloud side currently relies on pre-resolution
///   fail-closed only. ManifoldMCP depends on `ManifoldInference`, not
///   `ManifoldCloudCore` (see CLAUDE.md dependency rules), so this guard is
///   MCP-local rather than a shared type. `PrivateIPClassifier` (the IP-classification
///   logic) *is* reused across both.
final class MCPRedirectCapDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let maxRedirects: Int?
    private let validator: @Sendable (URL) throws -> Void
    private var redirectCount = 0

    /// Lock guarding `_blockedConnectedURL`. URLSession delivers
    /// `didFinishCollecting` on an arbitrary background queue, so the violation
    /// flag must be written under a lock and read back on the caller's actor.
    private let connectedLock = NSLock()
    private var _blockedConnectedURL: URL?

    /// The URL whose connection resolved to a blocked (private/reserved) address,
    /// or `nil` if every connected address was acceptable. Read by the transport
    /// after the request completes to decide whether to throw ``MCPError/ssrfBlocked``.
    var blockedConnectedURL: URL? {
        connectedLock.withLock { _blockedConnectedURL }
    }

    init(
        maxRedirects: Int? = 1,
        validator: @escaping @Sendable (URL) throws -> Void = { _ in }
    ) {
        self.maxRedirects = maxRedirects
        self.validator = validator
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        redirectCount += 1
        if let nextURL = request.url {
            do {
                try validator(nextURL)
            } catch {
                completionHandler(nil)
                return
            }
        }
        if let maxRedirects {
            completionHandler(redirectCount <= maxRedirects ? request : nil)
        } else {
            completionHandler(request)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        // Inspect every transaction (the original request plus any redirect hops):
        // each carries the address URLSession actually connected to. If any one is
        // private/reserved, the connection touched an internal host — block it.
        for transaction in metrics.transactionMetrics {
            guard let requestURL = transaction.request.url,
                  let remote = transaction.remoteAddress,
                  let category = Self.classifyConnectedAddress(remote, for: requestURL) else {
                continue
            }
            Log.network.error(
                "MCP transport: blocked connection — \(requestURL.host ?? "?", privacy: .public) connected to \(remote, privacy: .public) (\(category.description, privacy: .public)). DNS rebinding TOCTOU.")
            connectedLock.withLock {
                if _blockedConnectedURL == nil { _blockedConnectedURL = requestURL }
            }
            // Cancel so no further bytes flow over the offending connection.
            task.cancel()
            return
        }
    }

    /// Classifies the address URLSession connected to, returning the blocked
    /// category or `nil` when the address is public (or the request targets an
    /// explicitly configured localhost server, which always bypasses).
    ///
    /// `remoteAddress` from `URLSessionTaskTransactionMetrics` is a bare numeric
    /// host (no port), but may carry an IPv6 zone identifier (`fe80::1%en0`);
    /// ``PrivateIPClassifier`` strips the zone, so we pass it through unchanged.
    static func classifyConnectedAddress(_ remoteAddress: String, for url: URL) -> BlockedAddressCategory? {
        if PrivateIPClassifier.isLocalhostURL(url) { return nil }
        return PrivateIPClassifier.classifyIPLiteral(remoteAddress)
    }
}

// MARK: - Bearer redaction (D14)

/// Returns a 4-byte SHA-256 prefix of the bearer token, suitable for log lines.
/// Never returns the raw token value — prevents access tokens appearing in sysdiagnose.
func mcpBearerRedacted(_ data: Data) -> String {
    let hash = Data(SHA256.hash(data: data))
    return "Bearer <\(hash.prefix(4).map { String(format: "%02x", $0) }.joined())>"
}

// MARK: - Constant-time string comparison (D4)

/// Compares two strings in constant time relative to the length of the shorter string.
///
/// Because `timingsafe_bcmp` is not available in the Swift standard library, we
/// use the next-best option: XOR each byte pair and accumulate differences without
/// short-circuiting.  The result is O(min(a,b)) rather than O(1), which is
/// acceptable for URL strings — the important property is no early exit on the
/// first mismatch.
func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let aBytes = Array(a.utf8)
    let bBytes = Array(b.utf8)
    guard aBytes.count == bBytes.count else { return false }
    var diff: UInt8 = 0
    for (x, y) in zip(aBytes, bBytes) {
        diff |= x ^ y
    }
    return diff == 0
}


enum OAuthSecurity {
    static func enforceHTTPS(_ url: URL, label: String) throws {
        try MCPSSRFPolicy.validateOAuthURL(url, label: label)
    }

    static func requireSuccess(response: URLResponse, body: Data, operation: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.transportFailure("Missing HTTP response during \(operation)")
        }
        guard (200...299).contains(http.statusCode) else {
            let message = String(data: body, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw MCPError.authorizationFailed("\(operation) failed: \(message)")
        }
    }

    static func authorizationMetadataURL(for issuer: URL) -> URL {
        let trimmedPath = issuer.path == "/" ? "" : issuer.path
        var components = URLComponents()
        components.scheme = issuer.scheme
        components.host = issuer.host
        components.port = issuer.port
        components.path = "/.well-known/oauth-authorization-server\(trimmedPath)"
        return components.url ?? issuer.appendingPathComponent(".well-known/oauth-authorization-server")
    }

    static func resourceMetadataURL(for resourceURL: URL) -> URL {
        var components = URLComponents()
        components.scheme = resourceURL.scheme
        components.host = resourceURL.host
        components.port = resourceURL.port
        components.path = "/.well-known/oauth-protected-resource"
        return components.url ?? resourceURL
    }

    static func isSameOrigin(lhs: URL, rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? defaultPort(for: lhs)) == (rhs.port ?? defaultPort(for: rhs))
    }

    static func isSameIssuer(_ lhs: URL, _ rhs: URL) -> Bool {
        normalizedIssuerString(lhs) == normalizedIssuerString(rhs)
    }

    static func normalizedIssuerString(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        var path = components.path
        if path == "/" { path = "" }
        if path.hasSuffix("/") && path.count > 1 {
            path.removeLast()
        }
        components.path = path

        if components.port == defaultPort(for: url) {
            components.port = nil
        }

        components.query = nil
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    static func formURLEncoded(_ values: [String: String]) -> String {
        values
            .sorted { $0.key < $1.key }
            .map { key, value in "\(urlEncode(key))=\(urlEncode(value))" }
            .joined(separator: "&")
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func pkceChallenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    static func secureRandomData(length: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw MCPError.authorizationFailed(
                "CSPRNG unavailable (OSStatus \(status)) — cannot generate PKCE verifier securely"
            )
        }
        return Data(bytes)
    }

    private static func urlEncode(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func defaultPort(for url: URL) -> Int? {
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }
}
