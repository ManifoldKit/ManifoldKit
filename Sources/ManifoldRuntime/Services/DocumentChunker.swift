import Foundation
import ManifoldInference

/// Splits a document's text into overlapping ``DocumentChunk`` passages.
///
/// Uses character-count boundaries rather than token counts so chunking works
/// without a loaded tokenizer. The overlap keeps enough shared context between
/// consecutive chunks that relevant passages aren't split at a boundary.
///
/// Default chunk size of 1800 chars with 200-char overlap maps to roughly
/// 400–450 tokens for typical prose, leaving comfortable headroom in a
/// 512-token embedding model's context window.
public struct DocumentChunker: Sendable {
    public var chunkSize: Int
    public var overlap: Int

    public init(chunkSize: Int = 1800, overlap: Int = 200) {
        precondition(chunkSize > 0, "chunkSize must be positive")
        precondition(overlap >= 0 && overlap < chunkSize, "overlap must be in [0, chunkSize)")
        self.chunkSize = chunkSize
        self.overlap = overlap
    }

    /// Returns an ordered array of chunks for `text`, each tagged with `documentID`.
    public func chunk(text: String, documentID: UUID) -> [DocumentChunk] {
        guard !text.isEmpty else { return [] }

        let scalars = Array(text.unicodeScalars)
        let total = scalars.count
        var chunks: [DocumentChunk] = []
        var start = 0
        var index = 0

        while start < total {
            let end = min(start + chunkSize, total)
            let slice = String(String.UnicodeScalarView(scalars[start..<end]))
            let trimmed = slice.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                chunks.append(DocumentChunk(
                    documentID: documentID,
                    text: trimmed,
                    chunkIndex: index
                ))
                index += 1
            }
            if end == total { break }
            start = end - overlap
        }

        return chunks
    }
}
