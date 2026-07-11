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
    /// Records the `limit` the service requested so tests can assert candidate
    /// widening (or the absence of it).
    var lastSearchLimit: Int?
    var lastKeywordLimit: Int?

    func insert(chunks: [DocumentChunk], documentTitle: String, embeddings: [[Float]]) throws {
        insertedChunks.append(contentsOf: chunks)
        insertedEmbeddings.append(contentsOf: embeddings)
        insertedTitles.append(contentsOf: [String](repeating: documentTitle, count: chunks.count))
    }

    func search(embedding: [Float], limit: Int) throws -> [VectorSearchHit] {
        lastSearchLimit = limit
        return searchResults
    }
    func keywordSearch(query: String, limit: Int) throws -> [VectorSearchHit] {
        lastKeywordLimit = limit
        return keywordResults
    }
    func delete(documentID: UUID) throws { deletedDocumentIDs.append(documentID) }
    func deleteAll() throws { insertedChunks.removeAll() }
}

// MARK: - Reranker fakes

/// Reorders candidates with a caller-supplied closure (or reports itself not
/// ready). Lets a test inject a known re-ranking and assert the service honours
/// it.
private struct FakeReranker: Reranker {
    let ready: Bool
    let reorder: @Sendable ([VectorSearchHit]) -> [VectorSearchHit]

    init(ready: Bool = true, reorder: @escaping @Sendable ([VectorSearchHit]) -> [VectorSearchHit]) {
        self.ready = ready
        self.reorder = reorder
    }

    var isReady: Bool { ready }

    func rerank(query: String, candidates: [VectorSearchHit], limit: Int) async throws -> [VectorSearchHit] {
        Array(reorder(candidates).prefix(limit))
    }
}

/// A ready reranker whose `rerank` always throws — drives the graceful
/// fall-back-to-first-stage path.
private struct ThrowingReranker: Reranker {
    struct Boom: Error {}
    var isReady: Bool { true }
    func rerank(query: String, candidates: [VectorSearchHit], limit: Int) async throws -> [VectorSearchHit] {
        throw Boom()
    }
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

/// Returns *fewer* vectors than inputs (here: none), reproducing a backend
/// that does not guarantee output-count == input-count. Drives the
/// `embed([...]).first else { throw }` fallback path.
private final class EmptyResultEmbeddingBackend: EmbeddingBackend, @unchecked Sendable {
    var isModelLoaded: Bool = true
    var dimensions: Int = 4
    var embedCallCount = 0

    func loadModel(from url: URL) async throws { isModelLoaded = true }
    func embed(_ texts: [String]) async throws -> [[Float]] {
        embedCallCount += 1
        return []  // shorter than `texts` — `[0]` would trap
    }
    func unloadModel() { isModelLoaded = false }
}

/// A document store whose `insertDocument` always throws, simulating a
/// SwiftData metadata-row write failure after the vector write has landed.
@MainActor
private final class ThrowingDocumentStore: DocumentStore {
    struct InsertFailure: Error {}
    var insertCallCount = 0

    func insertDocument(_ record: DocumentRecord) throws {
        insertCallCount += 1
        throw InsertFailure()
    }
    func fetchDocuments() throws -> [DocumentRecord] { [] }
    func fetchDocument(id: UUID) throws -> DocumentRecord? { nil }
    func deleteDocument(id: UUID) throws {}
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

    // MARK: - #1622: embed empty result must fall back, not trap

    /// When `embed` returns fewer vectors than inputs (here: empty), the old
    /// `[0]` subscript was a runtime trap the surrounding do/catch could not
    /// intercept. The `.first else { throw }` form must route the failure into
    /// the keyword-search fallback instead.
    func test_retrieve_embedReturnsEmpty_fallsBackToKeyword() async throws {
        let vectorStore = FakeVectorStore()
        let chunk = DocumentChunk(documentID: UUID(), text: "keyword fallback hit", chunkIndex: 0)
        await vectorStore.setKeywordResults([VectorSearchHit(chunk: chunk, documentTitle: "Doc", score: 1.0)])

        let backend = EmptyResultEmbeddingBackend()
        let sut = RAGService(
            documentStore: FakeDocumentStore(),
            vectorStore: vectorStore,
            embeddingBackend: backend
        )

        let result = try await sut.retrieve(query: "anything")

        XCTAssertEqual(backend.embedCallCount, 1, "embed must have been attempted before falling back")
        XCTAssertEqual(result.slots.count, 1)
        XCTAssertTrue(result.slots[0].content.contains("keyword fallback hit"),
                      "empty embed result must route into keyword fallback, not crash")
    }

