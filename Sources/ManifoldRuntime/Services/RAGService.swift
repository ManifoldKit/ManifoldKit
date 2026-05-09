import Foundation
import ManifoldInference

/// Orchestrates document ingestion and retrieval for RAG-augmented turns.
///
/// Call ``ingest(url:)`` to parse, chunk, embed, and persist a document.
/// ``ConversationRuntime`` calls ``retrieveSlots(query:limit:)`` before each
/// generation turn to inject the most relevant passages as a ``PromptSlot``
/// with ``PromptSlotRole/retrieval``.
///
/// When no embedding model is loaded, retrieval falls back to case-insensitive
/// keyword search so the knowledge base remains useful without configuring a
/// separate embedding model.
public actor RAGService {

    private let documentStore: any DocumentStore
    private let vectorStore: any VectorStore
    private let embeddingBackend: (any EmbeddingBackend)?
    private let chunker: DocumentChunker
    private let parsers: [any DocumentParser]

    public init(
        documentStore: any DocumentStore,
        vectorStore: any VectorStore,
        embeddingBackend: (any EmbeddingBackend)? = nil,
        chunker: DocumentChunker = DocumentChunker(),
        parsers: [any DocumentParser] = [TextDocumentParser(), PDFDocumentParser()]
    ) {
        self.documentStore = documentStore
        self.vectorStore = vectorStore
        self.embeddingBackend = embeddingBackend
        self.chunker = chunker
        self.parsers = parsers
    }

    // MARK: - Ingestion

    /// Parses, chunks, embeds, and persists the document at `url`.
    ///
    /// - Returns: The ``DocumentRecord`` stored for the new document.
    /// - Throws: ``DocumentParserError`` if the file type is unsupported or
    ///   reading fails; ``RAGError/embeddingFailed`` if the embedding call fails.
    @discardableResult
    public func ingest(url: URL) async throws -> DocumentRecord {
        let ext = url.pathExtension.lowercased()
        guard let parser = parsers.first(where: { $0.supportedExtensions.contains(ext) }) else {
            throw DocumentParserError.unsupportedFileType(ext)
        }

        let text = try await parser.parse(url: url)
        let title = url.deletingPathExtension().lastPathComponent
        let documentID = UUID()
        let chunks = chunker.chunk(text: text, documentID: documentID)

        let embeddings: [[Float]]
        if let backend = embeddingBackend, backend.isModelLoaded, !chunks.isEmpty {
            do {
                embeddings = try await backend.embed(chunks.map(\.text))
            } catch {
                throw RAGError.embeddingFailed(underlying: error)
            }
        } else {
            embeddings = []
        }

        try await vectorStore.insert(
            chunks: chunks,
            documentTitle: title,
            embeddings: embeddings
        )

        let record = DocumentRecord(
            id: documentID,
            title: title,
            sourceURL: url,
            fileType: ext,
            chunkCount: chunks.count,
            indexedAt: Date()
        )
        try await documentStore.insertDocument(record)
        return record
    }

    /// Removes a document's metadata and all its chunks from the vector store.
    public func deleteDocument(id: UUID) async throws {
        try await vectorStore.delete(documentID: id)
        try await documentStore.deleteDocument(id: id)
    }

    public func fetchDocuments() async throws -> [DocumentRecord] {
        try await documentStore.fetchDocuments()
    }

    // MARK: - Retrieval

    /// The combined output of a single retrieval call: the prompt slot to inject
    /// into context, plus the per-hit ``Citation`` provenance to surface in the
    /// UI.
    ///
    /// ``slots`` and ``citations`` are produced from the same underlying
    /// ``VectorSearchHit`` array, so a non-empty `slots` always implies a
    /// non-empty `citations` (one citation per hit, in the same order).
    public struct RetrievalResult: Sendable {
        public let slots: [PromptSlot]
        public let citations: [Citation]

        public init(slots: [PromptSlot], citations: [Citation]) {
            self.slots = slots
            self.citations = citations
        }

        public static let empty = RetrievalResult(slots: [], citations: [])
    }

    /// Returns the prompt slot AND citation list for the top `limit` passages
    /// matching `query`.
    ///
    /// Called by ``ConversationRuntime`` before each generation turn. Empty
    /// results (whitespace-only query, no above-zero scores) round-trip as
    /// ``RetrievalResult/empty``.
    public func retrieve(query: String, limit: Int = 5) async throws -> RetrievalResult {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }

        let hits: [VectorSearchHit]
        if let backend = embeddingBackend, backend.isModelLoaded {
            do {
                let queryEmbedding = try await backend.embed([query])[0]
                hits = try await vectorStore.search(embedding: queryEmbedding, limit: limit)
            } catch {
                Log.inference.warning("RAGService: embedding query failed, falling back to keyword search: \(error.localizedDescription)")
                hits = try await vectorStore.keywordSearch(query: query, limit: limit)
            }
        } else {
            hits = try await vectorStore.keywordSearch(query: query, limit: limit)
        }

        guard !hits.isEmpty else { return .empty }

        let content = hits.map { hit in
            "[\(hit.documentTitle)]\n\(hit.chunk.text)"
        }.joined(separator: "\n\n---\n\n")

        let slot = PromptSlot(
            id: "rag-retrieval",
            content: content,
            position: .contextSetup,
            role: .retrieval,
            label: "Retrieved Documents"
        )

        let citations = hits.map { hit in
            Citation(
                documentID: hit.chunk.documentID,
                documentTitle: hit.documentTitle,
                chunkIndex: hit.chunk.chunkIndex,
                fullText: hit.chunk.text,
                score: hit.score
            )
        }

        return RetrievalResult(slots: [slot], citations: citations)
    }

    /// Returns a ``PromptSlot`` containing the top relevant passages for `query`,
    /// or an empty array when no passages score above zero.
    ///
    /// Compatibility shim retained for callers that don't need the citation
    /// metadata — internally just calls ``retrieve(query:limit:)``.
    public func retrieveSlots(query: String, limit: Int = 5) async throws -> [PromptSlot] {
        try await retrieve(query: query, limit: limit).slots
    }
}

// MARK: - RAGError

public enum RAGError: LocalizedError {
    case embeddingFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .embeddingFailed(let error):
            return "Embedding failed: \(error.localizedDescription)"
        }
    }
}
