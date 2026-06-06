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
            flag: "supportsNativeJSONMode"
        )
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: backendName,
            flag: "supportsParallelToolCalls"
        )

        BackendContractChecks.assertCapabilityMetaContract(
            backendName: backendName,
            capabilities: OllamaBackend().capabilities
        )
    }
}
#endif
