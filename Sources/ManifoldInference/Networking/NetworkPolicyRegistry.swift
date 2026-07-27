import Foundation
import os

/// Process-global registry of the live ``ManifoldSecurityPolicy`` values whose
/// ``ManifoldConfiguration/NetworkPolicy`` must be honoured by
/// ``NetworkPolicyURLProtocol``.
///
/// ## Why a registry, and not instance state (#2293)
///
/// Every other security enforcement point moved to instance state: the delegates
/// are per-`URLSession` objects with initialisers, and `CredentialedHostTrustGate`
/// takes the policy as a parameter. ``NetworkPolicyURLProtocol`` cannot follow —
/// `canInit(with:)` is an `override class func` that Foundation drives with only a
/// `URLRequest` in hand. `URLSessionTask` exposes no back-reference to its
/// session, so there is no route from the static entry point to the session, the
/// delegate, or the owning bootstrap. Dynamically minting one `URLProtocol`
/// subclass per policy would give per-registration scoping but requires
/// `objc_allocateClassPair`, which is not a trade worth making for a backstop.
///
/// ## Most-restrictive resolution
///
/// Because the layer is unavoidably shared, ``effectiveNetworkPolicy`` folds every
/// registered policy **and the live transitional global** with
/// ``ManifoldSecurityPolicy/intersect(_:_:)``. The fold only ever tightens, which
/// is the property that matters: it is structurally impossible for one graph
/// relaxing its own policy to relax another's — the exact regression #2293 is
/// about. Last-write-wins is never used.
///
/// The live global is always folded in so a host that sets
/// `ManifoldConfiguration.shared.networkPolicy` and never registers anything keeps
/// the enforcement it has today, including mutations made *after* a session was
/// created (which ``NetworkPolicyURLProtocol`` has always honoured).
///
/// See ``ManifoldSecurityPolicy/mostRestrictive(_:_:)`` for the disjoint-allowlist
/// caveat: two disjoint allowlists intersect to the empty set and block all
/// non-loopback traffic for every participant. ``register(_:)`` logs a warning
/// when that happens so the condition is diagnosable.
///
/// ## Lifetime — entries track live *service graphs*, not sessions
///
/// ``register(_:)`` returns a ``NetworkPolicyRegistration`` whose `deinit`
/// deregisters. The handle is owned by ``InferenceService``, so an entry lives
/// exactly as long as the service graph whose policy it represents: a torn-down
/// bootstrap stops restricting the graphs that outlive it, with nothing required
/// of the host.
///
/// It is deliberately **not** owned by the session's
/// ``CompositeURLSessionDelegate``, which was the first shape tried and is wrong:
/// `URLSession` retains its delegate until the session is invalidated, and
/// `URLSessionProvider`'s policy-scoped sessions are cached for the process
/// lifetime, so a delegate-owned entry would have been immortal on the only
/// first-party path that creates one. The obvious remedy — telling hosts to
/// invalidate those sessions — is worse still: it would hand the next graph with
/// an equal policy a dead session out of the cache.
package final class NetworkPolicyRegistry: Sendable {

    package static let shared = NetworkPolicyRegistry()

    /// Opaque identity for one registration. Not derived from the policy value,
    /// so two graphs that happen to hold equal policies still register and
    /// deregister independently.
    package struct Token: Hashable, Sendable {
        fileprivate let raw: UUID
    }

    private let entries = OSAllocatedUnfairLock<[Token: ManifoldConfiguration.NetworkPolicy]>(
        initialState: [:]
    )

    package init() {}

    /// Registers `policy` and returns a handle that deregisters on `deinit`.
    ///
    /// Logs a warning when the fold narrows `policy`'s own allowlist — that is
    /// the disjoint-allowlist condition, and the only signal a host gets that
    /// its traffic is about to be blocked by *someone else's* allowlist.
    package func register(_ policy: ManifoldConfiguration.NetworkPolicy) -> NetworkPolicyRegistration {
        let token = Token(raw: UUID())
        let merged = entries.withLock { table -> ManifoldConfiguration.NetworkPolicy in
            table[token] = policy
            return Self.fold(table.values)
        }
        let effective = ManifoldSecurityPolicy.intersect(merged, ManifoldConfiguration.shared.networkPolicy)
        if case .allowlist(let own) = policy, case .allowlist(let resolved) = effective, resolved != own {
            Log.network.warning(
                """
                NetworkPolicyRegistry: registered allowlist of \(own.count, privacy: .public) host(s) \
                but the process-wide effective allowlist is \(resolved.count, privacy: .public) host(s). \
                Another live security policy (or ManifoldConfiguration.shared.networkPolicy) restricts \
                hosts this policy admits; NetworkPolicyURLProtocol enforces the intersection (fail-closed). \
                See docs/MIGRATION-security-policy.md.
                """
            )
        }
        return NetworkPolicyRegistration(registry: self, token: token)
    }

    /// Removes a registration. Idempotent.
    package func deregister(_ token: Token) {
        entries.withLock { $0[token] = nil }
    }

    /// The strictest policy satisfying every registered policy and the live
    /// transitional global.
    package var effectiveNetworkPolicy: ManifoldConfiguration.NetworkPolicy {
        let registered = entries.withLock { Self.fold($0.values) }
        return ManifoldSecurityPolicy.intersect(registered, ManifoldConfiguration.shared.networkPolicy)
    }

    /// Number of live registrations. Exposed for the deregistration-leak test.
    package var registrationCount: Int {
        entries.withLock { $0.count }
    }

    private static func fold(
        _ policies: some Sequence<ManifoldConfiguration.NetworkPolicy>
    ) -> ManifoldConfiguration.NetworkPolicy {
        policies.reduce(ManifoldConfiguration.NetworkPolicy.unrestricted, ManifoldSecurityPolicy.intersect)
    }
}

/// Lifetime handle for one ``NetworkPolicyRegistry`` entry.
///
/// Held by the ``CompositeURLSessionDelegate`` that owns the policy, so the entry
/// disappears when the session's delegate is released. Deregistering in `deinit`
/// rather than requiring an explicit call is what keeps a dead bootstrap's
/// allowlist from restricting the graphs that outlive it.
package final class NetworkPolicyRegistration: Sendable {

    private let registry: NetworkPolicyRegistry
    private let token: NetworkPolicyRegistry.Token

    fileprivate init(registry: NetworkPolicyRegistry, token: NetworkPolicyRegistry.Token) {
        self.registry = registry
        self.token = token
    }

    deinit {
        registry.deregister(token)
    }
}
