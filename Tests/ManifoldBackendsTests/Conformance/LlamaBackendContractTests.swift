#if Llama
import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldBackends
@testable import ManifoldLlama

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

    override class func setUp() {
        super.setUp()
        BackendContractChecks.resetCapabilityClaims(forBackend: "LlamaBackend")
    }

    // MARK: - Universal invariants

    // Sabotage-evidence: assertAllInvariants trips on invariant 1 if
    // LlamaBackend.init() incorrectly sets isModelLoaded=true.
    func test_contract_allInvariants() {
        assertUniversalBackendContract()
    }

    // MARK: - Per-capability claims

    /// LlamaBackend declares `supportsToolCalling = true`. Full behavioural
    /// proof requires a loaded GGUF model and lives in the E2E tier. This
    /// claim records the obligation in the meta-contract registry until the
    /// parameterised fixture suite covers it under `RUN_SLOW_TESTS=1`.
    func test_contract_supportsToolCalling_claim() {
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: contractBackendName,
            flag: "supportsToolCalling"
        )
    }

    /// LlamaBackend declares `supportsThinking = true`. Behavioural proof
    /// requires a thinking-capable GGUF model and lives in the E2E tier; this
    /// claim records the meta-contract obligation.
    func test_contract_supportsThinking_claim() {
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: contractBackendName,
            flag: "supportsThinking"
        )
    }

    /// LlamaBackend declares `supportsTokenCounting = true`. Behavioural proof
    /// is exercised in the E2E suite against a loaded model; this claim records
    /// the meta-contract obligation.
    func test_contract_supportsTokenCounting_claim() {
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: contractBackendName,
            flag: "supportsTokenCounting"
        )
    }

    /// LlamaBackend declares `supportsKVCachePersistence = true`. Behavioural
    /// proof requires a loaded model and KV-cache telemetry; this claim records
    /// the meta-contract obligation.
    func test_contract_supportsKVCachePersistence_claim() {
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: contractBackendName,
            flag: "supportsKVCachePersistence"
        )
    }

    /// LlamaBackend declares `supportsGrammarConstrainedSampling = true`.
    /// Behavioural proof (grammar-constrained generation) requires a loaded
    /// GGUF model and lives in the E2E tier; this claim records the
    /// meta-contract obligation.
    func test_contract_supportsGrammarConstrainedSampling_claim() {
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: contractBackendName,
            flag: "supportsGrammarConstrainedSampling"
        )
    }

    // MARK: - Meta-contract (MUST be last)

    func test_z_contract_metaContract() {
        BackendContractChecks.assertCapabilityMetaContract(
            backendName: contractBackendName,
            capabilities: LlamaBackend().capabilities
        )
    }
}
#endif
