import XCTest
@testable import BaseChatPersistenceSwiftData
import BaseChatInference
import BaseChatRuntime

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
}
