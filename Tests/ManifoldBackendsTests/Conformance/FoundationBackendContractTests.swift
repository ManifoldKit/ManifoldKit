#if canImport(FoundationModels)
import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldBackends
@testable import ManifoldFoundation

/// FoundationBackend conformance against the universal backend contract.
///
/// Universal invariants (``assertUniversalBackendContract``) exercise state
/// that does not require a live session — `isModelLoaded == false` and
/// `isGenerating == false` on init. These run in every build where
/// `FoundationModels` is importable (macOS 26 / iOS 26+), without hardware
/// or `RUN_SLOW_TESTS` gates.
///
/// Generation-level behavioural assertions (fixture replay, streaming
/// cancellation) live in ``LocalBackendContractTests`` and are gated behind
/// `RUN_SLOW_TESTS=1` so they only execute in the nightly tier where macOS 26
/// / iOS 26 and Apple Intelligence are present.
///
/// ## macOS 15 / CI safety
///
/// `@available(macOS 26, iOS 26, *)` on the class declaration is NOT enforced
/// by XCTest — the ObjC runtime discovers test methods regardless of OS
/// availability annotations (see ``FoundationBackendUnitTests`` for the same
/// pattern). The `setUp()` override below throws `XCTSkip` on macOS < 26 so
/// that `FoundationBackend()` — which references `FoundationModels` types — is
/// never instantiated on a runner that doesn't have the framework at runtime.
/// Without this guard the CI lane (macOS 15, Xcode 26 SDK) would attempt to
/// call `FoundationBackend.generate()` before the system model is available,
/// producing a SIGABRT from the `FoundationModels` framework asserting
/// internal preconditions.
@available(macOS 26, iOS 26, *)
@MainActor
final class FoundationBackendContractTests: XCTestCase,
                                            BackendContractMixin {

    let contractBackendName = "FoundationBackend"

    func makeContractBackend() -> FoundationBackend {
        FoundationBackend()
    }

    override class func setUp() {
        super.setUp()
        BackendContractChecks.resetCapabilityClaims(forBackend: "FoundationBackend")
    }

    // XCTest bypasses Swift @available on test classes (ObjC runtime discovery).
    // Throw XCTSkip here so no FoundationModels API is touched on macOS 15 CI.
    override func setUp() async throws {
        try await super.setUp()
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(
            OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0)
        ) else {
            throw XCTSkip("FoundationModels requires macOS 26 / iOS 26")
        }
    }

    // MARK: - Universal invariants

    // Sabotage-evidence: assertAllInvariants trips on invariant 1 if
    // FoundationBackend.init() incorrectly sets isModelLoaded=true.
    func test_contract_allInvariants() {
        assertUniversalBackendContract()
    }

    // MARK: - Per-capability claims

    /// FoundationBackend declares `supportsToolCalling = true`. Full
    /// behavioural proof requires Apple Intelligence (a live session with the
    /// on-device model) and lives in the E2E tier. This claim records the
    /// obligation in the meta-contract registry until the parameterised fixture
    /// suite covers it under `RUN_SLOW_TESTS=1`.
    func test_contract_supportsToolCalling_claim() {
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: contractBackendName,
            flag: "supportsToolCalling"
        )
    }

    /// FoundationBackend declares `supportsGuidedStructuredOutput = true`.
    /// Behavioural proof (GuidedGeneration round-trip) requires a live session;
    /// this claim records the meta-contract obligation.
    func test_contract_supportsGuidedStructuredOutput_claim() {
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: contractBackendName,
            flag: "supportsGuidedStructuredOutput"
        )
    }

    // MARK: - Meta-contract (MUST be last)

    func test_z_contract_metaContract() {
        BackendContractChecks.assertCapabilityMetaContract(
            backendName: contractBackendName,
            capabilities: FoundationBackend().capabilities
        )
    }
}
#endif
