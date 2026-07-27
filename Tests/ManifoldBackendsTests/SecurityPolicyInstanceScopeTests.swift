import XCTest
import Security
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldCloudCore
@testable import ManifoldCloudSaaS

/// Regression tests for #2293: the three security-load-bearing fields
/// (`networkPolicy`, `customHostTrustPolicy`, `allowUnpinnedCredentialedHosts`)
/// must be resolvable from an instance rather than the process-global
/// ``ManifoldConfiguration/shared``.
///
/// ## How these tests are written to be honest
///
/// Every test here sets `ManifoldConfiguration.shared` to a value that
/// **contradicts** the instance policy under test, and asserts the instance
/// policy wins. A test that merely set the global and observed the expected
/// behaviour would pass just as well against the pre-#2293 process-global code,
/// which is exactly the coverage this issue does *not* need.
final class SecurityPolicyInstanceScopeTests: XCTestCase {

    private var savedConfiguration: ManifoldConfiguration!
    private var savedPins: [String: Set<String>]!

    override func setUp() {
        super.setUp()
        savedConfiguration = ManifoldConfiguration.shared
        savedPins = PinnedSessionDelegate.pinnedHosts
    }

    override func tearDown() {
        PinnedSessionDelegate.pinnedHosts = savedPins
        ManifoldConfiguration.shared = savedConfiguration
        super.tearDown()
    }

    // MARK: - Helpers

