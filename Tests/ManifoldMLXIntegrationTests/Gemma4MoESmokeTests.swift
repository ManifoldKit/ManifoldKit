#if MLX
import XCTest
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends
@testable import ManifoldMLX

/// Real-inference smoke test for `mlx-community/gemma-4-26b-a4b-it-4bit`,
/// the 26B Mixture-of-Experts Gemma 4 variant. Validates the VLM-factory
/// routing added in PR #769 (closes #752): the model has
/// `text_config.enable_moe_block: true`, so `MLXModelProbe.requiresVLMFactory`
/// should send it to `VLMModelFactory.shared.loadContainer` rather than the
/// LLM factory's no-MoE `Gemma4Model`.
///
/// Skipped automatically when the 15 GB weights aren't on disk at the
/// expected namespaced path.
@MainActor
final class Gemma4MoESmokeTests: XCTestCase {

    private static let modelRelativePath = "Models/mlx-community/gemma-4-26b-a4b-it-4bit"

    private var backend: MLXBackend!
    private var modelURL: URL!

    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "Requires Apple Silicon")
        try XCTSkipUnless(HardwareRequirements.hasMetalDevice, "Requires Metal GPU")

        let docs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first!
        let candidate = docs.appendingPathComponent(Self.modelRelativePath, isDirectory: true)
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: candidate.appendingPathComponent("config.json").path),
            "Gemma 4 26B MoE model not found at \(candidate.path) — skipping"
        )
        modelURL = candidate

        // Sanity: the routing helper must agree with the on-disk config.
        XCTAssertTrue(
            MLXModelProbe.requiresVLMFactory(at: modelURL),
            "requiresVLMFactory should return true for the 26B MoE config"
        )

        backend = MLXBackend()
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 2048))
        XCTAssertTrue(backend.isModelLoaded, "Backend should report model loaded")
    }

    override func tearDown() async throws {
        backend?.unloadModel()
        backend = nil
        modelURL = nil
        try await super.tearDown()
    }

    func test_loadAndGenerate_producesNonEmptyResponse() async throws {
        // FIXME: https://github.com/roryford/ManifoldKit/issues/802
        // Upstream mlx-swift-lm 3.31.3 crashes with a fatal C++ broadcast-shape
        // error ([broadcast_shapes] Shapes (20) and (39) cannot be broadcast)
        // on the first generate call for this MoE model. The abort fires inside
        // MLX's C++ runtime and cannot be caught by XCTExpectFailure, so we
        // skip the inference step until the upstream fix lands.
        throw XCTSkip("Skipped pending upstream mlx-swift-lm fix for Gemma4 MoE broadcast crash (issue #802)")

        let config = GenerationConfig(temperature: 0.3, maxOutputTokens: 32)
        let stream = try backend.generate(
            prompt: "Reply with exactly one word.",
            systemPrompt: nil,
            config: config
        )
        let response = try await collectTokens(stream)

        XCTAssertFalse(response.isEmpty, "MoE Gemma 4 should produce a response")
    }
}
#endif
