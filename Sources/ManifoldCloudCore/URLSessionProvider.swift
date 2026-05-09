import Foundation
import ManifoldInference

/// Centralized factory for URLSession instances used by cloud backends.
///
/// Eliminates the duplicated `static let pinnedSession` blocks that each
/// backend previously maintained with subtly different timeout configs.
/// All backends continue to accept a `urlSession:` init parameter for
/// test injection via `MockURLProtocol`.
///
/// ## Trait gating
///
/// The factories are conditionally compiled:
/// - ``pinned`` / ``pinned()`` are only available with the `CloudSaaS` trait —
///   no SaaS backend means no pinning is needed.
/// - ``unpinned`` / ``unpinned()`` are available whenever `Ollama` or
///   `CloudSaaS` is enabled — used by Ollama (LAN) and as the LM-Studio /
///   `.custom` provider session under `CloudSaaS`.
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
    /// Defaults to `false`. Set at app startup if needed; flipping it after
    /// sessions are already cached only affects callers that obtain a fresh
    /// session via the throwing factories below.
    ///
    /// `nonisolated(unsafe)` matches the project pattern for boot-time
    /// configuration flags (see `DNSRebindingGuard._resolverForTesting`):
    /// callers are expected to write this once at app startup before any
    /// concurrent reader can observe it.
    public nonisolated(unsafe) static var networkDisabled: Bool = false

    /// Default redirect hop cap for sessions built by this provider. Used
    /// by ``pinned``, ``unpinned``, and ``background(identifier:hopCap:additionalDownloadDelegate:)``
    /// when the caller does not supply an explicit cap. Three hops covers
    /// CDN redirects without leaving room for an extended SSRF chain.
    public static let defaultHopCap: Int = 3

    #if CloudSaaS
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
    #endif

    #if Ollama || CloudSaaS
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
    #endif

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