    // MARK: - #1622: non-atomic ingest rollback

    /// If the SwiftData metadata insert throws after the vectors were already
    /// written, the orphaned chunks must be rolled back so they do not pollute
    /// search/citations invisibly (the UI lists from `documentStore`).
    func test_ingest_metadataInsertFails_rollsBackVectorWrite() async throws {
        let vectorStore = FakeVectorStore()
        let docStore = ThrowingDocumentStore()
        let sut = RAGService(documentStore: docStore, vectorStore: vectorStore)

        let url = try writeTempFile(content: "Some content to chunk and embed.")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await sut.ingest(url: url)
            XCTFail("ingest must rethrow the metadata-insert failure")
        } catch is ThrowingDocumentStore.InsertFailure {
            // expected — the original failure is surfaced
        }

        let inserted = await vectorStore.insertedChunks
        XCTAssertFalse(inserted.isEmpty, "vectors were written before the metadata insert failed")
        let deleted = await vectorStore.deletedDocumentIDs
        XCTAssertEqual(deleted.count, 1, "the orphaned vector write must be rolled back exactly once")
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

    // MARK: - #2199: in-memory text ingestion

    /// The in-memory overload must share the same chunk/insert pipeline as
    /// `ingest(url:)`: chunks land in the vector store and a matching
    /// `DocumentRecord` lands in the document store, keyed to the
    /// caller-supplied `documentID`.
    func test_ingestText_storesChunksAndDocumentKeyedToCallerID() async throws {
        let vectorStore = FakeVectorStore()
        let docStore = FakeDocumentStore()
        let sut = RAGService(documentStore: docStore, vectorStore: vectorStore)

        let documentID = UUID()
        let record = try await sut.ingest(
            text: "Hello world. This is an in-memory test document.",
            documentID: documentID,
            title: "My Scene"
        )

        XCTAssertEqual(record.id, documentID, "the caller-supplied documentID must be preserved, not replaced with a fresh UUID")
        XCTAssertEqual(record.title, "My Scene")

        let inserted = await vectorStore.insertedChunks
        XCTAssertFalse(inserted.isEmpty)
        XCTAssertTrue(inserted.allSatisfy { $0.documentID == documentID })
        XCTAssertEqual(docStore.insertedRecords.count, 1)
        XCTAssertEqual(docStore.insertedRecords[0].id, documentID)
    }

    /// Omitting `title` falls back to the documentID string rather than
    /// leaving an empty/ambiguous label.
    func test_ingestText_defaultTitleFallsBackToDocumentIDString() async throws {
        let sut = RAGService(documentStore: FakeDocumentStore(), vectorStore: FakeVectorStore())
        let documentID = UUID()

        let record = try await sut.ingest(text: "Some text", documentID: documentID)

        XCTAssertEqual(record.title, documentID.uuidString)
    }

    /// The embedding pipeline must run identically to `ingest(url:)`: when a
    /// loaded embedding backend is present, `ingest(text:)` calls it and
    /// stores the resulting vectors.
    func test_ingestText_withEmbeddingBackendCallsEmbed() async throws {
        let vectorStore = FakeVectorStore()
        let docStore = FakeDocumentStore()
        let backend = FakeEmbeddingBackend(isModelLoaded: true)
        let sut = RAGService(documentStore: docStore, vectorStore: vectorStore, embeddingBackend: backend)

        try await sut.ingest(text: String(repeating: "word ", count: 20), documentID: UUID())

        XCTAssertGreaterThan(backend.embedCallCount, 0)
        let embeddings = await vectorStore.insertedEmbeddings
        XCTAssertFalse(embeddings.isEmpty)
    }

