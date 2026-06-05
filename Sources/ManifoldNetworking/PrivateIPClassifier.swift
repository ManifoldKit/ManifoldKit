import Foundation

/// Categories of blocked IP address ranges, used for SSRF and DNS rebinding mitigation.
///
/// Mirrors the IP-classification subset of ``APIEndpointValidationReason`` so that the
/// identical policy can be enforced from both `ManifoldCore` (URL validation) and
/// `ManifoldBackends` (DNS-resolved address checks) without duplicating the rules.
package enum BlockedAddressCategory: Sendable, CustomStringConvertible {
    /// RFC1918 private IPv4 range (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`).
    case privateHost
    /// Link-local range (IPv4 `169.254.0.0/16` or IPv6 `fe80::/10`).
    /// Includes cloud instance-metadata services (AWS/GCP/Azure IMDS).
    case linkLocalHost
    /// IPv6 unique-local range (`fc00::/7`) — the IPv6 equivalent of RFC1918.
    case ipv6UniqueLocal
    /// IPv4-mapped IPv6 address (`::ffff:0:0/96`). Rejected wholesale so that
    /// mapped loopback (`::ffff:127.0.0.1`) and mapped RFC1918 addresses cannot
    /// bypass the IPv4 filter.
    case ipv4MappedLoopback
    /// Multicast or reserved IPv4 range (`0.0.0.0/8`, `127.0.0.0/8`,
    /// `224.0.0.0/4`, `240.0.0.0/4`), or the IPv6 loopback address `::1`.
    case multicastReserved

    package var description: String {
        switch self {
        case .privateHost:       return "RFC1918 private address"
        case .linkLocalHost:     return "link-local address"
        case .ipv6UniqueLocal:   return "IPv6 unique-local address"
        case .ipv4MappedLoopback: return "IPv4-mapped IPv6 address"
        case .multicastReserved: return "multicast or reserved address"
        }
    }
}

