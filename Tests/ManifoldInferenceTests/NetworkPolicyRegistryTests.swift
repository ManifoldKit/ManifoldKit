import XCTest
import ManifoldTestSupport
@testable import ManifoldInference

/// Tests for the ``NetworkPolicyRegistry`` most-restrictive backstop and the
/// security-field mutation audit added by #2293.
///
/// `NetworkPolicyURLProtocol` is the one enforcement point that cannot be
/// instance-scoped (`canInit(with:)` is a `class func` with no route to a
/// session), so instead of last-write-wins it resolves the intersection of every
/// live registered policy and the transitional global. These tests pin both
/// halves of that contract: the fold tightens, and deregistration actually
/// releases — a leak there would let a dead bootstrap block a live one.
final class NetworkPolicyRegistryTests: XCTestCase {

    private var savedConfiguration: ManifoldConfiguration!

    override func setUp() {
        super.setUp()
        savedConfiguration = ManifoldConfiguration.shared
        // The registry is process-global by construction; assert we start from a
        // clean slate rather than silently inheriting another suite's entries.
        ManifoldConfiguration.shared = ManifoldConfiguration(networkPolicy: .unrestricted)
    }

    override func tearDown() {
        ManifoldConfiguration.shared = savedConfiguration
        super.tearDown()
    }

    // MARK: - Most-restrictive fold

    func test_effectivePolicy_unrestrictedWhenNothingRestricts() {
        let registry = NetworkPolicyRegistry()
        XCTAssertEqual(registry.effectiveNetworkPolicy, .unrestricted)
    }

    /// A restrictive registrant must win over a permissive one — never
    /// last-write-wins, in either registration order.
    func test_restrictiveRegistrant_beatsPermissive_inBothOrders() {
        for permissiveFirst in [true, false] {
            let registry = NetworkPolicyRegistry()
            var handles: [NetworkPolicyRegistration] = []
            let permissive = ManifoldConfiguration.NetworkPolicy.unrestricted
            let restrictive = ManifoldConfiguration.NetworkPolicy.allowlist(["a.manifoldtest"])

            if permissiveFirst {
                handles.append(registry.register(permissive))
                handles.append(registry.register(restrictive))
            } else {
                handles.append(registry.register(restrictive))
                handles.append(registry.register(permissive))
            }

            XCTAssertEqual(
                registry.effectiveNetworkPolicy,
                .allowlist(["a.manifoldtest"]),
                "The restrictive policy must win regardless of registration order (permissiveFirst=\(permissiveFirst))"
            )
            withExtendedLifetime(handles) {}
        }
    }

    /// Deregistration must actually release: after the restrictive registrant's
    /// handle is dropped, the permissive one must stop being over-restricted.
    /// This is the leak check — a dead bootstrap's allowlist must not outlive it.
    func test_deregistration_releasesRestriction() {
        let registry = NetworkPolicyRegistry()
        let permissiveHandle = registry.register(.unrestricted)

        do {
            let restrictiveHandle = registry.register(.allowlist(["a.manifoldtest"]))
            XCTAssertEqual(registry.registrationCount, 2)
            XCTAssertEqual(registry.effectiveNetworkPolicy, .allowlist(["a.manifoldtest"]))
            withExtendedLifetime(restrictiveHandle) {}
        }

        XCTAssertEqual(registry.registrationCount, 1,
            "Dropping a registration handle must remove its entry — otherwise a torn-down graph keeps restricting live ones")
        XCTAssertEqual(registry.effectiveNetworkPolicy, .unrestricted,
            "Once the restrictive registrant is gone the permissive one must no longer be over-restricted")
        withExtendedLifetime(permissiveHandle) {}
    }

    /// The live transitional global is always folded in, so a host that sets it
    /// and registers nothing keeps the enforcement it had before #2293 —
    /// including a mutation made after any session was created.
    func test_transitionalGlobal_isFoldedInLive() {
        let registry = NetworkPolicyRegistry()
        XCTAssertEqual(registry.effectiveNetworkPolicy, .unrestricted)

        ManifoldConfiguration.shared.networkPolicy = .allowlist(["global.manifoldtest"])
        XCTAssertEqual(registry.effectiveNetworkPolicy, .allowlist(["global.manifoldtest"]),
            "A global set after the registry exists must still be honoured")

        let handle = registry.register(.allowlist(["global.manifoldtest", "extra.manifoldtest"]))
        XCTAssertEqual(registry.effectiveNetworkPolicy, .allowlist(["global.manifoldtest"]),
            "A registrant cannot widen past the global — the fold only tightens")
        withExtendedLifetime(handle) {}
    }

