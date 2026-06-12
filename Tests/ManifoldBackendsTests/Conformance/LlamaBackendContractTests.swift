#if Llama
import XCTest
import ManifoldInference
import ManifoldBackendTestKit
import ManifoldTestSupport
import ManifoldBackends
import ManifoldLlama

/// LlamaBackend conformance against the universal backend contract.
///
/// Universal invariants (``assertUniversalBackendContract``) exercise state
/// that does not require a real model load — `isModelLoaded == false` and
/// `isGenerating == false` on init. These run in every trait build that
/// includes `Llama`, without hardware or `RUN_SLOW_TESTS` gates.
///
/// Generation-level behavioural assertions (fixture replay, streaming
/// cancellation) live in ``LocalBackendContractTests`` and are gated behind
/// `RUN_SLOW_TESTS=1` so they only execute in the nightly tier where a real
/// GGUF model and Apple Silicon hardware are present.
///
/// Note: per CLAUDE.md, ``LlamaBackend`` uses a global `llama_backend_init`.
/// All tests here execute without calling `loadModel()` to avoid accumulating
/// Metal buffer state alongside other Llama test suites.
@MainActor
final class LlamaBackendContractTests: XCTestCase,
                                       BackendContractMixin {

    let contractBackendName = "LlamaBackend"

    func makeContractBackend() -> LlamaBackend {
        LlamaBackend()
    }

    // MARK: - Universal invariants

    // Sabotage-evidence: assertAllInvariants trips on invariant 1 if
    // LlamaBackend.init() incorrectly sets isModelLoaded=true.
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
    /// - `supportsToolCalling`: requires a loaded GGUF model; lives in the E2E tier.
    /// - `supportsThinking`: requires a thinking-capable GGUF model; lives in the E2E tier.
    /// - `supportsTokenCounting`: exercised in the E2E suite against a loaded model.
    /// - `supportsKVCachePersistence`: requires a loaded model and KV-cache telemetry.
    /// - `supportsGrammarConstrainedSampling`: requires a loaded GGUF model; lives in the E2E tier.
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
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: contractBackendName,
            flag: "supportsKVCachePersistence"
        )
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: contractBackendName,
            flag: "supportsGrammarConstrainedSampling"
        )

        BackendContractChecks.assertCapabilityMetaContract(
            backendName: contractBackendName,
            capabilities: LlamaBackend().capabilities
        )
    }
}
#endif
