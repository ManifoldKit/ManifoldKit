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
        BackendContractChecks.resetCapabilityClaims()
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
