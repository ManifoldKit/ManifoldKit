import Foundation

/// A retrieved chunk with its relevance score and source document title.
///
/// Returned by `VectorStore.search(embedding:limit:)` and
/// `VectorStore.keywordSearch(query:limit:)`. The `documentTitle` is stored
/// alongside the chunk record so context formatters can attribute retrieved
/// passages without an extra round-trip to `DocumentStore`.
public struct VectorSearchHit: Sendable {
    public let chunk: DocumentChunk
    /// Human-readable source label (typically the document file name).
    public let documentTitle: String
    /// Cosine similarity in [0, 1] for semantic hits; 1.0 for keyword hits.
    public let score: Float

    public init(chunk: DocumentChunk, documentTitle: String, score: Float) {
        self.chunk = chunk
        self.documentTitle = documentTitle
        self.score = score
    }
}
