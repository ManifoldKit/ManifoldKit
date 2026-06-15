import XCTest
@testable import ManifoldInference

// MARK: - Mock

/// Inline mock conforming to `EmbeddingBackend` for protocol contract tests.
private final class MockEmbeddingBackend: EmbeddingBackend, @unchecked Sendable {
    var isModelLoaded: Bool = false
    var dimensions: Int = 384

    func loadModel(from url: URL) async throws {
        isModelLoaded = true
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard isModelLoaded else { throw EmbeddingError.modelNotLoaded }
        // Return a stub vector of the declared dimension for each input text.
        return texts.map { _ in [Float](repeating: 0.1, count: dimensions) }
    }

    func unloadModel() {
        isModelLoaded = false
    }
}

// MARK: - Tests

final class EmbeddingBackendProtocolTests: XCTestCase {

    // MARK: - Protocol conformance / embed stub

    func test_embed_returnsExpectedStubValue() async throws {
        let backend = MockEmbeddingBackend()
        try await backend.loadModel(from: URL(string: "file:///mock-embed")!)

        let result = try await backend.embed(["hello"])

        XCTAssertEqual(result.count, 1, "One input text should yield one embedding vector")
        XCTAssertEqual(result[0].count, backend.dimensions,
                       "Vector length must match the declared dimensions")
        XCTAssertEqual(result[0].first ?? 0, 0.1, accuracy: 0.001)
    }

    func test_embed_multipleTexts_returnsMatchingCount() async throws {
        let backend = MockEmbeddingBackend()
        try await backend.loadModel(from: URL(string: "file:///mock-embed")!)

        let texts = ["hello", "world", "foo"]
        let result = try await backend.embed(texts)

        XCTAssertEqual(result.count, texts.count)
    }

    // MARK: - EmbeddingError descriptions

    func test_embeddingError_modelNotLoaded_hasNonNilDescription() {
        let error = EmbeddingError.modelNotLoaded
        XCTAssertNotNil(error.errorDescription)
        XCTAssertFalse(error.errorDescription!.isEmpty)
    }

    func test_embeddingError_dimensionMismatch_hasNonNilDescription() {
        let error = EmbeddingError.dimensionMismatch(expected: 384, actual: 512)
        let desc = error.errorDescription
        XCTAssertNotNil(desc)
        XCTAssertTrue(desc!.contains("384"), "Should mention expected dimension")
        XCTAssertTrue(desc!.contains("512"), "Should mention actual dimension")
    }

    func test_embeddingError_encodingFailed_hasNonNilDescription() {
        let underlying = NSError(domain: "test", code: 42,
                                 userInfo: [NSLocalizedDescriptionKey: "bad encoding"])
        let error = EmbeddingError.encodingFailed(underlying: underlying)
        let desc = error.errorDescription
        XCTAssertNotNil(desc)
        XCTAssertFalse(desc!.isEmpty)
    }

    // MARK: - EmbeddingCapabilities

    /// A conformer that does not override `capabilities` inherits the
    /// protocol-extension default — proving the addition is non-breaking.
    func test_capabilities_defaultsToDefault_whenNotOverridden() {
        let backend = MockEmbeddingBackend()
        XCTAssertEqual(backend.capabilities, .default)
    }

    func test_embeddingCapabilities_codableRoundTrips() throws {
        let original = EmbeddingCapabilities(
            maxBatchSize: 32,
            maxInputLength: 512,
            producesNormalizedVectors: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EmbeddingCapabilities.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}
