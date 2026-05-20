import Foundation
import os

/// `URLProtocol` subclass that enforces the active
/// ``ManifoldConfiguration/networkPolicy`` before any connection is opened.
///
/// Registered at index 0 in the `protocolClasses` list of every
/// `URLSessionConfiguration` built by ``URLSessionFactory`` via
/// ``NetworkPolicyURLProtocol/register(in:)``. Because `URLProtocol` subclasses
/// are consulted before the OS opens a socket, this fires for the *initial*
/// request — complementing the redirect-level check in
/// ``CompositeURLSessionDelegate`` which covers 30x hops.
///
/// ## How interception works
///
/// `canInit(with:)` reads `ManifoldConfiguration.shared.networkPolicy` at call
/// time (not at session creation) so a policy set after session creation takes
/// effect on the next task. When the policy is `.unrestricted` or the host
/// passes the allowlist, `canInit` returns `false` so the OS transport handles
/// the request normally — zero overhead on the happy path. When the host is
/// blocked, `canInit` returns `true`, `startLoading` immediately calls
/// `urlProtocol(_:didFailWithError:)` with ``NetworkPolicyError/hostNotAllowed``,
/// and the task fails before any socket is opened.
final class NetworkPolicyURLProtocol: URLProtocol, @unchecked Sendable {

    // MARK: - Registration

    /// Inserts this protocol at position 0 of `config.protocolClasses` so it
    /// runs before any other protocol registered on the configuration.
    /// Safe to call multiple times on the same config — duplicates are skipped.
    static func register(in config: URLSessionConfiguration) {
        var existing = config.protocolClasses ?? []
        guard !existing.contains(where: { $0 == NetworkPolicyURLProtocol.self }) else { return }
        existing.insert(NetworkPolicyURLProtocol.self, at: 0)
        config.protocolClasses = existing
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool {
        // Only claim requests whose host is actively blocked by the policy.
        // Returning false here lets the OS transport handle allowed requests
        // with zero overhead.
        let policy = ManifoldConfiguration.shared.networkPolicy
        guard case .allowlist = policy else { return false }
        guard let url = request.url else { return false }
        do {
            try NetworkPolicyGuard.check(url: url, policy: policy)
            // Host is allowed — let the normal transport handle it.
            return false
        } catch {
            // Host is blocked — claim the request so startLoading can fail it.
            return true
        }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        // Re-run the check (policy may have changed between canInit and now,
        // though that is extremely unlikely). Regardless, if we reached
        // startLoading it's because canInit said the host is blocked.
        let url = request.url ?? URL(string: "about:blank")!
        let policy = ManifoldConfiguration.shared.networkPolicy
        let host = url.host ?? ""

        let policyError: NetworkPolicyError
        do {
            try NetworkPolicyGuard.check(url: url, policy: policy)
            // Policy changed in the window between canInit and startLoading
            // (extremely unlikely). Fail closed rather than silently allowing.
            policyError = NetworkPolicyError.hostNotAllowed(host: host)
        } catch let e as NetworkPolicyError {
            policyError = e
        } catch {
            policyError = NetworkPolicyError.hostNotAllowed(host: host)
        }

        Log.network.error(
            "NetworkPolicyURLProtocol: blocked request to \(host, privacy: .public) — host not in allowlist"
        )
        client?.urlProtocol(self, didFailWithError: policyError)
    }

    override func stopLoading() {
        // Nothing to cancel — we never opened a connection.
    }
}
