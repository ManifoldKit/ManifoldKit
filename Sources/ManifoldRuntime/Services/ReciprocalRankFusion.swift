import Foundation
import ManifoldInference

// MARK: - ReciprocalRankFusion

/// Reciprocal Rank Fusion (RRF) — the scale-free standard for combining several
/// ranked result lists into one.
///
/// RRF ignores the *magnitude* of each source's scores (which are
/// incomparable across retrievers — cosine similarity in `[0, 1]` vs unbounded
/// BM25) and fuses on *rank position* alone:
///
/// ```
/// rrf(d) = Σ_i  1 / (k + rank_i(d))
/// ```
///
/// where `rank_i(d)` is the 1-based position of document `d` in source list `i`
/// (documents absent from a list contribute nothing). The constant `k` damps the
/// influence of low ranks; `k = 60` is the value from Cormack et al. (2009) and
/// the de-facto default in Elasticsearch / OpenSearch hybrid search.
///
/// This is a pure free function so the fusion ordering is unit-testable against a
/// hand-computed `Σ 1/(k + rank)` without standing up the retrieval pipeline.
public enum ReciprocalRankFusion {

    /// Standard RRF damping constant. PROVISIONAL until the RAG eval harness
    /// (#1937) can defend a tuned value against recall@k / MRR.
    public static let defaultK: Int = 60

    /// Fuses `rankings` (each already sorted best-first) into a single ranked
    /// list of hits, keeping the top `limit`.
    ///
    /// Hits are identified across lists by `chunk.id`. The fused hit carries the
    /// *higher* source score so downstream citations stay meaningful (the user
    /// sees the strongest signal that surfaced the passage), while ordering is
    /// governed purely by the RRF score.
    ///
    /// - Parameters:
    ///   - rankings: One ranked `[VectorSearchHit]` per retriever. Empty lists are
    ///     harmless (they contribute no ranks).
    ///   - k: RRF damping constant.
    ///   - limit: Maximum number of fused hits to return. Non-positive returns `[]`.
    public static func fuse(
        _ rankings: [[VectorSearchHit]],
        k: Int = ReciprocalRankFusion.defaultK,
        limit: Int
    ) -> [VectorSearchHit] {
        guard limit > 0 else { return [] }

        // Accumulate the RRF score per chunk plus the representative hit (highest
        // source score wins for citation fidelity). Insertion order of first
        // sighting gives a stable tiebreak for equal RRF scores.
        var rrfScore: [UUID: Double] = [:]
        var representative: [UUID: VectorSearchHit] = [:]
        var firstSeen: [UUID: Int] = [:]
        var sightingCounter = 0

        for ranking in rankings {
            for (index, hit) in ranking.enumerated() {
                let rank = index + 1  // 1-based
                let id = hit.chunk.id
                rrfScore[id, default: 0] += 1.0 / Double(k + rank)

                if let existing = representative[id] {
                    if hit.score > existing.score { representative[id] = hit }
                } else {
                    representative[id] = hit
                    firstSeen[id] = sightingCounter
                    sightingCounter += 1
                }
            }
        }

        return rrfScore
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                // Deterministic tiebreak: earliest first sighting.
                return (firstSeen[lhs.key] ?? 0) < (firstSeen[rhs.key] ?? 0)
            }
            .prefix(limit)
            .compactMap { representative[$0.key] }
    }
}
