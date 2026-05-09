import XCTest
@testable import ManifoldInference

final class DocumentChunkTests: XCTestCase {

    func testDocumentRecordIdentity() {
        let id = UUID()
        let url = URL(filePath: "/tmp/test.pdf")
        let record = DocumentRecord(
            id: id,
            title: "Test",
            sourceURL: url,
            fileType: "pdf",
            chunkCount: 3
        )
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.title, "Test")
        XCTAssertEqual(record.fileType, "pdf")
        XCTAssertEqual(record.chunkCount, 3)
        XCTAssertEqual(record.sourceURL, url)
    }

    func testDocumentRecordCodable() throws {
        let record = DocumentRecord(
            title: "Doc",
            sourceURL: URL(filePath: "/tmp/doc.txt"),
            fileType: "txt",
            chunkCount: 7
        )
        let encoded = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(DocumentRecord.self, from: encoded)
        XCTAssertEqual(record, decoded)
    }

    func testDocumentChunkIdentity() {
        let docID = UUID()
        let chunk = DocumentChunk(documentID: docID, text: "Hello", chunkIndex: 2)
        XCTAssertEqual(chunk.documentID, docID)
        XCTAssertEqual(chunk.text, "Hello")
        XCTAssertEqual(chunk.chunkIndex, 2)
    }

    func testVectorSearchHitScore() {
        let chunk = DocumentChunk(documentID: UUID(), text: "passage", chunkIndex: 0)
        let hit = VectorSearchHit(chunk: chunk, documentTitle: "Doc", score: 0.92)
        XCTAssertEqual(hit.score, 0.92, accuracy: 1e-6)
        XCTAssertEqual(hit.documentTitle, "Doc")
    }

    // Sabotage: changing score should not equal original
    func testVectorSearchHitSabotage() {
        let chunk = DocumentChunk(documentID: UUID(), text: "x", chunkIndex: 0)
        let hit = VectorSearchHit(chunk: chunk, documentTitle: "D", score: 0.5)
        XCTAssertNotEqual(hit.score, 0.9)
    }
}
