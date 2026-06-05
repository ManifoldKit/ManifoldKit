import Darwin
import Foundation
import ManifoldNetworking
import os

/// `URLSessionTaskDelegate` that intercepts HTTP 30x redirects and applies
/// SSRF / credential-leakage policy before letting the redirect proceed.
///
/// ## What this guard does
///
/// On every `urlSession(_:task:willPerformHTTPRedirection:newRequest:completionHandler:)`
/// callback the delegate:
///
/// 1. Rejects the redirect if the new request's URL host classifies as a
///    blocked IP range (RFC1918, link-local, IPv4-mapped, multicast/reserved,
///    IPv6 unique-local) per ``PrivateIPClassifier``. Cloud IMDS endpoints
///    (`169.254.169.254`) are caught here.
/// 2. Rejects mDNS `.local` hostnames — these are LAN-discovery names that
///    shouldn't appear as redirect targets for outbound API calls.
/// 3. Performs a synchronous `getaddrinfo` resolve for DNS hostnames and
///    rejects the redirect if any returned address falls in a blocked range.
/// 4. Rejects scheme downgrades (`https → http`) — never let an attacker
///    walk a TLS-protected request to plaintext.
/// 5. Strips `Authorization`, `Cookie`, `Proxy-Authorization`, and any
///    `X-API-*` header from the new request when the redirect crosses
///    origin (host or port differs from the task's original request).
///    Same-origin redirects pass through with headers intact.
/// 6. Caps the total number of redirects per task at the configured
///    ``hopCap``. When the cap is exceeded, the redirect is cancelled.
///
/// ## Why synchronous DNS resolution
///
/// `URLSession`'s redirect callback signature is synchronous — there is no
/// async hop available before we must call `completionHandler(_:)`. The
/// resolve runs on URLSession's delegate queue (a background thread, not
/// the main thread) so a brief blocking `getaddrinfo` is acceptable.
/// Resolution typically completes in single-digit milliseconds against the
/// system resolver cache.
///
/// ## Hop-cap policy
///
/// - `0` — no redirects allowed. Use for SSE streams: a redirect mid-stream
///   is always a sign of misconfiguration or a hostile network.
/// - `1` — at most one redirect. Use for OAuth token-exchange endpoints.
/// - `3` — small chain. Use for model-list / download flows where CDN
///   redirects are common.
public final class RedirectGuardDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {

    // MARK: - Stored Properties

    /// Maximum number of redirects to follow per task. `0` rejects every
    /// redirect.
    public let hopCap: Int

    /// Lock guarding ``hopCounts``. The redirect callback is invoked on the
    /// session's delegate queue, which can be any background thread, so
    /// every read/write of the per-task hop counter must be serialised.
    /// We do **not** hold the lock while invoking `completionHandler` —
    /// the completion handler may queue further delegate work and
    /// re-entering the lock would deadlock.
    private let lock = NSLock()

    /// Per-task hop counters keyed by `URLSessionTask.taskIdentifier`.
    private var hopCounts: [Int: Int] = [:]

    // MARK: - Testing seam

    /// Overrides the synchronous hostname resolver used by ``blockedHostReason(for:)``.
    ///
    /// `nil` (the default) uses the real `getaddrinfo` resolver. Set this in
    /// tests to inject deterministic address lists. Return `nil` to simulate
    /// resolution failure (the redirect will be blocked).
    ///
    /// - Warning: For testing only. Reset to `nil` in `tearDown`.
    nonisolated(unsafe) static var _synchronousResolverForTesting: ((String) -> [String]?)? = nil

    // MARK: - Init

    /// Creates a redirect guard with the given hop cap.
    ///
    /// - Parameter hopCap: Maximum redirects to allow per task. Must be `>= 0`.
    public init(hopCap: Int) {
        precondition(hopCap >= 0, "RedirectGuardDelegate: hopCap must be non-negative")
        self.hopCap = hopCap
    }

    // MARK: - URLSessionTaskDelegate

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let taskID = task.taskIdentifier
        let originalURL = task.originalRequest?.url

        // 1. Hop-count check.
        lock.lock()
        let currentHops = hopCounts[taskID, default: 0] + 1
        hopCounts[taskID] = currentHops
        lock.unlock()

        guard currentHops <= hopCap else {
            Log.network.warning(
                "RedirectGuardDelegate: hop cap \(self.hopCap, privacy: .public) exceeded for task \(taskID, privacy: .public); cancelling redirect"
            )
            completionHandler(nil)
            return
        }

        guard let nextURL = request.url else {
            // No URL on the next request — let URLSession surface its own error.
            completionHandler(nil)
            return
        }

        // 2. Scheme downgrade check.
        if let originalScheme = originalURL?.scheme?.lowercased(),
           originalScheme == "https",
           let nextScheme = nextURL.scheme?.lowercased(),
           nextScheme != "https" {
            Log.network.error(
                "RedirectGuardDelegate: rejecting scheme downgrade https → \(nextScheme, privacy: .public) for task \(taskID, privacy: .public)"
            )
            completionHandler(nil)
            return
        }

