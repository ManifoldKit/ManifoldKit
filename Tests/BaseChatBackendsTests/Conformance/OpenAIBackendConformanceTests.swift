#if CloudSaaS
import XCTest
import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatBackends

/// OpenAIBackend conformance against the universal BCK backend contract.
///
/// Grammar fail-closed is asserted because OpenAIBackend currently reports
/// `supportsGrammarConstrainedSampling = false`.
///
/// Default model name is `gpt-4o-mini`, which matches the `gpt-4o`
/// substring token and therefore sets `supportsVision = true`.
@MainActor
final class OpenAIBackendConformanceTests: XCTestCase {

    private let backendName = "OpenAIBackend"

    override class func setUp() {
        super.setUp()
        BackendContractChecks.resetCapabilityClaims()
    }

    // MARK: - Universal invariants

    // Sabotage-evidence: assertAllInvariants trips on invariant 1 if init() sets isModelLoaded=true
    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants(makingBackend: { OpenAIBackend() })
    }

    // MARK: - Grammar fail-closed

    func test_contract_grammarFailClosed() async throws {
        try await BackendContractChecks.assertGrammarFailClosedContract(
            backendName: backendName,
            makingBackend: {
                let backend = OpenAIBackend()
                backend.configure(
                    baseURL: URL(string: "https://api.openai.com")!,
                    apiKey: "sk-test",
                    modelName: "gpt-4o-mini"
                )
                return backend
            }
        )
    }

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

    func test_contract_supportsNativeJSONMode_claim() {
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: backendName,
            flag: "supportsNativeJSONMode"
        )
    }

    func test_contract_supportsVision_claim() {
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: backendName,
            flag: "supportsVision"
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
            capabilities: OpenAIBackend().capabilities
        )
    }
}
#endif
