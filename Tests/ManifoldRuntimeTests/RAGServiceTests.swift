import XCTest
@testable import ManifoldRuntime
import ManifoldInference

// MARK: - Fakes

private actor FakeVectorStore: VectorStore {
    var insertedChunks: [DocumentChunk] = []
    var insertedEmbeddings: [[Float]] = []
    var insertedTitles: [String] = []
    var deletedDocumentIDs: [UUID] = []
    var searchResults: [VectorSearchHit] = []
    var keywordResults: [VectorSearchHit] = []

    func insert(chunks: [DocumentChunk], documentTitle: String, embeddings: [[Float]]) throws {
        insertedChunks.append(contentsOf: chunks)
        insertedEmbeddings.append(contentsOf: embeddings)
        insertedTitles.append(contentsOf: [String](repeating: documentTitle, count: chunks.count))
    }

    func search(embedding: [Float], limit: Int) throws -> [VectorSearchHit] { searchResults }
    func keywordSearch(query: String, limit: Int) throws -> [VectorSearchHit] { keywordResults }
    func delete(documentID: UUID) throws { deletedDocumentIDs.append(documentID) }
    func deleteAll() throws { insertedChunks.removeAll() }
}

@MainActor
private final class FakeDocumentStore: DocumentStore {
    var insertedRecords: [DocumentRecord] = []
    var deletedIDs: [UUID] = []

    func insertDocument(_ record: DocumentRecord) throws { insertedRecords.append(record) }
    func fetchDocuments() throws -> [DocumentRecord] { insertedRecords }
    func fetchDocument(id: UUID) throws -> DocumentRecord? { insertedRecords.first { $0.id == id } }
    func deleteDocument(id: UUID) throws {
        insertedRecords.removeAll { $0.id == id }
        deletedIDs.append(id)
    }
}

private final class FakeEmbeddingBackend: EmbeddingBackend, @unchecked Sendable {
    var isModelLoaded: Bool
    var dimensions: Int = 4
    var embedCallCount = 0

    init(isModelLoaded: Bool = true) { self.isModelLoaded = isModelLoaded }

    func loadModel(from url: URL) async throws { isModelLoaded = true }
    func embed(_ texts: [String]) async throws -> [[Float]] {
        embedCallCount += 1
        return texts.map { _ in [1.0, 0.0, 0.0, 0.0] }
    }
    func unloadModel() { isModelLoaded = false }
}

// MARK: - Tests

@MainActor
final class RAGServiceTests: XCTestCase {

    func testIngestStoresChunksAndDocument() async throws {
        let vectorStore = FakeVectorStore()
        let docStore = FakeDocumentStore()
        let sut = RAGService(documentStore: docStore, vectorStore: vectorStore)

        let url = try writeTempFile(content: "Hello world. This is a test document.")
        defer { try? FileManager.default.removeItem(at: url) }

        let record = try await sut.ingest(url: url)

        let inserted = await vectorStore.insertedChunks
        XCTAssertFalse(inserted.isEmpty)
        XCTAssertEqual(docStore.insertedRecords.count, 1)
        XCTAssertEqual(docStore.insertedRecords[0].id, record.id)
    }

    func testIngestWithEmbeddingBackendCallsEmbed() async throws {
        let vectorStore = FakeVectorStore()
        let docStore = FakeDocumentStore()
        let backend = FakeEmbeddingBackend(isModelLoaded: true)
        let sut = RAGService(
            documentStore: docStore,
            vectorStore: vectorStore,
            embeddingBackend: backend
        )

        let url = try writeTempFile(content: String(repeating: "word ", count: 20))
        defer { try? FileManager.default.removeItem(at: url) }

        try await sut.ingest(url: url)

        XCTAssertGreaterThan(backend.embedCallCount, 0)
        let embeddings = await vectorStore.insertedEmbeddings
        XCTAssertFalse(embeddings.isEmpty)
    }

