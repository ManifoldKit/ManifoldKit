import Foundation

/// Reasons an ``BaseChatSchemaV3/APIEndpoint`` URL can fail structural validation.
///
/// Produced by `APIEndpoint.validate()`. Conforms to `LocalizedError` so settings
/// UI can render `localizedDescription` directly as the reason the endpoint is
/// not ready, rather than showing a generic "Incomplete" label.
///
/// The SSRF-related cases (``privateHost``, ``linkLocalHost``, ``ipv6UniqueLocal``,
/// ``ipv4MappedLoopback``, ``multicastReserved``) correspond to the address-class
/// blocks enforced by ``BaseChatSchemaV3/APIEndpoint`` — see `validate()` for the
/// full classification.
public enum APIEndpointValidationReason: Error, Equatable, Sendable {
    /// The base URL string is empty or only whitespace.
    case emptyURL

    /// The base URL is not a parseable URL, or is missing a scheme/host.
    case malformedURL

    /// The URL uses a scheme other than `http` or `https` (for example
    /// `file://`, `ftp://`, `data:`, `javascript:`). The associated value is
    /// the offending scheme in lowercase, for display in UI or logs.
    case unsupportedScheme(String)

    /// The URL uses `http://` against a remote host. Only `https://` is
    /// accepted for non-loopback addresses; `localhost`, `127.0.0.1`, and `::1`
    /// may use `http://` for local development.
    case insecureScheme

    /// The URL targets an RFC1918 private IPv4 range (`10.0.0.0/8`,
    /// `172.16.0.0/12`, `192.168.0.0/16`). Blocked to prevent SSRF pivots onto
    /// the user's LAN.
    case privateHost

    /// The URL targets a link-local range (IPv4 `169.254.0.0/16` or IPv6
    /// `fe80::/10`). This includes cloud instance metadata services such as
    /// AWS / GCP / Azure IMDS at `169.254.169.254`.
    case linkLocalHost

    /// The URL targets the IPv6 unique-local range (`fc00::/7`), the IPv6
    /// equivalent of RFC1918 private addresses.
    case ipv6UniqueLocal

    /// The URL uses an IPv4-mapped IPv6 address (`::ffff:0:0/96`). These are
    /// rejected wholesale because they would otherwise bypass the IPv4
    /// loopback allowlist (e.g. `::ffff:127.0.0.1`) and the RFC1918 filter
    /// (e.g. `::ffff:192.168.1.1`).
    case ipv4MappedLoopback

    /// The URL targets a multicast or reserved IPv4 range (`0.0.0.0/8`,
    /// alternate loopback encodings in `127.0.0.0/8` other than `127.0.0.1`,
    /// `224.0.0.0/4` multicast, or `240.0.0.0/4` reserved / broadcast). None
    /// are valid API-server targets.
    case multicastReserved
}

// MARK: - LocalizedError

extension APIEndpointValidationReason: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .emptyURL:
            return "Enter a server URL to continue."
        case .malformedURL:
            return "The server URL is not valid. Include a scheme and host, for example https://api.example.com."
        case .unsupportedScheme(let scheme):
            return "The scheme \"\(scheme)://\" is not supported. Use https:// (or http:// for localhost)."
        case .insecureScheme:
            return "Remote servers must use https://. Plain http:// is only allowed for localhost."
        case .privateHost:
            return "Private IP addresses (10.x, 172.16–31.x, 192.168.x) are not allowed."
        case .linkLocalHost:
            return "Link-local addresses (169.254.x.x, fe80::/10) are blocked to protect cloud metadata services."
        case .ipv6UniqueLocal:
            return "IPv6 unique-local addresses (fc00::/7) are not allowed."
        case .ipv4MappedLoopback:
            return "IPv4-mapped IPv6 addresses (::ffff:…) are not a recognized local address."
        case .multicastReserved:
            return "Multicast and reserved IP addresses cannot be used as API endpoints."
        }
    }
}
