#if MLX
import XCTest
import ManifoldInference
@testable import ManifoldTestSupport
@testable import ManifoldBackends
@testable import ManifoldMLX  // MLXModelProbe is internal to ManifoldMLX, not re-exported by the umbrella

/// Hardware-gated end-to-end tests for MLX VLM vision inference.
///
/// Exercises the full `MLXBackend` + `VLMModelFactory` pipeline using a real
/// locally-installed VLM (e.g. `llava-1.5-7b-hf`). Every test in this suite
/// skips cleanly in CI and on machines where the `MLX_VLM` fixture slot is
/// absent from the manifest.
///
/// # Local setup
///
/// 1. Download any MLX Vision-Language Model snapshot (models with a
///    `vision_config` in `config.json` — e.g. LLaVA, Phi-3.5-Vision, Qwen2-VL).
/// 2. Place it under `~/Documents/Models/` or any location of your choice.
/// 3. Add a `MLX_VLM` slot to the test manifest:
///
///    ```bash
///    mkdir -p ~/Library/Caches/ManifoldKit/test-models
///    # Edit (or create) manifest.json to contain:
///    # { "slots": { "MLX_VLM": "/path/to/your/vlm-model-directory" } }
///    ```
///
/// 4. Run with:
///
///    ```bash
///    swift test --traits MLX --filter ManifoldE2ETests/VisionE2ETests
///    ```
///
/// # Why VLMs need Metal
///
/// MLX model loading requires Metal shader compilation from `.metallib` files
/// embedded in the Xcode framework bundle. `swift test` (SwiftPM) does not
/// produce a `.app` bundle, so running *any* MLX inference is not possible via
/// plain `swift test`. Use `scripts/test-mlx-integration.sh` for an Xcode-
/// hosted run, or rely on the `MLX_VLM` manifest guard to skip cleanly during
/// `swift test` invocations (the model URL check happens before `loadModel`).
///
/// # Fixture slot
///
/// The `MLX_VLM` slot in `~/Library/Caches/ManifoldKit/test-models/manifest.json`
/// must point to a directory that satisfies `HardwareRequirements.isValidMLXDirectory`
/// and whose `config.json` contains a `vision_config` key (or sets
/// `text_config.enable_moe_block`) — otherwise `MLXModelProbe.requiresVLMFactory`
/// returns `false` and the test skips with a clear message.
@MainActor
final class VisionE2ETests: XCTestCase {

    // MLX backends should not be shared across tests because `unloadModel()`
    // schedules async GPU teardown. Each test creates its own backend and the
    // `tearDown` drains it before the next test claims GPU resources.
    private var backend: MLXBackend!
    private var modelURL: URL!

    // MARK: - Setup / Teardown

    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(
            HardwareRequirements.isAppleSilicon,
            "MLXBackend requires Apple Silicon (arm64)"
        )
        try XCTSkipUnless(
            HardwareRequirements.hasMetalDevice,
            "MLXBackend requires a Metal GPU (headless / SSH sessions without GPU context will skip)"
        )

        guard let url = Self.locateVLMModelDirectory() else {
            throw XCTSkip(
                "No VLM fixture found. Add a 'MLX_VLM' slot to "
                + "~/Library/Caches/ManifoldKit/test-models/manifest.json "
                + "pointing at an MLX VLM directory (e.g. llava-1.5-7b-hf). "
                + "See Tests/ManifoldE2ETests/README.md for the full setup guide."
            )
        }

        try XCTSkipUnless(
            MLXModelProbe.requiresVLMFactory(at: url),
            "MLX_VLM slot '\(url.lastPathComponent)' does not appear to be a VLM "
            + "(requiresVLMFactory returned false — config.json lacks vision_config "
            + "or text_config.enable_moe_block). Swap in a real VLM directory."
        )

