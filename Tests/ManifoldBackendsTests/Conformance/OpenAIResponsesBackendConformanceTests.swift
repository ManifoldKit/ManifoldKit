#if CloudSaaS
import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldBackends

/// OpenAIResponsesBackend conformance against the universal BCK backend contract.
///
/// Grammar fail-closed is asserted because OpenAIResponsesBackend currently
/// reports `supportsGrammarConstrainedSampling = false`.
///
/// Default model name is `gpt-5`.
/// `supportsVision` evaluates to `false` for this backend regardless of model
/// name — `BackendVisionCapability.openAIResponsesSupportsImageInput` always
/// returns `false` until image input encoding is implemented for the Responses API.
@MainActor
final class OpenAIResponsesBackendConformanceTests: XCTestCase {

    private let backendName = "OpenAIResponsesBackend"

    override class func setUp() {
        super.setUp()
        BackendContractChecks.resetCapabilityClaims()
    }

    // MARK: - Universal invariants

    // Sabotage-evidence: assertAllInvariants trips on invariant 1 if init() sets isModelLoaded=true
    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants(makingBackend: { OpenAIResponsesBackend() })
    }

    // MARK: - Grammar fail-closed

    func test_contract_grammarFailClosed() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let baseURL = URL(string: "http://openai-responses-\(UUID().uuidString).test")!
        let responsesURL = baseURL.appendingPathComponent("v1/responses")
        MockURLProtocol.stub(url: responsesURL, response: .error(URLError(.cannotConnectToHost)))
        defer { MockURLProtocol.unstub(url: responsesURL) }

        try await BackendContractChecks.assertGrammarFailClosedContract(
            backendName: backendName,
            makingBackend: {
                let backend = OpenAIResponsesBackend(urlSession: URLSession(configuration: sessionConfig))
                backend.configure(
                    baseURL: baseURL,
                    apiKey: "sk-test",
                    modelName: "gpt-5"
                )
                return backend
            },
            forbiddenRequestURL: responsesURL
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
