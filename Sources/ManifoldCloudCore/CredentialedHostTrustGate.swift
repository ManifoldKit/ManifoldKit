import Foundation
import ManifoldInference

/// Pre-flight gate that refuses to send credentialed HTTP requests to
/// non-loopback hosts without SPKI pins, unless the host app has explicitly
/// opted into residual DNS-rebinding risk.
///
/// ## Why this exists (H1)
///
/// ``DNSRebindingGuard`` and ``ConnectAddressPinningDelegate`` close most of
/// the rebinding surface, but connect-time metrics arrive only after
/// URLSession has connected — and for HTTPS, after the TLS handshake. Under
/// platform trust (no pins), a rebound private peer that completes TLS can
/// receive the `Authorization` header before the connect-time pin cancels the
/// task. SPKI pins fail closed at the handshake when the rebound peer cannot
/// present a matching chain, so credentials never leave the client.
///
/// This gate enforces "pins required for credentialed non-loopback hosts" as
/// the default (``ManifoldConfiguration/allowUnpinnedCredentialedHosts`` =
/// `false`), with an explicit opt-out for deployments that cannot pin yet.
enum CredentialedHostTrustGate {

    /// Throws ``CloudBackendError/unpinnedCredentialedHost(_:)`` when a
    /// credentialed request would target an unpinned non-loopback host and
    /// unpinned credentialed hosts are not allowed.
    static func check(url: URL?, hasCredentials: Bool) throws {
        guard hasCredentials else { return }
        guard let url else { return }
        // Full IPv4 loopback range + canonical names — aligned with
        // PinnedSessionDelegate / server bind loopback classification.
        if PrivateIPClassifier.isLocalhostURL(url) { return }
        if let host = url.host(), PrivateIPClassifier.isLoopbackHost(host) { return }

        guard let host = url.host()?.lowercased(), !host.isEmpty else { return }
        let normalized = host.hasSuffix(".") ? String(host.dropLast()) : host

        // RFC 6761 special-use names (`.test`, `.localhost`, `.invalid`) are
        // exempt so MockURLProtocol suites keep working without fake pin sets.
        // Do not use these TLDs for production custom endpoints — corp DNS can
        // resolve them; prefer real hostnames with SPKI pins.
        if isTestOrLocalSpecialUseHost(normalized) { return }

        if ManifoldConfiguration.shared.allowUnpinnedCredentialedHosts { return }

        PinnedSessionDelegate.loadDefaultPins()
        if let pins = PinnedSessionDelegate.pinnedHosts[normalized], !pins.isEmpty {
            return
        }

        Log.network.error(
            "CredentialedHostTrustGate: rejecting credentialed request to unpinned host \(normalized, privacy: .public). Add SPKI pins or set allowUnpinnedCredentialedHosts = true."
        )
        throw CloudBackendError.unpinnedCredentialedHost(normalized)
    }

    /// Whether `host` is an RFC 6761 special-use name safe to exempt from the
    /// pin requirement (unit-test hosts and loopback special-use).
    static func isTestOrLocalSpecialUseHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        if host == "test" || host.hasSuffix(".test") { return true }
        if host == "invalid" || host.hasSuffix(".invalid") { return true }
        return false
    }
}
