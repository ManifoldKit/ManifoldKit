#if CloudSaaS
import XCTest
import ManifoldInference
import ManifoldTestSupport
@testable import ManifoldBackends

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

    // MARK: - Universal invariants

    // Sabotage-evidence: assertAllInvariants trips on invariant 1 if init() sets isModelLoaded=true
    func test_contract_allInvariants() {
        BackendContractChecks.assertAllInvariants(makingBackend: { ClaudeBackend() })
    }

    // MARK: - Grammar fail-closed

    func test_contract_grammarFailClosed() async throws {
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.protocolClasses = [MockURLProtocol.self]
        let baseURL = URL(string: "http://claude-\(UUID().uuidString).test")!
        let messagesURL = baseURL.appendingPathComponent("v1/messages")
        MockURLProtocol.stub(url: messagesURL, response: .error(URLError(.cannotConnectToHost)))
        defer { MockURLProtocol.unstub(url: messagesURL) }

        try await BackendContractChecks.assertGrammarFailClosedContract(
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
    /// one method so the registry is built and verified within a single process.
    /// Under `swift test --parallel` each test method runs in an isolated worker
    /// process; splitting claim recording across several methods meant the
    /// meta-contract reader saw an empty registry in its worker. (#1601)
    ///
    /// `ClaudeBackend.capabilities.supportsThinking` is derived from
    /// ``ModelManifest`` via ``CloudModelManifestTable/claude(modelName:)``.
    /// Default model `claude-sonnet-4-20250514` is a 4-class extended-thinking
    /// model. The behavioural assertion that proves Claude emits `.thinkingToken`
    /// events lives in `ClaudeThinkingErrorPathTests` / `CloudThinkingTokenTests`;
    /// this claim records the meta-contract obligation.
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
        BackendContractChecks.claimWithoutBehaviouralAssertion(
            backendName: backendName,
            flag: "supportsThinking"
        )

        BackendContractChecks.assertCapabilityMetaContract(
            backendName: backendName,
            capabilities: ClaudeBackend().capabilities
        )
    }
}
#endif
