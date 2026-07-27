import Foundation
import ManifoldInference
import os

/// Centralized factory for URLSession instances used by cloud backends.
///
/// Eliminates the duplicated `static let pinnedSession` blocks that each
/// backend previously maintained with subtly different timeout configs.
/// All backends continue to accept a `urlSession:` init parameter for
/// test injection via `MockURLProtocol`.
///
/// ## Availability
///
/// All factories compile unconditionally since v0.48 (the Ollama/CloudSaaS
/// traits are retired):
/// - ``pinned`` / ``pinned()`` — used by the SaaS backends (Claude, OpenAI).
/// - ``unpinned`` / ``unpinned()`` — used by Ollama (LAN) and as the
///   LM-Studio / `.custom` provider session.
/// - ``background(identifier:hopCap:additionalDownloadDelegate:)`` is
///   always available; it is the seam used by `BackgroundDownloadManager`
///   (under the `HuggingFace` trait) and any other long-running
///   OS-managed download path.
///
/// The ``networkDisabled`` runtime kill-switch is always available so
/// embedders can lock the network even in a `full`-trait build.
///
/// ## Two accessor flavours
///
/// Each session has two accessors:
/// - A non-throwing static property (``pinned``, ``unpinned``) that traps if
///   the kill-switch is set at first access. This is the legacy ergonomic API
///   used by every cloud backend's `init(urlSession:)` and by the bulk of the
///   test suite.
/// - A throwing function (``throwingPinned()``, ``throwingUnpinned()``) that
///   surfaces the kill-switch as a recoverable
///   ``CloudBackendError/networkDisabled`` error. Use this from embedders
///   that flip the kill-switch dynamically and from tests that exercise the
///   failure path.
///
/// ## Redirect policy
///
/// Every session built here has a ``RedirectGuardDelegate`` installed, which:
/// - Caps redirect chains at the configured hop count (default 3).
/// - Rejects scheme downgrades (`https → http`).
/// - Strips `Authorization`, `Cookie`, `Proxy-Authorization`, and any
///   `X-API-*` header on cross-origin redirects.
/// - Rejects redirect targets that classify as private/link-local IP ranges
///   per ``PrivateIPClassifier`` (cloud IMDS, RFC1918, IPv4-mapped, etc.)
///   or as mDNS `.local` names.
public enum URLSessionProvider {

    /// Belt-and-suspenders runtime kill-switch. When `true`, the throwing
    /// factories (``throwingPinned()``, ``throwingUnpinned()``) throw
    /// ``CloudBackendError/networkDisabled`` rather than returning a session;
    /// the non-throwing accessors trap with a precondition for the same
    /// reason. Useful for a regulated runtime that wants to lock network
    /// even in a `full`-trait build.
    ///
    /// Defaults to `false`. Callers may flip it at any point during the
    /// process lifetime, not only at boot — flipping it after sessions are
    /// already cached only affects callers that obtain a fresh session via
    /// the throwing factories below. Because a flip can happen at any time,
    /// not provably-before any reader, this is a genuine runtime toggle, not
    /// a write-once boot flag; a concurrent reader on another thread can race
    /// a writer. Lock-guarded storage below makes every read/write atomic
    /// without an actor hop; the public name and call sites are unchanged.
    /// Mirrors `CloudImageEncoding._encodeHook` (`OSAllocatedUnfairLock`,
    /// available below the macOS 15 / iOS 18 floor).
    private static let _networkDisabledLock = OSAllocatedUnfairLock<Bool>(initialState: false)

    public static var networkDisabled: Bool {
        get { _networkDisabledLock.withLock { $0 } }
        set { _networkDisabledLock.withLock { $0 = newValue } }
    }

    /// Default redirect hop cap for sessions built by this provider. Used
    /// by ``pinned``, ``unpinned``, and ``background(identifier:hopCap:additionalDownloadDelegate:)``
    /// when the caller does not supply an explicit cap. Three hops covers
    /// CDN redirects without leaving room for an extended SSRF chain.
    public static let defaultHopCap: Int = 3

