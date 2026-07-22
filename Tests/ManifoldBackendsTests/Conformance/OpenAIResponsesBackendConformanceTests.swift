import XCTest
import ManifoldInference
import ManifoldBackendTestKit
import ManifoldTestSupport
import ManifoldFoundation
import ManifoldOllama
import ManifoldCloudSaaS
import ManifoldCloudCore

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

    // Instance-scoped: XCTest instantiates a fresh test case per method, so
    // this registry starts empty for every method invocation. See
    // BackendContractChecks.ClaimRegistry.
    private let capabilityClaimRegistry = BackendContractChecks.ClaimRegistry()

    // MARK: - Universal invariants

    // Sabotage-evidence: assertAllInvariants trips on invariant 1 if init() sets isModelLoaded=true
    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants(makingBackend: { OpenAIResponsesBackend() })
    }

    // MARK: - Grammar fail-closed

    /// Runs the fail-closed grammar contract, recording the claim in
    /// `capabilityClaimRegistry`. Folded into `test_contract_allCapabilityClaims`
    /// (below): the meta-contract's declared-false requirement
    /// (`BackendContractChecks.failClosedContractFlags`) reads the same
    /// instance-scoped registry, and XCTest hands each method a fresh instance —
    /// so the claim must be recorded in the method that asserts the meta-contract.
    private func assertGrammarFailsClosed() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let baseURL = URL(string: "http://openai-responses-\(UUID().uuidString).test")!
        let responsesURL = baseURL.appendingPathComponent("v1/responses")
        MockURLProtocol.stub(url: responsesURL, response: .error(URLError(.cannotConnectToHost)))
        defer { MockURLProtocol.unstub(url: responsesURL) }

        try await BackendContractChecks.assertGrammarFailClosedContract(
            capabilityClaimRegistry,
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
    /// one method, threaded through one shared `capabilityClaimRegistry`
    /// instance, so the registry is built and verified within a single test-case
    /// lifetime. Historically necessary because the registry was process-global
    /// (#1601); now the registry is instance-scoped (arch-plan 4.2) and this
    /// suite is safe under `swift test --parallel` — the collapse remains as a
    /// readable, self-contained shape, not a correctness requirement. The
    /// grammar fail-closed assertion is folded in (see `assertGrammarFailsClosed`)
    /// because the meta-contract now requires a recorded claim for declared-false
    /// fail-closed flags.
    func test_contract_allCapabilityClaims() async throws {
        // Reset first — harmless given a freshly-constructed registry, kept
        // for symmetry with suites that build up several scenarios in one
        // test method.
        BackendContractChecks.resetCapabilityClaims(capabilityClaimRegistry, forBackend: backendName)

        try await assertGrammarFailsClosed()

        BackendContractChecks.claimWithoutBehaviouralAssertion(
            capabilityClaimRegistry,
            backendName: backendName,
            flag: "supportsToolCalling"
        )
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            capabilityClaimRegistry,
            backendName: backendName,
            flag: "supportsStructuredOutput"
        )
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            capabilityClaimRegistry,
            backendName: backendName,
            flag: "supportsThinking"
        )
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            capabilityClaimRegistry,
            backendName: backendName,
            flag: "streamsToolCallArguments"
        )
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            capabilityClaimRegistry,
            backendName: backendName,
            flag: "supportsParallelToolCalls"
        )

        BackendContractChecks.assertCapabilityMetaContract(
            capabilityClaimRegistry,
            backendName: backendName,
            capabilities: OpenAIResponsesBackend().capabilities
        )
    }
}