    func testIngestWithoutEmbeddingBackendStoresEmptyEmbeddings() async throws {
        let vectorStore = FakeVectorStore()
        let docStore = FakeDocumentStore()
        let sut = RAGService(documentStore: docStore, vectorStore: vectorStore)

        let url = try writeTempFile(content: "Some text")
        defer { try? FileManager.default.removeItem(at: url) }

        try await sut.ingest(url: url)

        let embeddings = await vectorStore.insertedEmbeddings
        XCTAssertTrue(embeddings.isEmpty)
    }

    func testIngestUnsupportedFileTypeThrows() async throws {
        let sut = RAGService(documentStore: FakeDocumentStore(), vectorStore: FakeVectorStore())
        let url = URL(filePath: "/tmp/file.docx")
        do {
            try await sut.ingest(url: url)
            XCTFail("Expected unsupportedFileType error")
        } catch DocumentParserError.unsupportedFileType {
            // expected
        }
    }

    func testRetrieveSlotsWithEmbeddingBackend() async throws {
        let vectorStore = FakeVectorStore()
        let chunk = DocumentChunk(documentID: UUID(), text: "Relevant passage", chunkIndex: 0)
        let hit = VectorSearchHit(chunk: chunk, documentTitle: "Doc", score: 0.9)
        await vectorStore.setSearchResults([hit])

        let backend = FakeEmbeddingBackend(isModelLoaded: true)
        let sut = RAGService(
            documentStore: FakeDocumentStore(),
            vectorStore: vectorStore,
            embeddingBackend: backend
        )

        let slots = try await sut.retrieveSlots(query: "What is relevant?")
        XCTAssertEqual(slots.count, 1)
        XCTAssertEqual(slots[0].role, .retrieval)
        XCTAssertTrue(slots[0].content.contains("Relevant passage"))
    }

    func testRetrieveSlotsWithoutEmbeddingFallsBackToKeyword() async throws {
        let vectorStore = FakeVectorStore()
        let chunk = DocumentChunk(documentID: UUID(), text: "keyword result", chunkIndex: 0)
        let hit = VectorSearchHit(chunk: chunk, documentTitle: "Doc", score: 1.0)
        await vectorStore.setKeywordResults([hit])

        let sut = RAGService(documentStore: FakeDocumentStore(), vectorStore: vectorStore)

        let slots = try await sut.retrieveSlots(query: "keyword")
        XCTAssertEqual(slots.count, 1)
        XCTAssertTrue(slots[0].content.contains("keyword result"))
    }

    func testRetrieveSlotsWithNoHitsReturnsEmpty() async throws {
        let sut = RAGService(documentStore: FakeDocumentStore(), vectorStore: FakeVectorStore())
        let slots = try await sut.retrieveSlots(query: "anything")
        XCTAssertTrue(slots.isEmpty)
    }

    func testRetrieveSlotsEmptyQueryReturnsEmpty() async throws {
        let sut = RAGService(documentStore: FakeDocumentStore(), vectorStore: FakeVectorStore())
        let slots = try await sut.retrieveSlots(query: "   ")
        XCTAssertTrue(slots.isEmpty)
    }

    func testDeleteDocumentRemovesFromBothStores() async throws {
        let vectorStore = FakeVectorStore()
        let docStore = FakeDocumentStore()
        let sut = RAGService(documentStore: docStore, vectorStore: vectorStore)

        let url = try writeTempFile(content: "Delete me")
        defer { try? FileManager.default.removeItem(at: url) }

        let record = try await sut.ingest(url: url)
        try await sut.deleteDocument(id: record.id)

        let deleted = await vectorStore.deletedDocumentIDs
        XCTAssertTrue(deleted.contains(record.id))
        XCTAssertTrue(docStore.deletedIDs.contains(record.id))
    }

    // MARK: - Helpers

    private func writeTempFile(content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".txt")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

// MARK: - FakeVectorStore helper

private extension FakeVectorStore {
    func setSearchResults(_ results: [VectorSearchHit]) {
        searchResults = results
    }
    func setKeywordResults(_ results: [VectorSearchHit]) {
        keywordResults = results
    }
}