/// Shared IP-address classification logic for SSRF / DNS-rebinding mitigation.
///
/// Used by:
/// - `ManifoldCore.APIEndpoint.validate()` — structural URL validation at config time.
/// - `ManifoldBackends.DNSRebindingGuard` — request-time check of DNS-resolved addresses.
///
/// Only IP literals are inspected. **DNS names are never resolved here.** Callers that
/// need to guard against DNS rebinding must resolve the hostname first (e.g. via
/// `getaddrinfo`) and then pass each resolved address to ``classifyIPLiteral(_:)``.
package enum PrivateIPClassifier {

    // MARK: - Localhost

    /// Returns `true` if `url`'s host is an explicit loopback literal.
    ///
    /// Only the three literals `localhost`, `127.0.0.1`, and `::1` match —
    /// broader `127.x.x.x` and IPv4-mapped IPv6 loopback are intentionally
    /// excluded to prevent bypass via alternate encodings.
    package static func isLocalhostURL(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    /// Returns `true` if `host` is a loopback host string.
    ///
    /// Recognises the literal `localhost`, the IPv6 loopback `::1`, and the
    /// full IPv4 loopback range `127.0.0.0/8` (RFC 1122). Distinct from
    /// ``isLocalhostURL(_:)``, which intentionally limits to the three canonical
    /// loopback literals for URL-configuration validation. This helper is for
    /// trust-decision call sites (e.g. certificate-pinning bypass) where every
    /// `127.x.x.x` address must be treated as loopback — otherwise hosts like
    /// `127.0.0.2` slip past a literal allowlist and fall through to platform
    /// trust [SEC-17].
    package static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        if normalized == "localhost" || normalized == "::1" {
            return true
        }
        if let octets = parseIPv4Literal(normalized), octets[0] == 127 {
            return true
        }
        return false
    }

    // MARK: - IP Literal Classification

    /// Classifies an IP literal string as belonging to a blocked address range.
    ///
    /// Returns `nil` for:
    /// - DNS names (not resolved here — return value is undefined for non-literals)
    /// - Addresses in routable public ranges (allowed)
    ///
    /// > Important: Both `127.0.0.1` and `::1` are classified as
    /// > ``BlockedAddressCategory/multicastReserved`` by this function.
    /// > For URL-configuration validation, callers must apply ``isLocalhostURL(_:)``
    /// > *before* calling this method so explicitly configured loopback servers remain
    /// > accessible. For DNS-resolved addresses, loopback returned by a remote domain
    /// > is always a rebinding attack and should be blocked unconditionally.
    package static func classifyIPLiteral(_ rawAddress: String) -> BlockedAddressCategory? {
        // Strip trailing dot — FQDN form (e.g. `192.168.1.1.`) resolves identically
        // to the dotless form and would bypass classification without this.
        let address = rawAddress.hasSuffix(".") ? String(rawAddress.dropLast()) : rawAddress

        if let octets = parseIPv4Literal(address) {
            return classifyIPv4(octets)
        }
        if let words = parseIPv6Literal(address) {
            return classifyIPv6(words)
        }
        return nil
    }

    // MARK: - IPv4

    /// Parses a dotted-quad IPv4 literal into four octets.
    ///
    /// Returns `nil` for non-literal inputs (DNS names, IPv6, shorthand forms like
    /// `127.1` that some resolvers accept but modern URL parsers reject).
    static func parseIPv4Literal(_ host: String) -> [UInt8]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [UInt8] = []
        octets.reserveCapacity(4)
        for part in parts {
            guard !part.isEmpty, part.allSatisfy(\.isASCII),
                  let value = UInt16(part), value <= 255 else {
                return nil
            }
            octets.append(UInt8(value))
        }
        return octets
    }

    /// Classifies an IPv4 address (as four octets) into a blocked range, or returns
    /// `nil` if the address is in a routable public range.
    static func classifyIPv4(_ octets: [UInt8]) -> BlockedAddressCategory? {
        let a = octets[0]
        let b = octets[1]

        if a == 10 { return .privateHost }                           // 10.0.0.0/8 — RFC1918
        if a == 172 && (16...31).contains(b) { return .privateHost } // 172.16.0.0/12 — RFC1918
        if a == 192 && b == 168 { return .privateHost }              // 192.168.0.0/16 — RFC1918
        // 100.64.0.0/10 — Shared Address Space (RFC 6598); carrier NAT / cloud-internal
        if a == 100 && (64...127).contains(b) { return .privateHost }
        if a == 169 && b == 254 { return .linkLocalHost }            // 169.254.0.0/16 — link-local (cloud IMDS)
        if a == 0 { return .multicastReserved }                      // 0.0.0.0/8 — "this host"
        // 127.0.0.0/8 — loopback (full /8, including 127.0.0.1).
        // For URL validation, callers apply isLocalhostURL first so 127.0.0.1
        // never reaches here. For DNS-resolved addresses, any 127.x.x.x is an attack.
        if a == 127 { return .multicastReserved }
        if (224...239).contains(a) { return .multicastReserved }     // 224.0.0.0/4 — multicast
        if a >= 240 { return .multicastReserved }                    // 240.0.0.0/4 — reserved / broadcast
        return nil
    }

    // MARK: - IPv6

    /// Parses an IPv6 literal (as returned by `URL.host()` — without surrounding
    /// brackets) into eight 16-bit words.
    ///
    /// Supports `::` zero-run compression and embedded IPv4 suffixes
    /// (e.g. `::ffff:127.0.0.1`). Zone identifiers (`fe80::1%en0`) are stripped.
    static func parseIPv6Literal(_ host: String) -> [UInt16]? {
        let bare = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        guard bare.contains(":") else { return nil }

        let doubleColonParts = bare.components(separatedBy: "::")
        guard doubleColonParts.count <= 2 else { return nil }

        func expand(_ segment: String) -> [UInt16]? {
            if segment.isEmpty { return [] }
            let groups = segment.split(separator: ":", omittingEmptySubsequences: false)
            var words: [UInt16] = []
            for (i, group) in groups.enumerated() {
                if group.contains(".") {
                    guard i == groups.count - 1,
                          let v4 = parseIPv4Literal(String(group)) else { return nil }
                    words.append((UInt16(v4[0]) << 8) | UInt16(v4[1]))
                    words.append((UInt16(v4[2]) << 8) | UInt16(v4[3]))
                } else {
                    guard !group.isEmpty, group.count <= 4,
                          let value = UInt16(group, radix: 16) else { return nil }
                    words.append(value)
                }
            }
            return words
        }

        let head = expand(doubleColonParts[0])
        let tail = doubleColonParts.count == 2 ? expand(doubleColonParts[1]) : []
        guard let headWords = head, let tailWords = tail else { return nil }

        let total = headWords.count + tailWords.count
        if doubleColonParts.count == 2 {
            guard total <= 8 else { return nil }
            return headWords + Array(repeating: UInt16(0), count: 8 - total) + tailWords
        } else {
            guard total == 8 else { return nil }
            return headWords
        }
    }

    /// Classifies an IPv6 address (as eight 16-bit words) into a blocked range, or
    /// returns `nil` if the address is in a routable public range.
    static func classifyIPv6(_ words: [UInt16]) -> BlockedAddressCategory? {
        guard words.count == 8 else { return nil }

        // ::1 — IPv6 loopback. Analogous to 127.0.0.0/8.
        // For URL validation, callers apply isLocalhostURL first.
        // For DNS-resolved addresses, ::1 from a remote domain is always an attack.
        if words == [0, 0, 0, 0, 0, 0, 0, 1] { return .multicastReserved }

        if (words[0] & 0xfe00) == 0xfc00 { return .ipv6UniqueLocal }  // fc00::/7 — unique local
        if (words[0] & 0xffc0) == 0xfe80 { return .linkLocalHost }    // fe80::/10 — link-local

        // ::ffff:0:0/96 — IPv4-mapped. Reject wholesale so that mapped loopback
        // (::ffff:127.0.0.1) and mapped RFC1918 addresses bypass the IPv4 filter.
        let isIPv4Mapped = words[0] == 0 && words[1] == 0 && words[2] == 0
            && words[3] == 0 && words[4] == 0 && words[5] == 0xffff
        if isIPv4Mapped { return .ipv4MappedLoopback }

        return nil
    }
}
