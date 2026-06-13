import Foundation

/// A contiguous passage of text extracted from a `DocumentRecord`.
///
/// The `text` is the retrieval unit — what gets embedded and what gets injected
/// into the context window when retrieved. `chunkIndex` is zero-based within the
/// parent document and is used to reconstruct reading order.
public struct DocumentChunk: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let documentID: UUID
    public let text: String
    public let chunkIndex: Int

    public init(
        id: UUID = UUID(),
        documentID: UUID,
        text: String,
        chunkIndex: Int
    ) {
        self.id = id
        self.documentID = documentID
        self.text = text
        self.chunkIndex = chunkIndex
    }
}
