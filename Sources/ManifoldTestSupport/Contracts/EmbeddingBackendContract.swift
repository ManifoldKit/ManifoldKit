#if canImport(XCTest)
import XCTest
import ManifoldInference

// MARK: - EmbeddingBackendContract

/// Opt-in XCTestCase mixin that exercises the ``EmbeddingBackend`` protocol
/// contract against any conforming implementation.
///
/// ```swift
/// final class MyEmbeddingBackendContractTests: XCTestCase, EmbeddingBackendContract {
///     var subject: any EmbeddingBackend { MyEmbeddingBackend() }
/// }
/// ```
@MainActor
public protocol EmbeddingBackendContract: AnyObject {
    /// Returns a fresh, unloaded embedding backend for each assertion call.
    func makeEmbeddingBackend() -> any EmbeddingBackend

    /// Returns the model URL passed to ``EmbeddingBackend/loadModel(from:)``.
    /// The default returns a synthetic placeholder; backends that validate the URL
    /// must override.
    func makeTestEmbeddingModelURL() -> URL
}

extension EmbeddingBackendContract {
    public func makeTestEmbeddingModelURL() -> URL {
        URL(fileURLWithPath: "/tmp/ManifoldContractTests/contract-embed.gguf")
    }
}

extension EmbeddingBackendContract where Self: XCTestCase {

    // MARK: - Initial State

    /// Asserts that a freshly-created backend reports ``isModelLoaded == false``.
    public func assertEmbeddingBackend_freshBackendIsNotLoaded(
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let backend = makeEmbeddingBackend()
        XCTAssertFalse(
            backend.isModelLoaded,
            "Fresh EmbeddingBackend must report isModelLoaded == false",
            file: file, line: line
        )
    }

    // MARK: - Load / Unload

    /// Asserts the load → unload state cycle.
    public func assertEmbeddingBackend_loadUnloadCycleUpdatesIsModelLoaded(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let backend = makeEmbeddingBackend()
        let url = makeTestEmbeddingModelURL()
        try await backend.loadModel(from: url)
        XCTAssertTrue(
            backend.isModelLoaded,
            "isModelLoaded must be true after loadModel()",
            file: file, line: line
        )
        backend.unloadModel()
        XCTAssertFalse(
            backend.isModelLoaded,
            "isModelLoaded must be false after unloadModel()",
            file: file, line: line
        )
    }

    // MARK: - dimensions

    /// Asserts that ``dimensions`` is positive after loading a model.
    public func assertEmbeddingBackend_dimensionsArePositiveAfterLoad(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let backend = makeEmbeddingBackend()
        let url = makeTestEmbeddingModelURL()
        try await backend.loadModel(from: url)
        XCTAssertGreaterThan(
            backend.dimensions,
            0,
            "EmbeddingBackend.dimensions must be > 0 after loadModel()",
            file: file, line: line
        )
    }

    // MARK: - embed(_:)

    /// Asserts that ``embed(_:)`` returns the correct number of embedding vectors
    /// (one per input text), each with the expected ``dimensions`` length.
    public func assertEmbeddingBackend_embedReturnsDimensionallyCorrectVectors(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let backend = makeEmbeddingBackend()
        let url = makeTestEmbeddingModelURL()
        try await backend.loadModel(from: url)

        let texts = ["Hello", "World"]
        let embeddings = try await backend.embed(texts)

        XCTAssertEqual(
            embeddings.count, texts.count,
            "embed() must return one vector per input text",
            file: file, line: line
        )
        let expectedDimensions = backend.dimensions
        for (index, vector) in embeddings.enumerated() {
            XCTAssertEqual(
                vector.count, expectedDimensions,
                "Vector at index \(index) has \(vector.count) dimensions; expected \(expectedDimensions)",
                file: file, line: line
            )
        }
    }

    /// Asserts that embedding an empty input array returns an empty array.
    public func assertEmbeddingBackend_embedEmptyInputReturnsEmptyArray(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let backend = makeEmbeddingBackend()
        let url = makeTestEmbeddingModelURL()
        try await backend.loadModel(from: url)

        let result = try await backend.embed([])
        XCTAssertTrue(
            result.isEmpty,
            "embed([]) must return an empty array",
            file: file, line: line
        )
    }

    /// Asserts that calling ``embed(_:)`` before loading a model throws
    /// ``EmbeddingError/modelNotLoaded``.
    public func assertEmbeddingBackend_embedBeforeLoadThrowsModelNotLoaded(
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let backend = makeEmbeddingBackend()
        do {
            _ = try await backend.embed(["test"])
            XCTFail(
                "embed() before loadModel() must throw; no error was thrown",
                file: file, line: line
            )
        } catch EmbeddingError.modelNotLoaded {
            // Expected — contract satisfied.
        } catch {
            XCTFail(
                "embed() before loadModel() threw unexpected error: \(error)",
                file: file, line: line
            )
        }
    }
}
#endif
