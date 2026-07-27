import Foundation
import ManifoldNetworking

/// Centralised constructors for `URLSession` instances that always install
/// ``RedirectGuardDelegate``.
///
/// Direct `URLSession(configuration:)` construction in production is forbidden
/// (enforced by `DirectURLSessionConstructionAuditTest` in
/// `ManifoldBackendsTests`). Every cloud-style request, model-list fetch,
/// LAN probe, and background download must funnel through one of:
///
/// - ``URLSessionFactory/ephemeral(hopCap:additionalDataDelegate:)``
///   — short-lived sessions for one-shot fetches (model lists, manifest
///   downloads). Uses `URLSessionConfiguration.ephemeral` so no cookies,
///   credentials, or caches persist between calls.
/// - ``URLSessionFactory/background(identifier:hopCap:additionalDownloadDelegate:)``
///   — long-running OS-managed downloads that survive app suspension.
///   Builds a `URLSessionConfiguration.background(withIdentifier:)` and
///   wires the redirect guard alongside the caller's
///   `URLSessionDownloadDelegate`.
///
/// Tighter factories (``URLSessionProvider/pinned`` for SaaS
/// API hosts, ``URLSessionProvider/unpinned`` for LAN servers) live in
/// `ManifoldCloudCore`. They wrap this factory and add certificate-pinning
/// + the runtime kill-switch.
public enum URLSessionFactory {

    /// Default request timeout (seconds) for ephemeral sessions used by
    /// short-lived fetches. Matches the timeouts on the trait-gated
    /// `URLSessionProvider` accessors so cross-target calls behave
    /// consistently.
    public static let defaultRequestTimeout: TimeInterval = 300

    /// Default resource timeout (seconds).
    public static let defaultResourceTimeout: TimeInterval = 600

    /// Builds an ephemeral `URLSession` with a `RedirectGuardDelegate` installed.
    ///
    /// - Parameters:
    ///   - hopCap: Maximum redirects allowed per task. Defaults to `3`,
    ///     appropriate for CDN-hosted model-manifest / file fetches.
    ///   - additionalDataDelegate: Optional caller-supplied data-task
    ///     delegate. Forwarded by the composite for `didReceive data:`,
    ///     `didCompleteWithError`, etc.
    /// - Returns: A new `URLSession`. Callers should retain the result for
    ///   the duration of the calls they make through it; sessions hold
    ///   their delegate strongly until invalidated.
    ///
    /// Every request emits begin/end to `NetworkActivityCenter.shared` (a
    /// `package`-visible activity funnel as of the 2026-07 inert-surface
    /// sweep, #2128) via an internally-wired `NetworkActivityTrackingDelegate`,
    /// stashed in ``CompositeURLSessionDelegate/ownedDataDelegate`` so it
    /// survives past `additionalDataDelegate`'s weak reference.
    ///   - securityPolicy: This session's own security policy, or `nil` to
    ///     resolve the transitional process-global ``ManifoldConfiguration``
    ///     at use time. A non-`nil` value is also entered into
    ///     ``NetworkPolicyRegistry`` for the session's lifetime (#2293) —
    ///     invalidate the session on teardown so the entry is released.
    public static func ephemeral(
        hopCap: Int = 3,
        resourceTimeout: TimeInterval = defaultResourceTimeout,
        additionalDataDelegate: URLSessionDataDelegate? = nil,
        securityPolicy: ManifoldSecurityPolicy? = nil
    ) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = defaultRequestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        NetworkPolicyURLProtocol.register(in: config)
        let tracker = NetworkActivityTrackingDelegate(
            center: NetworkActivityCenter.shared,
            downstream: additionalDataDelegate
        )
        let composite = CompositeURLSessionDelegate(
            redirectGuard: RedirectGuardDelegate(hopCap: hopCap),
            serverTrustHandler: nil,
            downloadDelegate: nil,
            dataDelegate: nil,
            ownedDataDelegate: tracker,
            securityPolicy: securityPolicy
        )
        return URLSession(configuration: config, delegate: composite, delegateQueue: nil)
    }

    /// Builds a background `URLSession` with a `RedirectGuardDelegate`
    /// installed alongside the caller's download delegate.
    ///
    /// - Parameters:
    ///   - identifier: Unique session identifier. Reusing an identifier
    ///     while a previous session is still being torn down causes the OS
    ///     to deliver callbacks to a deallocated delegate (double-free).
    ///   - hopCap: Maximum redirects allowed per task. Defaults to `3`.
    ///   - additionalDownloadDelegate: The caller's
    ///     `URLSessionDownloadDelegate` (typically a
    ///     `BackgroundDownloadManager`). Forwarded by the composite for
    ///     `didFinishDownloadingTo`, `didWriteData`, `didCompleteWithError`,
    ///     etc.
    ///   - securityPolicy: This session's own security policy, or `nil` to
    ///     resolve the transitional process-global ``ManifoldConfiguration``
    ///     at use time (#2293).
    public static func background(
        identifier: String,
        hopCap: Int = 3,
        additionalDownloadDelegate: URLSessionDownloadDelegate? = nil,
        securityPolicy: ManifoldSecurityPolicy? = nil
    ) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.allowsCellularAccess = true
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        NetworkPolicyURLProtocol.register(in: config)
        let composite = CompositeURLSessionDelegate(
            redirectGuard: RedirectGuardDelegate(hopCap: hopCap),
            serverTrustHandler: nil,
            downloadDelegate: additionalDownloadDelegate,
            dataDelegate: nil,
            securityPolicy: securityPolicy
        )
        return URLSession(configuration: config, delegate: composite, delegateQueue: nil)
    }
}
