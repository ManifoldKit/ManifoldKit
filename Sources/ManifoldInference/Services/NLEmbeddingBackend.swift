#if canImport(NaturalLanguage)
import Foundation
import NaturalLanguage

/// Zero-dependency, on-device ``EmbeddingBackend`` backed by Apple's
/// `NaturalLanguage` framework (`NLEmbedding.sentenceEmbedding`).
///
/// This is the **default** embedder wired by ``ManifoldBootstrap`` /
/// `quickStart()` so RAG retrieval works out of the box with no model download
/// and no companion package. It produces 512-dimensional sentence embeddings
/// entirely on-device; semantically related passages score markedly higher
/// cosine similarity than unrelated ones, which is sufficient for the
/// `FlatFileVectorStore` nearest-neighbour retrieval path.
///
/// For higher-quality embeddings, hosts can still inject their own
/// ``EmbeddingBackend`` (e.g. `MLXEmbedders` from the manifold-mlx companion
/// package, or `LlamaEmbeddingBackend`) — the injected backend always wins
/// over this default.
///
/// ## Locale availability
///
/// `NLEmbedding.sentenceEmbedding(for:)` returns `nil` for locales Apple does
/// not ship a model for. ``init(language:)`` is failable and returns `nil`
/// in that case rather than constructing an unusable backend, so callers can
/// fail-closed (fall back to keyword search) instead of crashing.
public final class NLEmbeddingBackend: EmbeddingBackend, @unchecked Sendable {

    // `NLEmbedding` is immutable after construction and documented as safe to
    // use concurrently; it is wrapped here only to satisfy `Sendable`.
    private let embedding: NLEmbedding

    public var isModelLoaded: Bool { true }

    public let dimensions: Int

    /// Creates a backend over the bundled sentence embedding for `language`.
    ///
    /// - Parameter language: The natural language to embed in. Defaults to
    ///   `.english`.
    /// - Returns: `nil` when no sentence-embedding model is available for the
    ///   requested language on this OS — callers should treat that as "no
    ///   embedder" and let RAG fall back to keyword search.
    public init?(language: NLLanguage = .english) {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else {
            Log.inference.warning("NLEmbeddingBackend: no sentence-embedding model available for language \(language.rawValue, privacy: .public); embedder unavailable.")
            return nil
        }
        self.embedding = embedding
        self.dimensions = embedding.dimension
    }

    /// No-op: the model is bundled with the OS, so there is no local file to
    /// load. The backend reports itself loaded from construction.
    public func loadModel(from url: URL) async throws {}

    public func unloadModel() {}

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        var result: [[Float]] = []
        result.reserveCapacity(texts.count)
        for text in texts {
            // `vector(for:)` returns nil for an empty/whitespace input or a
            // string the model cannot embed. A zero vector is the honest
            // "no signal" representation — `FlatFileVectorStore` L2-normalizes
            // it to an empty vector and skips it during cosine search rather
            // than ranking it spuriously.
            if let vector = embedding.vector(for: text) {
                result.append(vector.map { Float($0) })
            } else {
                result.append([Float](repeating: 0, count: dimensions))
            }
        }
        return result
    }
}
#endif
