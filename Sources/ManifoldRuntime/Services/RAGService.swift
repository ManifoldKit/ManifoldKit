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

    /// Default number of passages retrieved per turn when a caller does not pass
    /// an explicit `limit`. Threaded from ``RAGConfiguration/topK`` at bootstrap;
    /// the turn loop calls ``retrieve(query:)`` without a `limit`, so this is the
    /// value that actually governs production retrieval width.
    private let defaultLimit: Int

    /// Cosine-similarity floor: hits scoring strictly below this are dropped
    /// before injection. Threaded from ``RAGConfiguration/similarityThreshold``.
    /// The default of `0` preserves the historical behaviour — the vector store
    /// already excludes non-positive scores, so a `0` threshold is a no-op.
    private let similarityThreshold: Float

    /// When `true`, ``retrieve(query:limit:)`` first tries to inject the whole
    /// corpus verbatim (skipping chunk retrieval) if it fits
    /// ``fullContextBudgetTokens``, falling back to chunked retrieval otherwise.
    /// Threaded from ``RAGConfiguration/fullContextMode``. The default of `false`
    /// preserves the historical always-chunk behaviour.
    private let fullContextMode: Bool

    /// Token ceiling for the whole-document path. The corpus is injected verbatim
    /// only when its estimated token count is at or below this value. Threaded
    /// from ``RAGConfiguration/fullContextBudgetTokens``; ignored when
    /// ``fullContextMode`` is `false`.
    private let fullContextBudgetTokens: Int

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
        parsers: [any DocumentParser] = [TextDocumentParser(), PDFDocumentParser()],
        defaultLimit: Int = 5,
        similarityThreshold: Float = 0,
        fullContextMode: Bool = false,
        fullContextBudgetTokens: Int = 8192
    ) {
        self.documentStore = documentStore
        self.vectorStore = vectorStore
        self.embeddingBackend = embeddingBackend
        self.reranker = reranker
        self.chunker = chunker
        self.parsers = parsers
        // Clamp at the boundary: a non-positive limit would retrieve nothing
        // (or trap the vector store's `.prefix`), and a negative threshold is
        // meaningless for cosine scores in [-1, 1].
        self.defaultLimit = max(1, defaultLimit)
        self.similarityThreshold = max(0, similarityThreshold)
        self.fullContextMode = fullContextMode
        // A non-positive budget would make the whole-doc path unreachable; clamp
        // so a misconfigured `0` still admits trivially small corpora rather than
        // silently disabling the feature it was meant to enable.
        self.fullContextBudgetTokens = max(1, fullContextBudgetTokens)
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
        /// The same retrieved passages as structured ``RetrievedDocument`` values,
        /// for the embedded-Jinja render path's `documents` context variable
        /// (#1967). A template that exposes a `{% for document in documents %}`
        /// block grounds on these; templates without one still receive the same
        /// passages as system-prompt text via ``slots``. One document per hit, in
        /// the same order as ``citations``.
        public let documents: [RetrievedDocument]

        public init(
            slots: [PromptSlot],
            citations: [Citation],
            documents: [RetrievedDocument] = []
        ) {
            self.slots = slots
            self.citations = citations
            self.documents = documents
        }

        public static let empty = RetrievalResult(slots: [], citations: [], documents: [])
    }

    /// Returns the prompt slot AND citation list for the top `limit` passages
    /// matching `query`.
    ///
    /// Called by ``ConversationRuntime`` before each generation turn. Empty
    /// results (whitespace-only query, no above-zero scores) round-trip as
    /// ``RetrievalResult/empty``.
    public func retrieve(query: String, limit: Int? = nil) async throws -> RetrievalResult {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }

        // Full-context pre-retrieval branch. When enabled and the whole corpus
        // fits the token budget, inject every document verbatim and skip chunk
        // retrieval entirely — short knowledge bases benefit from the model
        // seeing complete documents rather than top-K passages. A `nil` return
        // means the corpus was over budget or unreadable, so we fall through to
        // the normal chunked path below.
        if fullContextMode, let wholeDocResult = try await retrieveWholeDocuments() {
            return wholeDocResult
        }

        // No explicit caller override falls back to the configured top-K
        // (``RAGConfiguration/topK``). Clamp to a positive width so the
        // vector-store `.prefix` and reranker pool math stay well-defined.
        let limit = max(1, limit ?? defaultLimit)

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

        // Similarity-threshold cutoff. Applied after reranking so the floor is
        // checked against the final score the user sees in citations. A `0`
        // threshold (the default) is a no-op since the vector store already
        // excludes non-positive scores.
        let filteredHits = similarityThreshold > 0
            ? rankedHits.filter { $0.score >= similarityThreshold }
            : rankedHits

        guard !filteredHits.isEmpty else { return .empty }

        let content = filteredHits.map { hit in
            "[\(hit.documentTitle)]\n\(hit.chunk.text)"
        }.joined(separator: "\n\n---\n\n")

        let slot = PromptSlot(
            id: "rag-retrieval",
            content: content,
            position: .contextSetup,
            role: .retrieval,
            label: "Retrieved Documents"
        )

        let citations = filteredHits.map { hit in
            Citation(
                documentID: hit.chunk.documentID,
                documentTitle: hit.documentTitle,
                chunkIndex: hit.chunk.chunkIndex,
                fullText: hit.chunk.text,
                score: hit.score
            )
        }

        // Structured form for a template's `documents` block (#1967). Carries the
        // full chunk text (not the citation snippet, which is truncated for the
        // UI) so a grounding template sees the same passage the system-prompt slot
        // injects. `doc_id` left to the renderer's positional fallback.
        let documents = filteredHits.map { hit in
            RetrievedDocument(title: hit.documentTitle, text: hit.chunk.text)
        }

        return RetrievalResult(slots: [slot], citations: citations, documents: documents)
    }

    /// Full-context path: reads every ingested document's source, estimates the
    /// combined token cost, and — only if it fits ``fullContextBudgetTokens`` —
    /// returns a single retrieval slot carrying all documents verbatim plus a
    /// per-document citation.
    ///
    /// Returns `nil` (signalling the caller to fall back to chunked retrieval)
    /// when there are no documents, when the corpus is over budget, or when no
    /// document source could be read. Document text is re-parsed from each
    /// record's `sourceURL` using the same parsers used at ingest, so this needs
    /// no new vector-store surface.
    private func retrieveWholeDocuments() async throws -> RetrievalResult? {
        let documents = try await documentStore.fetchDocuments()
        guard !documents.isEmpty else { return nil }

        // Re-parse each document from its source. A source that has since moved
        // or whose type lost its parser is skipped with a warning rather than
        // failing the turn — partial corpora are still useful, and a fully empty
        // result correctly falls back to chunking below.
        var parsed: [(record: DocumentRecord, text: String)] = []
        for record in documents {
            let ext = record.fileType.lowercased()
            guard let parser = parsers.first(where: { $0.supportedExtensions.contains(ext) }) else {
                Log.inference.warning("RAGService: no parser for full-context document \(record.title, privacy: .public) (.\(ext, privacy: .public)); skipping")
                continue
            }
            do {
                let text = try await parser.parse(url: record.sourceURL)
                parsed.append((record, text))
            } catch {
                Log.inference.warning("RAGService: failed to read full-context document \(record.title, privacy: .public): \(error.localizedDescription)")
            }
        }

        guard !parsed.isEmpty else { return nil }

        // Budget gate: estimate the combined token cost and bail out to chunked
        // retrieval when the corpus does not fit. The estimate reuses the same
        // context-budget primitive the trim/compaction path uses, so the
        // "does this fit?" question is answered consistently across the engine.
        let totalTokens = parsed.reduce(0) { running, doc in
            running + ContextWindowManager.estimateTokenCount(doc.text)
        }
        guard totalTokens <= fullContextBudgetTokens else {
            Log.inference.info("RAGService: full-context corpus (\(totalTokens) tokens) exceeds budget (\(self.fullContextBudgetTokens)); falling back to chunked retrieval")
            return nil
        }

        let content = parsed.map { doc in
            "[\(doc.record.title)]\n\(doc.text)"
        }.joined(separator: "\n\n---\n\n")

        let slot = PromptSlot(
            id: "rag-retrieval",
            content: content,
            position: .contextSetup,
            role: .retrieval,
            label: "Full Documents"
        )

        let citations = parsed.map { doc in
            Citation(
                documentID: doc.record.id,
                documentTitle: doc.record.title,
                chunkIndex: 0,
                fullText: doc.text,
                score: 1.0
            )
        }

        // Structured form for a template's `documents` block (#1967): the whole
        // document text per record, mirroring the verbatim slot content.
        let structuredDocuments = parsed.map { doc in
            RetrievedDocument(title: doc.record.title, text: doc.text)
        }

        return RetrievalResult(slots: [slot], citations: citations, documents: structuredDocuments)
    }

    /// Returns a ``PromptSlot`` containing the top relevant passages for `query`,
    /// or an empty array when no passages score above zero.
    ///
    /// Compatibility shim retained for callers that don't need the citation
    /// metadata — internally just calls ``retrieve(query:limit:)``.
    public func retrieveSlots(query: String, limit: Int? = nil) async throws -> [PromptSlot] {
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
