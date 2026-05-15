import Foundation
import Darwin
import Security
import CryptoKit

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

/// Limits redirect chains to at most one hop to prevent SSRF-via-redirect attacks.
final class MCPRedirectCapDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let maxRedirects: Int?
    private let validator: @Sendable (URL) throws -> Void
    private var redirectCount = 0

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
