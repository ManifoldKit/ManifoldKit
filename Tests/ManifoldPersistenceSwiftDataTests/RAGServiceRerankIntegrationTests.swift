import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldRuntime

/// Integration coverage for the #1637 rerank stage exercising the *real*
/// persistence stack: an in-memory SwiftData ``SwiftDataDocumentStore`` and an
/// on-disk ``FlatFileVectorStore``, driven end-to-end through ``RAGService``.
///
/// These are integration tests (they touch SwiftData and the flat-file index),
/// so they live in `ManifoldPersistenceSwiftDataTests` rather than the unit
/// suite. The reranker is a fake here: the *real* RANK-pooling reranker
/// (`LlamaReranker`) needs a cross-encoder GGUF and Metal, so its model path is
/// covered (and skipped without a model) in `ManifoldBackendsTests`. What this
/// suite pins is that the widen → rerank → trim wiring survives a trip through
/// the shipped stores.
@MainActor
final class RAGServiceRerankIntegrationTests: XCTestCase {

    private var container: ModelContainer!
    private var vectorURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainerFactory.makeInMemoryContainer()
        vectorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
    }

    override func tearDown() {
        if let vectorURL { try? FileManager.default.removeItem(at: vectorURL) }
        container = nil
        vectorURL = nil
        super.tearDown()
    }

    /// Ingest three chunks through the real stores, then retrieve with a
    /// reranker that intentionally inverts the cosine order. The injected slot
    /// and citations must reflect the reranked order, proving the stage is wired
    /// through SwiftData + the flat-file index, not just the in-memory fakes.
    func test_ingestThenRetrieve_rerankReordersThroughRealStores() async throws {
        let documentStore = SwiftDataDocumentStore(modelContext: container.mainContext)
        let vectorStore = FlatFileVectorStore(storageURL: vectorURL)

        // Pre-seed the vector index directly so we control the embedding
        // geometry (cosine order) independent of any embedding backend.
        let docID = UUID()
        let chunks = [
            DocumentChunk(documentID: docID, text: "alpha chunk", chunkIndex: 0),
            DocumentChunk(documentID: docID, text: "bravo chunk", chunkIndex: 1),
            DocumentChunk(documentID: docID, text: "charlie chunk", chunkIndex: 2),
        ]
        // Query will be [1,0,0]. Cosine order: alpha > bravo > charlie.
        let embeddings: [[Float]] = [[1, 0, 0], [0.7, 0.7, 0], [0.1, 0.99, 0]]
        try await vectorStore.insert(chunks: chunks, documentTitle: "Doc", embeddings: embeddings)
        try documentStore.insertDocument(DocumentRecord(
            id: docID, title: "Doc",
            sourceURL: URL(filePath: "/tmp/Doc.txt"),
            fileType: "txt", chunkCount: chunks.count
        ))

        // Reranker that flips the cosine order: charlie becomes most relevant.
        let reranker = ClosureReranker { hits in
            hits.sorted { lhs, rhs in lhs.chunk.chunkIndex > rhs.chunk.chunkIndex }
        }

        let sut = RAGService(
            documentStore: documentStore,
            vectorStore: vectorStore,
            embeddingBackend: AxisEmbeddingBackend(),
            reranker: reranker
        )

        let result = try await sut.retrieve(query: "alpha", limit: 3)

        XCTAssertEqual(result.citations.count, 3)
        XCTAssertEqual(result.citations.map(\.chunkIndex), [2, 1, 0],
                       "reranked order must flow through the real SwiftData + flat-file stores")

        // Sabotage: cosine order would be [0, 1, 2]; the rerank must have changed it.
        XCTAssertNotEqual(result.citations.map(\.chunkIndex), [0, 1, 2])
    }

    /// Without a reranker, the same real-store pipeline must return the cosine
    /// order untouched — the passthrough-default guarantee, end to end.
    func test_retrieve_noReranker_preservesCosineOrderThroughRealStores() async throws {
        let documentStore = SwiftDataDocumentStore(modelContext: container.mainContext)
        let vectorStore = FlatFileVectorStore(storageURL: vectorURL)

        let docID = UUID()
        let chunks = [
            DocumentChunk(documentID: docID, text: "alpha chunk", chunkIndex: 0),
            DocumentChunk(documentID: docID, text: "bravo chunk", chunkIndex: 1),
        ]
        try await vectorStore.insert(chunks: chunks, documentTitle: "Doc", embeddings: [[1, 0, 0], [0.5, 0.86, 0]])
        try documentStore.insertDocument(DocumentRecord(
            id: docID, title: "Doc",
            sourceURL: URL(filePath: "/tmp/Doc.txt"),
            fileType: "txt", chunkCount: chunks.count
        ))

        let sut = RAGService(
            documentStore: documentStore,
            vectorStore: vectorStore,
            embeddingBackend: AxisEmbeddingBackend()
        )

        let result = try await sut.retrieve(query: "alpha", limit: 3)
        XCTAssertEqual(result.citations.map(\.chunkIndex), [0, 1],
                       "no reranker must preserve descending cosine order")
    }

    // MARK: - #2199: in-memory text ingestion round trip

    /// Ingest through the real chunk → embed → SwiftData/flat-file pipeline
    /// via `ingest(text:documentID:title:)` (not `ingest(url:)`), then
    /// retrieve and delete — the acceptance criterion from #2199: an
    /// ingest→retrieve→delete round-trip for text ingestion against the
    /// shipped stores, not fakes.
    func test_ingestTextThenRetrieveThenDelete_roundTripsThroughRealStores() async throws {
        let documentStore = SwiftDataDocumentStore(modelContext: container.mainContext)
        let vectorStore = FlatFileVectorStore(storageURL: vectorURL)

        let sut = RAGService(
            documentStore: documentStore,
            vectorStore: vectorStore,
            embeddingBackend: AxisEmbeddingBackend()
        )

        let documentID = UUID()
        let record = try await sut.ingest(
            text: "This is a story scene generated in-memory, with enough words to form at least one chunk.",
            documentID: documentID,
            title: "Scene 1"
        )

        XCTAssertEqual(record.id, documentID)
        XCTAssertEqual(record.title, "Scene 1")

        let storedDocuments = try await documentStore.fetchDocuments()
        XCTAssertTrue(storedDocuments.contains { $0.id == documentID },
                       "the SwiftData document store must carry the text-ingested record")

        let result = try await sut.retrieve(query: "story scene", limit: 3)
        XCTAssertFalse(result.citations.isEmpty, "retrieval must find the in-memory-ingested chunk through the real flat-file index")
        XCTAssertTrue(result.citations.allSatisfy { $0.documentID == documentID })

        try await sut.deleteDocument(id: documentID)

        let documentsAfterDelete = try await documentStore.fetchDocuments()
        XCTAssertFalse(documentsAfterDelete.contains { $0.id == documentID },
                        "deleteDocument(id:) must remove text-ingested documents from the real document store")

        let resultAfterDelete = try await sut.retrieve(query: "story scene", limit: 3)
        XCTAssertTrue(resultAfterDelete.citations.isEmpty,
                       "deleteDocument(id:) must remove text-ingested chunks from the real vector store")
    }
}

// MARK: - Fakes

/// Reorders candidates with a closure; always ready.
private struct ClosureReranker: Reranker {
    let reorder: @Sendable ([VectorSearchHit]) -> [VectorSearchHit]
    var isReady: Bool { true }
    func rerank(query: String, candidates: [VectorSearchHit], limit: Int) async throws -> [VectorSearchHit] {
        Array(reorder(candidates).prefix(limit))
    }
}

/// Embeds every query as the unit vector along the first axis so the
/// pre-seeded chunk geometry drives a deterministic cosine order.
private final class AxisEmbeddingBackend: EmbeddingBackend, @unchecked Sendable {
    var isModelLoaded: Bool = true
    var dimensions: Int = 3
    func loadModel(from url: URL) async throws {}
    func embed(_ texts: [String]) async throws -> [[Float]] {
        texts.map { _ in [1, 0, 0] }
    }
    func unloadModel() { isModelLoaded = false }
}
