import XCTest
@testable import BaseChatRuntime
import BaseChatInference

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

    func testMultipleChunksForLongText() {
        let chunker = DocumentChunker(chunkSize: 100, overlap: 10)
        let text = String(repeating: "a", count: 350)
        let chunks = chunker.chunk(text: text, documentID: UUID())
        // Expect 4 chunks: [0-100], [90-190], [180-280], [270-350]
        XCTAssertEqual(chunks.count, 4)
    }

    func testChunkIndicesAreZeroBased() {
        let chunker = DocumentChunker(chunkSize: 50, overlap: 5)
        let text = String(repeating: "b", count: 200)
        let chunks = chunker.chunk(text: text, documentID: UUID())
        XCTAssertEqual(chunks[0].chunkIndex, 0)
        XCTAssertEqual(chunks[1].chunkIndex, 1)
        for (i, chunk) in chunks.enumerated() {
            XCTAssertEqual(chunk.chunkIndex, i)
        }
    }

    func testWhitespaceOnlyChunkIsDropped() {
        let chunker = DocumentChunker(chunkSize: 100, overlap: 10)
        let text = "Real content" + String(repeating: " ", count: 100)
        let chunks = chunker.chunk(text: text, documentID: UUID())
        // Last window is all spaces — should be dropped
        for chunk in chunks {
            XCTAssertFalse(chunk.text.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    func testChunkSizeOf1ReturnsSingleChunks() {
        let chunker = DocumentChunker(chunkSize: 1, overlap: 0)
        let chunks = chunker.chunk(text: "abc", documentID: UUID())
        XCTAssertEqual(chunks.count, 3)
    }

    // Sabotage check: without chunking, no chunks exist
    func testSabotageEmptyTextHasNoChunks() {
        let chunker = DocumentChunker()
        XCTAssertEqual(chunker.chunk(text: "", documentID: UUID()).count, 0)
        // If chunk() wrongly returned chunks for empty input, this would fail
        XCTAssertFalse(chunker.chunk(text: "", documentID: UUID()).count > 0)
    }
}
