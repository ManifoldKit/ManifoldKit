import XCTest
@testable import ManifoldUIModelManagement
import ManifoldRuntime
import ManifoldInference

/// Guards against the `DocumentLibrarySheet`/`DocumentLibraryViewModel`
/// embedding-availability regression: `ManifoldBootstrap.resolveEmbeddingBackend`
/// falls back to the bundled `NLEmbeddingBackend` (always `isModelLoaded == true`)
/// when the host injects no embedding backend, so `RAGService` takes the real
/// semantic/vector retrieval path — but `hasEmbeddingBackend` defaulted to a
/// hardcoded `false`, so `DocumentLibraryView` rendered "Using keyword fallback"
/// even when retrieval was actually semantic.
///
/// The fix derives `hasEmbeddingBackend` from `RAGService.usesSemanticRetrieval`
/// when the caller doesn't pass an explicit override.
@MainActor
final class DocumentLibraryEmbeddingSignalTests: XCTestCase {

    // MARK: - Fakes (protocol-conforming, not a persistence mock)

    private actor FakeVectorStore: VectorStore {
        func insert(chunks: [DocumentChunk], documentTitle: String, embeddings: [[Float]]) throws {}
        func search(embedding: [Float], limit: Int) throws -> [VectorSearchHit] { [] }
        func keywordSearch(query: String, limit: Int) throws -> [VectorSearchHit] { [] }
        func delete(documentID: UUID) throws {}
        func deleteAll() throws {}
    }

    private final class FakeDocumentStore: DocumentStore, @unchecked Sendable {
        func insertDocument(_ record: DocumentRecord) throws {}
        func fetchDocuments() throws -> [DocumentRecord] { [] }
        func fetchDocument(id: UUID) throws -> DocumentRecord? { nil }
        func deleteDocument(id: UUID) throws {}
    }

    /// Always-loaded stub embedding backend — the shape a bundled
    /// `NLEmbeddingBackend` (or the RAG-eval harness's `HashingEmbeddingBackend`)
    /// presents once loaded.
    private final class StubEmbeddingBackend: EmbeddingBackend, @unchecked Sendable {
        var isModelLoaded: Bool = true
        var dimensions: Int { 8 }
        func loadModel(from url: URL) async throws {}
        func unloadModel() { isModelLoaded = false }
        func embed(_ texts: [String]) async throws -> [[Float]] { texts.map { _ in [Float](repeating: 0, count: 8) } }
    }

    private func makeService(embeddingBackend: (any EmbeddingBackend)?) -> RAGService {
        RAGService(
            documentStore: FakeDocumentStore(),
            vectorStore: FakeVectorStore(),
            embeddingBackend: embeddingBackend
        )
    }

    /// No embedding backend at all → `hasEmbeddingBackend` must be `false`.
    func test_hasEmbeddingBackend_noBackend_isFalse() {
        let service = makeService(embeddingBackend: nil)
        let viewModel = DocumentLibraryViewModel(ragService: service)
        XCTAssertFalse(viewModel.hasEmbeddingBackend)
    }

    /// A loaded embedding backend (the `ManifoldBootstrap` default-fallback shape)
    /// → `hasEmbeddingBackend` must be `true`. RED against the pre-fix hardcoded
    /// `false` default (see PR description for the captured failure output).
    func test_hasEmbeddingBackend_loadedBackend_isTrue() {
        let service = makeService(embeddingBackend: StubEmbeddingBackend())
        let viewModel = DocumentLibraryViewModel(ragService: service)
        XCTAssertTrue(viewModel.hasEmbeddingBackend)
    }

    /// An explicit `false` override is preserved even against a loaded backend —
    /// the derivation only fills in when the caller passes `nil`.
    func test_hasEmbeddingBackend_explicitOverridePreserved() {
        let service = makeService(embeddingBackend: StubEmbeddingBackend())
        let viewModel = DocumentLibraryViewModel(ragService: service, hasEmbeddingBackend: false)
        XCTAssertFalse(viewModel.hasEmbeddingBackend, "An explicit override must win over the derivation")
    }
}
