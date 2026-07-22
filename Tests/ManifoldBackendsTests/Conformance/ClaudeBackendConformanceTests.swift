import XCTest
import ManifoldInference
import ManifoldBackendTestKit
import ManifoldTestSupport
import ManifoldFoundation
import ManifoldOllama
import ManifoldCloudSaaS
import ManifoldCloudCore

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

    // Instance-scoped: XCTest instantiates a fresh test case per method, so
    // this registry starts empty for every method invocation. See
    // BackendContractChecks.ClaimRegistry.
    private let capabilityClaimRegistry = BackendContractChecks.ClaimRegistry()

    // MARK: - Universal invariants

    // Sabotage-evidence: assertAllInvariants trips on invariant 1 if init() sets isModelLoaded=true
    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants(makingBackend: { ClaudeBackend() })
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
        let baseURL = URL(string: "http://claude-\(UUID().uuidString).test")!
        let messagesURL = baseURL.appendingPathComponent("v1/messages")
        MockURLProtocol.stub(url: messagesURL, response: .error(URLError(.cannotConnectToHost)))
        defer { MockURLProtocol.unstub(url: messagesURL) }

        try await BackendContractChecks.assertGrammarFailClosedContract(
            capabilityClaimRegistry,
            backendName: backendName,
            makingBackend: {
                let backend = ClaudeBackend(urlSession: URLSession(configuration: sessionConfig))
                backend.configure(
                    baseURL: baseURL,
                    apiKey: "sk-ant-test",
                    modelName: "claude-sonnet-4-20250514"
                )
                return backend
            },
            forbiddenRequestURL: messagesURL
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
    ///
    /// `ClaudeBackend.capabilities.supportsThinking` is derived from
    /// ``ModelManifest`` via ``CloudModelManifestTable/claude(modelName:)``.
    /// Default model `claude-sonnet-4-20250514` is a 4-class extended-thinking
    /// model. The behavioural assertion that proves Claude emits `.thinkingToken`
    /// events lives in `ClaudeThinkingErrorPathTests` / `CloudThinkingTokenTests`;
    /// this claim records the meta-contract obligation. The grammar fail-closed
    /// assertion is folded in (see `assertGrammarFailsClosed`) because the
    /// meta-contract now requires a recorded claim for declared-false fail-closed
    /// flags.
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
            flag: "supportsVision"
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
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            capabilityClaimRegistry,
            backendName: backendName,
            flag: "supportsThinking"
        )

        BackendContractChecks.assertCapabilityMetaContract(
            capabilityClaimRegistry,
            backendName: backendName,
            capabilities: ClaudeBackend().capabilities
        )
    }
}
