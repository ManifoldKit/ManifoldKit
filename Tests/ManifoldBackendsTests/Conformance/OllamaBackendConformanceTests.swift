#if Ollama
import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldBackends

/// OllamaBackend conformance against the universal BCK backend contract.
///
/// Grammar fail-closed is asserted because OllamaBackend currently reports
/// `supportsGrammarConstrainedSampling = false`.
@MainActor
final class OllamaBackendConformanceTests: XCTestCase {

    private let backendName = "OllamaBackend"

    override class func setUp() {
        super.setUp()
        BackendContractChecks.resetCapabilityClaims()
    }

    // MARK: - Universal invariants

    // Sabotage-evidence: assertAllInvariants trips on invariant 1 if init() sets isModelLoaded=true
    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants(makingBackend: { OllamaBackend() })
    }

    // MARK: - Grammar fail-closed

    func test_contract_grammarFailClosed() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let baseURL = URL(string: "http://localhost/ollama-\(UUID().uuidString)")!
        let showURL = baseURL.appendingPathComponent("api/show")
        let chatURL = baseURL.appendingPathComponent("api/chat")
        MockURLProtocol.stub(
            url: showURL,
            response: .immediate(
                data: Data(#"{"capabilities":[]}"#.utf8),
                statusCode: 200
            )
        )
        MockURLProtocol.stub(url: chatURL, response: .error(URLError(.cannotConnectToHost)))
        defer { MockURLProtocol.unstub(url: showURL) }
        defer { MockURLProtocol.unstub(url: chatURL) }

        try await BackendContractChecks.assertGrammarFailClosedContract(
            backendName: backendName,
            makingBackend: {
                let backend = OllamaBackend(urlSession: URLSession(configuration: sessionConfig))
                backend.configure(baseURL: baseURL, modelName: "llama3.2")
                return backend
            },
            forbiddenRequestURL: chatURL
        )
    }

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
