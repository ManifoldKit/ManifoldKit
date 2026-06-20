import XCTest
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldRuntime

final class FlatFileVectorStoreTests: XCTestCase {

    private var storeURL: URL!

    override func setUp() {
        super.setUp()
        storeURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: storeURL)
        super.tearDown()
    }

    func testEmptyStoreSearchReturnsNothing() async throws {
        let store = FlatFileVectorStore(storageURL: storeURL)
        let results = try await store.search(embedding: [1, 0, 0], limit: 5)
        XCTAssertTrue(results.isEmpty)
    }

    func testInsertAndSearchReturnsHits() async throws {
        let store = FlatFileVectorStore(storageURL: storeURL)
        let docID = UUID()
        let chunk = DocumentChunk(documentID: docID, text: "The quick brown fox", chunkIndex: 0)
        // Unit vector along first axis
        try await store.insert(chunks: [chunk], documentTitle: "Doc", embeddings: [[1, 0, 0]])

        let results = try await store.search(embedding: [1, 0, 0], limit: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].chunk.text, "The quick brown fox")
        XCTAssertEqual(results[0].documentTitle, "Doc")
        XCTAssertGreaterThan(results[0].score, 0.99)
    }

    func testSearchResultsAreSortedByDescendingScore() async throws {
        let store = FlatFileVectorStore(storageURL: storeURL)
        let docID = UUID()
        let chunkA = DocumentChunk(id: UUID(), documentID: docID, text: "A", chunkIndex: 0)
        let chunkB = DocumentChunk(id: UUID(), documentID: docID, text: "B", chunkIndex: 1)
        // chunkA is aligned with query; chunkB is perpendicular
        try await store.insert(
            chunks: [chunkA, chunkB],
            documentTitle: "Doc",
            embeddings: [[1, 0, 0], [0, 1, 0]]
        )

        let results = try await store.search(embedding: [1, 0, 0], limit: 5)
        XCTAssertEqual(results.count, 2)
        XCTAssertGreaterThanOrEqual(results[0].score, results[1].score)
        XCTAssertEqual(results[0].chunk.text, "A")
    }

    func testSearchRespectsLimit() async throws {
        let store = FlatFileVectorStore(storageURL: storeURL)
        let docID = UUID()
        let chunks = (0..<10).map { i in
            DocumentChunk(documentID: docID, text: "chunk \(i)", chunkIndex: i)
        }
        let embeddings = chunks.map { _ in [Float(1), 0, 0] }
        try await store.insert(chunks: chunks, documentTitle: "Doc", embeddings: embeddings)

        let results = try await store.search(embedding: [1, 0, 0], limit: 3)
        XCTAssertEqual(results.count, 3)
    }

    func testKeywordSearchFindsMatches() async throws {
        let store = FlatFileVectorStore(storageURL: storeURL)
        let docID = UUID()
        let chunkA = DocumentChunk(documentID: docID, text: "Swift is great", chunkIndex: 0)
        let chunkB = DocumentChunk(documentID: docID, text: "Python is also good", chunkIndex: 1)
        try await store.insert(chunks: [chunkA, chunkB], documentTitle: "Doc", embeddings: [])

        let results = try await store.keywordSearch(query: "swift", limit: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].chunk.text.lowercased().contains("swift"))
    }

    func testDeleteRemovesChunksForDocument() async throws {
        let store = FlatFileVectorStore(storageURL: storeURL)
        let docID = UUID()
        let chunk = DocumentChunk(documentID: docID, text: "To be deleted", chunkIndex: 0)
        try await store.insert(chunks: [chunk], documentTitle: "Doc", embeddings: [[1, 0, 0]])

        try await store.delete(documentID: docID)

        let results = try await store.search(embedding: [1, 0, 0], limit: 5)
        XCTAssertTrue(results.isEmpty)
    }

    func testDeleteAllClearsStore() async throws {
        let store = FlatFileVectorStore(storageURL: storeURL)
        let docID = UUID()
        let chunks = [DocumentChunk(documentID: docID, text: "text", chunkIndex: 0)]
        try await store.insert(chunks: chunks, documentTitle: "Doc", embeddings: [[1, 0, 0]])

        try await store.deleteAll()
        let results = try await store.search(embedding: [1, 0, 0], limit: 5)
        XCTAssertTrue(results.isEmpty)
    }

    func testPersistenceRoundTrip() async throws {
        // Insert into one store instance, reload from file in a second instance
        let store1 = FlatFileVectorStore(storageURL: storeURL)
        let docID = UUID()
        let chunk = DocumentChunk(documentID: docID, text: "Persisted chunk", chunkIndex: 0)
        try await store1.insert(chunks: [chunk], documentTitle: "Source", embeddings: [[0, 1, 0]])

        let store2 = FlatFileVectorStore(storageURL: storeURL)
        let results = try await store2.keywordSearch(query: "persisted", limit: 5)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].chunk.text, "Persisted chunk")
        XCTAssertEqual(results[0].documentTitle, "Source")
    }

    func testChunksWithNoEmbeddingAreExcludedFromVectorSearch() async throws {
        let store = FlatFileVectorStore(storageURL: storeURL)
        let docID = UUID()
        let chunk = DocumentChunk(documentID: docID, text: "keyword only chunk", chunkIndex: 0)
        // Insert with empty embeddings (keyword-only indexing)
        try await store.insert(chunks: [chunk], documentTitle: "Doc", embeddings: [])

        let vectorResults = try await store.search(embedding: [1, 0, 0], limit: 5)
        XCTAssertTrue(vectorResults.isEmpty, "Chunks without embeddings must not appear in vector search")

        let keywordResults = try await store.keywordSearch(query: "keyword", limit: 5)
        XCTAssertEqual(keywordResults.count, 1)
    }

    // Sabotage: deleted chunks must not appear
    func testSabotageDeletedChunksDoNotAppear() async throws {
        let store = FlatFileVectorStore(storageURL: storeURL)
        let docID = UUID()
        let chunk = DocumentChunk(documentID: docID, text: "delete me", chunkIndex: 0)
        try await store.insert(chunks: [chunk], documentTitle: "Doc", embeddings: [[1, 0, 0]])
        try await store.delete(documentID: docID)

        let keyword = try await store.keywordSearch(query: "delete", limit: 5)
        XCTAssertTrue(keyword.isEmpty, "Deleted chunks must not appear in keyword search")
    }

    // MARK: - BM25 sparse search (#1919)

    func testBM25SearchRanksRareTermFirst() async throws {
        let store = FlatFileVectorStore(storageURL: storeURL)
        let docID = UUID()
        let rare = DocumentChunk(documentID: docID, text: "engine xz9plasma module", chunkIndex: 0)
        let common = DocumentChunk(documentID: docID, text: "engine engine engine", chunkIndex: 1)
        let filler = DocumentChunk(documentID: docID, text: "an engine somewhere", chunkIndex: 2)
        // No embeddings needed — BM25 scores text only.
        try await store.insert(
            chunks: [rare, common, filler],
            documentTitle: "Doc",
            embeddings: []
        )

        let hits = try await store.bm25Search(query: "engine xz9plasma", limit: 5)
        // All three chunks contain "engine" (a positive-IDF term even at df == N),
        // so BM25 scores all three — proving the concrete BM25 witness runs, not
        // the substring-keyword default that would match only the literal phrase.
        XCTAssertEqual(hits.count, 3, "bm25 returned \(hits.map(\.chunk.text))")
        XCTAssertEqual(hits.first?.chunk.text, "engine xz9plasma module",
                       "The chunk with the rare query term must rank first under BM25")
        // Real term-weighted scores: distinct chunks score differently — the
        // rare-term chunk strictly above the common-only chunks. Under the legacy
        // constant-1.0 keyword scorer every match tied, so this distinction is
        // only possible with BM25.
        let scores = hits.map(\.score)
        XCTAssertGreaterThan(scores[0], scores[1],
                             "Rare-term chunk must outscore common-only chunks under BM25")
    }

    func testBM25SearchEmptyQueryReturnsNothing() async throws {
        let store = FlatFileVectorStore(storageURL: storeURL)
        try await store.insert(
            chunks: [DocumentChunk(documentID: UUID(), text: "some text", chunkIndex: 0)],
            documentTitle: "Doc",
            embeddings: []
        )
        let hits = try await store.bm25Search(query: "", limit: 5)
        XCTAssertTrue(hits.isEmpty)
    }
}
