import XCTest
import ManifoldPersistenceSwiftData
import ManifoldInference

/// Integration test (real SwiftData in-memory container) for #2293 acceptance
/// criterion 2: **two bootstraps in one process can hold different trust
/// policies without affecting each other.**
///
/// Classified as an integration test because `ManifoldBootstrap` builds a real
/// `ModelContainer` — an in-memory store, never a mocked persistence layer, per
/// `Tests/README.md`.
@MainActor
final class BootstrapSecurityPolicyScopeTests: XCTestCase {

    private var savedConfiguration: ManifoldConfiguration!

    override func setUp() {
        super.setUp()
        savedConfiguration = ManifoldConfiguration.shared
    }

    override func tearDown() {
        ManifoldConfiguration.shared = savedConfiguration
        super.tearDown()
    }

    /// Opting in is explicit — the caller passes `securityPolicy:`. It is
    /// deliberately not derived from the configuration; see
    /// ``test_defaultBootstrap_doesNotOptIn_soGlobalTighteningStillReaches()``.
    func test_twoBootstraps_holdIndependentSecurityPolicies() throws {
        let strictConfiguration = ManifoldConfiguration(
            appName: "Window A",
            bundleIdentifier: "com.manifoldkit.security-scope-tests.a.\(UUID().uuidString)",
            customHostTrustPolicy: .requireExplicitPins,
            allowUnpinnedCredentialedHosts: false,
            networkPolicy: .allowlist(["a.manifoldtest"])
        )
        let strict = try ManifoldBootstrap.makeInMemory(
            configuration: strictConfiguration,
            securityPolicy: strictConfiguration.securityPolicy
        )

        // Window B relaxes everything for its own dev endpoint. Before #2293 this
        // second `ManifoldConfiguration.shared` write silently downgraded window
        // A's TLS pinning; the assertions below are what that regression breaks.
        let laxConfiguration = ManifoldConfiguration(
            appName: "Window B",
            bundleIdentifier: "com.manifoldkit.security-scope-tests.b.\(UUID().uuidString)",
            customHostTrustPolicy: .platformDefault,
            allowUnpinnedCredentialedHosts: true,
            networkPolicy: .unrestricted
        )
        let lax = try ManifoldBootstrap.makeInMemory(
            configuration: laxConfiguration,
            securityPolicy: laxConfiguration.securityPolicy
        )

        let strictPolicy = try XCTUnwrap(strict.inferenceService.securityPolicy)
        let laxPolicy = try XCTUnwrap(lax.inferenceService.securityPolicy)

        XCTAssertEqual(strictPolicy.customHostTrustPolicy, .requireExplicitPins,
            "Bootstrap A's TLS trust policy must survive bootstrap B being created afterwards")
        XCTAssertFalse(strictPolicy.allowUnpinnedCredentialedHosts,
            "Bootstrap B opting into unpinned credentialed hosts must not relax bootstrap A")
        XCTAssertEqual(strictPolicy.networkPolicy, .allowlist(["a.manifoldtest"]))

        XCTAssertEqual(laxPolicy.customHostTrustPolicy, .platformDefault)
        XCTAssertTrue(laxPolicy.allowUnpinnedCredentialedHosts)
        XCTAssertNotEqual(strictPolicy, laxPolicy,
            "Two bootstraps in one process must not converge on a single process-global policy")

        // The process-global is still last-write-wins for unmigrated readers —
        // which is exactly why the instance policies above must not consult it.
        XCTAssertEqual(ManifoldConfiguration.shared.customHostTrustPolicy, .platformDefault,
            "Sanity: the global does reflect the last bootstrap, so a test reading it would see B's relaxed value")
    }

    /// The default bootstrap path must **not** opt in.
    ///
    /// Instance scoping is `securityPolicy?.X ?? ManifoldConfiguration.shared.X`,
    /// so a policy the host did not ask for makes the `?? global` branch dead and
    /// a later *tightening* of a security field silently stops reaching this
    /// graph's backends — a fail-open, and strictly worse than pre-#2293. AGENTS.md's
    /// canonical recipe (`build(configuration:)`, then set
    /// `ManifoldConfiguration.shared.customHostTrustPolicy` later) is exactly the
    /// shape that would break.
    func test_defaultBootstrap_doesNotOptIn_soGlobalTighteningStillReaches() throws {
        let bootstrap = try ManifoldBootstrap.makeInMemory(
            configuration: ManifoldConfiguration(
                appName: "Single Window",
                bundleIdentifier: "com.manifoldkit.security-scope-tests.default.\(UUID().uuidString)",
                customHostTrustPolicy: .requireExplicitPins,
                allowUnpinnedCredentialedHosts: true,
                networkPolicy: .allowlist(["a.manifoldtest"])
            )
        )

        XCTAssertNil(bootstrap.inferenceService.securityPolicy,
            "Bootstrap must not instance-scope a graph the caller did not ask to scope — even when the configuration's security fields are non-default, since that is the single-graph host's normal way of setting the global")

        // With no snapshot in the way, a later tightening of the global reaches
        // every enforcement seam, which is the pre-#2293 contract.
        ManifoldConfiguration.shared.allowUnpinnedCredentialedHosts = false
        XCTAssertFalse(
            bootstrap.inferenceService.securityPolicy?.allowUnpinnedCredentialedHosts
                ?? ManifoldConfiguration.shared.allowUnpinnedCredentialedHosts,
            "A non-opted-in graph must resolve the tightened global, not a stale snapshot"
        )
    }
}