    /// Cached session shared by all SaaS backends — created once on first call.
    ///
    /// Wires both the certificate-pinning delegate and the redirect guard
    /// onto a single `CompositeURLSessionDelegate` so both policies fire on
    /// every request without one delegate displacing the other.
    private static let _pinned: URLSession = {
        PinnedSessionDelegate.loadDefaultPins()
        let composite = CompositeURLSessionDelegate(
            redirectGuard: RedirectGuardDelegate(hopCap: defaultHopCap),
            serverTrustHandler: PinnedSessionDelegate(),
            downloadDelegate: nil,
            dataDelegate: nil
        )
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: config, delegate: composite, delegateQueue: nil)
    }()

    /// Session with ``PinnedSessionDelegate`` for production API hosts.
    ///
    /// Shared by OpenAI and Claude backends. Certificate pinning
    /// is enforced for `api.openai.com` and `api.anthropic.com`; custom hosts
    /// fall through to default trust evaluation.
    ///
    /// - Note: Traps with a precondition if ``networkDisabled`` is `true`.
    ///   Use ``throwingPinned()`` for a throwing variant.
    public static var pinned: URLSession {
        precondition(!networkDisabled, "URLSessionProvider.networkDisabled is set; use throwing variant URLSessionProvider.throwingPinned() instead.")
        return _pinned
    }

    /// Throwing accessor for the pinned session — surfaces the runtime
    /// kill-switch as a recoverable error.
    ///
    /// - Throws: ``CloudBackendError/networkDisabled`` when ``networkDisabled``
    ///   is `true`.
    public static func throwingPinned() throws -> URLSession {
        if networkDisabled {
            throw CloudBackendError.networkDisabled
        }
        return _pinned
    }

    /// Cached session shared by LAN / unpinned callers.
    ///
    /// No pinning, but the redirect guard still fires. LAN endpoints can
    /// safely chase same-origin redirects; cross-origin redirects to public
    /// IPs or away from `localhost` would have credentials stripped.
    private static let _unpinned: URLSession = {
        let composite = CompositeURLSessionDelegate(
            redirectGuard: RedirectGuardDelegate(hopCap: defaultHopCap),
            serverTrustHandler: nil,
            downloadDelegate: nil,
            dataDelegate: nil
        )
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: config, delegate: composite, delegateQueue: nil)
    }()

    /// Session without certificate pinning for LAN servers (Ollama, local endpoints).
    ///
    /// Appropriate for servers discovered via Bonjour or configured with
    /// private/local IP addresses where TLS pinning is not applicable.
    ///
    /// - Note: Traps with a precondition if ``networkDisabled`` is `true`.
    ///   Use ``throwingUnpinned()`` for a throwing variant.
    public static var unpinned: URLSession {
        precondition(!networkDisabled, "URLSessionProvider.networkDisabled is set; use throwing variant URLSessionProvider.throwingUnpinned() instead.")
        return _unpinned
    }

    /// Throwing accessor for the unpinned session — surfaces the runtime
    /// kill-switch as a recoverable error.
    ///
    /// - Throws: ``CloudBackendError/networkDisabled`` when ``networkDisabled``
    ///   is `true`.
    public static func throwingUnpinned() throws -> URLSession {
        if networkDisabled {
            throw CloudBackendError.networkDisabled
        }
        return _unpinned
    }

    // MARK: - Policy-scoped sessions (#2293)

    /// Sessions built for an explicit ``ManifoldSecurityPolicy``, keyed by the
    /// policy value.
    ///
    /// Keyed rather than one-per-caller because `URLSession` owns a connection
    /// pool: minting a fresh session per backend instance would fragment
    /// keep-alive connections and multiply delegate objects. Two graphs holding
    /// *different* policies get different sessions (which is the point); two
    /// graphs holding equal policies share one, exactly as they share ``pinned``
    /// today.
    ///
    /// Deliberately unbounded-but-tiny: the key space is the set of distinct
    /// policies a process configures, which is one or two in practice. Entries
    /// live for the process lifetime, matching ``pinned`` / ``unpinned``.
    private struct PolicyScopedKey: Equatable {
        let policy: ManifoldSecurityPolicy
        let pinning: Bool
    }

    private static let _policyScoped = OSAllocatedUnfairLock<[(PolicyScopedKey, URLSession)]>(
        initialState: []
    )

    /// A pinned session that enforces `securityPolicy` instead of the
    /// transitional process-global ``ManifoldConfiguration``.
    ///
    /// Passing `nil` returns the shared ``pinned`` session, whose delegates read
    /// the global live — the pre-#2293 behaviour.
    ///
    /// - Note: Traps with a precondition if ``networkDisabled`` is `true`, for
    ///   symmetry with ``pinned``.
    public static func pinned(securityPolicy: ManifoldSecurityPolicy?) -> URLSession {
        precondition(!networkDisabled, "URLSessionProvider.networkDisabled is set; use throwing variant URLSessionProvider.throwingPinned() instead.")
        guard let securityPolicy else { return _pinned }
        return policyScopedSession(securityPolicy, pinning: true)
    }

    /// An unpinned (LAN) session that enforces `securityPolicy` instead of the
    /// transitional process-global ``ManifoldConfiguration``.
    ///
    /// Passing `nil` returns the shared ``unpinned`` session.
    ///
    /// - Note: Traps with a precondition if ``networkDisabled`` is `true`, for
    ///   symmetry with ``unpinned``.
    public static func unpinned(securityPolicy: ManifoldSecurityPolicy?) -> URLSession {
        precondition(!networkDisabled, "URLSessionProvider.networkDisabled is set; use throwing variant URLSessionProvider.throwingUnpinned() instead.")
        guard let securityPolicy else { return _unpinned }
        return policyScopedSession(securityPolicy, pinning: false)
    }

    private static func policyScopedSession(
        _ policy: ManifoldSecurityPolicy,
        pinning: Bool
    ) -> URLSession {
        // The pinning flag participates in identity: a pinned and an unpinned
        // session for the same policy are different sessions.
        let key = PolicyScopedKey(policy: policy, pinning: pinning)

        if pinning {
            PinnedSessionDelegate.loadDefaultPins()
        }

        return _policyScoped.withLock { table in
            if let existing = table.first(where: { $0.0 == key }) {
                return existing.1
            }
            let composite = CompositeURLSessionDelegate(
                redirectGuard: RedirectGuardDelegate(hopCap: defaultHopCap),
                serverTrustHandler: pinning ? PinnedSessionDelegate(securityPolicy: policy) : nil,
                downloadDelegate: nil,
                dataDelegate: nil,
                securityPolicy: policy
            )
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 300
            config.timeoutIntervalForResource = 600
            config.tlsMinimumSupportedProtocolVersion = .TLSv12
            let session = URLSession(configuration: config, delegate: composite, delegateQueue: nil)
            table.append((key, session))
            return session
        }
    }

    /// Builds a background `URLSession` with the redirect guard installed.
    ///
    /// Forwards to ``URLSessionFactory/background(identifier:hopCap:additionalDownloadDelegate:)``.
    /// `BackgroundDownloadManager` calls this rather than constructing a
    /// `URLSession` directly so the redirect guard sees every download
    /// request — including the auto-reissue of partial transfers that the
    /// system download service initiates after a process restart.
    ///
    /// - Parameters:
    ///   - identifier: Unique session identifier. Tests must inject a
    ///     unique value per instance to avoid OS-level collision.
    ///   - hopCap: Maximum redirects allowed per task. Defaults to ``defaultHopCap``.
    ///   - additionalDownloadDelegate: The caller's download delegate;
    ///     forwarded for `didFinishDownloadingTo` etc.
    public static func background(
        identifier: String,
        hopCap: Int = defaultHopCap,
        additionalDownloadDelegate: URLSessionDownloadDelegate? = nil
    ) -> URLSession {
        URLSessionFactory.background(
            identifier: identifier,
            hopCap: hopCap,
            additionalDownloadDelegate: additionalDownloadDelegate
        )
    }
}