    /// Server-trust challenge for `host`. `serverTrust` is `nil`, which is fine
    /// for these tests: they only exercise the *no pins configured* branch,
    /// which decides before trust evaluation is reached.
    private func makeChallenge(host: String) -> URLAuthenticationChallenge {
        let space = URLProtectionSpace(
            host: host,
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        return URLAuthenticationChallenge(
            protectionSpace: space,
            proposedCredential: nil,
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: NoopChallengeSender()
        )
    }

    private func disposition(
        _ delegate: PinnedSessionDelegate,
        host: String
    ) async -> URLSession.AuthChallengeDisposition? {
        let expectation = XCTestExpectation(description: "challenge answered for \(host)")
        var received: URLSession.AuthChallengeDisposition?
        delegate.urlSession(URLSession.shared, didReceive: makeChallenge(host: host)) { d, _ in
            received = d
            expectation.fulfill()
        }
        await fulfillment(of: [expectation], timeout: 2.0)
        return received
    }

    // MARK: - customHostTrustPolicy (PinnedSessionDelegate)

    /// **The criterion that matters.** Two delegates alive at the same time, in
    /// the same process, holding opposing `customHostTrustPolicy` values, must
    /// each enforce their own — and mutating the global must not move either.
    func test_twoDelegates_holdOpposingTrustPolicies_independently() async {
        PinnedSessionDelegate.pinnedHosts = [:]

        let permissive = PinnedSessionDelegate(
            securityPolicy: ManifoldSecurityPolicy(customHostTrustPolicy: .platformDefault)
        )
        let strict = PinnedSessionDelegate(
            securityPolicy: ManifoldSecurityPolicy(customHostTrustPolicy: .requireExplicitPins)
        )

        // Global agrees with `permissive`. A delegate that reads the global would
        // return `.performDefaultHandling` for `strict` and red this assertion.
        ManifoldConfiguration.shared = ManifoldConfiguration(customHostTrustPolicy: .platformDefault)

        var permissiveResult = await disposition(permissive, host: "custom-a.mycompany.manifoldtest")
        var strictResult = await disposition(strict, host: "custom-b.mycompany.manifoldtest")
        XCTAssertEqual(permissiveResult, .performDefaultHandling,
            "Instance policy .platformDefault must fall back to OS trust for an unpinned custom host")
        XCTAssertEqual(strictResult, .cancelAuthenticationChallenge,
            "Instance policy .requireExplicitPins must fail closed even though the global says .platformDefault — reading the global here is the #2293 bug")

        // Flip the global to agree with `strict` instead. Now a delegate that
        // reads the global would fail `permissive`.
        ManifoldConfiguration.shared = ManifoldConfiguration(customHostTrustPolicy: .requireExplicitPins)

        permissiveResult = await disposition(permissive, host: "custom-a.mycompany.manifoldtest")
        strictResult = await disposition(strict, host: "custom-b.mycompany.manifoldtest")
        XCTAssertEqual(permissiveResult, .performDefaultHandling,
            "Instance policy .platformDefault must survive a global flip to .requireExplicitPins")
        XCTAssertEqual(strictResult, .cancelAuthenticationChallenge,
            "Instance policy .requireExplicitPins must stay fail-closed")
    }

    /// A `nil` instance policy keeps tracking the transitional global live, so a
    /// host that has not migrated loses no enforcement.
    func test_nilPolicy_tracksTransitionalGlobal() async {
        PinnedSessionDelegate.pinnedHosts = [:]
        let delegate = PinnedSessionDelegate()

        ManifoldConfiguration.shared = ManifoldConfiguration(customHostTrustPolicy: .platformDefault)
        let permissive = await disposition(delegate, host: "custom-c.mycompany.manifoldtest")
        XCTAssertEqual(permissive, .performDefaultHandling)

        // Same delegate instance, global tightened after construction.
        ManifoldConfiguration.shared = ManifoldConfiguration(customHostTrustPolicy: .requireExplicitPins)
        let strict = await disposition(delegate, host: "custom-c.mycompany.manifoldtest")
        XCTAssertEqual(strict, .cancelAuthenticationChallenge,
            "A nil instance policy must read the global at challenge time, not snapshot it at init")
    }

    // MARK: - allowUnpinnedCredentialedHosts (CredentialedHostTrustGate)

    /// Two graphs' credentialed-host gates disagree in the same process while the
    /// global contradicts both in turn.
    func test_credentialedHostGate_isInstanceScoped() throws {
        PinnedSessionDelegate.pinnedHosts = [:]
        PinnedSessionDelegate.resetDefaultPinsForTesting()

        let url = URL(string: "https://unpinned-\(UUID().uuidString.lowercased()).manifoldcorp/v1/chat")!
        let allowing = ManifoldSecurityPolicy(allowUnpinnedCredentialedHosts: true)
        let refusing = ManifoldSecurityPolicy(allowUnpinnedCredentialedHosts: false)

        // Global refuses. The `allowing` instance must still allow.
        ManifoldConfiguration.shared = ManifoldConfiguration(allowUnpinnedCredentialedHosts: false)
        XCTAssertNoThrow(
            try CredentialedHostTrustGate.check(url: url, hasCredentials: true, securityPolicy: allowing),
            "An instance policy that allows unpinned credentialed hosts must not be overridden by a refusing global"
        )
        XCTAssertThrowsError(
            try CredentialedHostTrustGate.check(url: url, hasCredentials: true, securityPolicy: refusing)
        )

        // Global allows. The `refusing` instance must still refuse — this is the
        // issue's failure scenario: window B relaxing must not relax window A.
        ManifoldConfiguration.shared = ManifoldConfiguration(allowUnpinnedCredentialedHosts: true)
        XCTAssertThrowsError(
            try CredentialedHostTrustGate.check(url: url, hasCredentials: true, securityPolicy: refusing)
        ) { error in
            guard case CloudBackendError.unpinnedCredentialedHost(let host) = error else {
                return XCTFail("Expected unpinnedCredentialedHost, got \(error)")
            }
            XCTAssertEqual(host, url.host()?.lowercased())
        }
        XCTAssertNoThrow(
            try CredentialedHostTrustGate.check(url: url, hasCredentials: true, securityPolicy: allowing)
        )
    }

    // MARK: - Liveness: registrars actually produce policy-scoped backends

    /// Principle 10 check: the seam is not inert. Two `InferenceService`s with
    /// different policies must hand `CloudSaaSBackends` enough to build backends
    /// that carry those policies — otherwise the plumbing above is a read path
    /// with no writer.
    @MainActor
    func test_cloudSaaSRegistrar_stampsServiceSecurityPolicyOntoBackends() throws {
        let strictService = InferenceService(backend: MockInferenceBackend())
        strictService.securityPolicy = ManifoldSecurityPolicy(
            customHostTrustPolicy: .requireExplicitPins,
            allowUnpinnedCredentialedHosts: false
        )
        let laxService = InferenceService(backend: MockInferenceBackend())
        laxService.securityPolicy = ManifoldSecurityPolicy(
            customHostTrustPolicy: .platformDefault,
            allowUnpinnedCredentialedHosts: true
        )

        CloudSaaSBackends.register(with: strictService)
        CloudSaaSBackends.register(with: laxService)

        let strictBackend = try XCTUnwrap(
            strictService.makeEndpointBackendWithoutLoading(for: .claude) as? SSECloudBackend,
            "Registrar must produce a Claude backend"
        )
        let laxBackend = try XCTUnwrap(
            laxService.makeEndpointBackendWithoutLoading(for: .claude) as? SSECloudBackend
        )

        XCTAssertEqual(strictBackend.securityPolicy, strictService.securityPolicy,
            "Backends built by the registrar must carry the registering service's policy, not the global")
        XCTAssertEqual(laxBackend.securityPolicy, laxService.securityPolicy)
        XCTAssertNotEqual(strictBackend.securityPolicy, laxBackend.securityPolicy,
            "Two service graphs in one process must end up with differently-scoped backends")
        XCTAssertFalse(strictBackend.urlSession === laxBackend.urlSession,
            "Different policies must not share a URLSession — the pinning delegate carries the policy")
    }

    // MARK: - Fail-open regression: opting in must be opt-IN

    /// A service graph that has **not** opted into instance scoping must keep
    /// tracking the transitional global **live**, in both directions.
    ///
    /// This is the F1 regression. Instance scoping is expressed as
    /// `securityPolicy?.X ?? ManifoldConfiguration.shared.X`, so a non-`nil` policy
    /// makes the `?? global` branch dead. If anything seeds a policy that the host
    /// did not ask for, a later *tightening* of
    /// `ManifoldConfiguration.shared.allowUnpinnedCredentialedHosts` (`true` →
    /// `false`) silently stops reaching the backend and credentialed requests keep
    /// going to unpinned hosts — a fail-open, and strictly worse than pre-#2293.
    @MainActor
    func test_defaultService_doesNotOptIn_andTracksGlobalTightening() throws {
        PinnedSessionDelegate.pinnedHosts = [:]
        PinnedSessionDelegate.resetDefaultPinsForTesting()

        let service = InferenceService(backend: MockInferenceBackend())
        XCTAssertNil(service.securityPolicy,
            "A service must not carry a security policy unless the host opted in")

        CloudSaaSBackends.register(with: service)
        let backend = try XCTUnwrap(
            service.makeEndpointBackendWithoutLoading(for: .claude) as? SSECloudBackend
        )
        XCTAssertNil(backend.securityPolicy,
            "A backend from a non-opted-in graph must keep resolving the global, not a snapshot of it")
        XCTAssertTrue(backend.urlSession === URLSessionProvider.pinned,
            "A non-opted-in graph must get the shared pinned session, exactly as before #2293")

        // Now prove the live tracking that a premature snapshot would destroy.
        let url = URL(string: "https://unpinned-\(UUID().uuidString.lowercased()).manifoldcorp/v1/chat")!

        ManifoldConfiguration.shared = ManifoldConfiguration(allowUnpinnedCredentialedHosts: true)
        XCTAssertNoThrow(
            try CredentialedHostTrustGate.check(
                url: url, hasCredentials: true, securityPolicy: backend.securityPolicy
            ),
            "Global relaxed: a non-opted-in backend must follow it"
        )

        // The direction that matters: the host tightens after the backend exists.
        ManifoldConfiguration.shared = ManifoldConfiguration(allowUnpinnedCredentialedHosts: false)
        XCTAssertThrowsError(
            try CredentialedHostTrustGate.check(
                url: url, hasCredentials: true, securityPolicy: backend.securityPolicy
            ),
            "Global tightened after the backend was built: a non-opted-in backend MUST fail closed. Seeding an unrequested policy here is a fail-open regression."
        )
    }

    /// The kill-switch must still trap at cloud-backend construction, not at
    /// registration. Registering under `networkDisabled` builds the policy-scoped
    /// session lazily, so `register(with:)` itself must not trip the
    /// `precondition` — otherwise a host that disables the network and calls
    /// `quickStart()` crashes at startup.
    @MainActor
    func test_registerUnderKillSwitch_doesNotTrap() {
        let saved = URLSessionProvider.networkDisabled
        URLSessionProvider.networkDisabled = true
        defer { URLSessionProvider.networkDisabled = saved }

        let optedIn = InferenceService(backend: MockInferenceBackend())
        optedIn.securityPolicy = ManifoldSecurityPolicy(customHostTrustPolicy: .requireExplicitPins)
        // Registering must be safe even with the network locked — the scoped
        // session is not resolved until a backend is actually constructed.
        CloudSaaSBackends.register(with: optedIn)

        let notOptedIn = InferenceService(backend: MockInferenceBackend())
        CloudSaaSBackends.register(with: notOptedIn)
    }

    // MARK: - pinnedData derives the policy from the session it was handed

    /// `ConnectAddressPinningDelegate.pinnedData(for:on:)` takes no policy
    /// parameter — it reads the policy off the session's
    /// `CompositeURLSessionDelegate`. That is what makes its four callers
    /// (`CloudReranker`, `DefaultWebSearchRuntime`, `OllamaModelListService`,
    /// `OllamaModelProbe`) scoped without a parameter no writer sets.
    func test_pinnedData_derivesPolicyFromTheSessionItWasHanded() {
        let allowing = ManifoldSecurityPolicy(allowUnpinnedCredentialedHosts: true)
        let scoped = URLSessionProvider.pinned(securityPolicy: allowing)

        XCTAssertEqual(
            ConnectAddressPinningDelegate.securityPolicy(carriedBy: scoped),
            allowing,
            "A policy-scoped session must carry its policy where pinnedData can find it"
        )
        XCTAssertNil(
            ConnectAddressPinningDelegate.securityPolicy(carriedBy: URLSessionProvider.pinned),
            "The shared unscoped session must report no policy so callers resolve the global"
        )
    }

    /// The credentialed path end to end: the global refuses unpinned credentialed
    /// hosts, the session's own policy allows them, and the request must get past
    /// the gate on the session's policy. The host does not resolve, so the call is
    /// expected to fail — the assertion is that it does **not** fail with
    /// `unpinnedCredentialedHost`.
    func test_pinnedData_credentialedRequest_usesSessionPolicyNotGlobal() async {
        PinnedSessionDelegate.pinnedHosts = [:]
        PinnedSessionDelegate.resetDefaultPinsForTesting()
        ManifoldConfiguration.shared = ManifoldConfiguration(allowUnpinnedCredentialedHosts: false)

        let scoped = URLSessionProvider.pinned(
            securityPolicy: ManifoldSecurityPolicy(allowUnpinnedCredentialedHosts: true)
        )
        var request = URLRequest(
            url: URL(string: "https://unresolvable-\(UUID().uuidString.lowercased()).manifoldcorp/v1/rerank")!
        )
        request.setValue("Bearer test", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 5

        do {
            _ = try await ConnectAddressPinningDelegate.pinnedData(for: request, on: scoped)
            // A successful response would be surprising but is not what this test
            // is about — it still proves the gate did not reject.
        } catch CloudBackendError.unpinnedCredentialedHost(let host) {
            XCTFail("Gate rejected \(host) using the global; it must use the session's own policy")
        } catch {
            // Any other error (DNS/connection failure) means the gate let it through.
        }
    }

    // MARK: - Registration lifetime on the real production path

    /// A graph's `NetworkPolicyRegistry` entry must be released when the graph
    /// dies — exercised through the **actual** producer: registrar, memoised
    /// policy-scoped session (which `URLSessionProvider` caches for the process
    /// lifetime), and a constructed backend.
    ///
    /// The earlier shape hung the registration off the session's
    /// `CompositeURLSessionDelegate`. `URLSession` retains its delegate until it is
    /// invalidated and the scoped sessions are cached forever, so that entry was
    /// immortal here even though a hand-built delegate released fine — window B
    /// closing would have left window A blocked until restart. A deliberately
    /// non-vacuous allowlist is used so a leak would actually restrict something.
    @MainActor
    func test_graphRegistration_releasedWhenGraphDies_throughTheRegistrar() {
        let baseline = NetworkPolicyRegistry.shared.registrationCount

        do {
            let service = InferenceService(backend: MockInferenceBackend())
            service.securityPolicy = ManifoldSecurityPolicy(
                networkPolicy: .allowlist(["scoped.manifoldtest"])
            )
            CloudSaaSBackends.register(with: service)
            _ = service.makeEndpointBackendWithoutLoading(for: .claude)

            XCTAssertEqual(NetworkPolicyRegistry.shared.registrationCount, baseline + 1,
                "An opted-in graph must hold exactly one registry entry")
            XCTAssertEqual(
                NetworkPolicyRegistry.shared.effectiveNetworkPolicy,
                .allowlist(["scoped.manifoldtest"]),
                "The graph's allowlist must reach the static URLProtocol backstop"
            )
        }

        XCTAssertEqual(NetworkPolicyRegistry.shared.registrationCount, baseline,
            "Dropping the graph must release its entry — a cached session must not keep it alive")
        XCTAssertEqual(NetworkPolicyRegistry.shared.effectiveNetworkPolicy, .unrestricted,
            "A dead graph's allowlist must stop restricting the graphs that outlive it")
    }
}

/// Minimal `URLAuthenticationChallengeSender` so a challenge can be constructed
/// without a live connection. None of its callbacks fire in these tests.
private final class NoopChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