        // 3. Synchronous SSRF / DNS-rebinding check on the new URL.
        if let blockReason = Self.blockedHostReason(for: nextURL) {
            Log.network.error(
                "RedirectGuardDelegate: rejecting redirect to \(nextURL.host ?? "?", privacy: .public) — \(blockReason, privacy: .public)"
            )
            completionHandler(nil)
            return
        }

        // 4. Cross-origin credential strip.
        let request = Self.stripSensitiveHeadersIfCrossOrigin(
            originalURL: originalURL,
            request: request
        )

        completionHandler(request)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        // Free the per-task hop counter. We don't forward `didCompleteWithError`
        // to anyone — `CompositeURLSessionDelegate` handles fan-out for the
        // composite case.
        lock.lock()
        hopCounts.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
    }

    // MARK: - Header policy

    /// Strips `Authorization`, `Cookie`, `Proxy-Authorization`, and any
    /// header whose name matches `^X-API-` (case-insensitive) when the
    /// redirect target's origin differs from the original request's
    /// origin. Returns the request unchanged for same-origin redirects.
    static func stripSensitiveHeadersIfCrossOrigin(
        originalURL: URL?,
        request: URLRequest
    ) -> URLRequest {
        guard let originalURL else { return request }
        guard let nextURL = request.url else { return request }
        if isSameOrigin(originalURL, nextURL) {
            return request
        }
        var stripped = request
        let headers = stripped.allHTTPHeaderFields ?? [:]
        for name in headers.keys {
            let lower = name.lowercased()
            if lower == "authorization"
                || lower == "cookie"
                || lower == "proxy-authorization"
                || lower.hasPrefix("x-api-") {
                stripped.setValue(nil, forHTTPHeaderField: name)
            }
        }
        return stripped
    }

    /// Two URLs are same-origin iff they share scheme (case-insensitive),
    /// host (case-insensitive), and effective port (using the scheme's
    /// default port when none is explicit).
    static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lScheme = lhs.scheme?.lowercased(),
              let rScheme = rhs.scheme?.lowercased(),
              lScheme == rScheme else { return false }
        guard let lHost = lhs.host?.lowercased(),
              let rHost = rhs.host?.lowercased(),
              lHost == rHost else { return false }
        return effectivePort(of: lhs) == effectivePort(of: rhs)
    }

    private static func effectivePort(of url: URL) -> Int? {
        if let explicit = url.port { return explicit }
        switch url.scheme?.lowercased() {
        case "https": return 443
        case "http": return 80
        default: return nil
        }
    }

    // MARK: - SSRF / rebinding policy

    /// Returns a human-readable reason if `url` should be rejected as a
    /// redirect target, or `nil` if it passes. Localhost is always
    /// allowed — the delegate trusts the original request's caller to have
    /// configured a local server intentionally.
    static func blockedHostReason(for url: URL) -> String? {
        if PrivateIPClassifier.isLocalhostURL(url) {
            return nil
        }
        guard let rawHost = url.host?.lowercased(), !rawHost.isEmpty else {
            return "missing host"
        }
        let host = rawHost.hasSuffix(".") ? String(rawHost.dropLast()) : rawHost

        // mDNS .local — never a valid redirect target for outbound API calls.
        if host == "local" || host.hasSuffix(".local") {
            return "mDNS .local hostname"
        }

        // Direct IP-literal rejection.
        if let category = PrivateIPClassifier.classifyIPLiteral(host) {
            return "blocked IP range (\(category))"
        }

        // DNS hostname — resolve synchronously and reject on any blocked address.
        // Nil return means resolution failed; block the redirect rather than
        // falling through (same TTL-0 bypass risk as in DNSRebindingGuard).
        guard let addresses = resolveSynchronously(host) else {
            return "could not resolve hostname '\(host)'"
        }
        for address in addresses {
            if let category = PrivateIPClassifier.classifyIPLiteral(address) {
                return "host \(host) resolved to \(address) (\(category))"
            }
        }
        return nil
    }

    /// Synchronous `getaddrinfo` wrapper. Returns `nil` on resolution failure;
    /// callers treat `nil` as a block rather than failing open.
    static func resolveSynchronously(_ hostname: String) -> [String]? {
        if let override = _synchronousResolverForTesting {
            return override(hostname)
        }
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG

        var result: UnsafeMutablePointer<addrinfo>?
        defer { freeaddrinfo(result) }

        guard getaddrinfo(hostname, nil, &hints, &result) == 0,
              result != nil else {
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
                nil, 0,
                NI_NUMERICHOST
            ) == 0 {
                let nullIdx = host.firstIndex(of: 0) ?? host.endIndex
                addresses.append(String(decoding: host[..<nullIdx].map { UInt8(bitPattern: $0) }, as: UTF8.self))
            }
            current = info.pointee.ai_next
        }
        return addresses
    }
}
