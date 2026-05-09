import Foundation
import SwiftData
import ManifoldInference
import ManifoldRuntime

/// ``DocumentStore`` backed by SwiftData's ``RagDocument`` model.
///
/// Operates on the ``ModelContext`` injected at init time, consistent with
/// other SwiftData adapters in this target.
@MainActor
public final class SwiftDataDocumentStore: DocumentStore {

    private let modelContext: ModelContext

    public init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    public func insertDocument(_ record: DocumentRecord) throws {
        let model = RagDocument(
            id: record.id,
            title: record.title,
            sourceURLString: record.sourceURL.absoluteString,
            fileType: record.fileType,
            chunkCount: record.chunkCount,
            indexedAt: record.indexedAt
        )
        modelContext.insert(model)
        try modelContext.save()
    }

    public func fetchDocuments() throws -> [DocumentRecord] {
        let descriptor = FetchDescriptor<RagDocument>(
            sortBy: [SortDescriptor(\.indexedAt, order: .reverse)]
        )
        let models = try modelContext.fetch(descriptor)
        return models.map { $0.toRecord() }
    }

    public func fetchDocument(id: UUID) throws -> DocumentRecord? {
        let needle = id
        let descriptor = FetchDescriptor<RagDocument>(
            predicate: #Predicate { $0.id == needle }
        )
        return try modelContext.fetch(descriptor).first?.toRecord()
    }

    public func deleteDocument(id: UUID) throws {
        let needle = id
        let descriptor = FetchDescriptor<RagDocument>(
            predicate: #Predicate { $0.id == needle }
        )
        let matches = try modelContext.fetch(descriptor)
        matches.forEach { modelContext.delete($0) }
        try modelContext.save()
    }
}
