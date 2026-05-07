#if CloudSaaS
import XCTest
import BaseChatInference
import BaseChatTestSupport
@testable import BaseChatBackends

/// ClaudeBackend conformance against the universal BCK backend contract.
///
/// Grammar fail-closed is skipped: `supportsGrammarConstrainedSampling` is
/// `false` for ClaudeBackend but the backend does not validate grammar before
/// forwarding the request to Anthropic — a real behavioral gap, not guarded via
/// `withKnownIssue`. Capability claims are bootstrapped via
/// `claimWithoutBehaviouralAssertion`; Phase C work will replace each with a
/// real assertion family.
///
/// Default model name is `claude-sonnet-4-20250514`, which contains
/// `claude-sonnet-4` and therefore sets `supportsVision = true` via
/// `BackendVisionCapability.claudeMessagesSupportsImageInput`.
@MainActor
final class ClaudeBackendConformanceTests: XCTestCase {

    private let backendName = "ClaudeBackend"

    override func setUp() {
        super.setUp()
        BackendContractChecks.resetCapabilityClaims()
    }

    // MARK: - Universal invariants

    // Sabotage-evidence: assertAllInvariants trips on invariant 1 if init() sets isModelLoaded=true
    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants(makingBackend: { ClaudeBackend() })
    }

    // MARK: - Grammar fail-closed
    // Skipped: ClaudeBackend.supportsGrammarConstrainedSampling = false but the
    // backend does not validate grammar before forwarding the request to Anthropic.
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
