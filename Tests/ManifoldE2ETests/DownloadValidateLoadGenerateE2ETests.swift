import Testing
import Foundation
import ManifoldRuntime
import ManifoldPersistenceSwiftData
@testable import ManifoldInference
import ManifoldTestSupport
#if HuggingFace
@testable import ManifoldHuggingFace

/// E2E test chaining the full model lifecycle: download files to disk,
/// validate them, load via a backend, and generate tokens.
///
/// Uses the real filesystem (temp directories) and `MockInferenceBackend`
/// so the test runs without hardware but exercises the real validation path.
@Suite("Download -> Validate -> Load -> Generate E2E")
@MainActor
struct DownloadValidateLoadGenerateE2ETests {

    private let fm = FileManager.default
    private let manager = BackgroundDownloadManager()

    // MARK: - Helpers

    /// Writes a valid GGUF file (correct magic + >1 MB) to the given directory.
    private func writeValidGGUF(in dir: URL, name: String = "test-model.gguf") throws -> URL {
        let url = dir.appendingPathComponent(name)
        var data = Data(ggufMagic)
        data.append(Data(repeating: 0xFF, count: 1_100_000))
        try data.write(to: url)
        return url
    }

    // MARK: - GGUF Lifecycle

    @Test("Full GGUF lifecycle: write -> validate -> load -> generate -> verify")
    func gguf_downloadValidateLoadGenerate() async throws {
        let dir = try makeE2ETempDir()
        defer { cleanupE2ETempDir(dir) }

        // 1. Write a valid GGUF file to disk.
        let modelURL = try writeValidGGUF(in: dir)

        // 2. Validate through the real pipeline.
        try manager.validateDownloadedFile(at: modelURL, modelType: .gguf)

        // 3. Load into mock backend and generate.
        let backend = MockInferenceBackend()
        backend.tokensToYield = ["Once", " upon", " a", " time"]

        #expect(!backend.isModelLoaded)
        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))
        #expect(backend.isModelLoaded)
        #expect(backend.loadModelCallCount == 1)

        // 4. Generate tokens.
        let config = GenerationConfig(temperature: 0.7, maxOutputTokens: 512)
        let output = try await collectTokens(backend.generate(
            prompt: "Tell me a story",
            systemPrompt: "You are a storyteller.",
            config: config
        ))

        // 5. Verify output and captured arguments.
        #expect(output == "Once upon a time")
        #expect(backend.generateCallCount == 1)
        #expect(backend.lastPrompt == "Tell me a story")
        #expect(backend.lastSystemPrompt == "You are a storyteller.")
        #expect(!backend.isGenerating)
    }

    @Test("Invalid GGUF file blocks the load step")
    func gguf_invalidFile_blocksLoad() throws {
        let dir = try makeE2ETempDir()
        defer { cleanupE2ETempDir(dir) }

        // Write a file with wrong magic bytes.
        let badModelURL = dir.appendingPathComponent("bad-model.gguf")
        var data = Data([0x00, 0x00, 0x00, 0x00])
        data.append(Data(repeating: 0xAA, count: 2_000_000))
        try data.write(to: badModelURL)

        // Validation rejects the file, so a real caller would never proceed to load.
        #expect(throws: HuggingFaceError.self) {
            try manager.validateDownloadedFile(at: badModelURL, modelType: .gguf)
        }
    }

    // MARK: - MLX Lifecycle

    @Test("Full MLX lifecycle: write directory -> validate -> load -> generate")
    func mlx_downloadValidateLoadGenerate() async throws {
        let dir = try makeE2ETempDir()
        defer { cleanupE2ETempDir(dir) }

        // 1. Simulate a downloaded MLX model directory.
        let mlxDir = dir.appendingPathComponent("test-model-mlx")
        try fm.createDirectory(at: mlxDir, withIntermediateDirectories: true)

        try Data("{\"model_type\":\"llama\"}".utf8)
            .write(to: mlxDir.appendingPathComponent("config.json"))
        try Data(repeating: 0xAB, count: 1_000)
            .write(to: mlxDir.appendingPathComponent("model.safetensors"))

        // 2. Validate through the real pipeline.
        try manager.validateDownloadedFile(at: mlxDir, modelType: .mlx)

        // 3. Load and generate.
        let backend = MockInferenceBackend()
        backend.tokensToYield = ["The", " answer", " is", " 42"]

        try await backend.loadModel(from: mlxDir, plan: .testStub(effectiveContextSize: 512))
        #expect(backend.isModelLoaded)

        let output = try await collectTokens(backend.generate(
            prompt: "What is the meaning of life?",
            systemPrompt: nil,
            config: GenerationConfig()
        ))

        #expect(output == "The answer is 42")
        #expect(backend.generateCallCount == 1)
    }

    // MARK: - Unload After Generate

    @Test("Full lifecycle with unload: load -> generate -> unload -> generate-after-unload fails")
    func fullLifecycleWithUnload() async throws {
        let dir = try makeE2ETempDir()
        defer { cleanupE2ETempDir(dir) }

        let modelURL = try writeValidGGUF(in: dir, name: "lifecycle-model.gguf")
        try manager.validateDownloadedFile(at: modelURL, modelType: .gguf)

        // Load and generate.
        let backend = MockInferenceBackend()
        backend.tokensToYield = ["Done"]

        try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))
        #expect(backend.isModelLoaded)

        let output = try await collectTokens(backend.generate(
            prompt: "Test",
            systemPrompt: nil,
            config: GenerationConfig()
        ))
        #expect(output == "Done")

        // Unload and verify cleanup.
        backend.unloadModel()
        #expect(!backend.isModelLoaded)
        #expect(!backend.isGenerating)
        #expect(backend.unloadCallCount == 1)

        // Generating after unload should throw InferenceError.inferenceFailure.
        #expect(throws: InferenceError.self) {
            _ = try backend.generate(
                prompt: "Should fail",
                systemPrompt: nil,
                config: GenerationConfig()
            )
        }
    }

    // MARK: - Sequential Load-Generate Cycles

    @Test("Multiple load -> generate -> unload cycles reuse the same backend")
    func multipleLoadGenerateCycles() async throws {
        let dir = try makeE2ETempDir()
        defer { cleanupE2ETempDir(dir) }

        let modelURL = try writeValidGGUF(in: dir, name: "multi-cycle.gguf")
        try manager.validateDownloadedFile(at: modelURL, modelType: .gguf)

        let backend = MockInferenceBackend()

        for cycle in 0..<3 {
            backend.tokensToYield = ["Cycle", " \(cycle)"]

            try await backend.loadModel(from: modelURL, plan: .testStub(effectiveContextSize: 512))
            #expect(backend.isModelLoaded)

            let output = try await collectTokens(backend.generate(
                prompt: "Cycle \(cycle)",
                systemPrompt: nil,
                config: GenerationConfig()
            ))
            #expect(output == "Cycle \(cycle)")

            backend.unloadModel()
            #expect(!backend.isModelLoaded)
        }

        #expect(backend.loadModelCallCount == 3)
        #expect(backend.generateCallCount == 3)
        #expect(backend.unloadCallCount == 3)
    }
}
#endif
