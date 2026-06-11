import Darwin
import Foundation
import ManifoldInference

// MARK: - MCPSSRFPolicy

internal enum MCPSSRFPolicy {
    private static let overrideLock = NSLock()
    nonisolated(unsafe) private static var _resolverForTesting_storage: ((String) async -> [String]?)? = nil
    static var _resolverForTesting: ((String) async -> [String]?)? {
        get { overrideLock.withLock { _resolverForTesting_storage } }
        set { overrideLock.withLock { _resolverForTesting_storage = newValue } }
    }
    nonisolated(unsafe) private static var _synchronousResolverForTesting_storage: ((String) -> [String]?)? = nil
    static var _synchronousResolverForTesting: ((String) -> [String]?)? {
        get { overrideLock.withLock { _synchronousResolverForTesting_storage } }
        set { overrideLock.withLock { _synchronousResolverForTesting_storage = newValue } }
    }

    static func validateTransportURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw MCPError.transportFailure("MCP transport endpoint must use http(s)")
        }
        if PrivateIPClassifier.isLocalhostURL(url) {
            return
        }
        guard scheme == "https" else {
            throw MCPError.transportFailure("MCP transport endpoint must use HTTPS outside localhost")
        }
        try validateHostNotBlocked(url, wrap: { .transportFailure($0) })
    }

    static func validateOAuthURL(_ url: URL, label: String) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw MCPError.authorizationFailed("Expected HTTPS \(label) URL")
        }
        try validateHostNotBlocked(url, wrap: { _ in .authorizationFailed("Expected host in \(label) URL") })
    }

    static func validateTransportRequestURL(_ url: URL) async throws {
        try validateTransportURL(url)
        try await validateResolvedHostNotBlocked(url)
    }

    static func validateOAuthRequestURL(_ url: URL, label: String) async throws {
        try validateOAuthURL(url, label: label)
        try await validateResolvedHostNotBlocked(url)
    }

    static func validateTransportRedirectURL(_ url: URL) throws {
        try validateTransportURL(url)
        try validateResolvedHostNotBlockedSynchronously(url)
    }

    static func validateOAuthRedirectURL(_ url: URL) throws {
        try validateOAuthURL(url, label: "oauth redirect")
        try validateResolvedHostNotBlockedSynchronously(url)
    }

    private static func validateHostNotBlocked(
        _ url: URL,
        wrap: (String) -> MCPError
    ) throws {
        guard let host = url.host?.lowercased(), !host.isEmpty else {
            throw wrap("missing host")
        }
        let normalizedHost = host.hasSuffix(".") ? String(host.dropLast()) : host

        // Gap A — block mDNS .local names (D6).
        if normalizedHost.hasSuffix(".local") || normalizedHost == "local" {
            throw MCPError.ssrfBlocked(url)
        }

        if PrivateIPClassifier.classifyIPLiteral(normalizedHost) != nil {
            if PrivateIPClassifier.isLocalhostURL(url) == false {
                throw MCPError.ssrfBlocked(url)
            }
        }
    }

    private static func validateResolvedHostNotBlocked(_ url: URL) async throws {
        guard PrivateIPClassifier.isLocalhostURL(url) == false else { return }
        guard let host = normalizedHost(from: url) else {
            throw MCPError.ssrfBlocked(url)
        }
        if PrivateIPClassifier.classifyIPLiteral(host) != nil {
            throw MCPError.ssrfBlocked(url)
        }
        // Nil means resolution failed. Block rather than fall through — an attacker can
        // arrange SERVFAIL for the guard's query, then serve a private IP to URLSession's
        // separate resolver query (TTL-0 / SERVFAIL pattern).
        guard let addresses = await resolveHostname(host) else {
            throw MCPError.ssrfBlocked(url)
        }
        for address in addresses where PrivateIPClassifier.classifyIPLiteral(address) != nil {
            throw MCPError.ssrfBlocked(url)
        }
    }

    private static func validateResolvedHostNotBlockedSynchronously(_ url: URL) throws {
        guard PrivateIPClassifier.isLocalhostURL(url) == false else { return }
        guard let host = normalizedHost(from: url) else {
            throw MCPError.ssrfBlocked(url)
        }
        if PrivateIPClassifier.classifyIPLiteral(host) != nil {
            throw MCPError.ssrfBlocked(url)
        }
        guard let addresses = resolveHostnameSynchronously(host) else {
            throw MCPError.ssrfBlocked(url)
        }
        for address in addresses where PrivateIPClassifier.classifyIPLiteral(address) != nil {
            throw MCPError.ssrfBlocked(url)
        }
    }

    private static func normalizedHost(from url: URL) -> String? {
        guard let host = url.host?.lowercased(), host.isEmpty == false else { return nil }
        return host.hasSuffix(".") ? String(host.dropLast()) : host
    }

    private static func resolveHostname(_ hostname: String) async -> [String]? {
        if let override = _resolverForTesting {
            return await override(hostname)
        }
        return await Task.detached(priority: .utility) {
            resolveHostnameSynchronously(hostname)
        }.value
    }

    /// Returns `nil` on resolution failure so callers can fail closed.
    private static func resolveHostnameSynchronously(_ hostname: String) -> [String]? {
        if let override = _synchronousResolverForTesting {
            return override(hostname)
        }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG

        var result: UnsafeMutablePointer<addrinfo>?
        defer { freeaddrinfo(result) }

        guard getaddrinfo(hostname, nil, &hints, &result) == 0, result != nil else {
            return nil
        }

        var addresses: [String] = []
        var current = result
        while let info = current {
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                info.pointee.ai_addr,
                info.pointee.ai_addrlen,
                &host,
                socklen_t(NI_MAXHOST),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 {
                let nullIndex = host.firstIndex(of: 0) ?? host.endIndex
                addresses.append(String(decoding: host[..<nullIndex].map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
            current = info.pointee.ai_next
        }
        return addresses
    }
}

// MARK: - IP pinning (Gap C — closed)
// The pre-resolution checks above (`validateResolvedHostNotBlocked`) close the
// "guard saw a private IP" half of the DNS-rebinding window. The other half —
// the guard's getaddrinfo query returning a public IP while URLSession's separate
// connect-time query returns a private one — is closed by connect-time IP pinning
// in `MCPRedirectCapDelegate` (OAuthSecurity.swift): it inspects the address
// URLSession actually connected to via `URLSessionTaskTransactionMetrics.remoteAddress`
// and blocks/cancels if it classifies as private/reserved per `PrivateIPClassifier`.
