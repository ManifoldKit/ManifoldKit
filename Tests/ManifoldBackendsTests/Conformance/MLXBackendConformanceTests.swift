#if MLX
import XCTest
import ManifoldInference
import ManifoldBackendTestKit
import ManifoldTestSupport
import ManifoldBackends
import ManifoldMLX

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

    // MARK: - Universal invariants

    // Sabotage-evidence: assertAllInvariants trips on invariant 1 if
    // MLXBackend.init() incorrectly sets isModelLoaded=true.
    func test_contract_allInvariants() {
        assertUniversalBackendContract()
    }

    // MARK: - Per-capability claims + meta-contract

    /// All bootstrap claims and the meta-contract assertion are collapsed into
    /// one method so the registry is built and verified within a single process.
    /// Under `swift test --parallel` each test method runs in an isolated worker
    /// process; splitting claim recording across several methods meant the
    /// meta-contract reader saw an empty registry in its worker. (#1601)
    ///
    /// Full behavioural proofs for each flag:
    /// - `supportsToolCalling`: lives in ``MLXBackendGenerationTests`` against a real Qwen model.
    /// - `supportsThinking`: lives in ``MLXBackendThinkingTests``.
    /// - `supportsTokenCounting`: exercised in the E2E suite against a loaded model.
    func test_contract_allCapabilityClaims() {
        // Reset first so a prior run of this method in the same process doesn't
        // leave stale claims that could mask a newly-removed flag.
        BackendContractChecks.resetCapabilityClaims(forBackend: contractBackendName)

        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: contractBackendName,
            flag: "supportsToolCalling"
        )
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: contractBackendName,
            flag: "supportsThinking"
        )
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: contractBackendName,
            flag: "supportsTokenCounting"
        )

        BackendContractChecks.assertCapabilityMetaContract(
            backendName: contractBackendName,
            capabilities: MLXBackend().capabilities
        )
    }
}
#endif
