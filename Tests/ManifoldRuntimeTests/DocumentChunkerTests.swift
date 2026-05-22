import XCTest
@testable import ManifoldRuntime
import ManifoldInference

final class DocumentChunkerTests: XCTestCase {

    func testEmptyTextReturnsNoChunks() {
        let chunker = DocumentChunker()
        XCTAssertTrue(chunker.chunk(text: "", documentID: UUID()).isEmpty)
    }

    func testSingleChunkWhenTextFitsInWindow() {
        let chunker = DocumentChunker(chunkSize: 1800, overlap: 200)
        let docID = UUID()
        let chunks = chunker.chunk(text: "Short text.", documentID: docID)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].text, "Short text.")
        XCTAssertEqual(chunks[0].documentID, docID)
        XCTAssertEqual(chunks[0].chunkIndex, 0)
    }

    func testLongTextWithManySentencesProducesMultipleChunks() {
        // Build a text with many short sentences that definitely exceed chunkSize
        // when accumulated. Each sentence is ~25 chars; 8 sentences = ~200 chars.
        // With chunkSize=100 and 4-sentence blocks we get at least 2 chunks.
        let sentences = (1...12).map { "Sentence number \($0) here." }
        let text = sentences.joined(separator: " ")
        let chunker = DocumentChunker(chunkSize: 100, overlap: 30)
        let chunks = chunker.chunk(text: text, documentID: UUID())
        XCTAssertGreaterThan(chunks.count, 1, "long multi-sentence text must produce multiple chunks")
    }

    func testChunkIndicesAreZeroBased() {
        // Use multiple short sentences to guarantee multiple chunks.
        let sentences = (1...20).map { "Item \($0) is listed." }
        let text = sentences.joined(separator: " ")
        let chunker = DocumentChunker(chunkSize: 60, overlap: 20)
        let chunks = chunker.chunk(text: text, documentID: UUID())
        for (i, chunk) in chunks.enumerated() {
            XCTAssertEqual(chunk.chunkIndex, i, "chunk at position \(i) must have chunkIndex == \(i)")
        }
    }

    func testWhitespaceOnlyInputReturnsNoChunks() {
        let chunker = DocumentChunker(chunkSize: 100, overlap: 10)
        let text = String(repeating: " ", count: 200)
        let chunks = chunker.chunk(text: text, documentID: UUID())
        XCTAssertTrue(chunks.isEmpty, "whitespace-only input must produce no chunks")
    }

    func testChunkTextContainsOriginalContent() {
        // All chunk text must be non-empty and come from the source document.
        let text = "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs."
        let chunker = DocumentChunker(chunkSize: 50, overlap: 10)
        let chunks = chunker.chunk(text: text, documentID: UUID())
        for chunk in chunks {
            XCTAssertFalse(chunk.text.trimmingCharacters(in: .whitespaces).isEmpty,
                           "no chunk may be whitespace-only")
            XCTAssertTrue(text.contains(chunk.text.prefix(10)),
                          "chunk text must originate from the source document")
        }
    }

    func testOversizeSingleSentenceIsEmittedAsOneChunk() {
        // A sentence longer than chunkSize must be emitted whole, not dropped.
        let longSentence = "This is a very long sentence that definitely exceeds the configured chunk size limit and should be emitted as a single untruncated chunk."
        let chunker = DocumentChunker(chunkSize: 50, overlap: 10)
        let chunks = chunker.chunk(text: longSentence, documentID: UUID())
        XCTAssertEqual(chunks.count, 1, "an oversize single sentence must be emitted as exactly one chunk")
        XCTAssertEqual(chunks[0].text, longSentence.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testSentenceBoundariesAreRespected() {
        // Construct a text where a naive character-offset cut would split a sentence.
        // "First sentence." is 16 chars; "Second sentence." is 17 chars.
        // chunkSize=20 forces a cut — the cut must land between sentences, not inside one.
        let text = "First sentence. Second sentence. Third sentence."
        let chunker = DocumentChunker(chunkSize: 20, overlap: 5)
        let chunks = chunker.chunk(text: text, documentID: UUID())
        for chunk in chunks {
            // Each chunk's text must end at a sentence boundary (last non-whitespace
            // char is a period, exclamation mark, or question mark after trimming).
            let trimmed = chunk.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let lastChar = trimmed.last
            let isSentenceEnd = lastChar == "." || lastChar == "!" || lastChar == "?"
            XCTAssertTrue(isSentenceEnd || chunks.count == 1,
                          "chunk text must end on a sentence boundary; got: '\(trimmed)'")
        }
    }

    func testOverlapProducesSharedContentBetweenConsecutiveChunks() {
        // With sentence-level overlap the tail sentences of chunk N appear at the
        // head of chunk N+1. We verify that at least one word from the last
        // sentence of chunk 0 appears in chunk 1.
        let sentences = (1...10).map { "Sentence \($0) fills space." }
        let text = sentences.joined(separator: " ")
        let chunker = DocumentChunker(chunkSize: 80, overlap: 30)
        let chunks = chunker.chunk(text: text, documentID: UUID())
        guard chunks.count >= 2 else { return }

        // Find a word unique to the end of chunk 0 and confirm it also appears in chunk 1.
        // Take the last word of chunk 0 (which should be in the overlap zone).
        let lastWordOfChunk0 = chunks[0].text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .last ?? ""
        XCTAssertFalse(lastWordOfChunk0.isEmpty)
        XCTAssertTrue(
            chunks[1].text.contains(lastWordOfChunk0),
            "overlap means the tail of chunk 0 must reappear in chunk 1"
        )
    }

    // Sabotage check: without chunking, no chunks exist
    func testSabotageEmptyTextHasNoChunks() {
        let chunker = DocumentChunker()
        XCTAssertEqual(chunker.chunk(text: "", documentID: UUID()).count, 0)
        XCTAssertFalse(chunker.chunk(text: "", documentID: UUID()).count > 0)
    }
}
