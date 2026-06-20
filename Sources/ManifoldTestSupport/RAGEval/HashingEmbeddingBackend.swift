import Foundation
import ManifoldInference

/// A deterministic, hermetic ``EmbeddingBackend`` for the RAG retrieval-eval
/// harness — no model file, no Metal, no network.
///
/// Each text is lowercased, tokenised on non-alphanumerics, and every token is
/// hashed into one of `dimensions` buckets (the classic *hashing trick* /
/// feature hashing). Bucket counts form a bag-of-words vector which is then
/// L2-normalised, so cosine similarity between a query and a chunk reflects
/// their shared-term overlap. Documents that share vocabulary with a query land
/// near it; unrelated documents are near-orthogonal.
///
/// This is deliberately a *lexical* embedding: it has no notion of synonyms, so
/// golden queries must share surface tokens with their relevant documents. That
/// is exactly the property that makes the harness reproducible and CI-safe — the
/// ranking is a pure function of the corpus text and the query string, with no
/// random seed and no learned weights. It also exercises ``RAGService``'s real
/// embedding → ``VectorStore/search(embedding:limit:)`` cosine path (not the
/// keyword fallback), so the metrics reflect the semantic retrieval pipeline.
///
/// The stable token hash is FNV-1a (folded to `Int`), chosen over Swift's
/// `Hasher` because the latter is randomly seeded per process, which would make
/// embeddings — and therefore retrieval rankings and metrics — non-reproducible
/// across runs.
public final class HashingEmbeddingBackend: EmbeddingBackend, @unchecked Sendable {

    public let dimensions: Int
    public var isModelLoaded: Bool = true

    public var capabilities: EmbeddingCapabilities {
        EmbeddingCapabilities(producesNormalizedVectors: true)
    }

    /// - Parameter dimensions: Bucket count for the hashing trick. 256 gives
    ///   enough capacity for a small fixture corpus while keeping vectors cheap.
    public init(dimensions: Int = 256) {
        precondition(dimensions > 0, "embedding dimensions must be positive")
        self.dimensions = dimensions
    }

    public func loadModel(from url: URL) async throws { isModelLoaded = true }
    public func unloadModel() { isModelLoaded = false }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard isModelLoaded else { throw EmbeddingError.modelNotLoaded }
        return texts.map { Self.vector(for: $0, into: dimensions) }
    }

    // MARK: - Embedding math

    private static func vector(for text: String, into dimensions: Int) -> [Float] {
        var buckets = [Float](repeating: 0, count: dimensions)
        for token in tokenize(text) {
            let bucket = Int(stableHash(token) % UInt64(dimensions))
            buckets[bucket] += 1
        }
        // L2-normalise so cosine similarity is a clean dot product and short and
        // long documents are comparable. An all-zero (token-less) text stays
        // zero — it simply won't match anything, which is the correct behaviour.
        let norm = sqrt(buckets.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return buckets }
        return buckets.map { $0 / norm }
    }

    private static func tokenize(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
    }

    /// FNV-1a 64-bit. Stable across processes (unlike `Hasher`'s seeded hash),
    /// so retrieval rankings — and the metrics computed from them — reproduce.
    private static func stableHash(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return hash
    }
}
