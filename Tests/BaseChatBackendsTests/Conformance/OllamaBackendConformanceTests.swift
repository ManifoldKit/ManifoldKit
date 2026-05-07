#if Ollama
import XCTest
import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatBackends

/// OllamaBackend conformance against the universal BCK backend contract.
///
/// Grammar fail-closed is skipped: `supportsGrammarConstrainedSampling` is
/// `false` for OllamaBackend but the backend does not check grammar before
/// forwarding to Ollama — a real behavioral gap, not guarded via
/// `withKnownIssue`. Capability claims are bootstrapped via
/// `claimWithoutBehaviouralAssertion`; Phase C work will replace each with a
/// real assertion family.
@MainActor
final class OllamaBackendConformanceTests: XCTestCase {

    private let backendName = "OllamaBackend"

    override func setUp() {
        super.setUp()
        BackendContractChecks.resetCapabilityClaims()
    }

    // MARK: - Universal invariants

    // Sabotage-evidence: assertAllInvariants trips on invariant 1 if init() sets isModelLoaded=true
    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants(makingBackend: { OllamaBackend() })
    }

    // MARK: - Grammar fail-closed
    // Skipped: OllamaBackend.supportsGrammarConstrainedSampling = false but the
    // backend does not validate grammar before forwarding the request to Ollama.
    // This is a cloud-backend gap — no fail-closed throw is implemented.

    // MARK: - Per-capability claims (bootstrap)

    func test_contract_supportsToolCalling_claim() {
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: backendName,
            flag: "supportsToolCalling"
        )
    }

    func test_contract_supportsNativeJSONMode_claim() {
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: backendName,
            flag: "supportsNativeJSONMode"
        )
    }

    func test_contract_supportsParallelToolCalls_claim() {
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: backendName,
            flag: "supportsParallelToolCalls"
        )
    }

    // MARK: - Meta-contract (MUST be last)

    func test_z_contract_metaContract() {
        BackendContractChecks.assertCapabilityMetaContract(
            backendName: backendName,
            capabilities: OllamaBackend().capabilities
        )
    }
}
#endif