    /// The synthetic `sourceURL`/`fileType` must not collide with any
    /// registered `DocumentParser`'s supported extensions — otherwise the
    /// full-context path would attempt (and fail) a filesystem read against a
    /// non-file URL instead of gracefully skipping.
    func test_ingestText_recordCarriesSyntheticNonFileSourceAndUnmatchedFileType() async throws {
        let sut = RAGService(documentStore: FakeDocumentStore(), vectorStore: FakeVectorStore())
        let documentID = UUID()

        let record = try await sut.ingest(text: "Some text", documentID: documentID)

        XCTAssertEqual(record.sourceURL.scheme, "manifold-inmemory")
        let parsers: [any DocumentParser] = [TextDocumentParser(), PDFDocumentParser()]
        XCTAssertFalse(
            parsers.contains { $0.supportedExtensions.contains(record.fileType) },
            "the in-memory fileType marker must not match a registered parser's supported extensions"
        )
    }

    /// `deleteDocument(id:)` must work against text-ingested documents just
    /// like file-ingested ones — the acceptance criterion from #2199.
    func test_ingestText_thenDeleteDocument_removesFromBothStores() async throws {
        let vectorStore = FakeVectorStore()
        let docStore = FakeDocumentStore()
        let sut = RAGService(documentStore: docStore, vectorStore: vectorStore)

        let documentID = UUID()
        let record = try await sut.ingest(text: "Delete me too", documentID: documentID)
        try await sut.deleteDocument(id: record.id)

        let deleted = await vectorStore.deletedDocumentIDs
        XCTAssertTrue(deleted.contains(documentID))
        XCTAssertTrue(docStore.deletedIDs.contains(documentID))
    }

    // MARK: - #1637: rerank stage

    /// Three semantic hits arrive in a deliberately *wrong* cosine order — the
    /// most relevant passage ("C") is ranked last by the bi-encoder. A reranker
    /// that knows C is best must pull it to the front of both the injected slot
    /// content and the citation list.
    func test_retrieve_rerankReordersKnownBadCosineOrdering() async throws {
        let docID = UUID()
        let hitA = VectorSearchHit(chunk: DocumentChunk(documentID: docID, text: "AAA passage", chunkIndex: 0), documentTitle: "Doc", score: 0.90)
        let hitB = VectorSearchHit(chunk: DocumentChunk(documentID: docID, text: "BBB passage", chunkIndex: 1), documentTitle: "Doc", score: 0.80)
        let hitC = VectorSearchHit(chunk: DocumentChunk(documentID: docID, text: "CCC passage", chunkIndex: 2), documentTitle: "Doc", score: 0.70)

        let vectorStore = FakeVectorStore()
        await vectorStore.setSearchResults([hitA, hitB, hitC])  // bad order: C last

        // Reranker knows the true relevance is C > A > B.
        let reranker = FakeReranker { hits in
            hits.sorted { lhs, rhs in
                func rank(_ t: String) -> Int { t.hasPrefix("CCC") ? 0 : t.hasPrefix("AAA") ? 1 : 2 }
                return rank(lhs.chunk.text) < rank(rhs.chunk.text)
            }
        }

        let sut = RAGService(
            documentStore: FakeDocumentStore(),
            vectorStore: vectorStore,
            embeddingBackend: FakeEmbeddingBackend(isModelLoaded: true),
            reranker: reranker
        )

        let result = try await sut.retrieve(query: "which is most relevant?", limit: 3)

        // Citations reflect the reranked order, not the cosine order.
        XCTAssertEqual(result.citations.map(\.chunkIndex), [2, 0, 1],
                       "reranker must reorder citations C, A, B")
        // The injected slot content leads with the reranked-best passage.
        let content = result.slots.first?.content ?? ""
        guard let cPos = content.range(of: "CCC passage")?.lowerBound,
              let aPos = content.range(of: "AAA passage")?.lowerBound else {
            return XCTFail("slot content must contain reranked passages")
        }
        XCTAssertLessThan(cPos, aPos, "reranked-best passage must appear first in the slot")

        // Sabotage: if the service ignored the reranker and used cosine order,
        // citations would be [0, 1, 2] and this equality would fail.
        XCTAssertNotEqual(result.citations.map(\.chunkIndex), [0, 1, 2])
    }

