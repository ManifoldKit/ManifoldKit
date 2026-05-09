#if Ollama || CloudSaaS
import Darwin
import Foundation
import BaseChatInference

/// Request-layer mitigation for DNS rebinding attacks on remote endpoints.
///
/// `APIEndpoint.validate()` intentionally skips DNS resolution (it is called
/// synchronously from SwiftUI forms and must stay fast). This guard fills that
/// gap by resolving the hostname immediately before each outbound connection and
/// rejecting any address in a private, link-local, or reserved range.
///
/// ## Threat model
/// An attacker registers `evil.example.com` and configures it as a custom
/// endpoint. Initially the domain resolves to a public IP that passes structural
/// validation. After the user has saved the endpoint, the attacker points the DNS
/// record at `169.254.169.254` (cloud IMDS) or `192.168.x.x` (LAN). On the next
/// API call, without this guard, the request would silently reach the internal
/// host. With this guard the connection is rejected before any bytes are sent.
///
/// ## Scope
/// Applied to every outbound connection made by:
/// - ``SSECloudBackend/generate(prompt:systemPrompt:config:)`` (OpenAI, Claude,
///   Ollama, and custom backends)
/// - ``OllamaModelListService/fetchModels(from:)`` (model-list fetches)
/// - ``OllamaBackend/loadModel(from:plan:)`` (pre-flight thinking-capability probe)
///
/// Localhost URLs (`localhost`, `127.0.0.1`, `::1`) always bypass the guard —
/// these are explicitly configured local servers, not DNS-resolved targets.
public enum DNSRebindingGuard {

    // MARK: - Testing seam

    /// Overrides the hostname resolver used by ``validate(url:)``.
    ///
    /// `nil` (the default) uses the real `getaddrinfo` resolver. Set this in
    /// tests to inject deterministic address lists without touching the network.
    ///
    /// - Warning: For testing only. Write this before any concurrent access.
    nonisolated(unsafe) static var _resolverForTesting: ((String) async -> [String])? = nil

    // MARK: - Public API

    /// Validates that `url`'s hostname does not resolve to a blocked IP address.
    ///
    /// - Localhost URLs always pass (explicitly configured local servers).
    /// - IP-literal URLs are checked immediately against ``PrivateIPClassifier``
    ///   without a network round-trip (defense-in-depth; `APIEndpoint.validate()`
    ///   should have already caught these, but we verify in case validation was bypassed).
    /// - DNS hostnames are resolved; each returned address is checked.
    ///
    /// Throws ``CloudBackendError/blockedAddress(_:)`` if any resolved address falls
    /// in a private, link-local, or reserved range. The error is non-retryable.
    public static func validate(url: URL) async throws {
        // Localhost is always allowed — it is an explicitly configured local server.
        if PrivateIPClassifier.isLocalhostURL(url) { return }

        guard let host = url.host() else { return }

        // IP literals are checked immediately without DNS resolution.
        if let category = PrivateIPClassifier.classifyIPLiteral(host) {
            throw CloudBackendError.blockedAddress(
                "IP address \(host) is in a blocked range (\(category))"
            )
        }

        // DNS hostname — resolve and check every returned address.
        let addresses = await resolveHostname(host)
        for address in addresses {
            if let category = PrivateIPClassifier.classifyIPLiteral(address) {
                Log.network.error(
                    "DNSRebindingGuard: blocked connection to \(host, privacy: .public) — resolved to \(address, privacy: .public) (\(category.description, privacy: .public))"
                )
                throw CloudBackendError.blockedAddress(
                    "Hostname \(host) resolved to \(address), which is a \(category)"
                )
            }
        }
    }

    // MARK: - DNS Resolution

    /// Resolves `hostname` to a list of IP address strings using the system resolver.
    ///
    /// Runs `getaddrinfo` on a utility-priority background task to avoid blocking
    /// the cooperative thread pool during the resolver round-trip.
    /// Returns an empty array on resolution failure (network error, NXDOMAIN, etc.)
    /// so the guard fails open for unresolvable names — the subsequent URLSession
    /// connection will produce the appropriate network error itself.
    private static func resolveHostname(_ hostname: String) async -> [String] {
        if let override = _resolverForTesting {
            return await override(hostname)
        }

        return await Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            hints.ai_flags = AI_ADDRCONFIG

            var result: UnsafeMutablePointer<addrinfo>?
            defer { freeaddrinfo(result) }

            guard getaddrinfo(hostname, nil, &hints, &result) == 0,
                  result != nil else {
                return []
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
                    nil, 0,
                    NI_NUMERICHOST
                ) == 0 {
                    let nullIdx = host.firstIndex(of: 0) ?? host.endIndex
                    addresses.append(String(decoding: host[..<nullIdx].map { UInt8(bitPattern: $0) }, as: UTF8.self))
                }
                current = info.pointee.ai_next
            }
            return addresses
        }.value
    }
}

#endif
