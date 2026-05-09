import Foundation
import ManifoldInference

/// Persistence port for chunk embeddings and text.
///
/// Implementations are responsible for storing ``DocumentChunk`` text alongside
/// its embedding vector and performing similarity search at query time. The
/// default concrete implementation is `FlatFileVectorStore` in
/// `ManifoldPersistenceSwiftData`.
public protocol VectorStore: Sendable {
    /// Persists `chunks` with their parallel `embeddings` and `documentTitle`.
    ///
    /// - Parameter chunks: Ordered chunks produced by ``DocumentChunker``.
    /// - Parameter documentTitle: Display name stored with every chunk for
    ///   context formatting; typically the source file name.
    /// - Parameter embeddings: Parallel Float32 vectors. When empty (no embedding
    ///   model loaded), chunks are stored for keyword search only.
    func insert(
        chunks: [DocumentChunk],
        documentTitle: String,
        embeddings: [[Float]]
    ) async throws

    /// Returns the `limit` most similar chunks to `embedding`, sorted by
    /// descending cosine similarity. Skips records with empty embeddings.
    func search(embedding: [Float], limit: Int) async throws -> [VectorSearchHit]

    /// Returns up to `limit` chunks whose text contains `query` (case-insensitive).
    /// Used as the fallback when no embedding model is loaded.
    func keywordSearch(query: String, limit: Int) async throws -> [VectorSearchHit]

    /// Removes all chunks belonging to `documentID`.
    func delete(documentID: UUID) async throws

    /// Removes all stored chunks and embeddings.
    func deleteAll() async throws
}
