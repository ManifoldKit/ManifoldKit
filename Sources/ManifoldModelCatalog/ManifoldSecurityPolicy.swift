import Foundation
import ManifoldNetworking
import os

/// The three security-load-bearing knobs that used to be readable only from the
/// process-global ``ManifoldConfiguration/shared``, packaged as a value type so a
/// service graph can own its own copy.
///
/// ## Why this type exists (#2293)
///
/// `ManifoldConfiguration.shared` is data-race-free (it sits behind an
/// `OSAllocatedUnfairLock`) but it is still *last-write-wins process-global
/// state*. Two `ManifoldBootstrap` instances in one process — a multi-window Mac
/// app, a multi-account app, SwiftUI Previews sharing a process with live code —
/// contend for it, so window B relaxing TLS pinning for its own dev endpoint
/// silently downgraded window A's production traffic.
///
/// The enforcement points now take a `ManifoldSecurityPolicy` explicitly:
/// - `PinnedSessionDelegate` (``customHostTrustPolicy``)
/// - `CredentialedHostTrustGate` (``allowUnpinnedCredentialedHosts``)
/// - `CompositeURLSessionDelegate` redirect check (``networkPolicy``)
///
/// ## The transitional global
///
/// Every seam takes `ManifoldSecurityPolicy?`. `nil` means *resolve from
/// ``ManifoldConfiguration/shared`` at use time* — byte-for-byte the pre-#2293
/// behaviour, so a host that has not migrated loses no enforcement. Passing a
/// non-`nil` value opts that object out of the global entirely. Mutating a
/// security field on the global now logs old → new so the "who relaxed my
/// pinning?" question has an answer in the log.
///
/// ## Most-restrictive merging
///
/// ``NetworkPolicyURLProtocol`` is the one enforcement point that *cannot* be
/// instance-scoped: `canInit(with:)` is a `class func` Foundation drives with no
/// route back to a session, task owner, or bootstrap. For that layer the
/// registered policies are folded with ``mostRestrictive(_:_:)``, which only ever
/// tightens — so it is structurally impossible for one graph relaxing its own
/// policy to relax another's. See ``mostRestrictive(_:_:)`` for the per-field
/// semantics and the disjoint-allowlist caveat.
public struct ManifoldSecurityPolicy: Sendable, Equatable {

    /// Host allowlist applied to initial requests and redirect targets.
    public var networkPolicy: ManifoldConfiguration.NetworkPolicy

    /// How TLS challenges from custom hosts with no configured SPKI pins are
    /// treated.
    public var customHostTrustPolicy: ManifoldConfiguration.CustomHostTrustPolicy

    /// When `false` (the default), credentialed requests to unpinned
    /// non-loopback hosts are rejected before the `Authorization` header can
    /// leave the client.
    public var allowUnpinnedCredentialedHosts: Bool

    public init(
        networkPolicy: ManifoldConfiguration.NetworkPolicy = .unrestricted,
        customHostTrustPolicy: ManifoldConfiguration.CustomHostTrustPolicy = .platformDefault,
        allowUnpinnedCredentialedHosts: Bool = false
    ) {
        self.networkPolicy = networkPolicy
        self.customHostTrustPolicy = customHostTrustPolicy
        self.allowUnpinnedCredentialedHosts = allowUnpinnedCredentialedHosts
    }

    /// The framework defaults: no host allowlist, platform trust for unpinned
    /// custom hosts, credentialed requests to unpinned hosts refused.
    public static let `default` = ManifoldSecurityPolicy()

    /// A snapshot of the transitional process-global configuration.
    ///
    /// Use this only where a *snapshot* is what you want. Seams that must track
    /// later mutations of the global take `ManifoldSecurityPolicy?` and read
    /// ``ManifoldConfiguration/shared`` when it is `nil` instead.
    public static var sharedConfiguration: ManifoldSecurityPolicy {
        ManifoldConfiguration.shared.securityPolicy
    }

    // MARK: - Most-restrictive merge

