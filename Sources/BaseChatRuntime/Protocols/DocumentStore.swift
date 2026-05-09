import Foundation
import BaseChatInference

/// Persistence port for ``DocumentRecord`` metadata.
///
/// Stores identity and provenance for ingested documents. Vector data lives
/// separately in ``VectorStore``. The default concrete implementation is
/// `SwiftDataDocumentStore` in `BaseChatPersistenceSwiftData`.
@MainActor
public protocol DocumentStore: AnyObject, Sendable {
    func insertDocument(_ record: DocumentRecord) async throws
    func fetchDocuments() async throws -> [DocumentRecord]
    func fetchDocument(id: UUID) async throws -> DocumentRecord?
    func deleteDocument(id: UUID) async throws
}
