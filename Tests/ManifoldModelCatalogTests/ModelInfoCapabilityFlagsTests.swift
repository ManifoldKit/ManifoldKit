import XCTest
import ManifoldInference
@testable import ManifoldModelCatalog

/// Verifies the override-over-detected resolution model for the three
/// ``ModelInfo`` capability flags (code / multilingual / reasoning), the GGUF
/// `configNotFound` fallback (no throw, curated-or-false), cloud reasoning
/// detection from ``CloudModelManifestTable``, and catalog round-trip
/// persistence of the flags.
final class ModelInfoCapabilityFlagsTests: XCTestCase {

    // MARK: - Helpers

    private func makeModel() -> ModelInfo {
        ModelInfo(
            name: "Test",
            fileName: "test.gguf",
            url: URL(fileURLWithPath: "/tmp/test.gguf"),
            fileSize: 1024,
            modelType: .gguf
        )
    }

    private func makeFixtureDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelInfoCapabilityFlagsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: - Resolution: curated ?? detected ?? false

    func testResolution_defaultsToFalse() {
        let model = makeModel()
        XCTAssertFalse(model.supportsCode)
        XCTAssertFalse(model.supportsMultilingual)
        XCTAssertFalse(model.supportsReasoning)
    }

    func testResolution_detectedWinsOverDefault() {
        var model = makeModel()
        model.detectedSupportsCode = true
        XCTAssertTrue(model.supportsCode, "detected true should resolve true with no override")
    }

    func testResolution_curatedOverridesDetected() {
        var model = makeModel()
        model.detectedSupportsCode = false
        model.curatedSupportsCode = true
        XCTAssertTrue(model.supportsCode, "curated override must win over a detected value")

        // And the reverse: curation can deny a detected-true capability.
        model.detectedSupportsMultilingual = true
        model.curatedSupportsMultilingual = false
        XCTAssertFalse(model.supportsMultilingual, "curated false must win over detected true")
    }

    func testApplyCuratedCapabilities_onlyOverridesNonNilFields() {
        var model = makeModel()
        model.detectedSupportsMultilingual = true
        // Override only code; multilingual nil must leave detected layer intact.
        model.applyCuratedCapabilities(CuratedModelCapabilities(supportsCode: true))
        XCTAssertTrue(model.supportsCode)
        XCTAssertTrue(model.supportsMultilingual, "nil curation field must not clobber detected value")
        XCTAssertFalse(model.supportsReasoning)
    }

    // MARK: - GGUF fallback: configNotFound → no throw, curated-or-false

    func testDetectCapabilities_GGUFNoConfig_doesNotThrowAndStaysFalse() throws {
        // A directory with NO config.json mirrors a GGUF single-file layout.
        let dir = try makeFixtureDirectory()
        var model = makeModel()
        // Must not throw (detectCapabilities swallows configNotFound).
        model.detectCapabilities(fromModelDirectory: dir)
        XCTAssertNil(model.detectedSupportsCode, "no config.json → detected layer stays nil")
        XCTAssertNil(model.detectedSupportsMultilingual)
        XCTAssertFalse(model.supportsCode, "uncurated GGUF resolves honest-false")

        // Curation is the documented escape hatch for GGUF.
        model.applyCuratedCapabilities(CuratedModelCapabilities(supportsCode: true))
        XCTAssertTrue(model.supportsCode)
    }