/// Memoises a policy-scoped pinned session so a registrar can defer building it
/// until a backend is actually constructed.
///
/// Lives here rather than in `CloudSaaSBackends` for two reasons: `URLSession`
/// types belong behind the networking boundary (`TrafficBoundaryAuditTest` rule 1
/// enforces that, and it caught the first attempt), and this is the file that owns
/// the policy-scoped session cache it draws from.
///
/// The deferral exists because ``URLSessionProvider/pinned(securityPolicy:)``
/// `precondition`s on the ``URLSessionProvider/networkDisabled`` kill-switch:
/// resolving at registration time would crash a host that locks the network and
/// then calls `quickStart()`, where before #2293 the trap deferred to
/// cloud-backend construction and never fired in a process with no cloud endpoint.
///
/// `@MainActor` because the backend factory closures it serves are `@MainActor`,
/// which is also what makes the unsynchronised `stored` safe.
@MainActor
package final class LazyPolicyScopedSession {
    private let securityPolicy: ManifoldSecurityPolicy?
    private var stored: URLSession?

    package init(securityPolicy: ManifoldSecurityPolicy?) {
        self.securityPolicy = securityPolicy
    }

    /// The scoped pinned session, or `nil` when the graph has no policy — in which
    /// case each backend resolves the shared ``URLSessionProvider/pinned`` itself,
    /// exactly as before #2293.
    package func resolve() -> URLSession? {
        guard let securityPolicy else { return nil }
        if let stored { return stored }
        let session = URLSessionProvider.pinned(securityPolicy: securityPolicy)
        stored = session
        return session
    }
}
