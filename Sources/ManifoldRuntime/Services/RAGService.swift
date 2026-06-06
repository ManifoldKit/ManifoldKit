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
///
/// ## Rerank stage
///
/// When a ``Reranker`` is supplied and reports ``Reranker/isReady`` as `true`,
/// ``retrieve(query:limit:)`` widens the first-stage candidate pool
/// (`limit * `` ``rerankCandidateMultiplier``) and hands it to the reranker,
/// which scores each passage against the query with a cross-encoder and returns
/// the top `limit`. With no reranker — the default — retrieval is byte-for-byte
/// identical to the pre-rerank pipeline, including the keyword fallback.
public actor RAGService {

    private let documentStore: any DocumentStore
    private let vectorStore: any VectorStore
    private let embeddingBackend: (any EmbeddingBackend)?
    private let reranker: (any Reranker)?
    private let chunker: DocumentChunker
    private let parsers: [any DocumentParser]

    /// How much wider than `limit` the first-stage candidate set is fetched
    /// when a reranker is active. A 3× pool gives the cross-encoder enough
    /// candidates to recover relevant passages the bi-encoder cosine stage
    /// ranked just outside the top-`limit`, without paying to score the whole
    /// index. Only applied when `reranker?.isReady == true`; otherwise the
    /// fetch width is exactly `limit` so behaviour is unchanged.
    static let rerankCandidateMultiplier = 3

    public init(
        documentStore: any DocumentStore,
        vectorStore: any VectorStore,
        embeddingBackend: (any EmbeddingBackend)? = nil,
        reranker: (any Reranker)? = nil,
        chunker: DocumentChunker = DocumentChunker(),
        parsers: [any DocumentParser] = [TextDocumentParser(), PDFDocumentParser()]
    ) {
        self.documentStore = documentStore
        self.vectorStore = vectorStore
        self.embeddingBackend = embeddingBackend
        self.reranker = reranker
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
        do {
            try await documentStore.insertDocument(record)
        } catch {
            // Two-store ingest is not atomic: the vectors above are already in
            // the flat-file index, but the SwiftData metadata row failed. The
            // UI lists documents from `documentStore`, so without a compensating
            // rollback the orphaned chunks would pollute search/citations
            // forever while being invisible and undeletable. Best-effort delete
            // the vector write, then surface the original failure.
            do {
                try await vectorStore.delete(documentID: documentID)
            } catch let rollbackError {
                Log.inference.error("RAGService: failed to roll back vector write for orphaned document \(documentID, privacy: .public): \(rollbackError.localizedDescription, privacy: .public)")
            }
            throw error
        }
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

        // Embedding models can hang or OOM on very long inputs. Truncate to
        // the configured byte cap before handing off — a shorter query loses
        // some precision but still produces useful nearest-neighbour results.
        let cappedQuery: String
        let maxRAGQueryBytes = ManifoldConfiguration.shared.maxRAGQueryBytes
        if query.utf8.count > maxRAGQueryBytes {
            cappedQuery = String(
                bytes: Array(query.utf8.prefix(maxRAGQueryBytes)),
                encoding: .utf8
            ) ?? String(query.prefix(maxRAGQueryBytes / 4))
        } else {
            cappedQuery = query
        }

        // When a reranker is loaded, widen the first-stage candidate pool so the
        // cross-encoder has more passages to reorder; we trim back to `limit`
        // after reranking. With no reranker active, `candidateLimit == limit`
        // and the fetch is byte-for-byte the pre-rerank behaviour.
        let rerankerActive = reranker?.isReady == true
        let candidateLimit = rerankerActive
            ? limit * Self.rerankCandidateMultiplier
            : limit

        let hits: [VectorSearchHit]
        if let backend = embeddingBackend, backend.isModelLoaded {
            do {
                // `EmbeddingBackend.embed` does not guarantee output count ==
                // input count. Subscripting `[0]` on an empty/short return is a
                // runtime *trap* that the surrounding catch (designed to fall
                // back to keyword search) cannot intercept — route the empty
                // case through `throw` so it lands in the keyword fallback.
                guard let queryEmbedding = try await backend.embed([cappedQuery]).first else {
                    throw RAGError.embeddingFailed(underlying: InferenceError.inferenceFailure("Embedding backend returned no vectors for query"))
                }
                hits = try await vectorStore.search(embedding: queryEmbedding, limit: candidateLimit)
            } catch {
                Log.inference.warning("RAGService: embedding query failed, falling back to keyword search: \(error.localizedDescription)")
                hits = try await vectorStore.keywordSearch(query: cappedQuery, limit: candidateLimit)
            }
        } else {
            hits = try await vectorStore.keywordSearch(query: cappedQuery, limit: candidateLimit)
        }

        guard !hits.isEmpty else { return .empty }

        // Rerank stage. Only runs when a reranker is loaded; otherwise `hits`
        // (already capped at `limit`) flows through untouched. A throwing
        // reranker degrades to the first-stage ordering — retrieval quality may
        // drop but the turn never fails for a reranker error.
        let rankedHits: [VectorSearchHit]
        if let reranker, rerankerActive {
            do {
                rankedHits = try await reranker.rerank(query: cappedQuery, candidates: hits, limit: limit)
            } catch {
                Log.inference.warning("RAGService: rerank failed, using first-stage ordering: \(error.localizedDescription)")
                rankedHits = Array(hits.prefix(limit))
            }
        } else {
            rankedHits = hits
        }

        guard !rankedHits.isEmpty else { return .empty }

        let content = rankedHits.map { hit in
            "[\(hit.documentTitle)]\n\(hit.chunk.text)"
        }.joined(separator: "\n\n---\n\n")

        let slot = PromptSlot(
            id: "rag-retrieval",
            content: content,
            position: .contextSetup,
            role: .retrieval,
            label: "Retrieved Documents"
        )

        let citations = rankedHits.map { hit in
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