    /// With a reranker loaded, the first-stage fetch must be widened to
    /// `limit * rerankCandidateMultiplier` so the cross-encoder has more
    /// candidates to reorder.
    func test_retrieve_withReranker_widensCandidatePool() async throws {
        let vectorStore = FakeVectorStore()
        let hit = VectorSearchHit(chunk: DocumentChunk(documentID: UUID(), text: "x", chunkIndex: 0), documentTitle: "Doc", score: 0.9)
        await vectorStore.setSearchResults([hit])

        let reranker = FakeReranker { $0 }  // ready, identity reorder
        let sut = RAGService(
            documentStore: FakeDocumentStore(),
            vectorStore: vectorStore,
            embeddingBackend: FakeEmbeddingBackend(isModelLoaded: true),
            reranker: reranker
        )

        _ = try await sut.retrieve(query: "anything", limit: 5)

        let requested = await vectorStore.lastSearchLimit
        XCTAssertEqual(requested, 5 * RAGService.rerankCandidateMultiplier,
                       "candidate pool must be widened to limit*\(RAGService.rerankCandidateMultiplier) when a reranker is active")
    }

    /// Passthrough default: a `PassthroughReranker` (or no reranker) must leave
    /// retrieval byte-for-byte unchanged — same fetch width, same ordering,
    /// same citations as the pre-rerank pipeline.
    func test_retrieve_passthroughDefault_leavesRetrievalUnchanged() async throws {
        let docID = UUID()
        let hits = [
            VectorSearchHit(chunk: DocumentChunk(documentID: docID, text: "first", chunkIndex: 0), documentTitle: "Doc", score: 0.9),
            VectorSearchHit(chunk: DocumentChunk(documentID: docID, text: "second", chunkIndex: 1), documentTitle: "Doc", score: 0.8),
        ]

        func run(reranker: (any Reranker)?) async throws -> (limit: Int?, citations: [Int]) {
            let vectorStore = FakeVectorStore()
            await vectorStore.setSearchResults(hits)
            let sut = RAGService(
                documentStore: FakeDocumentStore(),
                vectorStore: vectorStore,
                embeddingBackend: FakeEmbeddingBackend(isModelLoaded: true),
                reranker: reranker
            )
            let result = try await sut.retrieve(query: "q", limit: 5)
            let limit = await vectorStore.lastSearchLimit
            return (limit, result.citations.map(\.chunkIndex))
        }

        let baseline = try await run(reranker: nil)
        let passthrough = try await run(reranker: PassthroughReranker())

        XCTAssertEqual(baseline.limit, 5, "no reranker must fetch exactly `limit`, not a widened pool")
        XCTAssertEqual(passthrough.limit, 5, "PassthroughReranker must not widen the candidate pool")
        XCTAssertEqual(baseline.citations, passthrough.citations,
                       "passthrough reranker must produce identical results to no reranker")
        XCTAssertEqual(passthrough.citations, [0, 1], "ordering must be unchanged from the first stage")
    }

    /// A reranker that throws must degrade to the first-stage ordering rather
    /// than failing the retrieval.
    func test_retrieve_rerankFailure_fallsBackToFirstStage() async throws {
        let docID = UUID()
        let hits = (0..<3).map {
            VectorSearchHit(chunk: DocumentChunk(documentID: docID, text: "p\($0)", chunkIndex: $0), documentTitle: "Doc", score: Float(0.9) - Float($0) * 0.1)
        }
        let vectorStore = FakeVectorStore()
        await vectorStore.setSearchResults(hits)

        let sut = RAGService(
            documentStore: FakeDocumentStore(),
            vectorStore: vectorStore,
            embeddingBackend: FakeEmbeddingBackend(isModelLoaded: true),
            reranker: ThrowingReranker()
        )

        let result = try await sut.retrieve(query: "q", limit: 2)

        XCTAssertEqual(result.citations.count, 2, "must trim the widened pool back to `limit` even on rerank failure")
        XCTAssertEqual(result.citations.map(\.chunkIndex), [0, 1],
                       "rerank failure must preserve the first-stage cosine ordering")
    }

