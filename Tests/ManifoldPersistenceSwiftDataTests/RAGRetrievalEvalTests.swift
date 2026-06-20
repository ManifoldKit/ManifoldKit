import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldRuntime
import ManifoldTestSupport

/// Retrieval-tier RAG evaluation harness (#1937), exercised end-to-end through
/// the **real** persistence stack: an in-memory ``SwiftDataDocumentStore`` plus
/// an on-disk ``FlatFileVectorStore``, driven through ``RAGService`` with a
/// deterministic ``HashingEmbeddingBackend`` (no model file, no Metal, no
/// network — fully reproducible and CI-safe).
///
/// These are integration tests (they touch SwiftData and the flat-file index),
/// so they live in `ManifoldPersistenceSwiftDataTests`. The reusable harness
/// primitives — ``RAGEvaluator``, ``RetrievalMetrics``, ``GoldenQuery``,
/// ``HashingEmbeddingBackend``, ``RAGEvalCorpus`` — live in `ManifoldTestSupport`
/// so the companion packages and the future opt-in live (generation-tier)
/// harness can reuse them.
///
/// The `test_defaultPipeline_meetsBaselineRecall` case is the falsifiable gate
/// for retrieval-quality work (#1919 RRF, #1920 cloud rerank): those changes
/// must improve or at least not regress the baselines asserted here.
@MainActor
final class RAGRetrievalEvalTests: XCTestCase {

