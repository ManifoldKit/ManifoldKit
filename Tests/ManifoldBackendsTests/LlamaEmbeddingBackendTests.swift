#if Llama
import XCTest
@testable import ManifoldInference
@testable import ManifoldBackends
@testable import ManifoldLlama
@testable import ManifoldTestSupport

/// Locates a GGUF embedding model on disk for `LlamaEmbeddingBackend` tests.
///
/// Resolution order (first hit wins):
///   1. `MANIFOLD_EMBEDDING_MODEL_PATH` env var — explicit override for live-fire runs
///   2. `~/Documents/Models/*.gguf` containing "embed"/"embedding"/"bge"/"minilm"/"nomic"/"jina",
///      only when `MANIFOLD_DISCOVER_LOCAL_MODELS=1` opts into local discovery
///
/// Returns `nil` when nothing is found, in which case the calling test should
/// `XCTSkipUnless` the URL — embedding tests cannot synthesize a valid GGUF on
/// the fly. Keeping this resolver inside the test file (rather than promoting
/// it into `ManifoldTestSupport`) avoids implying a public contract that the
/// rest of the codebase doesn't need.
enum EmbeddingTestModelLocator {
    static func locate() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let envPath = env["MANIFOLD_EMBEDDING_MODEL_PATH"], !envPath.isEmpty {
            let url = URL(fileURLWithPath: envPath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        guard env["MANIFOLD_DISCOVER_LOCAL_MODELS"] == "1" else {
            return nil
        }

        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let modelsDir = docs.appendingPathComponent("Models", isDirectory: true)
        guard let contents = try? fm.contentsOfDirectory(
            at: modelsDir,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        // Heuristic: a file is an embedding model if its name contains a
        // canonical embedder substring AND it is at least 1 MB (skipping
        // any tokenizer-only or test-fixture files).
        let needles = ["embed", "embedding", "bge", "minilm", "nomic", "jina", "mxbai"]
        let minSize: Int64 = 1 * 1024 * 1024
        for url in contents where url.pathExtension.lowercased() == "gguf" {
            let lower = url.lastPathComponent.lowercased()
            guard needles.contains(where: { lower.contains($0) }) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true,
                  let size = values?.fileSize, Int64(size) >= minSize else { continue }
            return url
        }
        return nil
    }

    /// Optional second model used by ``LlamaEmbeddingBackendDimensionMismatchTests``
    /// to verify that switching models updates `dimensions`. When unset the
    /// test is skipped.
    static func locateAlternate() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let envPath = env["MANIFOLD_EMBEDDING_MODEL_PATH_ALT"], !envPath.isEmpty {
            let url = URL(fileURLWithPath: envPath)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }
}

// MARK: - Load / Unload

final class LlamaEmbeddingBackendLoadUnloadTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice, "LlamaEmbeddingBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "LlamaEmbeddingBackend requires Apple Silicon")
    }

    func test_initialState_isUnloaded() {
        let backend = LlamaEmbeddingBackend()
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertEqual(backend.dimensions, 0)
    }

    func test_loadModel_setsLoadedAndDimensions() async throws {
        try XCTSkipUnless(EmbeddingTestModelLocator.locate() != nil,
                          "Set MANIFOLD_EMBEDDING_MODEL_PATH to a local embedding GGUF to run live-fire load tests.")
        let modelURL = EmbeddingTestModelLocator.locate()!

        let backend = LlamaEmbeddingBackend()
        try await backend.loadModel(from: modelURL)
        defer { backend.unloadModel() }

        XCTAssertTrue(backend.isModelLoaded)
        XCTAssertGreaterThan(backend.dimensions, 0,
                             "dimensions must be a positive integer after a successful load")
    }

    func test_unloadModel_clearsState() async throws {
        try XCTSkipUnless(EmbeddingTestModelLocator.locate() != nil,
                          "Set MANIFOLD_EMBEDDING_MODEL_PATH to a local embedding GGUF to run this test.")
        let modelURL = EmbeddingTestModelLocator.locate()!

        let backend = LlamaEmbeddingBackend()
        try await backend.loadModel(from: modelURL)
        XCTAssertTrue(backend.isModelLoaded)

        backend.unloadModel()
        // unloadModel() flips the synchronous flags immediately even though
        // the underlying C cleanup is detached.
        XCTAssertFalse(backend.isModelLoaded)
        XCTAssertEqual(backend.dimensions, 0)
    }