    func testDetectCapabilities_withConfig_populatesDetectedLayer() throws {
        let dir = try makeFixtureDirectory()
        // config.json carries a multi-language array (multilingual signal). The
        // code signal comes from README front-matter `tags`, which is the
        // probe's primary path (the architectures heuristic only fires on class
        // names literally containing "coder", so it is not exercised here).
        try #"""
        {
            "model_type": "llama",
            "language": ["en", "fr", "de"]
        }
        """#.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try #"""
        ---
        tags:
          - code
        ---
        # Model card
        """#.write(to: dir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)

        var model = makeModel()
        model.detectCapabilities(fromModelDirectory: dir)
        XCTAssertEqual(model.detectedSupportsCode, true)
        XCTAssertEqual(model.detectedSupportsMultilingual, true)
        XCTAssertTrue(model.supportsCode)
        XCTAssertTrue(model.supportsMultilingual)
    }

    // MARK: - #2348: detectedContextLength from config.json (MLX has no GGUF header)

    /// The regression this guards: before #2348, MLX `ModelInfo`s never got
    /// `detectedContextLength` populated from anywhere, so
    /// `ModelLoadCoordinator` silently fell back to the hardcoded 8192 ceiling
    /// for every MLX model regardless of the real trained context or a user's
    /// session override. `max_position_embeddings` in `config.json` is the
    /// only on-disk signal MLX snapshots carry for this.
    func testDetectCapabilities_withConfig_populatesContextLengthAboveDefaultCeiling() throws {
        let dir = try makeFixtureDirectory()
        try #"""
        {
            "model_type": "llama",
            "max_position_embeddings": 131072
        }
        """#.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        var model = makeModel()
        XCTAssertNil(model.detectedContextLength, "precondition: model starts with no detected context")
        model.detectCapabilities(fromModelDirectory: dir)
        XCTAssertEqual(
            model.detectedContextLength, 131_072,
            "MLX config.json's max_position_embeddings must populate detectedContextLength, not stay hardcoded at 8192"
        )
    }

    /// `config.json` present but silent on context length (e.g. an
    /// embedding-only model, or a stripped config) must leave
    /// `detectedContextLength` untouched rather than asserting a wrong value —
    /// `ModelLoadCoordinator`'s `?? 8_192` fallback is the correct behavior here.
    func testDetectCapabilities_configWithoutContextLength_leavesDetectedContextLengthNil() throws {
        let dir = try makeFixtureDirectory()
        try #"""
        {
            "model_type": "llama"
        }
        """#.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        var model = makeModel()
        model.detectCapabilities(fromModelDirectory: dir)
        XCTAssertNil(model.detectedContextLength, "no context-length key in config.json → fall back to today's nil behavior, don't fabricate a value")
    }

    /// Mirrors `testDetectCapabilities_GGUFNoConfig_doesNotThrowAndStaysFalse`
    /// for the context-length field specifically: an absent `config.json`
    /// (single-file GGUF layout) must not throw and must leave
    /// `detectedContextLength` as whatever the caller already set (GGUF's own
    /// header-derived value), never clobbered by the MLX-only probe path.
    func testDetectCapabilities_GGUFNoConfig_leavesExistingDetectedContextLengthIntact() throws {
        let dir = try makeFixtureDirectory()
        var model = makeModel()
        model.detectedContextLength = 4_096 // as if already set from the GGUF header
        model.detectCapabilities(fromModelDirectory: dir)
        XCTAssertEqual(model.detectedContextLength, 4_096, "configNotFound must not clobber an existing GGUF-header-derived context length")
    }

    /// Malformed `config.json` (not a JSON object) must be reported via the
    /// existing warning-log path — not silently absorbed — and must not crash
    /// or fabricate a context length.
    func testDetectCapabilities_malformedConfig_doesNotCrashAndLeavesContextLengthNil() throws {
        let dir = try makeFixtureDirectory()
        try "not a json object".write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)

        var model = makeModel()
        // Must not throw — detectCapabilities is `try`-free at the call site by design.
        model.detectCapabilities(fromModelDirectory: dir)
        XCTAssertNil(model.detectedContextLength)
        XCTAssertNil(model.detectedSupportsCode)
        XCTAssertNil(model.detectedSupportsMultilingual)
    }

    // MARK: - Cloud reasoning detection

    func testDetectCloudReasoning_anthropicThinkingFamily() {
        var model = makeModel()
        model.detectCloudReasoning(modelName: "claude-opus-4-5-20260101", producer: .anthropic)
        XCTAssertEqual(model.detectedSupportsReasoning, true)
        XCTAssertTrue(model.supportsReasoning)
    }

    func testDetectCloudReasoning_nonThinkingFamily() {
        var model = makeModel()
        model.detectCloudReasoning(modelName: "claude-3-5-haiku-20241022", producer: .anthropic)
        XCTAssertEqual(model.detectedSupportsReasoning, false)
        XCTAssertFalse(model.supportsReasoning)
    }

    func testDetectCloudReasoning_openAIReasoningFamily() {
        var model = makeModel()
        model.detectCloudReasoning(modelName: "o3-mini", producer: .openAI)
        XCTAssertEqual(model.detectedSupportsReasoning, true)
        XCTAssertTrue(model.supportsReasoning)
    }

    func testReasoning_localModelHonestFalse() {
        // Local models never get a detected reasoning signal; honest-false
        // unless curated.
        var model = makeModel()
        XCTAssertFalse(model.supportsReasoning)
        model.applyCuratedCapabilities(CuratedModelCapabilities(supportsReasoning: true))
        XCTAssertTrue(model.supportsReasoning, "curation is the only path to local reasoning=true")
    }

    // MARK: - Catalog round-trip persistence

    func testCatalogRoundTrip_persistsResolvedFlags() async throws {
        let modelsDir = try makeFixtureDirectory()
        let storage = ModelStorageService(baseDirectory: modelsDir)
        let manifestURL = modelsDir.appendingPathComponent(ModelCatalog.manifestFileName)
        let catalog = ModelCatalog(storage: storage, manifestURL: manifestURL)

        // The catalog reconciles against disk presence (missing artifacts are
        // dropped), so the model must point at a real on-disk GGUF inside the
        // models directory to survive reload. A 4-byte GGUF magic header is
        // enough to pass ModelInfo.load's validity check.
        let ggufURL = modelsDir.appendingPathComponent("coder.gguf")
        try Data([0x47, 0x47, 0x55, 0x46] + Array(repeating: UInt8(0), count: 1020))
            .write(to: ggufURL)
        var model = try ModelInfo.load(ggufURL: ggufURL)
        model.curatedSupportsCode = true
        model.detectedSupportsMultilingual = true
        model.detectedSupportsReasoning = false
        let entry = CatalogEntry(modelInfo: model, source: .imported)
        try await catalog.record(entry)

        // Reload from a fresh catalog instance reading the same manifest file.
        let reloaded = ModelCatalog(storage: storage, manifestURL: manifestURL)
        let entries = try await reloaded.catalog()
        let restored = try XCTUnwrap(entries.first { $0.id == model.id }).modelInfo

        XCTAssertEqual(restored.curatedSupportsCode, true)
        XCTAssertEqual(restored.detectedSupportsMultilingual, true)
        XCTAssertEqual(restored.detectedSupportsReasoning, false)
        XCTAssertTrue(restored.supportsCode, "resolved code flag survives round-trip")
        XCTAssertTrue(restored.supportsMultilingual)
        XCTAssertFalse(restored.supportsReasoning)
    }
}
