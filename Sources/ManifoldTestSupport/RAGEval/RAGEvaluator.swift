import Foundation
import ManifoldInference
import ManifoldRuntime

/// First-party RAG **retrieval-tier** evaluation harness (#1937).
///
/// Drives the real ``RAGService/retrieve(query:limit:)`` path over a corpus that
/// has already been ingested into the service's stores, scores the returned
/// ranking against hand-labelled ``GoldenQuery`` ground truth, and reports
/// deterministic ``RetrievalMetrics`` (hit-rate, recall@k, precision@k, MRR).
///
/// Because the metrics are pure functions of the ranking and the labels — no
/// language model — they are CI-safe and reproducible. This makes the harness
/// the falsifiable gate for retrieval-quality work (RRF / cloud rerank, #1919 /
/// #1920): those changes must *improve or not regress* the baseline asserted by
/// the consuming test.
///
/// ## Generation tier — deferred
///
/// LlamaIndex-style faithfulness / answer-relevancy / context-relevancy require
/// an LLM-as-judge: non-deterministic, slow, and impossible to run in core CI
/// without a bundled judge model. That tier is intentionally **not** implemented
/// here. See ``evaluateGeneration(service:queries:k:)`` for the env-gated stub
/// and the follow-up note.
public enum RAGEvaluator {

    /// Runs `service.retrieve` for each golden query and computes aggregate
    /// retrieval metrics at cut-off `k`.
    ///
    /// The `service` must already have the fixture corpus ingested (see
    /// ``RAGEvalCorpus``). Relevance is matched by **document title**: a
    /// retrieved ``Citation`` counts as relevant when its `documentTitle` is in
    /// the query's `relevantDocumentTitles`. Duplicate titles within one
    /// retrieval (multiple chunks from the same doc) collapse to a single
    /// relevant document so recall is not inflated past `1.0`.
    ///
    /// - Parameters:
    ///   - service: A ``RAGService`` with the corpus ingested.
    ///   - queries: Hand-labelled ground-truth queries.
    ///   - k: Retrieval cut-off (top-`k`). Must be `> 0`.
    /// - Returns: Aggregate ``RetrievalMetrics`` over all queries.
    public static func evaluateRetrieval(
        service: RAGService,
        queries: [GoldenQuery],
        k: Int
    ) async throws -> RetrievalMetrics {
        precondition(k > 0, "retrieval cut-off k must be positive")
        guard !queries.isEmpty else {
            return RetrievalMetrics(
                hitRate: 0, recallAtK: 0, precisionAtK: 0, mrr: 0, k: k, queryCount: 0
            )
        }

        var hitSum = 0.0
        var recallSum = 0.0
        var precisionSum = 0.0
        var reciprocalRankSum = 0.0

        for golden in queries {
            let result = try await service.retrieve(query: golden.query, limit: k)
            // The retrieved ranking as document titles, ordered by relevance
            // (citations are returned in retrieval order — best first).
            let rankedTitles = result.citations.map(\.documentTitle)

            // Reciprocal rank of the first relevant document (1-based).
            var reciprocalRank = 0.0
            for (index, title) in rankedTitles.enumerated()
            where golden.relevantDocumentTitles.contains(title) {
                reciprocalRank = 1.0 / Double(index + 1)
                break
            }
            reciprocalRankSum += reciprocalRank

            // Distinct relevant documents retrieved within top-k. Distinct so a
            // document appearing as several chunks doesn't over-count recall.
            let retrievedRelevant = Set(rankedTitles).intersection(golden.relevantDocumentTitles)
            let relevantCount = golden.relevantDocumentTitles.count

            hitSum += retrievedRelevant.isEmpty ? 0.0 : 1.0
            recallSum += relevantCount == 0 ? 0.0 : Double(retrievedRelevant.count) / Double(relevantCount)
            precisionSum += Double(retrievedRelevant.count) / Double(k)
        }

        let n = Double(queries.count)
        return RetrievalMetrics(
            hitRate: hitSum / n,
            recallAtK: recallSum / n,
            precisionAtK: precisionSum / n,
            mrr: reciprocalRankSum / n,
            k: k,
            queryCount: queries.count
        )
    }

    // MARK: - Generation tier (DEFERRED — opt-in live harness)

    /// **Deferred follow-up — not implemented.** The generation tier
    /// (faithfulness / grounding, answer-relevancy, context-relevancy) is scored
    /// by an LLM-as-judge, which means a live model: non-deterministic, slow, and
    /// not runnable in core CI without a bundled judge.
    ///
    /// When implemented it should follow the `RUN_MCP_E2E` env-gated pattern
    /// (e.g. `RUN_RAG_LIVE_EVAL=1`) so it is filtered out of the deterministic
    /// CI surface, with an optional deterministic *lexical* faithfulness proxy
    /// (n-gram overlap between answer claims and the injected
    /// ``RAGService/RetrievalResult/slots`` text) for a CI-safe approximation.
    /// Synthetic Q&A generation likewise needs a live model and is deferred.
    ///
    /// - Throws: ``RAGEvalError/generationTierNotImplemented`` always.
    @available(*, unavailable, message: "Generation tier (faithfulness/relevancy) is deferred to an opt-in live harness — see #1937.")
    public static func evaluateGeneration(
        service: RAGService,
        queries: [GoldenQuery],
        k: Int
    ) async throws -> Never {
        throw RAGEvalError.generationTierNotImplemented
    }
}

/// Errors surfaced by the RAG eval harness.
public enum RAGEvalError: LocalizedError {
    /// The generation tier is deferred to an opt-in live harness (#1937).
    case generationTierNotImplemented

    public var errorDescription: String? {
        switch self {
        case .generationTierNotImplemented:
            return "RAG generation-tier evaluation (faithfulness/relevancy) is deferred to an opt-in live harness (#1937)."
        }
    }
}