    // MARK: - #1939 item 6: configurable top-K + similarity threshold

    /// `defaultLimit` (threaded from `RAGConfiguration.topK`) must govern the
    /// first-stage fetch width when the caller passes no explicit `limit` — the
    /// production turn loop calls `retrieve(query:)` with no limit.
    func test_retrieve_defaultLimit_drivesFetchWidthWhenNoExplicitLimit() async throws {
        let vectorStore = FakeVectorStore()
        let hit = VectorSearchHit(chunk: DocumentChunk(documentID: UUID(), text: "x", chunkIndex: 0), documentTitle: "Doc", score: 0.9)
        await vectorStore.setKeywordResults([hit])

        let sut = RAGService(
            documentStore: FakeDocumentStore(),
            vectorStore: vectorStore,
            defaultLimit: 9
        )

        _ = try await sut.retrieve(query: "anything")

        let requested = await vectorStore.lastKeywordLimit
        XCTAssertEqual(requested, 9, "configured defaultLimit (topK) must drive the fetch width")

        // Sabotage: the old hardcoded `limit: 5` would have requested 5, not 9.
        XCTAssertNotEqual(requested, 5)
    }

    /// An explicit `limit` argument still overrides the configured default.
    func test_retrieve_explicitLimit_overridesDefaultLimit() async throws {
        let vectorStore = FakeVectorStore()
        let hit = VectorSearchHit(chunk: DocumentChunk(documentID: UUID(), text: "x", chunkIndex: 0), documentTitle: "Doc", score: 0.9)
        await vectorStore.setKeywordResults([hit])

        let sut = RAGService(
            documentStore: FakeDocumentStore(),
            vectorStore: vectorStore,
            defaultLimit: 9
        )

        _ = try await sut.retrieve(query: "anything", limit: 3)

        let requested = await vectorStore.lastKeywordLimit
        XCTAssertEqual(requested, 3, "explicit limit must override the configured default")
    }

    /// The similarity threshold drops hits scoring strictly below the floor from
    /// both the injected slot and the citation list.
    func test_retrieve_similarityThreshold_filtersLowScoringHits() async throws {
        let docID = UUID()
        let hits = [
            VectorSearchHit(chunk: DocumentChunk(documentID: docID, text: "strong hit", chunkIndex: 0), documentTitle: "Doc", score: 0.80),
            VectorSearchHit(chunk: DocumentChunk(documentID: docID, text: "borderline hit", chunkIndex: 1), documentTitle: "Doc", score: 0.50),
            VectorSearchHit(chunk: DocumentChunk(documentID: docID, text: "weak hit", chunkIndex: 2), documentTitle: "Doc", score: 0.20),
        ]
        let vectorStore = FakeVectorStore()
        await vectorStore.setKeywordResults(hits)

        let sut = RAGService(
            documentStore: FakeDocumentStore(),
            vectorStore: vectorStore,
            similarityThreshold: 0.5
        )

        let result = try await sut.retrieve(query: "q")

        // Only the two hits at-or-above 0.5 survive; the 0.20 hit is dropped.
        XCTAssertEqual(result.citations.map(\.chunkIndex), [0, 1],
                       "hits below the similarity threshold must be filtered out")
        XCTAssertFalse(result.slots[0].content.contains("weak hit"),
                       "below-threshold passage must not reach the injected slot")

        // Sabotage: with the default (0) threshold all three would survive.
        XCTAssertNotEqual(result.citations.map(\.chunkIndex), [0, 1, 2])
    }

