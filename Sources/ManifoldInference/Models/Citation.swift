import Foundation

/// Provenance for a single retrieved chunk surfaced as part of a RAG-augmented
/// assistant turn.
///
/// One ``Citation`` is produced per ``VectorSearchHit`` returned by
/// ``VectorStore/search(embedding:limit:)`` /
/// ``VectorStore/keywordSearch(query:limit:)``. ``ConversationRuntime`` attaches
/// the citation list to the assistant ``ChatMessageRecord`` it produces so the
/// UI can render a "Sources" disclosure beneath the bubble.
///
/// The struct is intentionally minimal: ``documentTitle`` + ``chunkIndex``
/// uniquely identify the source passage, ``snippet`` is a truncated preview for
/// the UI, and ``score`` is the relevance score (cosine similarity for semantic
/// hits, 1.0 for keyword hits) so adopters can filter or sort if they want.
public struct Citation: Sendable, Hashable, Codable {
    /// UUID of the parent ``DocumentRecord``.
    public let documentID: UUID
    /// Human-readable source label (typically the document file name).
    public let documentTitle: String
    /// Zero-based chunk index within the parent document.
    public let chunkIndex: Int
    /// Truncated preview of the chunk text. Capped at ``snippetCharacterLimit``
    /// to keep persisted/wire payloads bounded.
    public let snippet: String
    /// Relevance score in `[0, 1]`. Cosine similarity for semantic search,
    /// `1.0` for keyword hits.
    public let score: Float

    /// Maximum characters retained in ``snippet``. Anything longer is
    /// truncated with an ellipsis when constructed via
    /// ``init(documentID:documentTitle:chunkIndex:fullText:score:)``.
    public static let snippetCharacterLimit = 240

    public init(
        documentID: UUID,
        documentTitle: String,
        chunkIndex: Int,
        snippet: String,
        score: Float
    ) {
        self.documentID = documentID
        self.documentTitle = documentTitle
        self.chunkIndex = chunkIndex
        self.snippet = snippet
        self.score = score
    }

    /// Convenience initialiser that truncates `fullText` to
    /// ``snippetCharacterLimit`` characters with an ellipsis when needed.
    public init(
        documentID: UUID,
        documentTitle: String,
        chunkIndex: Int,
        fullText: String,
        score: Float
    ) {
        let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet: String
        if trimmed.count <= Self.snippetCharacterLimit {
            snippet = trimmed
        } else {
            let endIndex = trimmed.index(trimmed.startIndex, offsetBy: Self.snippetCharacterLimit)
            snippet = String(trimmed[..<endIndex]) + "…"
        }
        self.init(
            documentID: documentID,
            documentTitle: documentTitle,
            chunkIndex: chunkIndex,
            snippet: snippet,
            score: score
        )
    }
}
