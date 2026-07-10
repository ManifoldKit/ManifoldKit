import XCTest
import ManifoldInference
import ManifoldBackendTestKit
import ManifoldTestSupport
import ManifoldFoundation
import ManifoldOllama
import ManifoldCloudSaaS
import ManifoldCloudCore

/// OllamaBackend conformance against the universal BCK backend contract.
///
/// Grammar fail-closed is asserted because OllamaBackend currently reports
/// `supportsGrammarConstrainedSampling = false`.
@MainActor
final class OllamaBackendConformanceTests: XCTestCase {

    private let backendName = "OllamaBackend"

    // Instance-scoped: XCTest instantiates a fresh test case per method, so
    // this registry starts empty for every method invocation. See
    // BackendContractChecks.ClaimRegistry.
    private let capabilityClaimRegistry = BackendContractChecks.ClaimRegistry()

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
            capabilityClaimRegistry,
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
    /// one method, threaded through one shared `capabilityClaimRegistry`
    /// instance, so the registry is built and verified within a single test-case
    /// lifetime. Historically necessary because the registry was process-global
    /// (#1601); now the registry is instance-scoped (arch-plan 4.2) and this
    /// suite is safe under `swift test --parallel` — the collapse remains as a
    /// readable, self-contained shape, not a correctness requirement.
    func test_contract_allCapabilityClaims() {
        // Reset first — harmless given a freshly-constructed registry, kept
        // for symmetry with suites that build up several scenarios in one
        // test method.
        BackendContractChecks.resetCapabilityClaims(capabilityClaimRegistry, forBackend: backendName)

        BackendContractChecks.claimWithoutBehaviouralAssertion(
            capabilityClaimRegistry,
            backendName: backendName,
            flag: "supportsToolCalling"
        )
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            capabilityClaimRegistry,
            backendName: backendName,
            flag: "supportsNativeJSONMode"
        )
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            capabilityClaimRegistry,
            backendName: backendName,
            flag: "supportsParallelToolCalls"
        )

        BackendContractChecks.assertCapabilityMetaContract(
            capabilityClaimRegistry,
            backendName: backendName,
            capabilities: OllamaBackend().capabilities
        )
    }
}
