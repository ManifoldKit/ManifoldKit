#if Llama
import Foundation
import LlamaSwift
import os
import ManifoldInference

/// llama.cpp cross-encoder reranker for RANK-pooling GGUF models
/// (e.g. `bge-reranker-v2-m3`, `jina-reranker`).
///
/// A reranker model is a BERT-family classifier with a single-output rank head.
/// Unlike ``LlamaEmbeddingBackend`` — a *bi-encoder* that embeds the query and
/// each document independently and compares them with cosine similarity — this
/// is a *cross-encoder*: it feeds the `[query, document]` pair through the model
/// in one pass so the attention layers see both sides together, then reads the
/// rank logit from `llama_get_embeddings_seq` (which, under
/// `LLAMA_POOLING_TYPE_RANK`, returns the classification score rather than an
/// embedding vector). Cross-encoders are slower but materially more accurate at
/// relevance ordering, which is why they run as a second stage over a small
/// widened candidate set rather than over the whole index.
///
/// ## Design notes
///
/// Mirrors ``LlamaEmbeddingBackend``'s ownership model: all C-level state
/// (`llama_model *`, `llama_context *`, vocab) is confined to a private actor so
/// the public surface can be `Sendable` while the underlying pointers are never
/// touched concurrently. Pooling is forced to `LLAMA_POOLING_TYPE_RANK` at
/// context creation — llama.cpp's own rerank path sets it explicitly rather than
/// trusting GGUF metadata, and without it the model emits an embedding instead
/// of a rank score.
///
/// ## Scores
///
/// The raw rank head emits an unbounded logit. ``rerank(query:candidates:limit:)``
/// applies a logistic squash so the ``VectorSearchHit/score`` it writes back is
/// a monotonic relevance probability in `(0, 1)` — comparable across calls and
/// safe to surface in citations — while preserving the ordering the logits
/// imply.
public final class LlamaReranker: Reranker, @unchecked Sendable {

    // MARK: - Logging

    private static let logger = Logger(
        subsystem: ManifoldConfiguration.shared.logSubsystem,
        category: "reranker"
    )

    // MARK: - Storage

    /// Owns all C-level resources. Confined to an actor so the C pointers are
    /// never read from more than one task concurrently.
    fileprivate actor Storage {
        var model: OpaquePointer?
        var context: OpaquePointer?
        var vocab: OpaquePointer?
        var contextSize: Int32 = 0
        /// Sentence-separator token inserted between the query and the document
        /// halves of the pair. `LLAMA_TOKEN_NULL` when the vocab has none.
        var sepToken: llama_token = -1
        var eosToken: llama_token = -1

        var isLoaded: Bool { model != nil && context != nil }

        func install(
            model: OpaquePointer,
            context: OpaquePointer,
            vocab: OpaquePointer,
            contextSize: Int32,
            sepToken: llama_token,
            eosToken: llama_token
        ) {
            self.model = model
            self.context = context
            self.vocab = vocab
            self.contextSize = contextSize
            self.sepToken = sepToken
            self.eosToken = eosToken
        }

        /// Drops references and frees the C resources in the order
        /// `llama_free` (context) → `llama_model_free` (model). Safe to call
        /// when nothing is loaded.
        func unload() {
            let ctx = context
            let mdl = model
            context = nil
            model = nil
            vocab = nil
            contextSize = 0
            sepToken = -1
            eosToken = -1
            if let ctx { llama_free(ctx) }
            if let mdl { llama_model_free(mdl) }
        }

        /// Scores a single `[query, document]` pair, returning the raw rank
        /// logit emitted by the classification head.
        ///
        /// Builds the sequence `[BOS] query [EOS] [SEP] document [EOS]`,
        /// encodes it, and reads `llama_get_embeddings_seq(ctx, 0)[0]`. Pointers
        /// are read under the actor's serial executor so `unload()` cannot
        /// interleave.
        func score(query: String, document: String) throws -> Float {
            guard let context, let vocab else {
                throw RerankerError.modelNotLoaded
            }
            let maxTokens = Int(contextSize)

            // Query half carries the BOS; document half does not. Separator and
            // closing EOS tokens frame the pair the way BERT rerankers were
            // trained on (`[CLS] q [SEP] d [SEP]`); we use EOS as the trailing
            // marker since not every reranker vocab defines a distinct SEP.
            var tokens = LlamaTokenization.tokenize(query, vocab: vocab, addBos: true)
            if eosToken >= 0 { tokens.append(eosToken) }
            if sepToken >= 0 { tokens.append(sepToken) }
            tokens.append(contentsOf: LlamaTokenization.tokenize(document, vocab: vocab, addBos: false))
            if eosToken >= 0 { tokens.append(eosToken) }

            guard !tokens.isEmpty else {
                // An all-empty pair has no relevance signal; the lowest possible
                // score keeps it at the bottom of the ranking without throwing.
                return -.greatestFiniteMagnitude
            }

            // Truncate from the tail so the query (sequence head) always
            // survives — a query-less pair scores nothing meaningful.
            if tokens.count > maxTokens {
                tokens = Array(tokens.prefix(maxTokens))
            }

            // Clear KV / output state so back-to-back pair scores never share
            // buffers across sequences.
            if let mem = llama_get_memory(context) {
                llama_memory_clear(mem, true)
            }

            var batch = llama_batch_init(Int32(tokens.count), 0, 1)
            defer { llama_batch_free(batch) }
            for i in 0..<tokens.count {
                batch.token[i] = tokens[i]
                batch.pos[i] = Int32(i)
                batch.n_seq_id[i] = 1
                batch.seq_id[i]?[0] = 0
                batch.logits[i] = 1
            }
            batch.n_tokens = Int32(tokens.count)

            let rc = llama_encode(context, batch)
            if rc != 0 {
                // Some reranker GGUFs expose only decode, mirroring the
                // embedding backend's resilience to upstream packaging.
                let drc = llama_decode(context, batch)
                if drc != 0 {
                    throw RerankerError.scoringFailed(underlying: NSError(
                        domain: "LlamaReranker",
                        code: Int(rc),
                        userInfo: [NSLocalizedDescriptionKey: "llama_encode/decode failed (encode rc=\(rc), decode rc=\(drc))"]
                    ))
                }
            }

            llama_synchronize(context)

            // Under RANK pooling this row is `float[n_cls_out]` — the rank
            // score(s). Rerankers have a single-output head, so element 0 is the
            // relevance logit.
            guard let row = llama_get_embeddings_seq(context, 0) else {
                throw RerankerError.scoringFailed(underlying: NSError(
                    domain: "LlamaReranker",
                    code: -20,
                    userInfo: [NSLocalizedDescriptionKey: "llama_get_embeddings_seq returned NULL — model is not a RANK-pooling reranker"]
                ))
            }
            return row[0]
        }
    }

