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

/// Records every text passed to `embed(_:)` so tests can inspect whether
/// the RAG service truncated the query before calling the backend.
private final class CapturingEmbeddingBackend: EmbeddingBackend, @unchecked Sendable {
    var isModelLoaded: Bool = true
    var dimensions: Int = 4
    var capturedTexts: [String] = []

    func loadModel(from url: URL) async throws { isModelLoaded = true }
    func embed(_ texts: [String]) async throws -> [[Float]] {
        capturedTexts.append(contentsOf: texts)
        return texts.map { _ in [1.0, 0.0, 0.0, 0.0] }
    }
    func unloadModel() { isModelLoaded = false }
}

/// Always returns an empty array — exercises the guard-let crash fix (#1622 item 2).
private final class EmptyEmbeddingBackend: EmbeddingBackend, @unchecked Sendable {
    var isModelLoaded: Bool = true
    var dimensions: Int = 4
    func loadModel(from url: URL) async throws { isModelLoaded = true }
    func embed(_ texts: [String]) async throws -> [[Float]] { return [] }
    func unloadModel() { isModelLoaded = false }
}

/// Throws on `insertDocument` — exercises the vector-rollback path (#1622 item 5).
@MainActor
private final class ThrowingDocumentStore: DocumentStore {
    struct StoreError: Error {}
    var insertedRecords: [DocumentRecord] = []
    var deletedIDs: [UUID] = []

    func insertDocument(_ record: DocumentRecord) throws { throw StoreError() }
    func fetchDocuments() throws -> [DocumentRecord] { insertedRecords }
    func fetchDocument(id: UUID) throws -> DocumentRecord? { nil }
    func deleteDocument(id: UUID) throws {
        insertedRecords.removeAll { $0.id == id }
        deletedIDs.append(id)
    }
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

    // MARK: - retrieve(query:) — citations

    func testRetrieveReturnsCitationsForEachHit() async throws {
        let vectorStore = FakeVectorStore()
        let docID = UUID()
        let hits = [
            VectorSearchHit(
                chunk: DocumentChunk(documentID: docID, text: "First passage about widgets.", chunkIndex: 0),
                documentTitle: "Widgets.pdf",
                score: 0.91
            ),
            VectorSearchHit(
                chunk: DocumentChunk(documentID: docID, text: "Second passage about widgets and gadgets.", chunkIndex: 3),
                documentTitle: "Widgets.pdf",
                score: 0.78
            ),
        ]
        await vectorStore.setKeywordResults(hits)

        let sut = RAGService(documentStore: FakeDocumentStore(), vectorStore: vectorStore)
        let result = try await sut.retrieve(query: "widgets")

        XCTAssertEqual(result.slots.count, 1)
        XCTAssertEqual(result.citations.count, 2)
        XCTAssertEqual(result.citations[0].documentID, docID)
        XCTAssertEqual(result.citations[0].documentTitle, "Widgets.pdf")
        XCTAssertEqual(result.citations[0].chunkIndex, 0)
        XCTAssertEqual(result.citations[0].score, 0.91, accuracy: 0.001)
        XCTAssertEqual(result.citations[1].chunkIndex, 3)
        XCTAssertTrue(result.citations[0].snippet.contains("First passage"))
    }

    func testRetrieveEmptyQueryReturnsEmptyResult() async throws {
        let sut = RAGService(documentStore: FakeDocumentStore(), vectorStore: FakeVectorStore())
        let result = try await sut.retrieve(query: "  ")
        XCTAssertTrue(result.slots.isEmpty)
        XCTAssertTrue(result.citations.isEmpty)
    }

    func testRetrieveNoHitsReturnsEmptyResult() async throws {
        let sut = RAGService(documentStore: FakeDocumentStore(), vectorStore: FakeVectorStore())
        let result = try await sut.retrieve(query: "anything")
        XCTAssertTrue(result.slots.isEmpty)
        XCTAssertTrue(result.citations.isEmpty)
    }

    func testCitationSnippetTruncatesLongText() {
        let longText = String(repeating: "a", count: Citation.snippetCharacterLimit + 50)
        let citation = Citation(
            documentID: UUID(),
            documentTitle: "Doc",
            chunkIndex: 0,
            fullText: longText,
            score: 1.0
        )
        XCTAssertTrue(citation.snippet.hasSuffix("…"))
        XCTAssertEqual(citation.snippet.count, Citation.snippetCharacterLimit + 1)
    }

    func testCitationSnippetPreservesShortText() {
        let citation = Citation(
            documentID: UUID(),
            documentTitle: "Doc",
            chunkIndex: 0,
            fullText: "Short.",
            score: 1.0
        )
        XCTAssertEqual(citation.snippet, "Short.")
    }

    // MARK: - SEC-02: RAG query size cap

