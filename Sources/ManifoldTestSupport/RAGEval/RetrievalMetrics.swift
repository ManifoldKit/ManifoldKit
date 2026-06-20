import Foundation

/// A hand-labelled query paired with the set of documents that *should* be
/// retrieved for it — the ground truth a retrieval-quality metric is scored
/// against.
///
/// Relevance is keyed by **document title** rather than chunk UUID. Chunk UUIDs
/// are minted non-deterministically at ingest time and are *not* exposed on the
/// ``Citation`` a retrieval call returns (a citation carries `documentID`,
/// `documentTitle`, and `chunkIndex` — never the chunk's own UUID), so a
/// chunk-UUID label could never be matched back against a real retrieval result.
/// Title-keyed labels are stable across ingests and round-trip cleanly through
/// the citation list. The fixture corpus keeps each document to a single chunk
/// so "document relevant" and "chunk relevant" coincide.
public struct GoldenQuery: Sendable, Hashable {
    /// The natural-language query to retrieve against.
    public let query: String
    /// Titles of the documents considered relevant ground truth for `query`.
    /// `RAGService` derives a document title from the source file name
    /// (sans extension), so these must match the corpus file stems.
    public let relevantDocumentTitles: Set<String>

    public init(query: String, relevantDocumentTitles: Set<String>) {
        self.query = query
        self.relevantDocumentTitles = relevantDocumentTitles
    }
}

/// Aggregate retrieval-quality metrics computed over a set of ``GoldenQuery``
/// labels at a fixed cut-off `k`.
///
/// All four are deterministic functions of the retrieved ranking and the
/// ground-truth labels — no language model is involved, so they are CI-safe and
/// reproducible. This is the *retrieval tier* of the RAG eval harness (#1937);
/// the generation tier (faithfulness / answer-relevancy via an LLM-as-judge) is
/// deferred to an opt-in live harness — see ``RAGEvaluator`` for the stub.
public struct RetrievalMetrics: Sendable, Hashable {
    /// Fraction of queries with at least one relevant document in the top-`k`.
    /// Range `[0, 1]`.
    public let hitRate: Double
    /// Mean over queries of `|relevant ∩ top-k| / |relevant|`. Range `[0, 1]`.
    public let recallAtK: Double
    /// Mean over queries of `|relevant ∩ top-k| / k`. Range `[0, 1]`.
    public let precisionAtK: Double
    /// Mean reciprocal rank: average of `1 / rank-of-first-relevant`
    /// (rank is 1-based; `0` contributed when no relevant document is in the
    /// top-`k`). Range `[0, 1]`. Rank-sensitive where recall is not.
    public let mrr: Double
    /// The cut-off the metrics were computed at.
    public let k: Int
    /// Number of queries evaluated.
    public let queryCount: Int

    public init(
        hitRate: Double,
        recallAtK: Double,
        precisionAtK: Double,
        mrr: Double,
        k: Int,
        queryCount: Int
    ) {
        self.hitRate = hitRate
        self.recallAtK = recallAtK
        self.precisionAtK = precisionAtK
        self.mrr = mrr
        self.k = k
        self.queryCount = queryCount
    }
}

extension RetrievalMetrics: CustomStringConvertible {
    public var description: String {
        String(
            format: "RetrievalMetrics(k=%d, n=%d) hitRate=%.3f recall@k=%.3f precision@k=%.3f MRR=%.3f",
            k, queryCount, hitRate, recallAtK, precisionAtK, mrr
        )
    }
}
