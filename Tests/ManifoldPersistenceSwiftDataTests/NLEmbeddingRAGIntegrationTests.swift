#if canImport(NaturalLanguage)
import XCTest
import SwiftData
import NaturalLanguage
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldRuntime

/// End-to-end integration coverage for the bundled on-device
/// ``NLEmbeddingBackend`` (issue #1812 Stage 1): embed real text with Apple's
/// `NaturalLanguage` framework, persist the vectors through the shipped
/// ``FlatFileVectorStore``, and retrieve through ``RAGService`` driving an
/// in-memory ``SwiftDataDocumentStore``.
///
/// These touch SwiftData and the on-disk flat-file index, so they are
/// integration tests and live here rather than in a unit suite. No mocks are
/// used for the embedding or persistence paths — only the real stack.
@MainActor
final class NLEmbeddingRAGIntegrationTests: XCTestCase {

    private var container: ModelContainer!
    private var vectorURL: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // Skip on hosts/locales where Apple ships no sentence-embedding model —
        // the backend is correctly nil there and RAG degrades to keyword search.
        try XCTSkipIf(
            NLEmbedding.sentenceEmbedding(for: .english) == nil,
            "No English sentence-embedding model on this host."
        )
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

    private func makeRAGService() throws -> RAGService {
        let backend = try XCTUnwrap(NLEmbeddingBackend(), "NLEmbeddingBackend should construct after the skip guard.")
        XCTAssertTrue(backend.isModelLoaded)
        XCTAssertGreaterThan(backend.dimensions, 0)

        let documentStore = SwiftDataDocumentStore(modelContext: container.mainContext)
        let vectorStore = FlatFileVectorStore(storageURL: vectorURL)
        return RAGService(
            documentStore: documentStore,
            vectorStore: vectorStore,
            embeddingBackend: backend
        )
    }

    /// Embed three semantically distinct documents, store them via the real
    /// flat-file index, then query with text semantically near one of them.
    /// The relevant document must rank top — proving NLEmbedding's vectors
    /// produce a usable nearest-neighbour signal through the shipped store.
    func test_embedStoreRetrieve_semanticQueryRanksRelevantDocTop() async throws {
        let rag = try makeRAGService()

        try await ingest(rag, title: "Cooking",
            text: "Preheat the oven and bake the bread until the crust turns golden brown.")
        try await ingest(rag, title: "Astronomy",
            text: "The telescope captured a distant galaxy of countless stars and nebulae.")
        try await ingest(rag, title: "Finance",
            text: "The company reported strong quarterly earnings and raised its dividend.")

        // Semantically near the Astronomy passage but shares no salient keyword
        // (no "telescope"/"galaxy"/"stars"), so a keyword fallback would not
        // float it — this exercises the vector path.
        let result = try await rag.retrieve(query: "observing planets and the night sky", limit: 3)

        let topTitle = try XCTUnwrap(result.citations.first?.documentTitle, "Expected at least one hit.")
        XCTAssertEqual(topTitle, "Astronomy",
            "Semantic query should rank the astronomy document first via NLEmbedding vectors.")
    }

    /// Negative assertion: a query semantically far from every stored document
    /// must NOT rank the astronomy document top. This is the sabotage check kept
    /// as a genuine negative — if NLEmbedding vectors collapsed to a constant
    /// (or the wiring fell back to a degenerate path) the semantic ordering
    /// above would be meaningless, and this would fail.
    func test_embedStoreRetrieve_unrelatedQueryDoesNotRankAstronomyTop() async throws {
        let rag = try makeRAGService()

        try await ingest(rag, title: "Cooking",
            text: "Preheat the oven and bake the bread until the crust turns golden brown.")
        try await ingest(rag, title: "Astronomy",
            text: "The telescope captured a distant galaxy of countless stars and nebulae.")
        try await ingest(rag, title: "Finance",
            text: "The company reported strong quarterly earnings and raised its dividend.")

        let result = try await rag.retrieve(query: "stir the simmering soup and season the stew", limit: 3)

        let topTitle = try XCTUnwrap(result.citations.first?.documentTitle, "Expected at least one hit.")
        XCTAssertNotEqual(topTitle, "Astronomy",
            "A cooking-themed query must not rank the astronomy document first.")
        XCTAssertEqual(topTitle, "Cooking",
            "A cooking-themed query should rank the cooking document first.")
    }

    /// The default-resolution seam used by `quickStart()` / bootstrap returns
    /// the bundled backend when the host injects nothing, and honours a
    /// host-supplied backend over the default.
    func test_resolveEmbeddingBackend_defaultsToBundledAndHonoursOverride() throws {
        let resolvedDefault = try XCTUnwrap(
            ManifoldBootstrap.resolveEmbeddingBackend(nil),
            "Bootstrap should fall back to the bundled NLEmbeddingBackend."
        )
        XCTAssertTrue(resolvedDefault is NLEmbeddingBackend)

        let host = try XCTUnwrap(NLEmbeddingBackend())
        let resolvedOverride = ManifoldBootstrap.resolveEmbeddingBackend(host)
        XCTAssertTrue(resolvedOverride === host, "Host-supplied backend must win over the default.")
    }

    // MARK: - Helpers

    private func ingest(_ rag: RAGService, title: String, text: String) async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(title)-\(UUID().uuidString).txt")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        // The parser derives the title from the file's last path component; we
        // assert on the human title above, so name the file accordingly.
        let titledURL = url.deletingLastPathComponent().appendingPathComponent("\(title).txt")
        try? FileManager.default.removeItem(at: titledURL)
        try FileManager.default.moveItem(at: url, to: titledURL)
        defer { try? FileManager.default.removeItem(at: titledURL) }
        try await rag.ingest(url: titledURL)
    }
}
#endif