    // MARK: - Allowlist intersection semantics

    func test_intersect_isSuffixAware() {
        // `example.manifoldtest` admits `sub.example.manifoldtest`, so the
        // intersection is the narrower entry, not the empty set a naive
        // Set-intersection would produce.
        XCTAssertEqual(
            ManifoldSecurityPolicy.intersect(
                .allowlist(["example.manifoldtest"]),
                .allowlist(["sub.example.manifoldtest"])
            ),
            .allowlist(["sub.example.manifoldtest"])
        )
    }

    func test_intersect_disjointAllowlists_failClosed() {
        // Documented and deliberate: disjoint allowlists block everything rather
        // than silently letting one side lose its restriction.
        XCTAssertEqual(
            ManifoldSecurityPolicy.intersect(
                .allowlist(["a.manifoldtest"]),
                .allowlist(["b.manifoldtest"])
            ),
            .allowlist([])
        )
    }

    func test_intersect_unrestrictedIsUniversalSet() {
        XCTAssertEqual(
            ManifoldSecurityPolicy.intersect(.unrestricted, .allowlist(["a.manifoldtest"])),
            .allowlist(["a.manifoldtest"])
        )
        XCTAssertEqual(
            ManifoldSecurityPolicy.intersect(.unrestricted, .unrestricted),
            .unrestricted
        )
    }

    // MARK: - mostRestrictive across all three fields

    func test_mostRestrictive_tightensEveryField() {
        let lax = ManifoldSecurityPolicy(
            networkPolicy: .unrestricted,
            customHostTrustPolicy: .platformDefault,
            allowUnpinnedCredentialedHosts: true
        )
        let strict = ManifoldSecurityPolicy(
            networkPolicy: .allowlist(["a.manifoldtest"]),
            customHostTrustPolicy: .requireExplicitPins,
            allowUnpinnedCredentialedHosts: false
        )

        for merged in [
            ManifoldSecurityPolicy.mostRestrictive(lax, strict),
            ManifoldSecurityPolicy.mostRestrictive(strict, lax)
        ] {
            XCTAssertEqual(merged.networkPolicy, .allowlist(["a.manifoldtest"]))
            XCTAssertEqual(merged.customHostTrustPolicy, .requireExplicitPins)
            XCTAssertFalse(merged.allowUnpinnedCredentialedHosts)
        }
    }

    // MARK: - URLProtocol reads the fold, not the global alone

    /// The static `canInit` path must claim a request that a *registered* policy
    /// blocks even when the transitional global is `.unrestricted`. Against the
    /// pre-#2293 code (which read only the global) this reds.
    /// Both directions are asserted. `setUp` holds the global at `.unrestricted`,
    /// and SwiftPM's parallel runner schedules one process per test *method*, so no
    /// foreign suite can move the global underneath this test. The admitted-host
    /// assertion is the one that catches a `canInit` claiming everything — e.g. an
    /// effective policy that collapsed to `.allowlist([])`.
    func test_canInit_honoursRegisteredPolicy_notOnlyTheGlobal() {
        let blocked = URLRequest(url: URL(string: "https://blocked.manifoldtest/api")!)
        let allowed = URLRequest(url: URL(string: "https://allowed.manifoldtest/api")!)
        let baselineCount = NetworkPolicyRegistry.shared.registrationCount

        XCTAssertFalse(NetworkPolicyURLProtocol.canInit(with: blocked),
            "Precondition: nothing registered and an unrestricted global must not claim")

        do {
            let handle = NetworkPolicyRegistry.shared.register(.allowlist(["allowed.manifoldtest"]))
            XCTAssertTrue(NetworkPolicyURLProtocol.canInit(with: blocked),
                "A registered allowlist must be enforced by the static URLProtocol path — pre-#2293 this read only ManifoldConfiguration.shared and would not claim")
            XCTAssertFalse(NetworkPolicyURLProtocol.canInit(with: allowed),
                "A host the registered allowlist admits must NOT be claimed — claiming it would block traffic the policy permits")
            withExtendedLifetime(handle) {}
        }

        XCTAssertEqual(NetworkPolicyRegistry.shared.registrationCount, baselineCount,
            "The registration must be released back off the shared registry so it cannot restrict the rest of the process")
        XCTAssertFalse(NetworkPolicyURLProtocol.canInit(with: blocked),
            "Releasing the registration must restore unrestricted behaviour")
    }

