import Foundation
import NaturalLanguage
import ManifoldInference

/// Splits a document's text into overlapping ``DocumentChunk`` passages that
/// respect sentence boundaries.
///
/// Chunking strategy:
/// 1. `NLTokenizer` with `.sentence` unit tokenizes the text into sentences.
/// 2. Sentences are greedily accumulated into a window until the next sentence
///    would exceed `chunkSize` characters.
/// 3. At the window boundary the chunker steps back `overlap` characters worth
///    of sentences (rather than a hard byte offset) so every chunk boundary
///    lands on a complete sentence — no mid-sentence splits.
///
/// When a single sentence exceeds `chunkSize` (e.g. a legal document with
/// very long clauses) it is emitted as its own chunk unchanged. This keeps
/// correctness over compactness.
///
/// Default chunk size of 1800 chars with 200-char overlap maps to roughly
/// 400–450 tokens for typical prose, leaving comfortable headroom in a
/// 512-token embedding model's context window.
public struct DocumentChunker: Sendable {
    public var chunkSize: Int
    public var overlap: Int

    /// `chunkSize`/`overlap` are clamped to a valid range with a logged
    /// warning rather than trapping on an invalid value: unlike a hardcoded
    /// literal, this is public API that `ManifoldBootstrap` feeds directly
    /// from a host app's `RAGConfiguration` (`chunkSize`/`chunkOverlap`) —
    /// runtime, host-supplied configuration, not a value only the library's
    /// own authors control. A malformed RAG config setting should degrade
    /// (fall back to the documented default / clamp the overlap) rather than
    /// crash the app at RAG-service construction time.
    public init(chunkSize: Int = 1800, overlap: Int = 200) {
        var resolvedChunkSize = chunkSize
        if resolvedChunkSize <= 0 {
            Log.persistence.warning("DocumentChunker: chunkSize \(chunkSize) is not positive; falling back to the default of 1800.")
            resolvedChunkSize = 1800
        }
        var resolvedOverlap = overlap
        if resolvedOverlap < 0 || resolvedOverlap >= resolvedChunkSize {
            let clamped = max(0, min(overlap, resolvedChunkSize - 1))
            Log.persistence.warning("DocumentChunker: overlap \(overlap) is out of range [0, \(resolvedChunkSize)); clamping to \(clamped).")
            resolvedOverlap = clamped
        }
        self.chunkSize = resolvedChunkSize
        self.overlap = resolvedOverlap
    }

    // MARK: - Public API

    /// Returns an ordered array of chunks for `text`, each tagged with `documentID`.
    ///
    /// Each chunk contains one or more complete sentences. The last `overlap`
    /// characters of sentences from the previous window are prepended to the
    /// next window to preserve cross-boundary context.
    public func chunk(text: String, documentID: UUID) -> [DocumentChunk] {
        guard !text.isEmpty else { return [] }

        let sentences = tokenizeSentences(text)
        guard !sentences.isEmpty else {
            // Fallback: text with no sentence boundaries (e.g. binary-as-text) —
            // emit as a single chunk.
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [DocumentChunk(documentID: documentID, text: trimmed, chunkIndex: 0)]
        }

        var chunks: [DocumentChunk] = []
        // `windowStart` is the index into `sentences` where the current window begins.
        var windowStart = 0
        var chunkIndex = 0

        while windowStart < sentences.count {
            // Greedily extend the window until adding the next sentence would
            // exceed `chunkSize`.
            var windowEnd = windowStart
            var currentLength = 0

            while windowEnd < sentences.count {
                let sentenceLen = sentences[windowEnd].count
                // Always include at least one sentence per chunk, even if it
                // alone exceeds chunkSize.
                if currentLength > 0 && currentLength + sentenceLen > chunkSize {
                    break
                }
                currentLength += sentenceLen
                windowEnd += 1
            }

            // Build the chunk text from sentences[windowStart..<windowEnd].
            let chunkText = sentences[windowStart..<windowEnd]
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !chunkText.isEmpty {
                chunks.append(DocumentChunk(
                    documentID: documentID,
                    text: chunkText,
                    chunkIndex: chunkIndex
                ))
                chunkIndex += 1
            }

            if windowEnd >= sentences.count { break }

            // Advance `windowStart` so that the new window begins with enough
            // overlap: step back through sentences until we've covered at
            // least `overlap` characters from the end of the current window.
            var overlapAccumulated = 0
            var overlapStart = windowEnd
            while overlapStart > windowStart + 1 {
                let prev = overlapStart - 1
                overlapAccumulated += sentences[prev].count
                if overlapAccumulated >= overlap {
                    overlapStart = prev
                    break
                }
                overlapStart = prev
            }
            // Always advance by at least one sentence so we don't loop forever.
            windowStart = max(windowStart + 1, overlapStart)
        }

        return chunks
    }

    // MARK: - Sentence tokenization

    /// Returns an array of sentence strings (including trailing whitespace) for
    /// natural sentence overlap. `NLTokenizer` handles English, CJK, and other
    /// languages that Apple's NLP stack supports.
    private func tokenizeSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text

        var sentences: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            sentences.append(String(text[range]))
            return true
        }
        return sentences
    }
}
