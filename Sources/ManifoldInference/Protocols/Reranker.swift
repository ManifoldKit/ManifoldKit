import Foundation

/// Re-scores and re-orders retrieval candidates by query relevance.
///
/// A reranker is the post-retrieve, pre-inject stage of RAG: the retriever
/// widens its initial candidate pool (e.g. cosine top-k*3), then the reranker
/// scores every candidate against the query with a cross-encoder and returns
/// the best `limit` in descending relevance order. Cross-encoders read the
/// query and document *together*, so they recover relevance signal that the
/// bi-encoder cosine stage — which embeds each side independently — misses.
///
/// ## Placement
///
/// This port lives in `ManifoldInference` rather than `ManifoldRuntime` for the
/// same reason ``EmbeddingBackend`` does: the concrete on-device implementation
/// (`LlamaReranker`) lives in a backend family target that depends on
/// `ManifoldInference`, *not* `ManifoldRuntime`. `RAGService` (in
/// `ManifoldRuntime`) consumes the port through its existing `ManifoldInference`
/// import. A cloud reranker would conform to this same protocol — the seam is
/// backend-agnostic.
///
/// ## Fallback contract
///
/// When no reranker is configured, `RAGService` retrieval behaves byte-for-byte
/// as it did before this stage existed. ``PassthroughReranker`` makes that the
/// default: it reports ``isReady`` as `false`, so the retriever neither widens
/// the candidate set nor invokes ``rerank(query:candidates:limit:)``.
public protocol Reranker: Sendable {
    /// Whether a reranker model is loaded and ready to score.
    ///
    /// When `false`, `RAGService` skips candidate widening and the rerank call
    /// entirely — retrieval (including the keyword fallback) is identical to the
    /// pre-rerank pipeline. Implementations that load a model asynchronously
    /// should report `false` until the model is resident.
    var isReady: Bool { get }

    /// Returns up to `limit` of `candidates`, re-scored against `query` and
    /// sorted by descending relevance.
    ///
    /// - Parameters:
    ///   - query: The user query the candidates were retrieved for.
    ///   - candidates: The widened candidate set from the cosine/keyword stage,
    ///     already ordered by their first-stage score.
    ///   - limit: The maximum number of hits to return after reranking.
    /// - Returns: At most `limit` hits in descending rerank-score order. Each
    ///   returned hit carries the cross-encoder score in ``VectorSearchHit/score``
    ///   so downstream citations surface the reranked relevance.
    /// - Throws: When scoring fails. `RAGService` catches and falls back to the
    ///   first-stage ordering, so a throwing reranker degrades gracefully rather
    ///   than failing the turn.
    func rerank(query: String, candidates: [VectorSearchHit], limit: Int) async throws -> [VectorSearchHit]
}

/// The no-op default reranker: reports itself as not ready so retrieval runs
/// exactly as it did before the rerank stage was added.
///
/// Wiring `PassthroughReranker()` is equivalent to wiring no reranker at all —
/// it exists so call sites can hold a non-optional ``Reranker`` without
/// branching on `nil`.
public struct PassthroughReranker: Reranker {
    public init() {}

    /// Always `false`: the passthrough reranker never widens or reorders.
    public var isReady: Bool { false }

    /// Returns the first `limit` candidates unchanged, preserving the
    /// first-stage ordering and scores.
    public func rerank(query: String, candidates: [VectorSearchHit], limit: Int) async throws -> [VectorSearchHit] {
        Array(candidates.prefix(limit))
    }
}