    // MARK: - Registration ownership: the service graph, not the session delegate

    /// The registry entry is owned by ``InferenceService``, so dropping the graph
    /// releases it. Pinning it here documents where the ownership lives;
    /// `SecurityPolicyInstanceScopeTests` proves the same through the registrar,
    /// cached session and a real backend.
    @MainActor
    func test_inferenceServiceOwnsRegistration_andReleasesItOnDeinit() {
        let baseline = NetworkPolicyRegistry.shared.registrationCount

        do {
            let service = InferenceService(backend: MockInferenceBackend())
            XCTAssertEqual(NetworkPolicyRegistry.shared.registrationCount, baseline,
                "A service with no policy must not register at all — it tracks the global live")

            service.securityPolicy = ManifoldSecurityPolicy(networkPolicy: .allowlist(["a.manifoldtest"]))
            XCTAssertEqual(NetworkPolicyRegistry.shared.registrationCount, baseline + 1)

            // Re-assigning must replace, not accumulate.
            service.securityPolicy = ManifoldSecurityPolicy(networkPolicy: .allowlist(["b.manifoldtest"]))
            XCTAssertEqual(NetworkPolicyRegistry.shared.registrationCount, baseline + 1,
                "Re-assigning a policy must swap the entry, not add a second one")
            XCTAssertEqual(NetworkPolicyRegistry.shared.effectiveNetworkPolicy,
                           .allowlist(["b.manifoldtest"]),
                "The stale entry must be gone — otherwise the fold intersects the old and new allowlists and blocks both")

            service.securityPolicy = nil
            XCTAssertEqual(NetworkPolicyRegistry.shared.registrationCount, baseline,
                "Clearing the policy must deregister and restore live global tracking")
        }

        XCTAssertEqual(NetworkPolicyRegistry.shared.registrationCount, baseline)
    }

    // MARK: - Security-field mutation audit (acceptance criterion 3)

    /// Every mutation of a security field on the transitional global must emit an
    /// audit line naming the field and both values.
    func test_securityFieldMutation_logsOldAndNewValues() {
        let captured = MessageBox()
        ManifoldConfiguration.securityMutationObserverForTesting = { captured.append($0) }
        defer { ManifoldConfiguration.securityMutationObserverForTesting = nil }

        ManifoldConfiguration.shared = ManifoldConfiguration(
            customHostTrustPolicy: .requireExplicitPins,
            allowUnpinnedCredentialedHosts: true,
            networkPolicy: .allowlist(["audited.manifoldtest"])
        )

        let messages = captured.messages
        XCTAssertEqual(messages.count, 1, "One assignment must produce exactly one audit line")
        let line = messages.first ?? ""
        // Old values (the framework defaults installed by setUp) …
        XCTAssertTrue(line.contains("platformDefault"), "Audit line must name the old customHostTrustPolicy: \(line)")
        XCTAssertTrue(line.contains("unrestricted"), "Audit line must name the old networkPolicy: \(line)")
        XCTAssertTrue(line.contains("false"), "Audit line must name the old allowUnpinnedCredentialedHosts: \(line)")
        // … and the new ones.
        XCTAssertTrue(line.contains("requireExplicitPins"), "Audit line must name the new customHostTrustPolicy: \(line)")
        XCTAssertTrue(line.contains("audited.manifoldtest"), "Audit line must name the new networkPolicy: \(line)")
        XCTAssertTrue(line.contains("true"), "Audit line must name the new allowUnpinnedCredentialedHosts: \(line)")
        XCTAssertTrue(line.contains("->"), "Audit line must render the transition as old -> new: \(line)")
    }

    /// A non-security field changing must not emit an audit line — the audit has
    /// to stay signal, not noise, or nobody will read it.
    func test_nonSecurityFieldMutation_doesNotLog() {
        let captured = MessageBox()
        ManifoldConfiguration.securityMutationObserverForTesting = { captured.append($0) }
        defer { ManifoldConfiguration.securityMutationObserverForTesting = nil }

        ManifoldConfiguration.shared = ManifoldConfiguration(appName: "Renamed App")

        XCTAssertTrue(captured.messages.isEmpty,
            "Changing appName must not emit a security audit line, got: \(captured.messages)")
    }
}

/// Thread-safe collector for audit lines. The observer is `@Sendable` and the
/// setter may be invoked from whichever thread assigns the configuration, so a
/// bare array capture would be a race under `swift test --parallel`.
private final class MessageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(message)
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
