import Foundation
import BaseChatInference
import BaseChatRuntime
@preconcurrency import SwiftData

/// BaseChatKit SwiftData schema version 5.
///
/// Adds ``RagDocument`` for the RAG knowledge base. All V4 model types are
/// carried forward unchanged via a lightweight migration stage.
public enum BaseChatSchemaV5: VersionedSchema {
    public static let versionIdentifier = Schema.Version(5, 0, 0)

    public static var models: [any PersistentModel.Type] {
        [
            BaseChatSchemaV4.ChatMessage.self,
            BaseChatSchemaV4.ChatSession.self,
            BaseChatSchemaV4.SamplerPreset.self,
            BaseChatSchemaV4.APIEndpoint.self,
            BaseChatSchemaV4.ModelBenchmarkCache.self,
            RagDocument.self,
        ]
    }

    // MARK: - RagDocument

    /// Persisted metadata for a document in the RAG knowledge base.
    ///
    /// The actual chunk text and embedding vectors are stored separately in
    /// `FlatFileVectorStore`. This record tracks identity and provenance so
    /// callers can list and delete documents without touching the vector index.
    @Model
    public final class RagDocument {
        public var id: UUID
        public var title: String
        /// Absolute URL of the original source file, stored as a string.
        public var sourceURLString: String
        /// Lowercase file extension without the dot (e.g. "pdf", "txt").
        public var fileType: String
        public var chunkCount: Int
        public var indexedAt: Date

        public init(
            id: UUID,
            title: String,
            sourceURLString: String,
            fileType: String,
            chunkCount: Int,
            indexedAt: Date
        ) {
            self.id = id
            self.title = title
            self.sourceURLString = sourceURLString
            self.fileType = fileType
            self.chunkCount = chunkCount
            self.indexedAt = indexedAt
        }

        func toRecord() -> DocumentRecord {
            DocumentRecord(
                id: id,
                title: title,
                sourceURL: URL(string: sourceURLString) ?? URL(filePath: "/"),
                fileType: fileType,
                chunkCount: chunkCount,
                indexedAt: indexedAt
            )
        }
    }
}

/// Public alias for the current SwiftData RAG document model.
public typealias RagDocument = BaseChatSchemaV5.RagDocument
