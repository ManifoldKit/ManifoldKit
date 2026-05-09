import XCTest
import SwiftData
@testable import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldRuntime

@MainActor
final class SwiftDataDocumentStoreTests: XCTestCase {

    private var container: ModelContainer!
    private var sut: SwiftDataDocumentStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainerFactory.makeInMemoryContainer()
        sut = SwiftDataDocumentStore(modelContext: container.mainContext)
    }

    override func tearDown() {
        container = nil
        sut = nil
        super.tearDown()
    }

    func testInsertAndFetch() throws {
        let record = makeRecord(title: "Test Doc")
        try sut.insertDocument(record)

        let fetched = try sut.fetchDocuments()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].title, "Test Doc")
        XCTAssertEqual(fetched[0].id, record.id)
    }

    func testFetchDocumentById() throws {
        let record = makeRecord(title: "Find Me")
        try sut.insertDocument(record)

        let found = try sut.fetchDocument(id: record.id)
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.title, "Find Me")
    }

    func testFetchDocumentByIdMissing() throws {
        let result = try sut.fetchDocument(id: UUID())
        XCTAssertNil(result)
    }

    func testDeleteDocument() throws {
        let record = makeRecord(title: "Delete Me")
        try sut.insertDocument(record)
        try sut.deleteDocument(id: record.id)

        let fetched = try sut.fetchDocuments()
        XCTAssertTrue(fetched.isEmpty)
    }

    func testMultipleDocuments() throws {
        try sut.insertDocument(makeRecord(title: "A"))
        try sut.insertDocument(makeRecord(title: "B"))
        try sut.insertDocument(makeRecord(title: "C"))

        let fetched = try sut.fetchDocuments()
        XCTAssertEqual(fetched.count, 3)
    }

    func testDeleteOnlyTargetedDocument() throws {
        let recordA = makeRecord(title: "Keep")
        let recordB = makeRecord(title: "Remove")
        try sut.insertDocument(recordA)
        try sut.insertDocument(recordB)

        try sut.deleteDocument(id: recordB.id)

        let fetched = try sut.fetchDocuments()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].title, "Keep")
    }

    // Sabotage: deleted document must not be fetchable by ID
    func testSabotageDeletedDocumentNotFetchable() throws {
        let record = makeRecord(title: "Gone")
        try sut.insertDocument(record)
        try sut.deleteDocument(id: record.id)

        let found = try sut.fetchDocument(id: record.id)
        XCTAssertNil(found, "Deleted document must not be retrievable")
    }

    // MARK: - Helper

    private func makeRecord(title: String) -> DocumentRecord {
        DocumentRecord(
            title: title,
            sourceURL: URL(filePath: "/tmp/\(title).txt"),
            fileType: "txt",
            chunkCount: 1
        )
    }
}
