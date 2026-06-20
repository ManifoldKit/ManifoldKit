import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldRuntime
import ManifoldInference

/// Integration tests for the hybrid BM25 + dense + RRF retrieval path (#1919).
///
/// Uses the *real* `FlatFileVectorStore` (temp-file backed) and a *real*
/// `SwiftDataDocumentStore` over an in-memory `ModelContainer` — no mocked
/// persistence. The embedding backend is a controllable fake so we can force a
/// dense "miss" and prove the sparse leg recovers the passage under `.hybrid`.
@MainActor
final class HybridRetrievalIntegrationTests: XCTestCase {

    private var vectorURL: URL!

    override func setUp() {
        super.setUp()
        vectorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: vectorURL)
        super.tearDown()
    }

    // MARK: - Fakes

    /// Embedding backend whose vectors are deterministic per-text so the dense
    /// cosine ranking is fully controllable. Each text is embedded as a unit
    /// vector along an axis chosen by a marker token, letting a test arrange for
    /// the query embedding to point *away* from the passage that holds the rare
    /// exact token (a dense miss).
    private final class AxisEmbeddingBackend: EmbeddingBackend, @unchecked Sendable {
        var isModelLoaded: Bool = true
        var dimensions: Int = 3

        func loadModel(from url: URL) async throws {}
        func unloadModel() { isModelLoaded = false }

        func embed(_ texts: [String]) async throws -> [[Float]] {
            texts.map { Self.vector(for: $0) }
        }

        /// Axis selection: "apple" → x, "banana" → y, anything else → z.
        static func vector(for text: String) -> [Float] {
            let lower = text.lowercased()
            if lower.contains("apple") { return [1, 0, 0] }
            if lower.contains("banana") { return [0, 1, 0] }
            return [0, 0, 1]
        }
    }

    private func makeDocumentStore() throws -> SwiftDataDocumentStore {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        return SwiftDataDocumentStore(modelContext: ModelContext(container))
    }

    /// Ingests three chunks directly into the vector store with chosen
    /// embeddings, returning the store. The "target" chunk carries a rare exact
    /// token (`zq7widget`) but an embedding on the z-axis, so a query embedding
    /// on the x-axis (apple) will rank it last by cosine.
    private func seededStore() async throws -> FlatFileVectorStore {
        let store = FlatFileVectorStore(storageURL: vectorURL)
        let docID = UUID()
        let chunks = [
            DocumentChunk(documentID: docID, text: "all about apples and apple pie", chunkIndex: 0),
            DocumentChunk(documentID: docID, text: "bananas and more bananas", chunkIndex: 1),
            DocumentChunk(documentID: docID, text: "the rare zq7widget specification", chunkIndex: 2),
        ]
        let embeddings = chunks.map { AxisEmbeddingBackend.vector(for: $0.text) }
        try await store.insert(chunks: chunks, documentTitle: "Doc", embeddings: embeddings)
        return store
    }

    // MARK: - Tests

    func testHybridSurfacesRareTokenThatDenseMisses() async throws {
        let store = try await seededStore()
        let documentStore = try makeDocumentStore()
        let backend = AxisEmbeddingBackend()

        // The query embeds onto the apple (x) axis, so cosine ranks the
        // zq7widget chunk *last*. But the query text contains the exact rare
        // token, which BM25 scores highly → RRF should lift it into the top-k.
        let service = RAGService(
            documentStore: documentStore,
            vectorStore: store,
            embeddingBackend: backend,
            defaultLimit: 2,
            retrievalStrategy: .hybrid
        )

        let result = try await service.retrieve(query: "apple zq7widget", limit: 2)
        let texts = result.citations.map(\.snippet)
        XCTAssertTrue(
            texts.contains(where: { $0.contains("zq7widget") }),
            "Hybrid retrieval should surface the rare exact token via BM25+RRF; got \(texts)"
        )
    }

    func testDenseStrategyMissesTheRareTokenWithinTopK() async throws {
        // Sabotage / contrast: the *same* corpus and query under `.dense` ranks
        // the rare-token chunk last (z-axis vs x-axis query), so with limit 2 it
        // falls outside the window — proving the hybrid lift above is real and
        // not an artefact of the corpus.
        let store = try await seededStore()
        let documentStore = try makeDocumentStore()
        let backend = AxisEmbeddingBackend()

        let service = RAGService(
            documentStore: documentStore,
            vectorStore: store,
            embeddingBackend: backend,
            defaultLimit: 2,
            retrievalStrategy: .dense
        )

        let result = try await service.retrieve(query: "apple zq7widget", limit: 2)
        let texts = result.citations.map(\.snippet)
        XCTAssertFalse(
            texts.contains(where: { $0.contains("zq7widget") }),
            "Dense-only top-2 should miss the rare token (it ranks last by cosine); got \(texts)"
        )
    }

    func testFlagOffMatchesLegacyDenseOrdering() async throws {
        // The bootstrap maps `hybridRetrieval = false` → `.dense`. Verify the
        // service built with the legacy strategy returns the dense ordering for a
        // well-aligned query (apple → x-axis chunk first), unchanged by the new
        // code paths.
        let store = try await seededStore()
        let documentStore = try makeDocumentStore()
        let backend = AxisEmbeddingBackend()

        let service = RAGService(
            documentStore: documentStore,
            vectorStore: store,
            embeddingBackend: backend,
            defaultLimit: 3,
            retrievalStrategy: .dense
        )

        let result = try await service.retrieve(query: "apple", limit: 1)
        XCTAssertEqual(
            result.citations.first?.snippet,
            "all about apples and apple pie",
            "Dense (flag-off) retrieval must rank the cosine-nearest chunk first"
        )
    }
}
