#if MLX
import XCTest
@testable import BaseChatBackends
@testable import BaseChatInference

/// Unit tests for ``MLXBackend/produceManifest(at:detectedThinkingMarkers:supportsVision:)``.
///
/// These tests don't load real MLX weights — they construct a temporary
/// directory with a synthetic `config.json` and assert the probe extracts the
/// right context window. The Metal-bound path (real `loadContainer`) lives in
/// `BaseChatMLXIntegrationTests` and is hardware-gated.
final class MLXManifestProbeTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-manifest-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
        }
        return dir
    }

    private func writeConfig(_ json: [String: Any], in dir: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [])
        try data.write(to: dir.appendingPathComponent("config.json"))
    }

    // MARK: - Context window extraction

    func test_extractsTopLevelMaxPositionEmbeddings() throws {
        let dir = try makeTempDir()
        try writeConfig([
            "model_type": "qwen3",
            "max_position_embeddings": 32_768,
        ], in: dir)

        let manifest = MLXBackend.produceManifest(
            at: dir,
            detectedThinkingMarkers: nil,
            supportsVision: false
        )

        XCTAssertEqual(manifest.contextWindow, 32_768)
        XCTAssertEqual(manifest.modelIdentifier, dir.lastPathComponent)
        XCTAssertEqual(manifest.producerKind, .local)
        XCTAssertFalse(manifest.supportsThinking,
                       "supportsThinking must be false when no markers are detected")
    }

    func test_extractsNestedTextConfigMaxPositionEmbeddings() throws {
        let dir = try makeTempDir()
        try writeConfig([
            "model_type": "gemma4",
            "text_config": [
                "max_position_embeddings": 131_072,
            ] as [String: Any],
        ], in: dir)

        let manifest = MLXBackend.produceManifest(
            at: dir,
            detectedThinkingMarkers: nil,
            supportsVision: false
        )
        XCTAssertEqual(manifest.contextWindow, 131_072,
                       "text_config.max_position_embeddings must be preferred over the top-level value")
    }

    func test_textConfigWinsOverTopLevel_whenBothPresent() throws {
        let dir = try makeTempDir()
        try writeConfig([
            "model_type": "vlm-test",
            "max_position_embeddings": 4096,
            "text_config": [
                "max_position_embeddings": 200_000,
            ] as [String: Any],
        ], in: dir)

        let manifest = MLXBackend.produceManifest(
            at: dir,
            detectedThinkingMarkers: nil,
            supportsVision: true
        )
        XCTAssertEqual(manifest.contextWindow, 200_000,
                       "text_config wins so VLM/MoE configs reflect the text-encoder window, not the (smaller) image-encoder window")
    }

    func test_fallsBackToModelMaxLength_whenMaxPositionAbsent() throws {
        let dir = try makeTempDir()
        try writeConfig([
            "model_type": "legacy-mlx",
            "model_max_length": 16_384,
        ], in: dir)

        let manifest = MLXBackend.produceManifest(
            at: dir,
            detectedThinkingMarkers: nil,
            supportsVision: false
        )
        XCTAssertEqual(manifest.contextWindow, 16_384)
    }

    func test_returnsUnknownDefaults_whenConfigJsonMissing() throws {
        let dir = try makeTempDir()
        // No config.json written.

        let manifest = MLXBackend.produceManifest(
            at: dir,
            detectedThinkingMarkers: nil,
            supportsVision: false
        )
        XCTAssertEqual(manifest.contextWindow, 8192,
                       "Missing config.json must fall back to the conservative 8k default")
        XCTAssertFalse(manifest.supportsThinking)
        XCTAssertFalse(manifest.supportsTools,
                       "ModelManifest.unknown reports no tool support")
    }

    func test_fallsBackTo8k_whenNoContextHintFound() throws {
        let dir = try makeTempDir()
        try writeConfig([
            "model_type": "minimal",
        ], in: dir)

        let manifest = MLXBackend.produceManifest(
            at: dir,
            detectedThinkingMarkers: nil,
            supportsVision: false
        )
        XCTAssertEqual(manifest.contextWindow, 8192,
                       "Configs without max_position_embeddings / model_max_length must fall back to 8k")
    }

    // MARK: - Thinking marker plumbing

    func test_carriesDetectedThinkingMarkers() throws {
        let dir = try makeTempDir()
        try writeConfig([
            "model_type": "qwen3",
            "max_position_embeddings": 32_768,
        ], in: dir)

        let manifest = MLXBackend.produceManifest(
            at: dir,
            detectedThinkingMarkers: .qwen3,
            supportsVision: false
        )
        XCTAssertEqual(manifest.thinkingMarkers, .qwen3)
        XCTAssertTrue(manifest.supportsThinking,
                      "supportsThinking is implied by non-nil thinkingMarkers")
    }
}
#endif
