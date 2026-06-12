import XCTest
import ManifoldInference
import ManifoldBackendTestKit
import ManifoldTestSupport
import ManifoldBackends

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

    // MARK: - Universal invariants

    // Sabotage-evidence: assertAllInvariants trips on invariant 1 if init() sets isModelLoaded=true
    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants(makingBackend: { OpenAIBackend() })
    }

    // MARK: - Grammar fail-closed

    func test_contract_grammarFailClosed() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let baseURL = URL(string: "http://openai-\(UUID().uuidString).test")!
        let completionsURL = baseURL.appendingPathComponent("v1/chat/completions")
        MockURLProtocol.stub(url: completionsURL, response: .error(URLError(.cannotConnectToHost)))
        defer { MockURLProtocol.unstub(url: completionsURL) }

        try await BackendContractChecks.assertGrammarFailClosedContract(
            backendName: backendName,
            makingBackend: {
                let backend = OpenAIBackend(urlSession: URLSession(configuration: sessionConfig))
                backend.configure(
                    baseURL: baseURL,
                    apiKey: "sk-test",
                    modelName: "gpt-4o-mini"
                )
                return backend
            },
            forbiddenRequestURL: completionsURL
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
            flag: "supportsNativeJSONMode"
        )
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: backendName,
            flag: "supportsVision"
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
            capabilities: OpenAIBackend().capabilities
        )
    }
}
