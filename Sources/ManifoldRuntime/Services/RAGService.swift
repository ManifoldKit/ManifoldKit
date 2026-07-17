import Foundation
import ManifoldInference

// MARK: - RetrievalStrategy

/// Which retriever(s) feed the first-stage candidate pool (#1919).
///
/// - ``dense``: cosine over embeddings only, with the legacy keyword fallback
///   when no embedding model is loaded or the embed call throws. This is the
///   historical behaviour and the default — selecting it makes retrieval
///   byte-for-byte identical to the pre-hybrid pipeline.
/// - ``sparse``: BM25 only. Useful for exact-token / no-embedding corpora.
/// - ``hybrid``: run dense *and* BM25, then fuse the two rankings with
///   Reciprocal Rank Fusion before the top-k + rerank stages. Opt in via
///   `RAGConfiguration.hybridRetrieval`.
public enum RetrievalStrategy: Sendable {
    case dense
    case sparse
    case hybrid
}

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

    /// First-stage retrieval strategy. Defaults to ``RetrievalStrategy/dense`` so
    /// existing adopters' behaviour is unchanged; the hybrid BM25+RRF path is
    /// opt-in (#1919, gated behind `RAGConfiguration.hybridRetrieval`).
    private let retrievalStrategy: RetrievalStrategy

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
        fullContextBudgetTokens: Int = 8192,
        retrievalStrategy: RetrievalStrategy = .dense
    ) {
        self.retrievalStrategy = retrievalStrategy
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
        return try await ingestParsedText(
            text,
            documentID: documentID,
            title: title,
            sourceURL: url,
            fileType: ext
        )
    }

    /// Chunks, embeds, and persists caller-supplied text without routing
    /// through ``DocumentParser``/the filesystem (#2199).
    ///
    /// Consumers whose corpus is produced in-memory — e.g. Fireside's
    /// generated story scenes — previously had to write a scratch file per
    /// document just to reach ``ingest(url:)``, then own that temp file's
    /// lifecycle themselves (MK never cleaned it up). This overload shares the
    /// same chunk → embed → insert pipeline as ``ingest(url:)`` after parsing,
    /// so retrieval/citation behaviour is identical between the two entry
    /// points; only the source of the text differs.
    ///
    /// The stored ``DocumentRecord/sourceURL`` is a synthetic
    /// `manifold-inmemory://` URL keyed to `documentID` — there is no file to
    /// point at. The full-context path (``retrieveWholeDocuments()``) re-parses
    /// documents from `sourceURL` using the registered ``DocumentParser``s;
    /// documents ingested this way have no matching parser for their synthetic
    /// `fileType`, so they degrade gracefully to the chunked retrieval path
    /// rather than attempting (and failing) a filesystem read.
    ///
    /// - Parameters:
    ///   - text: The document body to chunk, embed, and index.
    ///   - documentID: Caller-supplied identity. Passing the same ID as an
    ///     earlier ingest is treated as a brand-new document (this call does
    ///     not diff/replace) — callers that re-ingest under a stable ID should
    ///     ``deleteDocument(id:)`` first. Threading the caller's own ID (rather
    ///     than minting a fresh ``UUID``) is what makes ``deleteDocument(id:)``
    ///     usable against caller-managed corpora, e.g. one document per
    ///     `StoryNode`.
    ///   - title: Human-readable label surfaced in citations and the document
    ///     list. Defaults to the `documentID` string when omitted.
    /// - Returns: The ``DocumentRecord`` stored for the new document.
    /// - Throws: ``RAGError/embeddingFailed`` if the embedding call fails, or
    ///   whatever `documentStore`/`vectorStore` throw on write failure.
    @discardableResult
    public func ingest(text: String, documentID: UUID, title: String? = nil) async throws -> DocumentRecord {
        try await ingestParsedText(
            text,
            documentID: documentID,
            title: title ?? documentID.uuidString,
            sourceURL: Self.inMemorySourceURL(documentID: documentID),
            fileType: Self.inMemoryFileType
        )
    }

    /// Marker `fileType` for text ingested via ``ingest(text:documentID:title:)``.
    /// Deliberately does not match any registered ``DocumentParser``'s
    /// `supportedExtensions`, so the full-context re-parse path
    /// (``retrieveWholeDocuments()``) skips these documents with a log
    /// rather than attempting a filesystem read against the synthetic URL.
    private static let inMemoryFileType = "manifold-inmemory"

    /// Synthesizes a stable, non-file `sourceURL` for in-memory ingestion.
    /// `DocumentRecord/sourceURL` is non-optional, so text ingested without a
    /// backing file still needs *some* URL to satisfy the record shape; this
    /// scheme makes the origin unambiguous to anyone inspecting a record.
    private static func inMemorySourceURL(documentID: UUID) -> URL {
        URL(string: "manifold-inmemory:///\(documentID.uuidString)")
            ?? URL(filePath: "/manifold-inmemory/\(documentID.uuidString)")
    }

    /// Shared tail of both ingestion entry points: chunk → embed → persist,
    /// with the same orphan-rollback behaviour on a `documentStore` write
    /// failure. `ingest(url:)` and ``ingest(text:documentID:title:)`` differ
    /// only in how `text`/`sourceURL`/`fileType` are produced upstream of this
    /// call.
    private func ingestParsedText(
        _ text: String,
        documentID: UUID,
        title: String,
        sourceURL: URL,
        fileType: String
    ) async throws -> DocumentRecord {
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
            sourceURL: sourceURL,
            fileType: fileType,
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

        let cappedQuery = capQuery(query)
        let filteredHits = try await rankedFilteredHits(cappedQuery: cappedQuery, limit: limit)

        guard !filteredHits.isEmpty else { return .empty }

        return buildResult(from: filteredHits)
    }

    /// Returns the prompt slot AND citation list for score-ordered passages
    /// matching `query`, greedily packed to fit `tokenBudget` (#2207).
    ///
    /// Token-budgeted consumers (the norm — MK's own `PromptAssembler` budgets
    /// slots by tokens) previously had to over-fetch ``retrieve(query:limit:)``
    /// by a guessed-wide hit count, then re-implement greedy token packing
    /// themselves. This entry point does that packing internally, reusing
    /// ``ContextWindowManager/estimateTokenCount(_:tokenizer:)`` — the same
    /// primitive `trimMessages`/`calculateBudget` use — so "does this hit fit?"
    /// is answered consistently with the rest of the engine rather than by a
    /// second, drifting estimator.
    ///
    /// Hits are walked in score order (after rerank/threshold, same as
    /// ``retrieve(query:limit:)``); a hit is appended only while the running
    /// total plus its estimated token cost stays at or under `tokenBudget`.
    /// The walk **stops** at the first hit that would overflow rather than
    /// skipping ahead to a smaller one — packing preserves relevance order,
    /// it does not bin-pack for maximum fill (mirrors
    /// ``ContextWindowManager/trimMessages(_:systemPrompt:maxTokens:responseBuffer:tokenizer:)``'s
    /// walk-and-break shape).
    ///
    /// Does **not** consult ``fullContextMode`` — that path answers "does the
    /// whole corpus fit `fullContextBudgetTokens`?" against a *configured*
    /// budget, not the caller's per-call `tokenBudget`; conflating the two
    /// would make this method's behaviour depend on unrelated bootstrap
    /// configuration. Chunked retrieval only.
    ///
    /// - Parameters:
    ///   - query: The user query. Empty/whitespace-only rounds-trip as
    ///     ``RetrievalResult/empty``.
    ///   - tokenBudget: Token ceiling for the packed passages. Must be
    ///     positive; a non-positive budget rounds-trips as
    ///     ``RetrievalResult/empty`` (there is no budget to pack into).
    ///   - tokenizer: Optional tokenizer for accurate per-hit counts. Falls
    ///     back to the ~4-chars-per-token heuristic when `nil`, same default
    ///     as every other `ContextWindowManager` entry point.
    public func retrieve(
        query: String,
        tokenBudget: Int,
        tokenizer: TokenizerProvider? = nil
    ) async throws -> RetrievalResult {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }
        guard tokenBudget > 0 else { return .empty }

        let cappedQuery = capQuery(query)

        // Widen the candidate pool relative to the requested budget rather
        // than a caller-supplied hit count — there is no `limit` here, so the
        // width has to be derived from `tokenBudget` itself. Conservative
        // (small) per-chunk floor so the pool stays wide enough for corpora
        // chunked much smaller than the chunker's default, capped so a huge
        // budget doesn't force an unbounded fetch/rerank.
        let candidateLimit = min(
            Self.maxBudgetCandidates,
            max(defaultLimit, tokenBudget / Self.minEstimatedTokensPerChunk)
        )

        let filteredHits = try await rankedFilteredHits(cappedQuery: cappedQuery, limit: candidateLimit)
        guard !filteredHits.isEmpty else { return .empty }

        var packed: [VectorSearchHit] = []
        var usedTokens = 0
        for hit in filteredHits {
            let hitTokens = ContextWindowManager.estimateTokenCount(hit.chunk.text, tokenizer: tokenizer)
            guard usedTokens + hitTokens <= tokenBudget else { break }
            packed.append(hit)
            usedTokens += hitTokens
        }

        guard !packed.isEmpty else { return .empty }

        return buildResult(from: packed)
    }

    /// Conservative floor used to size the budget-aware candidate pool
    /// (``retrieve(query:tokenBudget:tokenizer:)``): assumes chunks could be as
    /// small as this many tokens, so the first-stage fetch stays wide enough to
    /// fill the requested budget even for a corpus chunked much finer than
    /// ``DocumentChunker``'s ~450-token (1800-char) default.
    private static let minEstimatedTokensPerChunk = 50

    /// Upper bound on the budget-aware candidate pool width, regardless of how
    /// large `tokenBudget` is — bounds the first-stage fetch and rerank cost
    /// for pathologically large budgets.
    private static let maxBudgetCandidates = 200

    /// Embedding models can hang or OOM on very long inputs. Truncates `query`
    /// to the configured byte cap before it reaches the embedding backend — a
    /// shorter query loses some precision but still produces useful
    /// nearest-neighbour results. Shared by both `retrieve` overloads.
    private func capQuery(_ query: String) -> String {
        let maxRAGQueryBytes = ManifoldConfiguration.shared.maxRAGQueryBytes
        guard query.utf8.count > maxRAGQueryBytes else { return query }
        return String(
            bytes: Array(query.utf8.prefix(maxRAGQueryBytes)),
            encoding: .utf8
        ) ?? String(query.prefix(maxRAGQueryBytes / 4))
    }

    /// Shared candidate pipeline: first-stage retrieval (dispatching on
    /// ``retrievalStrategy``) → optional rerank widening/trim → similarity
    /// threshold filter. Both `retrieve(query:limit:)` and
    /// `retrieve(query:tokenBudget:tokenizer:)` build their result from this
    /// same score-ordered hit list — they differ only in how they cut it down
    /// afterward (by count vs. by greedy token packing).
    ///
    /// - Parameter limit: The result-set width the reranker trims to. For the
    ///   count-based caller this is the requested `limit`; for the
    ///   budget-based caller it's the derived candidate-pool width.
    private func rankedFilteredHits(cappedQuery: String, limit: Int) async throws -> [VectorSearchHit] {
        // When a reranker is loaded, widen the first-stage candidate pool so the
        // cross-encoder has more passages to reorder; we trim back to `limit`
        // after reranking. With no reranker active, `candidateLimit == limit`
        // and the fetch is byte-for-byte the pre-rerank behaviour.
        let rerankerActive = reranker?.isReady == true
        let candidateLimit = rerankerActive
            ? limit * Self.rerankCandidateMultiplier
            : limit

        let hits = try await firstStageHits(query: cappedQuery, candidateLimit: candidateLimit)
        guard !hits.isEmpty else { return [] }

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

        guard !rankedHits.isEmpty else { return [] }

        // Similarity-threshold cutoff. Applied after reranking so the floor is
        // checked against the final score the user sees in citations. A `0`
        // threshold (the default) is a no-op since the vector store already
        // excludes non-positive scores.
        return similarityThreshold > 0
            ? rankedHits.filter { $0.score >= similarityThreshold }
            : rankedHits
    }

    /// Builds the slot/citation/document triple from a final, already-cut-down
    /// hit list. Shared tail of both `retrieve` overloads.
    private func buildResult(from hits: [VectorSearchHit]) -> RetrievalResult {
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

        // Structured form for a template's `documents` block (#1967). Carries the
        // full chunk text (not the citation snippet, which is truncated for the
        // UI) so a grounding template sees the same passage the system-prompt slot
        // injects. `doc_id` left to the renderer's positional fallback;
        // `documentID` carries the chunk's actual document identity (#2207) so
        // consumers can post-filter `documents` without detouring through
        // `citations`.
        let documents = hits.map { hit in
            RetrievedDocument(documentID: hit.chunk.documentID, title: hit.documentTitle, text: hit.chunk.text)
        }

        return RetrievalResult(slots: [slot], citations: citations, documents: documents)
    }

    /// Produces the first-stage candidate pool, dispatching on
    /// ``retrievalStrategy``.
    ///
    /// `.dense` reproduces the historical dense-with-keyword-fallback path
    /// byte-for-byte. `.sparse` runs BM25 only. `.hybrid` runs *both* the dense
    /// and BM25 legs and fuses their rankings with RRF before returning the
    /// fused top-`candidateLimit` — which then flows into the existing rerank +
    /// threshold + injection stages unchanged.
    private func firstStageHits(query: String, candidateLimit: Int) async throws -> [VectorSearchHit] {
        switch retrievalStrategy {
        case .dense:
            return try await denseHits(query: query, candidateLimit: candidateLimit)

        case .sparse:
            return try await vectorStore.bm25Search(query: query, limit: candidateLimit)

        case .hybrid:
            // Widen each leg to the full candidate pool, fuse, then trim back to
            // `candidateLimit` so the downstream rerank pool width is identical to
            // the non-hybrid path. The dense leg keeps its keyword fallback so a
            // missing/throwing embedding model degrades hybrid → (BM25 ⊕ keyword)
            // rather than failing the turn.
            let dense = try await denseHits(query: query, candidateLimit: candidateLimit)
            let sparse = try await vectorStore.bm25Search(query: query, limit: candidateLimit)

            // If a leg returned nothing the fusion is a no-op pass-through of the
            // other — RRF over a single non-empty list preserves its order.
            return ReciprocalRankFusion.fuse([dense, sparse], limit: candidateLimit)
        }
    }

    /// Dense cosine retrieval with the legacy keyword fallback for the
    /// no-embedding / embed-failure case. Extracted so both `.dense` and the
    /// dense leg of `.hybrid` share one implementation.
    private func denseHits(query: String, candidateLimit: Int) async throws -> [VectorSearchHit] {
        guard let backend = embeddingBackend, backend.isModelLoaded else {
            Log.inference.warning("RAGService: no loaded embedding backend, falling back to keyword search.")
            return try await vectorStore.keywordSearch(query: query, limit: candidateLimit)
        }
        do {
            // `EmbeddingBackend.embed` does not guarantee output count == input
            // count. Subscripting `[0]` on an empty/short return is a runtime
            // *trap* the catch (designed to fall back to keyword search) cannot
            // intercept — route the empty case through `throw` so it lands in the
            // keyword fallback.
            guard let queryEmbedding = try await backend.embed([query]).first else {
                throw RAGError.embeddingFailed(underlying: InferenceError.inferenceFailure("Embedding backend returned no vectors for query"))
            }
            return try await vectorStore.search(embedding: queryEmbedding, limit: candidateLimit)
        } catch {
            Log.inference.warning("RAGService: embedding query failed, falling back to keyword search: \(error.localizedDescription)")
            return try await vectorStore.keywordSearch(query: query, limit: candidateLimit)
        }
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
            RetrievedDocument(documentID: doc.record.id, title: doc.record.title, text: doc.text)
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
