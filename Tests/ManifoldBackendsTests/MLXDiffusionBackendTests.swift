#if MLX

import XCTest
import ManifoldBackends
@_spi(Testing) import ManifoldMLX
import ManifoldInference

/// Unit tests for ``MLXDiffusionBackend``.
///
/// These tests avoid real model weights — Metal shaders can't run in the
/// simulator and the XCTest runner can't access actual diffusion models. Tests
/// cover path-safe error surfaces and state-machine behaviour without touching
/// the MLX inference stack. Real E2E coverage lives in
/// ``MLXDiffusionIntegrationTests`` (Xcode-only, MANIFOLD_DISCOVER_LOCAL_MODELS).
final class MLXDiffusionBackendTests: XCTestCase {

    // MARK: - Initial state

    func test_isLoaded_initiallyFalse() {
        XCTAssertFalse(MLXDiffusionBackend().isLoaded)
    }

    func test_isGenerating_initiallyFalse() {
        XCTAssertFalse(MLXDiffusionBackend().isGenerating)
    }

    // MARK: - Error surfaces that don't require Metal

    func test_loadModel_emptyDirectory_throwsUnsupportedLayout() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "BCKTest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let backend = MLXDiffusionBackend()
        do {
            try await backend.loadModel(from: dir)
            XCTFail("Expected MLXDiffusionError.unsupportedModelLayout")
        } catch MLXDiffusionError.unsupportedModelLayout {
            // expected
        }
    }

    func test_loadModel_onlyVaeNoUnet_throwsUnsupportedLayout() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "BCKTest-\(UUID().uuidString)")
        // Has vae/ but no unet/ and no text_encoder_2/ → should throw
        let vaeDir = dir.appending(component: "vae")
        try FileManager.default.createDirectory(at: vaeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let backend = MLXDiffusionBackend()
        do {
            try await backend.loadModel(from: dir)
            XCTFail("Expected MLXDiffusionError.unsupportedModelLayout")
        } catch MLXDiffusionError.unsupportedModelLayout {
            // expected
        }
    }

    func test_generate_notLoaded_throwsNotLoaded() throws {
        let backend = MLXDiffusionBackend()
        XCTAssertFalse(backend.isLoaded)
        do {
            _ = try backend.generate(prompt: "a cat", config: .init())
            XCTFail("Expected MLXDiffusionError.notLoaded")
        } catch MLXDiffusionError.notLoaded {
            // expected
        }
    }

    // MARK: - State machine safety (no Metal required)

    func test_stopGeneration_whenIdle_doesNotCrash() {
        let backend = MLXDiffusionBackend()
        backend.stopGeneration()  // must not crash or deadlock
        XCTAssertFalse(backend.isGenerating)
    }

    func test_unloadModel_whenNotLoaded_doesNotCrash() {
        let backend = MLXDiffusionBackend()
        backend.unloadModel()  // must not crash
        XCTAssertFalse(backend.isLoaded)
    }

    // MARK: - Layout detection (SD 2.1 vs SDXL)

    func test_detectPreset_unetOnly_selectsSD21() throws {
        let dir = makeModelDir(withXLEncoder: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        // Test the layout-detection logic directly without going through
        // loadModel → textToImageGenerator, which triggers Metal/MLX
        // initialisation and fatally crashes if the metallib isn't compiled.
        let preset = try MLXDiffusionBackend.detectPreset(at: dir)
        XCTAssertTrue(preset.id.contains("stable-diffusion-2-1"),
                      "unet/ without text_encoder_2/ must select the SD 2.1 preset")
    }

    func test_detectPreset_textEncoder2_selectsSDXL() throws {
        let dir = makeModelDir(withXLEncoder: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let preset = try MLXDiffusionBackend.detectPreset(at: dir)
        XCTAssertTrue(preset.id.contains("sdxl"),
                      "text_encoder_2/ present must select the SDXL preset")
    }

    // MARK: - Sabotage check (documented in CLAUDE.md test conventions)
    //
    // To verify test_loadModel_emptyDirectory_throwsUnsupportedLayout is
    // truly testing the right thing, temporarily comment out the throw in
    // detectPreset and confirm the test fails. Restored before commit.

    // MARK: - Helpers

    private func makeModelDir(withXLEncoder: Bool) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(component: "BCKTest-\(UUID().uuidString)")
        let unetDir = dir.appending(component: "unet")
        try? FileManager.default.createDirectory(at: unetDir, withIntermediateDirectories: true)
        if withXLEncoder {
            let te2Dir = dir.appending(component: "text_encoder_2")
            try? FileManager.default.createDirectory(at: te2Dir, withIntermediateDirectories: true)
        }
        return dir
    }
}

#endif