    /// A query longer than maxRAGQueryBytes must be truncated to at most
    /// maxRAGQueryBytes UTF-8 bytes before hitting the embedding backend.
    func test_retrieve_oversizeQuery_isTruncatedBeforeEmbedding() async throws {
        let maxBytes = 8_000
        var config = ManifoldConfiguration.shared
        config.maxRAGQueryBytes = maxBytes
        ManifoldConfiguration.shared = config
        defer {
            var restore = ManifoldConfiguration.shared
            restore.maxRAGQueryBytes = 8_000
            ManifoldConfiguration.shared = restore
        }

        // Build a query that is clearly over the limit: 10_000 ASCII bytes.
        let oversizeQuery = String(repeating: "a", count: 10_000)
        XCTAssertGreaterThan(oversizeQuery.utf8.count, maxBytes)

        // FakeEmbeddingBackend stores the text it received so we can inspect it.
        let capturingBackend = CapturingEmbeddingBackend()
        let vectorStore = FakeVectorStore()
        let sut = RAGService(
            documentStore: FakeDocumentStore(),
            vectorStore: vectorStore,
            embeddingBackend: capturingBackend
        )

        _ = try await sut.retrieve(query: oversizeQuery)

        let capturedTexts = capturingBackend.capturedTexts
        XCTAssertEqual(capturedTexts.count, 1,
                       "embedding backend must receive exactly one query text")
        let receivedBytes = capturedTexts[0].utf8.count
        XCTAssertLessThanOrEqual(receivedBytes, maxBytes,
                                 "embedded query must be capped at \(maxBytes) bytes, got \(receivedBytes)")

        // Sabotage: confirm the test would fail if truncation weren't applied.
        XCTAssertLessThan(receivedBytes, oversizeQuery.utf8.count,
                          "captured query must be shorter than the original oversize input")
    }

    /// A query at exactly the limit must pass through unchanged.
    func test_retrieve_atLimitQuery_isNotTruncated() async throws {
        let maxBytes = 8_000
        // Construct a query whose UTF-8 length is exactly maxBytes.
        let exactQuery = String(repeating: "x", count: maxBytes)
        XCTAssertEqual(exactQuery.utf8.count, maxBytes)

        let capturingBackend = CapturingEmbeddingBackend()
        let vectorStore = FakeVectorStore()
        let sut = RAGService(
            documentStore: FakeDocumentStore(),
            vectorStore: vectorStore,
            embeddingBackend: capturingBackend
        )

        _ = try await sut.retrieve(query: exactQuery)

        let capturedTexts = capturingBackend.capturedTexts
        guard capturedTexts.count == 1 else {
            XCTFail("Expected 1 captured text, got \(capturedTexts.count)")
            return
        }
        XCTAssertEqual(capturedTexts[0].utf8.count, maxBytes,
                       "query at exactly the limit must not be truncated")
    }

    // MARK: - Fix #1622 item 2: empty embedding guard

    /// When the embedding backend returns an empty array the service must not crash;
    /// it must fall back to keyword search instead.
    func test_retrieve_embedReturnsEmpty_fallsBackToKeyword() async throws {
        let vectorStore = FakeVectorStore()
        let chunk = DocumentChunk(documentID: UUID(), text: "fallback hit", chunkIndex: 0)
        await vectorStore.setKeywordResults([VectorSearchHit(chunk: chunk, documentTitle: "Doc", score: 1.0)])

        let sut = RAGService(
            documentStore: FakeDocumentStore(),
            vectorStore: vectorStore,
            embeddingBackend: EmptyEmbeddingBackend()
        )

        let slots = try await sut.retrieveSlots(query: "anything")
        XCTAssertEqual(slots.count, 1, "Must fall back to keyword search when embed returns empty")
        XCTAssertTrue(slots[0].content.contains("fallback hit"))
        // Sabotage: removing the guard-let around embed().first would cause a crash
        // (force-unwrapping nil from an empty array) instead of falling back here.
    }

    // MARK: - Fix #1622 item 5: non-atomic ingest rollback

    /// When the metadata write fails after the vector chunks are already written,
    /// the service must delete the orphaned vector entries and rethrow the error.
    func test_ingest_documentStoreThrows_rollsBackVectors() async throws {
        let vectorStore = FakeVectorStore()
        let docStore = ThrowingDocumentStore()
        let sut = RAGService(documentStore: docStore, vectorStore: vectorStore)

        let url = try writeTempFile(content: "Some content that will be chunked")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            try await sut.ingest(url: url)
            XCTFail("Expected error from ThrowingDocumentStore")
        } catch is ThrowingDocumentStore.StoreError {
            // expected
        }

        let deleted = await vectorStore.deletedDocumentIDs
        XCTAssertEqual(deleted.count, 1, "Vector chunks must be rolled back on metadata failure")
        let inserted = await vectorStore.insertedChunks
        // Inserted chunks use the same documentID that was rolled back.
        XCTAssertEqual(deleted[0], inserted[0].documentID)
        // Sabotage: removing the vectorStore.delete(documentID:) call from the catch block
        // in RAGService.ingest would leave deleted.count == 0, failing this assertion.
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
