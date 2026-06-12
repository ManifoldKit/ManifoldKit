#if MLX
import XCTest
import ManifoldInference
import ManifoldTestSupport
import ManifoldBackendTestKit
@_spi(Testing) import ManifoldMLX

/// MLX participant for the local-backend contract suite.
///
/// Moves to manifold-mlx with the backend (#1749). Scenario implementations
/// live in ``ManifoldBackendTestKit/LocalBackendContractRunner``.
///
/// The `makeBackend` factory creates an `MLXBackend` in its initial
/// unconfigured state — no real model is loaded. This is intentional:
/// the `isGenerating == false on init` invariant and the `capabilities`
/// snapshot checks do not require a model. Scenarios that call `generate()`
/// are gated behind `RUN_SLOW_TESTS=1` so they only run in the nightly tier
/// where a real model is present.
///
/// `MLXBackend.capabilities` before any `loadModel` call falls back to
/// the 8192-token conservative context default, which is reflected in the
/// participant's `capabilities` snapshot below.
final class MLXLocalBackendContractTests: XCTestCase {

    private static let participant = LocalBackendContractParticipant(
        label: "mlx.backend",
        fixtureDirectory: "mlx",
        capabilities: BackendCapabilities(
            supportedParameters: [
                .temperature, .topP, .topK, .repeatPenalty,
                .minP, .repetitionPenalty, .presencePenalty, .frequencyPenalty,
            ],
            maxContextTokens: 8192,
            requiresPromptTemplate: false,
            supportsSystemPrompt: true,
            supportsToolCalling: true,
            supportsStructuredOutput: false,
            supportsNativeJSONMode: false,
            cancellationStyle: .cooperative,
            supportsTokenCounting: true,
            memoryStrategy: .resident,
            maxOutputTokens: 4096,
            supportsStreaming: true,
            isRemote: false,
            supportsKVCachePersistence: false,
            supportsThinking: true,
            supportsVision: false,
            sharesMLXProcessResources: true
        ),
        requiresSlowTests: true,
        makeBackend: {
            // No model loaded — factory returns the backend in its zero state.
            // Generation scenarios gate themselves behind RUN_SLOW_TESTS=1 and
            // Metal availability via the runner's hardware gate.
            MLXBackend()
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

/// Real-driver coverage + adapter-shape checks for the MLX generation driver.
/// Split out of the shared `LocalBackendRealDriverCoverageTest` /
/// `LocalInferenceAdapterSmokeTests` so the file can move to manifold-mlx.
final class MLXLocalDriverCoverageTests: XCTestCase {

    @MainActor
    func test_mlxDriverHasRealPathForEveryClaim() throws {
        let driver = MLXGenerationDriver()
        try LocalDriverCoverageChecks.assertCoverage(
            adapter: driver,
            sourceFileSuffix: "Sources/ManifoldMLX/MLX/MLXGenerationDriver.swift"
        )
    }

    @MainActor
    func test_mlxGenerationDriverConformsToProtocol() {
        let driver = MLXGenerationDriver()
        LocalDriverCoverageChecks.assertAdapterShape(driver, expectedName: "mlx.generation")
        XCTAssertTrue(
            driver.declaredCapabilities.sharesMLXProcessResources,
            "MLX driver must advertise shared process-global resources"
        )
    }
}
#endif