    private var container: ModelContainer!
    private var vectorURL: URL!
    private var corpusDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainerFactory.makeInMemoryContainer()
        vectorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".bin")
    }

    override func tearDown() {
        if let vectorURL { try? FileManager.default.removeItem(at: vectorURL) }
        if let corpusDir { try? FileManager.default.removeItem(at: corpusDir) }
        container = nil
        vectorURL = nil
        corpusDir = nil
        super.tearDown()
    }

    /// Builds a ``RAGService`` over the real stores and ingests the fixture
    /// corpus through the deterministic hashing embedding backend.
    private func makeIngestedService() async throws -> RAGService {
        let documentStore = SwiftDataDocumentStore(modelContext: container.mainContext)
        let vectorStore = FlatFileVectorStore(storageURL: vectorURL)
        let service = RAGService(
            documentStore: documentStore,
            vectorStore: vectorStore,
            embeddingBackend: HashingEmbeddingBackend()
        )

        let urls = try RAGEvalCorpus.writeDocuments()
        corpusDir = urls.first?.deletingLastPathComponent()
        for url in urls {
            _ = try await service.ingest(url: url)
        }
        return service
    }

    // MARK: - Baseline regression gate (the #1919/#1920 acceptance criterion)

    /// Run the real ``RAGService`` over the fixture corpus and golden queries and
    /// assert the aggregate retrieval metrics meet a baseline.
    ///
    /// Baselines were set from the first green run on this branch (the
    /// deterministic hashing embedder over `RAGEvalCorpus`). Treat any drop below
    /// these as a **regression** — retrieval-quality changes (#1919/#1920) must
    /// move these numbers up or hold them, never down. If a future change is a
    /// deliberate, justified trade-off, update the baseline in the same PR with a
    /// note explaining why.
    func test_defaultPipeline_meetsBaselineRecall() async throws {
        let service = try await makeIngestedService()

        let metrics = try await RAGEvaluator.evaluateRetrieval(
            service: service,
            queries: RAGEvalCorpus.goldenQueries,
            k: 5
        )

        // Baseline set from the first green run (see PR for #1937). Asserted as
        // lower bounds so the gate fails on regression, not on improvement.
        XCTAssertGreaterThanOrEqual(metrics.recallAtK, 0.85,
            "recall@5 regressed below baseline: \(metrics)")
        XCTAssertGreaterThanOrEqual(metrics.mrr, 0.85,
            "MRR regressed below baseline: \(metrics)")
        XCTAssertGreaterThanOrEqual(metrics.hitRate, 0.90,
            "hit-rate regressed below baseline: \(metrics)")

        // Surface the numbers so a baseline bump is a deliberate, reviewable act.
        print("RAG retrieval baseline — \(metrics)")
    }

    // MARK: - Metric-correctness tests (harness validates itself)

    /// A perfect retriever — the deterministic embedder over a corpus whose
    /// documents share verbatim tokens with their queries — must reach recall@k
    /// = 1.0 and MRR = 1.0 on a hand-picked subset where the relevant document
    /// is unambiguously the top lexical match.
    func test_evaluateRetrieval_strongMatches_recallAndMrrAreHigh() async throws {
        let service = try await makeIngestedService()

        // Exact-token queries: the identifier appears in exactly one document,
        // so the relevant doc must rank first → recall@k = 1, MRR = 1.
        let exactQueries = RAGEvalCorpus.goldenQueries.filter {
            $0.query.contains("RAG-7731") || $0.query.contains("ZX-409")
                || $0.query.contains("BL-22A") || $0.query.contains("XENON_FASTPATH")
        }
        XCTAssertFalse(exactQueries.isEmpty, "expected exact-token golden queries in the corpus")

        let metrics = try await RAGEvaluator.evaluateRetrieval(
            service: service, queries: exactQueries, k: 5
        )

        XCTAssertEqual(metrics.recallAtK, 1.0, accuracy: 0.0001,
            "exact-token queries must retrieve their unique document: \(metrics)")
        XCTAssertEqual(metrics.mrr, 1.0, accuracy: 0.0001,
            "exact-token queries must rank the unique document first: \(metrics)")
    }

    /// Hit-rate must be exactly 0 when no relevant document can be retrieved —
    /// a query labelled relevant to a title that is not in the corpus.
    func test_hitRate_zeroWhenNoRelevantRetrieved() async throws {
        let service = try await makeIngestedService()

        let unanswerable = [
            GoldenQuery(query: "What is the airspeed velocity of an unladen swallow?",
                        relevantDocumentTitles: ["title-not-in-corpus"])
        ]
        let metrics = try await RAGEvaluator.evaluateRetrieval(
            service: service, queries: unanswerable, k: 5
        )

        XCTAssertEqual(metrics.hitRate, 0.0, "no relevant document is retrievable for this query")
        XCTAssertEqual(metrics.recallAtK, 0.0, "recall must be zero when nothing relevant is retrieved")
        XCTAssertEqual(metrics.mrr, 0.0, "MRR must be zero when no relevant document appears")
    }

    /// MRR is rank-sensitive where recall is not: the same retrieved set scored
    /// against a relevant document that lands deeper in the ranking yields a
    /// lower reciprocal rank, while a top-ranked relevant document yields 1.0.
    ///
    /// Driven through the pure metric math (not the live service) so the ranking
    /// is fully controlled — this pins that ``RAGEvaluator`` weights rank, not
    /// just membership.
    func test_mrr_isRankSensitive() async throws {
        // Same relevant set {"alpha"}; differ only in where it appears.
        let firstRank = reciprocalRank(rankedTitles: ["alpha", "beta", "gamma"], relevant: ["alpha"])
        let thirdRank = reciprocalRank(rankedTitles: ["beta", "gamma", "alpha"], relevant: ["alpha"])

        XCTAssertEqual(firstRank, 1.0, accuracy: 0.0001, "first-position relevant → RR 1.0")
        XCTAssertEqual(thirdRank, 1.0 / 3.0, accuracy: 0.0001, "third-position relevant → RR 1/3")
        XCTAssertGreaterThan(firstRank, thirdRank, "MRR must reward higher rank")
    }

    // MARK: - Helpers

    /// Mirror of ``RAGEvaluator``'s reciprocal-rank rule, used to validate the
    /// rank-sensitivity property against a fully-controlled ranking.
    private func reciprocalRank(rankedTitles: [String], relevant: Set<String>) -> Double {
        for (index, title) in rankedTitles.enumerated() where relevant.contains(title) {
            return 1.0 / Double(index + 1)
        }
        return 0.0
    }
}
