#if Llama
import XCTest
import BaseChatInference
@testable import BaseChatTestSupport
@testable import BaseChatBackends

/// Real-hardware conformance suite for ``LlamaEmbeddingBackend`` against
/// embedding-specific pre-load invariants.
///
/// ``LlamaEmbeddingBackend`` conforms to ``EmbeddingBackend``, not
/// ``InferenceBackend``, so it cannot use ``BackendContractChecks/assertAllInvariants``
/// (which is generic over ``InferenceBackend``). Instead this suite defines
/// equivalent embedding-specific pre-load assertions directly.
///
/// All tests skip cleanly when:
/// - The host is not Apple Silicon (llama.cpp requires arm64 + Metal for GPU).
/// - The test environment is the iOS Simulator (no Metal compute).
/// - The `Q8_VARIANT` fixture slot in
///   `~/Library/Caches/BaseChatKit/test-models/manifest.json` is `null` or
///   the manifest file is absent.
///
/// ## Why `loadModel` is NOT called here
///
/// Like ``LlamaBackend``, ``LlamaEmbeddingBackend`` shares the global
/// `llama_backend_init` refcount via ``LlamaBackendProcessLifecycle``. Loading
/// an embedding model in conformance tests risks accumulating Metal state across
/// the suite. The pre-load invariants below are sufficient for contract verification
/// without a live model.
@MainActor
final class LlamaEmbeddingBackendE2EConformanceTests: XCTestCase {

    // Fixture slot — embedding models typically ship as Q8 GGUFs.
    private static let fixtureSlot = "Q8_VARIANT"

    // MARK: - Fixture discovery

    /// Reads `~/Library/Caches/BaseChatKit/test-models/manifest.json` and returns
    /// the URL for the given fixture slot, or `nil` when the slot is absent, null,
    /// or the manifest does not exist.
    private static func modelURL(forSlot slot: String) -> URL? {
        let manifestURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(components: "Library", "Caches", "BaseChatKit", "test-models", "manifest.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let slots = json["slots"] as? [String: Any?],
              let pathValue = slots[slot] as? String
        else { return nil }
        return URL(fileURLWithPath: pathValue)
    }

    // MARK: - Hardware prerequisites

    private func requireHardware() throws {
        try XCTSkipUnless(
            HardwareRequirements.isAppleSilicon,
            "LlamaEmbeddingBackend requires Apple Silicon"
        )
        try XCTSkipUnless(
            HardwareRequirements.isPhysicalDevice,
            "LlamaEmbeddingBackend requires Metal (unavailable in simulator)"
        )
        try XCTSkipUnless(
            Self.modelURL(forSlot: Self.fixtureSlot) != nil,
            "Skipping: \(Self.fixtureSlot) slot absent from manifest. " +
            "Install an embedding GGUF (e.g. nomic-embed-text) and set the path " +
            "in ~/Library/Caches/BaseChatKit/test-models/manifest.json"
        )
    }

    // MARK: - Pre-load invariants

    /// A freshly initialized backend must report `isModelLoaded == false`.
    func test_preLoad_isModelLoaded_isFalse() throws {
        try requireHardware()
        let backend = LlamaEmbeddingBackend()
        XCTAssertFalse(
            backend.isModelLoaded,
            "LlamaEmbeddingBackend must report isModelLoaded == false before loadModel is called"
        )
    }

    /// `dimensions` must be 0 before a model is loaded — the contract
    /// for ``EmbeddingBackend`` is that `dimensions` reflects the loaded model's
    /// embedding dimensionality, which is unknown before load.
    func test_preLoad_dimensions_isZero() throws {
        try requireHardware()
        let backend = LlamaEmbeddingBackend()
        XCTAssertEqual(
            backend.dimensions,
            0,
            "LlamaEmbeddingBackend must report dimensions == 0 before loadModel is called"
        )
    }

    /// `embed(["hello"])` before `loadModel` must throw ``EmbeddingError/modelNotLoaded``.
    /// Silently returning an empty or zero vector would be misleading.
    func test_preLoad_embedSingleText_throwsModelNotLoaded() async throws {
        try requireHardware()
        let backend = LlamaEmbeddingBackend()
        do {
            _ = try await backend.embed(["hello"])
            XCTFail("embed() should throw EmbeddingError.modelNotLoaded before loadModel is called")
        } catch EmbeddingError.modelNotLoaded {
            // Expected — fail-closed contract satisfied.
        } catch {
            XCTFail("Expected EmbeddingError.modelNotLoaded; got \(error)")
        }
    }

    /// `embed([])` with an unloaded backend must return an empty array, not throw.
    /// Per ``LlamaEmbeddingBackend/embed(_:)``: "guard !texts.isEmpty else { return [] }"
    /// — the empty-input early return fires before the isModelLoaded check.
    func test_preLoad_embedEmptyArray_returnsEmpty() async throws {
        try requireHardware()
        let backend = LlamaEmbeddingBackend()
        let result = try await backend.embed([])
        XCTAssertEqual(
            result,
            [],
            "embed([]) must return an empty array regardless of model load state"
        )
    }

    /// `unloadModel()` on an unloaded backend must not crash. Idempotent cleanup
    /// is required by the ``EmbeddingBackend`` protocol contract.
    func test_preLoad_unloadModel_isIdempotent() throws {
        try requireHardware()
        let backend = LlamaEmbeddingBackend()
        backend.unloadModel()
        backend.unloadModel()  // second call must not crash
        XCTAssertFalse(
            backend.isModelLoaded,
            "isModelLoaded must remain false after repeated unloadModel calls on an unloaded backend"
        )
    }
}
#endif