    /// A threshold of 0 (the default) is a no-op: every hit the vector store
    /// returns flows through, preserving the historical behaviour.
    func test_retrieve_zeroThreshold_preservesAllHits() async throws {
        let docID = UUID()
        let hits = [
            VectorSearchHit(chunk: DocumentChunk(documentID: docID, text: "a", chunkIndex: 0), documentTitle: "Doc", score: 0.80),
            VectorSearchHit(chunk: DocumentChunk(documentID: docID, text: "b", chunkIndex: 1), documentTitle: "Doc", score: 0.10),
        ]
        let vectorStore = FakeVectorStore()
        await vectorStore.setKeywordResults(hits)

        let sut = RAGService(documentStore: FakeDocumentStore(), vectorStore: vectorStore)

        let result = try await sut.retrieve(query: "q")
        XCTAssertEqual(result.citations.map(\.chunkIndex), [0, 1],
                       "default (0) threshold must not drop any hit")
    }

    /// If every hit falls below the threshold, retrieval round-trips as empty
    /// rather than injecting an empty slot.
    func test_retrieve_allHitsBelowThreshold_returnsEmpty() async throws {
        let hits = [
            VectorSearchHit(chunk: DocumentChunk(documentID: UUID(), text: "weak", chunkIndex: 0), documentTitle: "Doc", score: 0.1),
        ]
        let vectorStore = FakeVectorStore()
        await vectorStore.setKeywordResults(hits)

        let sut = RAGService(
            documentStore: FakeDocumentStore(),
            vectorStore: vectorStore,
            similarityThreshold: 0.9
        )

        let result = try await sut.retrieve(query: "q")
        XCTAssertTrue(result.slots.isEmpty)
        XCTAssertTrue(result.citations.isEmpty)
    }

    // MARK: - #1939 item 7: full-context mode (whole-doc injection)

    /// With `fullContextMode` on and a corpus that fits the token budget, the
    /// retriever must inject the *whole* document verbatim — never touching the
    /// chunk-retrieval path (no vector/keyword search at all).
    func test_fullContextMode_underBudget_injectsWholeDocumentAndSkipsChunking() async throws {
        let body = "The complete contents of a short document, injected verbatim."
        let url = try writeTempFile(content: body)
        defer { try? FileManager.default.removeItem(at: url) }

        let docStore = FakeDocumentStore()
        let docID = UUID()
        docStore.insertedRecords = [
            DocumentRecord(id: docID, title: "ShortDoc", sourceURL: url, fileType: "txt", chunkCount: 1)
        ]

        // The keyword store would return a *different* string if the chunk path
        // ran — its absence in the output proves the whole-doc branch won.
        let vectorStore = FakeVectorStore()
        await vectorStore.setKeywordResults([
            VectorSearchHit(chunk: DocumentChunk(documentID: docID, text: "CHUNK PASSAGE", chunkIndex: 0), documentTitle: "ShortDoc", score: 1.0)
        ])

        let sut = RAGService(
            documentStore: docStore,
            vectorStore: vectorStore,
            fullContextMode: true,
            fullContextBudgetTokens: 8192
        )

        let result = try await sut.retrieve(query: "anything")

        XCTAssertEqual(result.slots.count, 1)
        XCTAssertTrue(result.slots[0].content.contains(body),
                      "the whole document body must be injected verbatim")
        XCTAssertFalse(result.slots[0].content.contains("CHUNK PASSAGE"),
                       "the chunk-retrieval path must not run under full-context mode when under budget")
        XCTAssertEqual(result.citations.count, 1)
        XCTAssertEqual(result.citations[0].documentID, docID)

        // The chunked path was never reached, so the vector store saw no query.
        let keywordLimit = await vectorStore.lastKeywordLimit
        XCTAssertNil(keywordLimit, "no keyword/vector search must happen on the under-budget whole-doc path")

        // Sabotage: with full-context mode OFF this would be the CHUNK PASSAGE.
        XCTAssertNotEqual(result.slots[0].content, "[ShortDoc]\nCHUNK PASSAGE")
    }