    private let storage = Storage()

    private let stateLock = NSLock()
    private var _isReady = false

    /// `true` once a RANK-pooling GGUF is resident. Reads are lock-guarded so a
    /// concurrent `loadModel` / `unloadModel` cannot expose a half-installed
    /// context to a scoring call.
    public var isReady: Bool {
        stateLock.withLock { _isReady }
    }

    // MARK: - Init / Deinit

    public init() {
        LlamaBackendProcessLifecycle.retain()
    }

    deinit {
        // Fire-and-forget the actor unload; never block deinit. Same rationale
        // as ``LlamaEmbeddingBackend``: blocking here freezes the owning actor
        // (often @MainActor) or deadlocks on a main-actor hop inside unload.
        // Keep the process refcount alive until the detached unload finishes.
        LlamaBackendProcessLifecycle.retain()
        let storage = storage
        Task.detached(priority: .utility) {
            await storage.unload()
            LlamaBackendProcessLifecycle.release()
        }
        LlamaBackendProcessLifecycle.release()
    }

    // MARK: - Loading

    /// Loads a cross-encoder reranker GGUF and makes the instance ``isReady``.
    ///
    /// - Throws: ``RerankerError/modelLoadFailed`` when the GGUF cannot be
    ///   opened or a RANK context cannot be created.
    public func loadModel(from url: URL) async throws {
        await storage.unload()
        stateLock.withLock { _isReady = false }

        let loaded: LoadedReranker
        do {
            loaded = try await Task.detached(priority: .userInitiated) {
                try Self.serializedLoad(from: url)
            }.value
        } catch let error as RerankerError {
            throw error
        } catch {
            throw RerankerError.modelLoadFailed(underlying: error)
        }

        await storage.install(
            model: loaded.model,
            context: loaded.context,
            vocab: loaded.vocab,
            contextSize: loaded.contextSize,
            sepToken: loaded.sepToken,
            eosToken: loaded.eosToken
        )
        stateLock.withLock { _isReady = true }

        Self.logger.info("LlamaReranker loaded \(url.lastPathComponent) (n_ctx=\(loaded.contextSize))")
    }

    /// Unloads the model, flipping ``isReady`` to `false` immediately. Any
    /// in-flight scoring finishes first via the actor's serial executor.
    public func unloadModel() {
        stateLock.withLock { _isReady = false }
        let storage = storage
        Task.detached(priority: .utility) {
            await storage.unload()
        }
    }

    // MARK: - Reranker

    public func rerank(
        query: String,
        candidates: [VectorSearchHit],
        limit: Int
    ) async throws -> [VectorSearchHit] {
        guard isReady else {
            // Defensive: `RAGService` only calls us when `isReady`, but honour
            // the contract directly rather than scoring against a freed context
            // if the model was unloaded between the gate and this call.
            return Array(candidates.prefix(limit))
        }
        guard !candidates.isEmpty, limit > 0 else { return [] }

        // Score each candidate against the query, then sort by descending
        // relevance. Scoring is sequential because the actor owns one context;
        // the candidate set is small (top-k*3) so this stays well-bounded.
        var scored: [(hit: VectorSearchHit, score: Float)] = []
        scored.reserveCapacity(candidates.count)
        for hit in candidates {
            let logit = try await storage.score(query: query, document: hit.chunk.text)
            scored.append((hit, logit))
        }

        scored.sort { $0.score > $1.score }

        return scored.prefix(limit).map { entry in
            VectorSearchHit(
                chunk: entry.hit.chunk,
                documentTitle: entry.hit.documentTitle,
                // Squash the unbounded logit into (0, 1) so the surfaced score
                // is a comparable relevance probability, not a raw activation.
                score: Self.sigmoid(entry.score)
            )
        }
    }

