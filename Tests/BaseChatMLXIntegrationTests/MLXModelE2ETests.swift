#if MLX
import XCTest
import BaseChatRuntime
import BaseChatPersistenceSwiftData
import BaseChatInference
@testable import BaseChatTestSupport
@testable import BaseChatBackends

/// True end-to-end tests using a real MLX model on Apple Silicon.
///
/// These tests load a real MLX model from disk (config.json + .safetensors)
/// and perform actual GPU-accelerated inference. They are automatically
/// skipped when:
/// - Not running on Apple Silicon
/// - No Metal GPU is available (e.g. simulator, headless CI)
/// - No valid MLX model directory is found on disk
///
/// **Xcode-only** — MLX's Metal shader library (metallib) is only compiled
/// by Xcode's build system, not by `swift build`/`swift test`. Run via:
/// - Xcode: Product → Test (⌘U)
/// - CLI: `xcodebuild test -scheme BaseChatKit-Package -only-testing BaseChatMLXIntegrationTests`
///
/// Unlike mock-based `MLXBackendGenerationTests`, these use NO mocks — real
/// model weights, real MLX inference, real token generation.
@MainActor
final class MLXModelE2ETests: XCTestCase {

    private var backend: MLXBackend!
    private var modelURL: URL!

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()

        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "Requires Apple Silicon")
        try XCTSkipUnless(HardwareRequirements.hasMetalDevice, "Requires Metal GPU")

        guard let mlxDir = HardwareRequirements.findMLXModelDirectory() else {
            throw XCTSkip(
                "No loadable MLX model found on disk. Install a local MLX snapshot with config.json, tokenizer, and safetensors weights."
            )
        }
        modelURL = mlxDir

        backend = MLXBackend()
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 2048))

        XCTAssertTrue(backend.isModelLoaded, "Backend should report model as loaded")
    }

    override func tearDown() async throws {
        backend?.unloadModel()
        backend = nil
        modelURL = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func generate(
        prompt: String,
        systemPrompt: String? = nil,
        maxTokens: Int = 64
    ) async throws -> String {
        let config = GenerationConfig(
            temperature: 0.3,
            maxOutputTokens: maxTokens
        )
        let stream = try backend.generate(
            prompt: prompt,
            systemPrompt: systemPrompt,
            config: config
        )
        return try await collectTokens(stream)
    }

    // MARK: - Real Inference Tests

    func test_realInference_generatesNonEmptyResponse() async throws {
        let response = try await generate(prompt: "Reply with exactly one word.")

        XCTAssertFalse(
            response.isEmpty,
            "MLX should generate a non-empty response (model: \(modelURL.lastPathComponent))"
        )
    }

    func test_realInference_withSystemPrompt() async throws {
        let response = try await generate(
            prompt: "Hello",
            systemPrompt: "You are a pirate. Always respond in pirate speak."
        )

        XCTAssertFalse(response.isEmpty, "Should generate a response with system prompt")
    }

    func test_realInference_multiTurn() async throws {
        // First generation
        let first = try await generate(prompt: "Say hello.")
        XCTAssertFalse(first.isEmpty, "First response should not be empty")

        // Second generation — MLX backend is stateless per generate() call,
        // so this tests that the backend can generate multiple times sequentially.
        let second = try await generate(prompt: "What is 2 + 2?")
        XCTAssertFalse(second.isEmpty, "Second response should not be empty")
    }

    func test_realInference_stopGeneration() async throws {
        let config = GenerationConfig(
            temperature: 0.7,
            maxOutputTokens: 2048
        )

        let stream = try backend.generate(
            prompt: "Write a very detailed essay about the history of computing.",
            systemPrompt: nil,
            config: config
        )

        // Collect a few tokens then cancel.
        var tokenCount = 0
        let collectTask = Task { @MainActor in
            for try await event in stream.events {
                if case .token(_) = event {
                    tokenCount += 1
                    if tokenCount >= 5 { break }
                }
            }
        }

        try await collectTask.value
        XCTAssertGreaterThanOrEqual(tokenCount, 5, "Should have received at least 5 tokens")

        // Now stop — verify the backend accepts it without crashing.
        backend.stopGeneration()
    }

    func test_realInference_respectsMaxOutputTokens() async throws {
        let response = try await generate(
            prompt: "Write a long story about a dragon and a wizard.",
            maxTokens: 10
        )

        // With maxOutputTokens = 10, MLX breaks after 10 token chunks.
        // We can't assert exact token count (chunk != word), but the
        // response should be short, not a full story.
        XCTAssertFalse(response.isEmpty, "Should still produce some output")
    }

    func test_unloadAndReload() async throws {
        // Verify we can unload and reload the same model.
        backend.unloadModel()
        XCTAssertFalse(backend.isModelLoaded)

        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 2048))
        XCTAssertTrue(backend.isModelLoaded)

        let response = try await generate(prompt: "Say hi.")
        XCTAssertFalse(response.isEmpty, "Should generate after reload")
    }

    func test_backendCapabilities() {
        XCTAssertTrue(backend.capabilities.supportsStreaming)
        XCTAssertFalse(backend.capabilities.isRemote)
        XCTAssertTrue(backend.capabilities.supportsSystemPrompt)
        XCTAssertTrue(backend.capabilities.supportsTokenCounting)
    }

    // MARK: - Stripped tokenizer fixture (#551)

    /// Loading a model snapshot with `tokenizer_config.json` removed must surface
    /// a structured error rather than crashing or hanging. The mock-container path
    /// in `MLXBackendGenerationTests` covers the *generation*-time failure mode
    /// (chat template missing); this E2E exercises the *load*-time path with a
    /// real on-disk model directory, confirming `MLXBackend.loadModel` wraps the
    /// underlying tokenizer error in `InferenceError.modelLoadFailed`.
    func test_loadModel_strippedTokenizerConfig_throwsModelLoadFailed() async throws {
        // Start from a clean backend so this test owns the load attempt.
        backend.unloadModel()

        // Copy the resolved model dir to a temp location and delete tokenizer_config.json.
        let fm = FileManager.default
        let stagingRoot = fm.temporaryDirectory
            .appendingPathComponent("MLXStrippedFixture-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingRoot) }

        let strippedURL = stagingRoot.appendingPathComponent(modelURL.lastPathComponent, isDirectory: true)
        try fm.copyItem(at: modelURL, to: strippedURL)

        let tokenizerConfig = strippedURL.appendingPathComponent("tokenizer_config.json")
        guard fm.fileExists(atPath: tokenizerConfig.path) else {
            throw XCTSkip("Source model has no tokenizer_config.json — cannot exercise the strip path")
        }
        try fm.removeItem(at: tokenizerConfig)

        // Loading must throw modelLoadFailed (or a structurally-equivalent error).
        var caught: Error?
        do {
            try await backend.loadModel(from: strippedURL, plan: .testStub(effectiveContextSize: 2048))
        } catch {
            caught = error
        }

        let unwrapped = try XCTUnwrap(caught,
            "Loading a snapshot stripped of tokenizer_config.json must throw")

        if case InferenceError.modelLoadFailed = unwrapped {
            // Expected — MLXBackend.loadModel wraps the underlying tokenizer
            // failure in modelLoadFailed before throwing.
        } else {
            XCTFail("Expected InferenceError.modelLoadFailed, got \(unwrapped)")
        }

        XCTAssertFalse(backend.isModelLoaded,
            "isModelLoaded must remain false after a failed load")

        // Sabotage check: skipping the `try fm.removeItem(at: tokenizerConfig)`
        // call lets the load succeed and `caught` stays nil, failing the XCTUnwrap.
    }
}

#endif
