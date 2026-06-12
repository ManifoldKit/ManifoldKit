import XCTest
import ManifoldInference
import ManifoldBackendTestKit
import ManifoldTestSupport
import ManifoldBackends

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

    // MARK: - Per-capability claims + meta-contract

    /// All bootstrap claims and the meta-contract assertion are collapsed into
    /// one method so the registry is built and verified within a single process.
    /// Under `swift test --parallel` each test method runs in an isolated worker
    /// process; splitting claim recording across several methods meant the
    /// meta-contract reader saw an empty registry in its worker. (#1601)
    func test_contract_allCapabilityClaims() {
        // Reset first so a prior run of this method in the same process doesn't
        // leave stale claims that could mask a newly-removed flag.
        BackendContractChecks.resetCapabilityClaims(forBackend: backendName)

        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: backendName,
            flag: "supportsToolCalling"
        )
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: backendName,
            flag: "supportsStructuredOutput"
        )
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: backendName,
            flag: "supportsThinking"
        )
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: backendName,
            flag: "streamsToolCallArguments"
        )
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: backendName,
            flag: "supportsParallelToolCalls"
        )

        BackendContractChecks.assertCapabilityMetaContract(
            backendName: backendName,
            capabilities: OpenAIResponsesBackend().capabilities
        )
    }
}
