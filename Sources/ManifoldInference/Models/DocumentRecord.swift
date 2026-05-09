import Foundation

/// Metadata for a document that has been ingested into the RAG knowledge base.
///
/// The raw text and embeddings live in the `VectorStore`; this record tracks
/// identity, provenance, and chunk count so callers can list and delete documents
/// without touching the vector index directly.
public struct DocumentRecord: Identifiable, Sendable, Codable, Hashable {
    public let id: UUID
    public var title: String
    public var sourceURL: URL
    /// Lowercase file extension without the dot (e.g. "pdf", "txt").
    public var fileType: String
    public var chunkCount: Int
    public var indexedAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        sourceURL: URL,
        fileType: String,
        chunkCount: Int,
        indexedAt: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.sourceURL = sourceURL
        self.fileType = fileType
        self.chunkCount = chunkCount
        self.indexedAt = indexedAt
    }
}