    /// With `fullContextMode` on but a corpus that *exceeds* the token budget,
    /// the retriever must fall back to normal chunk retrieval.
    func test_fullContextMode_overBudget_fallsBackToChunkedRetrieval() async throws {
        // A document far larger than a tiny budget forces the fallback.
        let body = String(repeating: "word ", count: 4000)
        let url = try writeTempFile(content: body)
        defer { try? FileManager.default.removeItem(at: url) }

        let docStore = FakeDocumentStore()
        let docID = UUID()
        docStore.insertedRecords = [
            DocumentRecord(id: docID, title: "BigDoc", sourceURL: url, fileType: "txt", chunkCount: 10)
        ]

        let vectorStore = FakeVectorStore()
        await vectorStore.setKeywordResults([
            VectorSearchHit(chunk: DocumentChunk(documentID: docID, text: "CHUNK PASSAGE", chunkIndex: 0), documentTitle: "BigDoc", score: 1.0)
        ])

        let sut = RAGService(
            documentStore: docStore,
            vectorStore: vectorStore,
            fullContextMode: true,
            fullContextBudgetTokens: 16  // far below the ~5000-token corpus
        )

        let result = try await sut.retrieve(query: "anything")

        XCTAssertEqual(result.slots.count, 1)
        XCTAssertTrue(result.slots[0].content.contains("CHUNK PASSAGE"),
                      "over-budget corpus must fall back to the chunk-retrieval path")
        XCTAssertFalse(result.slots[0].content.contains(body),
                       "the whole document must NOT be injected when over budget")

        // The fallback chunked path actually ran a keyword search.
        let keywordLimit = await vectorStore.lastKeywordLimit
        XCTAssertNotNil(keywordLimit, "over-budget fallback must invoke the chunk-retrieval search")
    }

    /// The default (`fullContextMode == false`) must preserve the historical
    /// chunked behaviour even when a corpus would fit a budget.
    func test_fullContextMode_disabledByDefault_usesChunkedRetrieval() async throws {
        let url = try writeTempFile(content: "Tiny doc that would fit any budget.")
        defer { try? FileManager.default.removeItem(at: url) }

        let docStore = FakeDocumentStore()
        let docID = UUID()
        docStore.insertedRecords = [
            DocumentRecord(id: docID, title: "TinyDoc", sourceURL: url, fileType: "txt", chunkCount: 1)
        ]

        let vectorStore = FakeVectorStore()
        await vectorStore.setKeywordResults([
            VectorSearchHit(chunk: DocumentChunk(documentID: docID, text: "CHUNK PASSAGE", chunkIndex: 0), documentTitle: "TinyDoc", score: 1.0)
        ])

        // No fullContextMode argument → defaults to off.
        let sut = RAGService(documentStore: docStore, vectorStore: vectorStore)

        let result = try await sut.retrieve(query: "anything")

        XCTAssertTrue(result.slots[0].content.contains("CHUNK PASSAGE"),
                      "with full-context mode off, retrieval must use chunks")
        let keywordLimit = await vectorStore.lastKeywordLimit
        XCTAssertNotNil(keywordLimit, "default mode must run the chunk-retrieval search")
    }

    /// An empty corpus under full-context mode must fall back to chunked
    /// retrieval (which then round-trips empty) rather than injecting a blank
    /// whole-document slot.
    func test_fullContextMode_emptyCorpus_fallsBackToChunked() async throws {
        let docStore = FakeDocumentStore()  // no documents
        let vectorStore = FakeVectorStore()  // no hits

        let sut = RAGService(
            documentStore: docStore,
            vectorStore: vectorStore,
            fullContextMode: true
        )

        let result = try await sut.retrieve(query: "anything")
        XCTAssertTrue(result.slots.isEmpty)
        XCTAssertTrue(result.citations.isEmpty)

        // The fallback chunked path ran (and found nothing).
        let keywordLimit = await vectorStore.lastKeywordLimit
        XCTAssertNotNil(keywordLimit, "empty corpus must fall through to the chunk-retrieval search")
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
