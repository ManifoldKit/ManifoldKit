import Foundation
import ManifoldInference

/// Per-task `URLSessionTaskDelegate` that closes the connect-time half of the
/// DNS-rebinding TOCTOU on the cloud transport path.
///
/// ## The residual window `DNSRebindingGuard` cannot close
///
/// ``DNSRebindingGuard/validate(url:)`` resolves the endpoint hostname with its
/// own `getaddrinfo` query *before* the request and fails closed on a private
/// address. But `URLSession.bytes(for:)` / `data(for:)` re-resolve the hostname
/// at connect time with a **separate** query. An attacker controlling DNS can
/// return a public IP to the guard's pre-flight query (so the check passes) and a
/// private IP — loopback, RFC1918, `169.254.169.254` (cloud IMDS), link-local,
/// IPv4-mapped, NAT64, etc. — to URLSession's actual connection, reaching internal
/// services. The pre-resolution guard never sees the address URLSession truly used.
///
/// This delegate closes that window by inspecting the address URLSession
/// *actually* connected to (`URLSessionTaskTransactionMetrics.remoteAddress`,
/// per redirect hop) once the connection's metrics are collected, classifying it
/// with ``PrivateIPClassifier``, and cancelling the task plus recording a
/// blocked-connection URL on violation. The transport reads ``blockedConnectedURL``
/// after the request returns (or after the stream errors) and surfaces
/// ``CloudBackendError/blockedAddress(_:)``.
///
/// Localhost literals (`localhost`, `127.0.0.1`, `::1`) bypass the check — these
/// are explicitly configured local servers (Ollama, LM Studio), mirroring the
/// bypass in ``DNSRebindingGuard`` and ``PrivateIPClassifier/isLocalhostURL(_:)``.
///
/// ## Defense-in-depth, not a replacement
///
/// This composes with — and does not replace — the pre-resolution
/// ``DNSRebindingGuard`` (which catches the "guard saw a private IP" half of the
/// window and fails closed before any bytes are sent) and the session-level
/// ``RedirectGuardDelegate`` (hop cap, scheme-downgrade reject, redirect-target IP
/// filter, cross-origin credential strip). All three fire on the cloud session task.
///
/// - Note: This intentionally parallels `ManifoldMCP`'s `MCPRedirectCapDelegate`
///   connect-time pinning (PR #1748). ManifoldMCP depends on `ManifoldInference`,
///   not `ManifoldCloudCore`, and the reverse edge is likewise forbidden by the
///   module dependency rules, so the small delegate logic is mirrored cloud-side
///   rather than shared as a single type. The IP-classification logic itself
///   (`PrivateIPClassifier`) *is* shared across both stacks.
public final class ConnectAddressPinningDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    /// Lock guarding `_blockedConnectedURL`. URLSession delivers
    /// `didFinishCollecting` on an arbitrary background queue, so the violation
    /// flag must be written under a lock and read back on the caller's actor.
    private let lock = NSLock()
    private var _blockedConnectedURL: URL?

    /// The URL whose connection resolved to a blocked (private/reserved) address,
    /// or `nil` if every connected address was acceptable. Read by the transport
    /// after the request completes to decide whether to throw
    /// ``CloudBackendError/blockedAddress(_:)``.
    var blockedConnectedURL: URL? {
        lock.withLock { _blockedConnectedURL }
    }

    public func urlSession(
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
                "Cloud transport: blocked connection — \(requestURL.host ?? "?", privacy: .public) connected to \(remote, privacy: .public) (\(category.description, privacy: .public)). DNS rebinding TOCTOU."
            )
            lock.withLock {
                if _blockedConnectedURL == nil { _blockedConnectedURL = requestURL }
            }
            // Cancel so no further bytes flow over the offending connection — a
            // long-lived SSE stream that rebinds mid-handshake is torn down here.
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

    /// Performs `session.data(for:)` with DNS rebinding pre-flight, credentialed
    /// host pin gate, and connect-time IP pinning attached, then throws
    /// ``CloudBackendError/blockedAddress(_:)`` if URLSession connected to a
    /// private/reserved address (DNS rebinding) before returning the response body.
    ///
    /// `data(for:)` returns only after the task completes, by which point the
    /// connection's metrics report the address URLSession actually connected to —
    /// so a single post-call check covers the whole request. Non-streaming cloud
    /// callers (Ollama model-list / probe, web search) use this instead of calling
    /// `data(for:)` directly so they get the same connect-time guarantee the SSE
    /// path has, without each call site re-implementing the check.
    ///
    /// On a blocked connect address the response body is zero-filled before the
    /// throw so private-network payloads (e.g. cloud IMDS) do not linger in the
    /// returned `Data` buffer even for the brief window before ARC reclaim.
    ///
    /// The ``ManifoldSecurityPolicy`` handed to ``CredentialedHostTrustGate`` is
    /// **read off `session`**, not taken as a parameter (#2293). Every
    /// policy-scoped session `URLSessionProvider` builds carries its policy on its
    /// ``CompositeURLSessionDelegate``, so a caller handed a scoped session gets
    /// scoped enforcement with no call-site change — and this function grows no
    /// public parameter that no first-party writer sets. Callers using the shared
    /// unscoped session resolve the transitional global, exactly as before.
    public static func pinnedData(
        for request: URLRequest,
        on session: URLSession
    ) async throws -> (Data, URLResponse) {
        if let url = request.url {
            try await DNSRebindingGuard.validate(url: url)
            let hasCredentials = request.value(forHTTPHeaderField: "Authorization") != nil
                || request.value(forHTTPHeaderField: "x-api-key") != nil
                || request.value(forHTTPHeaderField: "api-key") != nil
            try CredentialedHostTrustGate.check(
                url: url,
                hasCredentials: hasCredentials,
                securityPolicy: securityPolicy(carriedBy: session)
            )
        }

        let connectionGuard = ConnectAddressPinningDelegate()
        var (data, response) = try await session.data(for: request, delegate: connectionGuard)
        if let blocked = connectionGuard.blockedConnectedURL {
            // Best-effort scrub: overwrite COW buffer contents so a blocked
            // private-network body is not returned or retained as cleartext.
            data.resetBytes(in: 0..<data.count)
            throw CloudBackendError.blockedAddress(
                "Connection to \(blocked.host ?? "endpoint") resolved to a private/reserved address (DNS rebinding) — blocked"
            )
        }
        return (data, response)
    }

    /// The ``ManifoldSecurityPolicy`` a session was built with, or `nil` for a
    /// session that tracks the transitional process-global configuration.
    ///
    /// Reads it off the session's ``CompositeURLSessionDelegate`` — the object
    /// `URLSessionProvider` already stamps the policy onto when it builds a
    /// policy-scoped session. This is what lets `pinnedData(for:on:)` enforce the
    /// right graph's `allowUnpinnedCredentialedHosts` without every call site
    /// (`CloudReranker`, `DefaultWebSearchRuntime`, `OllamaModelListService`,
    /// `OllamaModelProbe`) having to thread a policy it has no way to obtain.
    static func securityPolicy(carriedBy session: URLSession) -> ManifoldSecurityPolicy? {
        (session.delegate as? CompositeURLSessionDelegate)?.securityPolicy
    }
}
