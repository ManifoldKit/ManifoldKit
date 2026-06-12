#if Llama
import XCTest
import ManifoldInference
import ManifoldTestSupport
import ManifoldBackendTestKit
import ManifoldLlama

/// Llama participant for the local-backend contract suite.
///
/// Moves to manifold-llama with the backend (#1749). Scenario implementations
/// live in ``ManifoldBackendTestKit/LocalBackendContractRunner``.
///
/// The `makeBackend` factory creates a `LlamaBackend` in its initial
/// unconfigured state — no model loaded and no `llama_backend_init` call
/// triggered. This is intentional: the `isGenerating == false on init`
/// invariant and the `capabilities` snapshot checks do not require a model.
/// Scenarios that call `generate()` are gated behind `RUN_SLOW_TESTS=1` and
/// a Metal-availability check.
///
/// The `maxContextTokens: 4096` value mirrors the default `_effectiveContextSize`
/// set at `LlamaBackend.init()` before any model is loaded.
final class LlamaLocalBackendContractTests: XCTestCase {

    private static let participant = LocalBackendContractParticipant(
        label: "llama.backend",
        fixtureDirectory: "llama",
        capabilities: BackendCapabilities(
            supportedParameters: [
                .temperature, .topP, .topK, .repeatPenalty,
                .minP, .repetitionPenalty, .presencePenalty, .frequencyPenalty,
                .llamaDRY, .llamaXTC, .llamaMirostatV2,
            ],
            maxContextTokens: 4096,
            requiresPromptTemplate: true,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: false,
            supportsNativeJSONMode: false,
            cancellationStyle: .explicit,
            supportsTokenCounting: true,
            memoryStrategy: .mappable,
            maxOutputTokens: 4096,
            supportsStreaming: true,
            isRemote: false,
            supportsKVCachePersistence: true,
            supportsGrammarConstrainedSampling: true,
            supportsThinking: true,
            supportsVision: false
        ),
        requiresSlowTests: true,
        makeBackend: {
            // No model loaded — factory returns the backend in its zero state.
            // Generation scenarios gate themselves behind RUN_SLOW_TESTS=1 and
            // Metal availability via the runner's hardware gate.
            LlamaBackend()
        }
    )

    func test_generate_simplePrompt_emitsTokensInOrder() async throws {
        try await LocalBackendContractRunner.assertSimplePromptEmitsTokensInOrder(
            participant: Self.participant,
            fixturesRoot: LocalBackendContractRunner.locateFixturesRoot()
        )
    }

    func test_generate_stopsGenerating_afterStreamEnd() async throws {
        try await LocalBackendContractRunner.assertStopsGeneratingAfterStreamEnd(
            participant: Self.participant
        )
    }

    func test_capabilityGate_disclaimedRequirementThrows() async {
        await LocalBackendContractRunner.assertCapabilityGateDisclaimedRequirementThrows(
            participant: Self.participant
        )
    }
}

/// Real-driver coverage + adapter-shape checks for the Llama generation driver.
/// Split out of the shared `LocalBackendRealDriverCoverageTest` /
/// `LocalInferenceAdapterSmokeTests` so the file can move to manifold-llama.
final class LlamaLocalDriverCoverageTests: XCTestCase {

    func test_llamaDriverHasRealPathForEveryClaim() throws {
        let driver = LlamaGenerationDriver()
        try LocalDriverCoverageChecks.assertCoverage(
            adapter: driver,
            sourceFileSuffix: "Sources/ManifoldLlama/LlamaGenerationDriver.swift"
        )
    }

    func test_llamaGenerationDriverConformsToProtocol() {
        let driver = LlamaGenerationDriver()
        LocalDriverCoverageChecks.assertAdapterShape(driver, expectedName: "llama.generation")
    }
}
#endif
