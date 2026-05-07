#if CloudSaaS
import XCTest
import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatBackends

/// ClaudeBackend conformance against the universal BCK backend contract.
///
/// Grammar fail-closed is asserted because ClaudeBackend currently reports
/// `supportsGrammarConstrainedSampling = false`.
///
/// Default model name is `claude-sonnet-4-20250514`, which contains
/// `claude-sonnet-4` and therefore sets `supportsVision = true` via
/// `BackendVisionCapability.claudeMessagesSupportsImageInput`.
@MainActor
final class ClaudeBackendConformanceTests: XCTestCase {

    private let backendName = "ClaudeBackend"

    override class func setUp() {
        super.setUp()
        BackendContractChecks.resetCapabilityClaims()
    }

    // MARK: - Universal invariants

    // Sabotage-evidence: assertAllInvariants trips on invariant 1 if init() sets isModelLoaded=true
    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants(makingBackend: { ClaudeBackend() })
    }

    // MARK: - Grammar fail-closed

    func test_contract_grammarFailClosed() async throws {
        try await BackendContractChecks.assertGrammarFailClosedContract(
            backendName: backendName,
            makingBackend: {
                let backend = ClaudeBackend()
                backend.configure(
                    baseURL: URL(string: "https://api.anthropic.com")!,
                    apiKey: "sk-ant-test",
                    modelName: "claude-sonnet-4-20250514"
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
            capabilities: ClaudeBackend().capabilities
        )
    }
}
#endif