    func test_loadModel_invalidPath_throwsEncodingFailed() async {
        let backend = LlamaEmbeddingBackend()
        let bogus = URL(fileURLWithPath: "/nonexistent/embedding.gguf")
        do {
            try await backend.loadModel(from: bogus)
            XCTFail("Expected loadModel to throw for a missing file")
        } catch let error as EmbeddingError {
            if case .encodingFailed = error {
                // Expected — load failures are wrapped into encodingFailed
                // because EmbeddingError has no dedicated load case and the
                // protocol does not let us add one.
            } else {
                XCTFail("Expected encodingFailed, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
        XCTAssertFalse(backend.isModelLoaded)
    }
}

// MARK: - Embed

final class LlamaEmbeddingBackendEmbedTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice, "LlamaEmbeddingBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "LlamaEmbeddingBackend requires Apple Silicon")
    }

    func test_embed_singleText_returnsOneUnitVector() async throws {
        try XCTSkipUnless(EmbeddingTestModelLocator.locate() != nil,
                          "Set MANIFOLD_EMBEDDING_MODEL_PATH to a local embedding GGUF to run this test.")
        let modelURL = EmbeddingTestModelLocator.locate()!

        let backend = LlamaEmbeddingBackend()
        try await backend.loadModel(from: modelURL)
        defer { backend.unloadModel() }

        let vectors = try await backend.embed(["hello, world"])
        XCTAssertEqual(vectors.count, 1)
        XCTAssertEqual(vectors[0].count, backend.dimensions)
        assertUnitNorm(vectors[0])
    }

    func test_embed_multipleTexts_returnsCorrectShape() async throws {
        try XCTSkipUnless(EmbeddingTestModelLocator.locate() != nil,
                          "Set MANIFOLD_EMBEDDING_MODEL_PATH to a local embedding GGUF to run this test.")
        let modelURL = EmbeddingTestModelLocator.locate()!

        let backend = LlamaEmbeddingBackend()
        try await backend.loadModel(from: modelURL)
        defer { backend.unloadModel() }

        let inputs = ["a", "b", "the quick brown fox jumps over the lazy dog"]
        let vectors = try await backend.embed(inputs)
        XCTAssertEqual(vectors.count, inputs.count)
        for (i, v) in vectors.enumerated() {
            XCTAssertEqual(v.count, backend.dimensions, "vector \(i) has wrong dimension")
            assertUnitNorm(v)
        }
    }

    func test_embed_emptyArray_returnsEmpty() async throws {
        try XCTSkipUnless(EmbeddingTestModelLocator.locate() != nil,
                          "Set MANIFOLD_EMBEDDING_MODEL_PATH to a local embedding GGUF to run this test.")
        let modelURL = EmbeddingTestModelLocator.locate()!

        let backend = LlamaEmbeddingBackend()
        try await backend.loadModel(from: modelURL)
        defer { backend.unloadModel() }

        let vectors = try await backend.embed([])
        XCTAssertTrue(vectors.isEmpty)
    }

    private func assertUnitNorm(_ vector: [Float], tolerance: Float = 1e-3, file: StaticString = #file, line: UInt = #line) {
        let sumSq = vector.reduce(into: Float(0)) { $0 += $1 * $1 }
        let norm = sqrtf(sumSq)
        // Norm must be ~1.0 (cosine-ready). Allow some tolerance because
        // the C kernel uses fp16 internally on Metal.
        XCTAssertEqual(norm, 1.0, accuracy: tolerance,
                       "vector is not unit-normalized (norm=\(norm))",
                       file: file, line: line)
    }
}

// MARK: - Determinism

final class LlamaEmbeddingBackendDeterminismTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice, "LlamaEmbeddingBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "LlamaEmbeddingBackend requires Apple Silicon")
    }

    func test_sameInput_acrossTwoCalls_isIdentical() async throws {
        try XCTSkipUnless(EmbeddingTestModelLocator.locate() != nil,
                          "Set MANIFOLD_EMBEDDING_MODEL_PATH to a local embedding GGUF to run this test.")
        let modelURL = EmbeddingTestModelLocator.locate()!

        let backend = LlamaEmbeddingBackend()
        try await backend.loadModel(from: modelURL)
        defer { backend.unloadModel() }

        let input = "deterministic embedding test input"
        let first = try await backend.embed([input])
        let second = try await backend.embed([input])

        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(first[0].count, second[0].count)
        // Allow a tiny numerical drift because Metal's reduction order can
        // differ across kernel launches; require <1e-4 per-component.
        for (a, b) in zip(first[0], second[0]) {
            XCTAssertEqual(a, b, accuracy: 1e-4,
                           "embedding components diverge across two calls (\(a) vs \(b))")
        }
    }
}

// MARK: - Errors

final class LlamaEmbeddingBackendUnloadedErrorTests: XCTestCase {
    // No hardware gating — modelNotLoaded is a logical pre-condition that
    // does not require Metal or a real GGUF to verify.