    /// Folds two policies into the strictest policy that satisfies both.
    ///
    /// Per-field semantics — each is monotonically tightening, so the fold is
    /// commutative and associative and can never produce a policy weaker than
    /// either input:
    ///
    /// | Field | Rule |
    /// |-------|------|
    /// | ``allowUnpinnedCredentialedHosts`` | logical AND — one `false` refuses for both |
    /// | ``customHostTrustPolicy`` | `.requireExplicitPins` beats `.platformDefault` |
    /// | ``networkPolicy`` | `.unrestricted` is the universal set; two allowlists intersect |
    ///
    /// ### Allowlist intersection is suffix-aware
    ///
    /// An allowlist entry admits its subdomains (`"example.com"` admits
    /// `sub.example.com`), so the entries form a suffix-closed set of hosts and a
    /// naive `Set` intersection would be *wrong* — it would drop
    /// `sub.example.com` from `{"example.com"} ∩ {"sub.example.com"}` even though
    /// both sides admit that host. ``intersect(_:_:)`` therefore keeps every
    /// entry that the *other* side also admits, which is exactly the set of hosts
    /// permitted by both.
    ///
    /// ### The disjoint-allowlist caveat
    ///
    /// Two genuinely disjoint allowlists intersect to the empty set, which blocks
    /// **all** non-loopback traffic for every participant. That is deliberate and
    /// it is the lesser evil: the pre-#2293 behaviour for the same configuration
    /// was that the last writer won and every other graph *silently lost its
    /// restriction*. Turning a silent security failure into a loud, logged
    /// functional failure is the fail-closed choice. ``NetworkPolicyRegistry``
    /// logs a warning when a registrant's own allowlist is narrowed by the fold,
    /// so the condition is diagnosable rather than mysterious.
    public static func mostRestrictive(
        _ lhs: ManifoldSecurityPolicy,
        _ rhs: ManifoldSecurityPolicy
    ) -> ManifoldSecurityPolicy {
        ManifoldSecurityPolicy(
            networkPolicy: intersect(lhs.networkPolicy, rhs.networkPolicy),
            customHostTrustPolicy: (lhs.customHostTrustPolicy == .requireExplicitPins
                || rhs.customHostTrustPolicy == .requireExplicitPins)
                ? .requireExplicitPins
                : .platformDefault,
            allowUnpinnedCredentialedHosts: lhs.allowUnpinnedCredentialedHosts
                && rhs.allowUnpinnedCredentialedHosts
        )
    }

    /// Folds a sequence of policies with ``mostRestrictive(_:_:)``.
    ///
    /// An empty sequence yields ``default`` — the framework defaults, which
    /// restrict nothing beyond refusing unpinned credentialed hosts.
    public static func mostRestrictive(
        of policies: some Sequence<ManifoldSecurityPolicy>
    ) -> ManifoldSecurityPolicy {
        policies.reduce(ManifoldSecurityPolicy.default, mostRestrictive)
    }

    /// Intersects two network policies, treating `.unrestricted` as the
    /// universal set. See ``mostRestrictive(_:_:)`` for why this is
    /// suffix-aware rather than a plain `Set` intersection.
    public static func intersect(
        _ lhs: ManifoldConfiguration.NetworkPolicy,
        _ rhs: ManifoldConfiguration.NetworkPolicy
    ) -> ManifoldConfiguration.NetworkPolicy {
        switch (lhs, rhs) {
        case (.unrestricted, .unrestricted):
            return .unrestricted
        case (.unrestricted, .allowlist(let hosts)),
             (.allowlist(let hosts), .unrestricted):
            return .allowlist(hosts)
        case (.allowlist(let a), .allowlist(let b)):
            var merged: Set<String> = []
            for entry in a where admits(b, host: entry) { merged.insert(entry) }
            for entry in b where admits(a, host: entry) { merged.insert(entry) }
            return .allowlist(merged)
        }
    }

    /// Whether `hosts` (an allowlist entry set) admits `host` under the
    /// apex-plus-subdomain matching rule `NetworkPolicyGuard` applies.
    private static func admits(_ hosts: Set<String>, host: String) -> Bool {
        let candidate = normalizedEntry(host)
        for entry in hosts {
            let apex = normalizedEntry(entry)
            if candidate == apex || candidate.hasSuffix("." + apex) { return true }
        }
        return false
    }

    /// Lower-cases an entry and strips leading/trailing dots, matching
    /// `NetworkPolicyGuard.check(url:policy:)`'s normalisation.
    private static func normalizedEntry(_ entry: String) -> String {
        entry.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}

// MARK: - ManifoldConfiguration bridge

extension ManifoldConfiguration {

    /// The three security fields of this configuration, as a value a service
    /// graph can own and pass explicitly.
    ///
    /// Reading `ManifoldConfiguration.shared.securityPolicy` is still a read of
    /// process-global state; the point of the type is that the value can then be
    /// handed to an instance and stop tracking the global. Setting it writes the
    /// three fields back.
    public var securityPolicy: ManifoldSecurityPolicy {
        get {
            ManifoldSecurityPolicy(
                networkPolicy: networkPolicy,
                customHostTrustPolicy: customHostTrustPolicy,
                allowUnpinnedCredentialedHosts: allowUnpinnedCredentialedHosts
            )
        }
        set {
            networkPolicy = newValue.networkPolicy
            customHostTrustPolicy = newValue.customHostTrustPolicy
            allowUnpinnedCredentialedHosts = newValue.allowUnpinnedCredentialedHosts
        }
    }
}