        modelURL = url
        backend = MLXBackend()
    }

    override func tearDown() async throws {
        if let backend {
            backend.unloadModel()
        }
        backend = nil
        modelURL = nil
        try await super.tearDown()
    }

    // MARK: - Fixture discovery

    /// Reads the `MLX_VLM` slot from the test manifest.
    ///
    /// Returns `nil` when:
    /// - The manifest file does not exist.
    /// - The `MLX_VLM` slot is absent, `null`, or an empty string.
    /// - The path does not resolve to a directory that satisfies
    ///   `HardwareRequirements.isValidMLXDirectory`.
    private static func locateVLMModelDirectory() -> URL? {
        let manifestURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(components: "Library", "Caches", "ManifoldKit", "test-models", "manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let slots = json["slots"] as? [String: Any?],
              let pathValue = slots["MLX_VLM"] as? String,
              !pathValue.isEmpty
        else { return nil }

        let url = URL(fileURLWithPath: (pathValue as NSString).expandingTildeInPath)
        guard HardwareRequirements.isValidMLXDirectory(url) else { return nil }
        return url
    }

    // MARK: - Helpers

    /// Convenience: set structured history with a user message containing image bytes,
    /// then generate and collect the full visible text response.
    private func generateWithImage(
        imageData: Data,
        mimeType: String = "image/png",
        textPrompt: String,
        maxOutputTokens: Int = 128
    ) async throws -> String {
        // VLM backends consume multimodal input via StructuredHistoryReceiver:
        // the image bytes ride in a MessagePart.image part alongside the text prompt.
        let userMessage = StructuredMessage(
            role: "user",
            parts: [
                .image(data: imageData, mimeType: mimeType),
                .text(textPrompt),
            ]
        )
        backend.setStructuredHistory([userMessage])

        let config = GenerationConfig(
            temperature: 0.0,
            maxOutputTokens: maxOutputTokens,
            maxThinkingTokens: 0
        )
        let stream = try backend.generate(prompt: "", systemPrompt: nil, config: config)
        return try await collectTokens(stream)
    }

    // MARK: - Tests

    /// Verifies that the VLM backend advertises `supportsVision = true` after
    /// `loadModel` is called against a real VLM directory.
    ///
    /// This is the minimal smoke test — it does not require actual GPU inference
    /// because it asserts a synchronously-readable capability flag that is set
    /// at load time by `MLXModelProbe`. If this fails, the model directory does
    /// not contain a recognised VLM architecture.
    ///
    /// # Why we load the model here
    ///
    /// `supportsVision` is computed by `BackendVisionCapability.mlxSupportsImageInput`
    /// from the `ModelCapabilityProbe` result produced inside `loadModel`. A backend
    /// constructed but never loaded always reports `supportsVision = false`.
    func test_vlm_afterLoad_supportsVisionIsTrue() async throws {
        // loadModel requires a real Metal runtime. This test will hard-fail
        // (not skip) when the metallib is missing — see the suite-level
        // `hasMetalDevice` gate in setUp which prevents reaching this point
        // without a valid GPU context.
        try await backend.loadModel(
            from: modelURL,
            plan: .testStub(effectiveContextSize: 2048)
        )

        XCTAssertTrue(
            backend.capabilities.supportsVision,
            "An MLX VLM must report supportsVision = true after a successful loadModel "
            + "(model: \(modelURL.lastPathComponent))"
        )
    }

    /// Sends a real image attachment through the VLM and verifies that a
    /// non-empty text response is produced.
    ///
    /// Uses the bundled 1×1 PNG from `ImageFixtures` — a minimal but fully
    /// valid PNG that any VLM can process without model-specific fixtures.
    /// Assertions are deliberately loose (non-empty response) because the
    /// exact caption depends on the model and its sampling seed.
    ///
    /// # Sabotage evidence
    ///
    /// Removing `.image(data:mimeType:)` from the `MessagePart` array and
    /// replacing it with `.text("<image>")` would cause VLMs that gate on
    /// the presence of real pixel data (e.g. Phi-3.5-Vision) to return an
    /// empty stream or an error, failing the `XCTAssertFalse(response.isEmpty)`
    /// assertion below. On some models the response will be non-empty but
    /// will describe "no image provided" — a clear regression signal.
    func test_vlm_imagePrompt_generatesNonEmptyResponse() async throws {
        try await backend.loadModel(
            from: modelURL,
            plan: .testStub(effectiveContextSize: 2048)
        )

        let response = try await generateWithImage(
            imageData: ImageFixtures.oneByOnePNGData,
            textPrompt: "Describe this image in one sentence."
        )

        XCTAssertFalse(
            response.isEmpty,
            "VLM must produce a non-empty response to an image prompt "
            + "(model: \(modelURL.lastPathComponent))"
        )
    }

    /// Verifies that running two sequential image prompts on the same loaded
    /// backend does not crash. This guards the VLM-specific KV-cache clearing
    /// path in `MLXGenerationDriver` — reuse is currently gated off for VLMs
    /// (see `MLXVLMGateExperimentTests`) but the second call must still
    /// complete cleanly.
    func test_vlm_consecutiveImagePrompts_doesNotCrash() async throws {
        try await backend.loadModel(
            from: modelURL,
            plan: .testStub(effectiveContextSize: 2048)
        )

        let firstResponse = try await generateWithImage(
            imageData: ImageFixtures.oneByOnePNGData,
            textPrompt: "What colour is this image?"
        )
        XCTAssertFalse(
            firstResponse.isEmpty,
            "First VLM call must return a non-empty response "
            + "(model: \(modelURL.lastPathComponent))"
        )

        let secondResponse = try await generateWithImage(
            imageData: ImageFixtures.oneByOnePNGData,
            textPrompt: "Is there anything in this image?"
        )
        XCTAssertFalse(
            secondResponse.isEmpty,
            "Second consecutive VLM call must not crash and must return a "
            + "non-empty response (model: \(modelURL.lastPathComponent))"
        )
    }
}
#endif
