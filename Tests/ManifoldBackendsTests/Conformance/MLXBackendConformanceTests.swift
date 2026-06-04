#if MLX
import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldBackends
@testable import ManifoldMLX

/// MLXBackend conformance against the universal backend contract.
///
/// Universal invariants (``assertUniversalBackendContract``) exercise state
/// that does not require a real model load — `isModelLoaded == false` and
/// `isGenerating == false` on init. These run in every trait build that
/// includes `MLX`, without hardware or `RUN_SLOW_TESTS` gates.
///
/// Generation-level behavioural assertions (fixture replay, streaming
/// cancellation) live in ``LocalBackendContractTests`` and are gated behind
/// `RUN_SLOW_TESTS=1` so they only execute in the nightly tier where a real
/// model and Apple Silicon hardware are present.
@MainActor
final class MLXBackendConformanceTests: XCTestCase,
                                        BackendContractMixin {

    let contractBackendName = "MLXBackend"

    func makeContractBackend() -> MLXBackend {
        MLXBackend()
    }

    override class func setUp() {
        super.setUp()
        BackendContractChecks.resetCapabilityClaims(forBackend: "MLXBackend")
    }

    // MARK: - Universal invariants

    // Sabotage-evidence: assertAllInvariants trips on invariant 1 if
    // MLXBackend.init() incorrectly sets isModelLoaded=true.
    func test_contract_allInvariants() {
        assertUniversalBackendContract()
    }

    // MARK: - Per-capability claims

    /// MLXBackend declares `supportsToolCalling = true`. Full behavioural
    /// proof lives in ``MLXBackendGenerationTests`` against a real Qwen
    /// model. This claim records the obligation in the meta-contract registry
    /// until the parameterised fixture suite covers it under `RUN_SLOW_TESTS=1`.
    func test_contract_supportsToolCalling_claim() {
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: contractBackendName,
            flag: "supportsToolCalling"
        )
    }

    /// MLXBackend declares `supportsThinking = true`. Behavioural proof lives
    /// in ``MLXBackendThinkingTests``; this claim records the meta-contract
    /// obligation.
    func test_contract_supportsThinking_claim() {
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: contractBackendName,
            flag: "supportsThinking"
        )
    }

    /// MLXBackend declares `supportsTokenCounting = true`. Behavioural proof
    /// is exercised in the E2E suite against a loaded model; this claim records
    /// the meta-contract obligation.
    func test_contract_supportsTokenCounting_claim() {
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: contractBackendName,
            flag: "supportsTokenCounting"
        )
    }

    // MARK: - Meta-contract (MUST be last)

    func test_z_contract_metaContract() {
        BackendContractChecks.assertCapabilityMetaContract(
            backendName: contractBackendName,
            capabilities: MLXBackend().capabilities
        )
    }
}
#endif