    /// Numerically stable logistic squash. Branches on the sign so neither
    /// `exp(+large)` nor `exp(-large)` overflows.
    static func sigmoid(_ x: Float) -> Float {
        if x >= 0 {
            return 1 / (1 + expf(-x))
        } else {
            let e = expf(x)
            return e / (1 + e)
        }
    }

    // MARK: - Loader

    private struct LoadedReranker: @unchecked Sendable {
        let model: OpaquePointer
        let context: OpaquePointer
        let vocab: OpaquePointer
        let contextSize: Int32
        let sepToken: llama_token
        let eosToken: llama_token
    }

    /// BERT-family architectures a reranker GGUF can legitimately declare. Same
    /// set the embedding loader allows — rerankers are BERT classifiers — minus
    /// the encoder-only families that have no classification head.
    private static let rerankerArchitectureAllowlist: Set<String> = [
        "bert",
        "nomic-bert",
        "jina-bert-v2",
    ]

    private static func serializedLoad(from url: URL) throws -> LoadedReranker {
        loadLock.lock()
        defer { loadLock.unlock() }

        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = LlamaSamplingPolicy.gpuLayerCount()

        guard let rawModel = llama_model_load_from_file(url.path, modelParams) else {
            throw RerankerError.modelLoadFailed(underlying: NSError(
                domain: "LlamaReranker",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load reranker GGUF from \(url.lastPathComponent)"]
            ))
        }

        if let architecture = LlamaModelLoader.readArchitectureMetadata(model: rawModel) {
            let normalized = architecture.lowercased()
            let isRerankerAllowlisted = rerankerArchitectureAllowlist.contains(normalized)
            let isGenerationDenied = LlamaModelLoader.isUnsupportedArchitecture(architecture)
            if !isRerankerAllowlisted && isGenerationDenied {
                llama_model_free(rawModel)
                throw RerankerError.modelLoadFailed(underlying: InferenceError.unsupportedModelArchitecture(architecture))
            }
        }

        var ctxParams = llama_context_default_params()
        ctxParams.embeddings = true
        // Force the rank head on rather than trusting GGUF pooling metadata —
        // this is what makes `llama_get_embeddings_seq` return a score instead
        // of a hidden-state vector. Matches llama.cpp's rerank example.
        ctxParams.pooling_type = LLAMA_POOLING_TYPE_RANK
        let trainCtx = llama_model_n_ctx_train(rawModel)
        let requestedCtx = max(Int32(512), min(trainCtx, Int32(8192)))
        ctxParams.n_ctx = UInt32(requestedCtx)
        ctxParams.n_batch = UInt32(requestedCtx)
        ctxParams.n_ubatch = UInt32(requestedCtx)
        ctxParams.n_threads = LlamaSamplingPolicy.threadCount()
        ctxParams.n_threads_batch = ctxParams.n_threads

        guard let ctx = llama_init_from_model(rawModel, ctxParams) else {
            llama_model_free(rawModel)
            throw RerankerError.modelLoadFailed(underlying: NSError(
                domain: "LlamaReranker",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create RANK context for \(url.lastPathComponent)"]
            ))
        }

        llama_set_embeddings(ctx, true)

        guard let vocab = llama_model_get_vocab(rawModel) else {
            llama_free(ctx)
            llama_model_free(rawModel)
            throw RerankerError.modelLoadFailed(underlying: NSError(
                domain: "LlamaReranker",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Reranker model has no vocabulary"]
            ))
        }

        return LoadedReranker(
            model: rawModel,
            context: ctx,
            vocab: vocab,
            contextSize: requestedCtx,
            sepToken: llama_vocab_sep(vocab),
            eosToken: llama_vocab_eos(vocab)
        )
    }

    /// Serializes reranker-load `llama_model_load_from_file` calls against each
    /// other. Eventually funnels through GGML's process-global init lock, so
    /// cross-pool serialisation with generation / embedding loads is implicit.
    private static let loadLock = NSLock()
}

// MARK: - RerankerError

public enum RerankerError: LocalizedError {
    case modelNotLoaded
    case modelLoadFailed(underlying: Error)
    case scoringFailed(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded:
            return "Reranker model is not loaded."
        case .modelLoadFailed(let underlying):
            return "Reranker model load failed: \(underlying.localizedDescription)"
        case .scoringFailed(let underlying):
            return "Reranker scoring failed: \(underlying.localizedDescription)"
        }
    }
}
#endif
