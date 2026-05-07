#if CloudSaaS
import XCTest
import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatBackends

/// OpenAIResponsesBackend conformance against the universal BCK backend contract.
///
/// Grammar fail-closed is skipped: `supportsGrammarConstrainedSampling` is
/// `false` for OpenAIResponsesBackend but the backend does not validate grammar
/// before forwarding the request to OpenAI — a real behavioral gap, not guarded
/// via `withKnownIssue`. Capability claims are bootstrapped via
/// `claimWithoutBehaviouralAssertion`; Phase C work will replace each with a
/// real assertion family.
///
/// Default model name is `gpt-5`.
/// `supportsVision` evaluates to `false` for this backend regardless of model
/// name — `BackendVisionCapability.openAIResponsesSupportsImageInput` always
/// returns `false` until image input encoding is implemented for the Responses API.
@MainActor
final class OpenAIResponsesBackendConformanceTests: XCTestCase {

    private let backendName = "OpenAIResponsesBackend"

    override func setUp() {
        super.setUp()
        BackendContractChecks.resetCapabilityClaims()
    }

    // MARK: - Universal invariants

    // Sabotage-evidence: assertAllInvariants trips on invariant 1 if init() sets isModelLoaded=true
    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants(makingBackend: { OpenAIResponsesBackend() })
    }

    // MARK: - Grammar fail-closed
    // Skipped: OpenAIResponsesBackend.supportsGrammarConstrainedSampling = false but the
    // backend does not validate grammar before forwarding the request to OpenAI.
    // This is a cloud-backend gap — no fail-closed throw is implemented.

    // MARK: - Per-capability claims (bootstrap)

    func test_contract_supportsToolCalling_claim() {
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: backendName,
            flag: "supportsToolCalling"
        )
    }

    func test_contract_supportsStructuredOutput_claim() {
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: backendName,
            flag: "supportsStructuredOutput"
        )
    }

    func test_contract_supportsThinking_claim() {
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: backendName,
            flag: "supportsThinking"
        )
    }

    func test_contract_streamsToolCallArguments_claim() {
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: backendName,
            flag: "streamsToolCallArguments"
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
            capabilities: OpenAIResponsesBackend().capabilities
        )
    }
}
#endif