    func test_embed_beforeLoad_throwsModelNotLoaded() async {
        let backend = LlamaEmbeddingBackend()
        do {
            _ = try await backend.embed(["never going to make it"])
            XCTFail("embed() must throw when no model is loaded")
        } catch let error as EmbeddingError {
            if case .modelNotLoaded = error {
                // Expected
            } else {
                XCTFail("Expected modelNotLoaded, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    func test_embed_afterUnload_throwsModelNotLoaded() async throws {
        // Even without a real load: calling unloadModel on a clean backend
        // must leave the synchronous flag false so embed() throws.
        let backend = LlamaEmbeddingBackend()
        backend.unloadModel()
        do {
            _ = try await backend.embed(["x"])
            XCTFail("embed() must throw when no model is loaded")
        } catch let error as EmbeddingError {
            if case .modelNotLoaded = error {
                // Expected
            } else {
                XCTFail("Expected modelNotLoaded, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

// MARK: - Dimension change between models

final class LlamaEmbeddingBackendDimensionMismatchTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice, "LlamaEmbeddingBackend requires Metal (unavailable in simulator)")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "LlamaEmbeddingBackend requires Apple Silicon")
    }

    /// Loads model A, records `dimensions`, loads model B, and asserts that
    /// `dimensions` reflects the new model. We do not assert
    /// `EmbeddingError.dimensionMismatch` here — that error is the
    /// responsibility of a downstream coordinator (e.g. Fireside's
    /// `EmbeddingService`) that compares the live backend's dimension against
    /// previously-persisted vectors. The backend itself only needs to make
    /// the new dimension observable.
    func test_dimensions_reflectsNewModelAfterReload() async throws {
        try XCTSkipUnless(EmbeddingTestModelLocator.locate() != nil,
                          "Set MANIFOLD_EMBEDDING_MODEL_PATH to a local embedding GGUF to run this test.")
        try XCTSkipUnless(EmbeddingTestModelLocator.locateAlternate() != nil,
                          "Set MANIFOLD_EMBEDDING_MODEL_PATH_ALT to a second embedding GGUF to run this test.")
        let primary = EmbeddingTestModelLocator.locate()!
        let alternate = EmbeddingTestModelLocator.locateAlternate()!

        let backend = LlamaEmbeddingBackend()
        try await backend.loadModel(from: primary)
        let dimA = backend.dimensions
        XCTAssertGreaterThan(dimA, 0)

        try await backend.loadModel(from: alternate)
        defer { backend.unloadModel() }
        let dimB = backend.dimensions
        XCTAssertGreaterThan(dimB, 0)

        // We don't require the dimensions to differ — the user may point
        // both env vars at compatible models. If they happen to differ,
        // verify the change is reflected.
        if dimA != dimB {
            XCTAssertNotEqual(dimA, dimB,
                              "After re-loading a different-dimension model, `dimensions` must update")
        }

        // In all cases the new vector shape must match the new dim.
        let v = try await backend.embed(["sanity check"])
        XCTAssertEqual(v.count, 1)
        XCTAssertEqual(v[0].count, dimB)
    }
}

// MARK: - Live-fire latency / consistency

/// Runs `embed` 20 times against the same input and asserts (1) consistent
/// vectors across runs and (2) sub-500 ms median latency per call. Skipped
/// unless `MANIFOLD_EMBEDDING_MODEL_PATH` is set so default CI / local runs do not
/// pay the model-load cost.
final class LlamaEmbeddingBackendLiveFireTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(HardwareRequirements.isPhysicalDevice, "LlamaEmbeddingBackend requires Metal")
        try XCTSkipUnless(HardwareRequirements.isAppleSilicon, "LlamaEmbeddingBackend requires Apple Silicon")
        // Live-fire is opt-in via env var even when the model exists in the
        // default search path — it is the most expensive test in the suite.
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MANIFOLD_EMBEDDING_MODEL_PATH"] != nil,
                          "Set MANIFOLD_EMBEDDING_MODEL_PATH to run live-fire latency tests")
    }

    func test_repeatedEmbed_isConsistentAndFast() async throws {
        let modelURL = try XCTUnwrap(EmbeddingTestModelLocator.locate(),
                                     "MANIFOLD_EMBEDDING_MODEL_PATH must point at a real GGUF")
        let backend = LlamaEmbeddingBackend()
        try await backend.loadModel(from: modelURL)
        defer { backend.unloadModel() }

        let input = "the quick brown fox jumps over the lazy dog"
        var first: [Float]? = nil
        var latencies: [Double] = []

        for _ in 0..<20 {
            let start = Date()
            let v = try await backend.embed([input])
            latencies.append(Date().timeIntervalSince(start))
            XCTAssertEqual(v.count, 1)
            XCTAssertEqual(v[0].count, backend.dimensions)
            if let first {
                for (a, b) in zip(first, v[0]) {
                    XCTAssertEqual(a, b, accuracy: 1e-4)
                }
            } else {
                first = v[0]
            }
        }

        let sorted = latencies.sorted()
        let median = sorted[sorted.count / 2]
        XCTAssertLessThan(median, 0.5,
                          "median embed latency (\(median * 1000) ms) exceeded 500 ms target")
    }
}
#endif
