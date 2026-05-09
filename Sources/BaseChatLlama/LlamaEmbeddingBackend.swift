#if Llama
import Foundation
import LlamaSwift
import os
import BaseChatInference

/// llama.cpp embedding backend for GGUF embedding models (BERT, Nomic, Jina, etc.).
///
/// Holds a single `llama_context *` dedicated to embedding extraction, separate
/// from any generation context owned by ``LlamaBackend``. Pointer ownership and
/// all C-level state (model + context + vocab) are confined to a private actor
/// so the public API can be `Sendable` while the underlying C resources are
/// never touched from more than one task at a time.
///
/// ## Design notes
///
/// - **Actor isolation:** `llama_context` is an opaque C pointer with no ARC
///   guarantees. Wrapping all access in an actor (`Storage`) means we never need
///   `@unchecked Sendable` for the pointer itself — the actor's serial executor
///   guarantees there is no concurrent decode or free. The outer
///   `LlamaEmbeddingBackend` is a `final class` so it can be shared by reference
///   while still satisfying `EmbeddingBackend: AnyObject, Sendable`.
///
/// - **Process lifecycle:** Shares ``LlamaBackendProcessLifecycle`` with
///   ``LlamaBackend``. `llama_backend_init` is global and must only be called
///   once per process; the lifecycle helper refcounts that init across both
///   backends.
///
/// - **Architecture allowlist for embedders:** ``LlamaModelLoader``'s denylist
///   rejects `bert`, `nomic-bert`, and `jina-bert-v2` — those are *valid*
///   embedding architectures, but the loader treats them as unsupported because
///   they are not causal LMs. This backend uses its own loader path that
///   explicitly allows the embedder-family architectures.
///
/// - **Pooling-aware extraction:** After `llama_encode`, embeddings are
///   read via either `llama_get_embeddings_seq` (when the model declares a
///   pooling type other than `NONE`) or by averaging per-token outputs from
///   `llama_get_embeddings_ith` (NONE). Vectors are L2-normalized to unit
///   length before being returned, matching cosine-retrieval expectations.
///
/// - **Batching:** `embed([texts])` evaluates each text in its own
///   `llama_encode` call against `seq_id = 0` to keep the pooled-embedding
///   read paths simple. Texts are truncated to the context window when
///   tokenization exceeds capacity. A future optimisation can pack multiple
///   short texts into a single batch by assigning distinct `seq_id`s; we
///   defer that until measurement justifies the added complexity.
public final class LlamaEmbeddingBackend: EmbeddingBackend, @unchecked Sendable {

    // MARK: - Logging

    private static let logger = Logger(
        subsystem: BaseChatConfiguration.shared.logSubsystem,
        category: "embedding"
    )

    // MARK: - Storage

    /// Owns all C-level resources. Confined to an actor so the C pointers are
    /// never read from more than one task concurrently.
    fileprivate actor Storage {
        var model: OpaquePointer?
        var context: OpaquePointer?
        var vocab: OpaquePointer?
        var dimensions: Int = 0
        var contextSize: Int32 = 0
        /// Captured pooling type. `LLAMA_POOLING_TYPE_NONE` means we manually
        /// average per-token embeddings; any other value means the C side has
        /// already pooled and we read via `llama_get_embeddings_seq`.
        var poolingType: llama_pooling_type = LLAMA_POOLING_TYPE_UNSPECIFIED

        var isLoaded: Bool { model != nil && context != nil }

        func install(model: OpaquePointer, context: OpaquePointer, vocab: OpaquePointer, dimensions: Int, contextSize: Int32, pooling: llama_pooling_type) {
            self.model = model
            self.context = context
            self.vocab = vocab
            self.dimensions = dimensions
            self.contextSize = contextSize
            self.poolingType = pooling
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
            dimensions = 0
            contextSize = 0
            poolingType = LLAMA_POOLING_TYPE_UNSPECIFIED
            if let ctx { llama_free(ctx) }
            if let mdl { llama_model_free(mdl) }
        }

        /// Tokenizes `text`, runs `llama_encode`, reads the pooled (or manually
        /// averaged) embedding, and returns it normalized to unit length.
        ///
        /// Pointers are read from `self` under the actor's serial executor —
        /// no caller-side snapshot is needed because `unload()` cannot
        /// interleave with this method.
        func encode(text: String) throws -> [Float] {
            guard let context, let vocab else {
                throw EmbeddingError.modelNotLoaded
            }
            let dim = dimensions
            let pooling = poolingType
            let maxTokens = Int(contextSize)

            // Tokenize via the existing helper. `addBos: true` matches what the
            // BERT-family GGUFs expect (CLS at position 0); the helper is also
            // safe for non-BERT embedders.
            var tokens = LlamaTokenization.tokenize(text, vocab: vocab, addBos: true)
            if tokens.isEmpty {
                // Empty input produces a zero vector of the right shape rather
                // than throwing — callers commonly embed user input that may be
                // pure whitespace, and a typed exception there would be noisy.
                return [Float](repeating: 0, count: dim)
            }

            // Truncate to context capacity. We deliberately keep the head of the
            // sequence (CLS + leading content) rather than the tail — for BERT
            // pooling the CLS token's representation is what gets returned, and
            // most embedding workloads expect the document's prefix to dominate.
            if tokens.count > maxTokens {
                tokens = Array(tokens.prefix(maxTokens))
            }

            // Clear any prior KV / output state so back-to-back `encode` calls
            // do not accidentally share embedding buffers across sequences.
            // No-op on a freshly initialised context.
            if let mem = llama_get_memory(context) {
                llama_memory_clear(mem, true)
            }

            // Build a one-sequence batch. `logits[i] = 1` on every token tells
            // the context to emit per-token outputs; `llama_encode` then writes
            // the pooled result into `llama_get_embeddings_seq(ctx, 0)` (or
            // the per-token outputs into `llama_get_embeddings_ith`, depending
            // on the pooling type).
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
                // Some embedder GGUFs ship without a true encoder graph and
                // only expose decode. Fall back to llama_decode so we are
                // resilient to upstream packaging differences.
                let drc = llama_decode(context, batch)
                if drc != 0 {
                    throw EmbeddingError.encodingFailed(underlying: NSError(
                        domain: "LlamaEmbeddingBackend",
                        code: Int(rc),
                        userInfo: [NSLocalizedDescriptionKey: "llama_encode/decode failed (encode rc=\(rc), decode rc=\(drc))"]
                    ))
                }
            }

            llama_synchronize(context)

            let raw = try Self.extractVector(
                context: context,
                tokenCount: tokens.count,
                dim: dim,
                pooling: pooling
            )
            return Self.normalize(raw)
        }

        /// Reads embeddings from the C context based on the configured pooling
        /// strategy, returning a `dim`-element `Float` vector.
        static func extractVector(
            context: OpaquePointer,
            tokenCount: Int,
            dim: Int,
            pooling: llama_pooling_type
        ) throws -> [Float] {
            if pooling == LLAMA_POOLING_TYPE_NONE {
                // No model-level pooling. Mean-pool the per-token outputs
                // ourselves so callers get a single vector per text.
                var accum = [Float](repeating: 0, count: dim)
                var contributing = 0
                for i in 0..<tokenCount {
                    guard let row = llama_get_embeddings_ith(context, Int32(i)) else { continue }
                    contributing += 1
                    let buf = UnsafeBufferPointer(start: row, count: dim)
                    for d in 0..<dim {
                        accum[d] += buf[d]
                    }
                }
                guard contributing > 0 else {
                    throw EmbeddingError.encodingFailed(underlying: NSError(
                        domain: "LlamaEmbeddingBackend",
                        code: -10,
                        userInfo: [NSLocalizedDescriptionKey: "llama_get_embeddings_ith returned NULL for every token"]
                    ))
                }
                let inv = 1.0 / Float(contributing)
                for d in 0..<dim {
                    accum[d] *= inv
                }
                return accum
            } else {
                // Pooled by the model. `llama_get_embeddings_seq(ctx, 0)`
                // returns a `dim`-element row.
                guard let row = llama_get_embeddings_seq(context, 0) else {
                    // Some pooling configurations (e.g. RANK reranker models)
                    // return NULL here — that is not a valid embedder for
                    // this backend.
                    throw EmbeddingError.encodingFailed(underlying: NSError(
                        domain: "LlamaEmbeddingBackend",
                        code: -11,
                        userInfo: [NSLocalizedDescriptionKey: "llama_get_embeddings_seq returned NULL (pooling=\(pooling.rawValue))"]
                    ))
                }
                let buf = UnsafeBufferPointer(start: row, count: dim)
                return Array(buf)
            }
        }

        /// L2-normalizes `vector`, returning a new array. A zero-norm vector
        /// is returned unchanged — dividing by zero would yield NaNs and there
        /// is no meaningful unit direction to substitute.
        static func normalize(_ vector: [Float]) -> [Float] {
            var sumSq: Float = 0
            for v in vector { sumSq += v * v }
            let norm = sqrtf(sumSq)
            guard norm > 0 else { return vector }
            let inv = 1 / norm
            return vector.map { $0 * inv }
        }
    }

    private let storage = Storage()

    /// Mirror of ``Storage`` `isLoaded` exposed synchronously for the
    /// ``EmbeddingBackend`` protocol. Updated under `stateLock` whenever the
    /// actor's state changes via `loadModel` / `unloadModel`. The atomic
    /// nature of `Bool` reads is sufficient for the synchronous accessor; the
    /// lock only matters when paired with `_dimensions` so callers reading
    /// both observe a consistent (loaded, dim) tuple.
    public var isModelLoaded: Bool {
        stateLock.withLock { _isModelLoaded }
    }

    /// Mirror of ``Storage`` `dimensions` exposed synchronously for the
    /// ``EmbeddingBackend`` protocol.
    public var dimensions: Int {
        stateLock.withLock { _dimensions }
    }

    private let stateLock = NSLock()
    private var _isModelLoaded = false
    private var _dimensions = 0

    // MARK: - Init / Deinit

    public init() {
        LlamaBackendProcessLifecycle.retain()
    }

    deinit {
        // Fire-and-forget the actor unload; do NOT block the thread running
        // deinit. Blocking here (e.g. with a semaphore) is unsafe: if deinit
        // runs on the main actor (typical when the backend is owned by an
        // @MainActor InferenceService), blocking freezes the UI for the
        // duration of the C cleanup, and any main-actor hop inside unload
        // would deadlock outright.
        //
        // Keep the process-level refcount alive until the detached unload
        // finishes, then release — mirrors LlamaBackend's pattern so the
        // llama_backend_free call can't race with an in-flight unload.
        LlamaBackendProcessLifecycle.retain()
        let storage = storage
        Task.detached(priority: .utility) {
            await storage.unload()
            LlamaBackendProcessLifecycle.release()
        }
        LlamaBackendProcessLifecycle.release()
    }

    // MARK: - EmbeddingBackend

    public func loadModel(from url: URL) async throws {
        // Drop any previously loaded model first so dimension changes between
        // back-to-back loads are reflected without leaking C memory.
        await storage.unload()
        stateLock.withLock {
            _isModelLoaded = false
            _dimensions = 0
        }

        // Move the C work off the calling task's executor. `serializedLoad`
        // shares the embedding-load lock so we never race with a concurrent
        // `loadModel` on a sibling instance.
        let loaded: LoadedEmbedder
        do {
            loaded = try await Task.detached(priority: .userInitiated) {
                try Self.serializedLoad(from: url)
            }.value
        } catch let error as EmbeddingError {
            throw error
        } catch {
            throw EmbeddingError.encodingFailed(underlying: error)
        }

        await storage.install(
            model: loaded.model,
            context: loaded.context,
            vocab: loaded.vocab,
            dimensions: loaded.dimensions,
            contextSize: loaded.contextSize,
            pooling: loaded.poolingType
        )
        stateLock.withLock {
            _isModelLoaded = true
            _dimensions = loaded.dimensions
        }

        Self.logger.info("LlamaEmbeddingBackend loaded \(url.lastPathComponent) (dim=\(loaded.dimensions), pooling=\(loaded.poolingType.rawValue))")
    }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        // Cheap pre-check: surface modelNotLoaded synchronously rather than
        // forcing every caller to round-trip through the actor first.
        guard isModelLoaded else {
            throw EmbeddingError.modelNotLoaded
        }

        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            let vector = try await storage.encode(text: text)
            results.append(vector)
        }
        return results
    }

    public func unloadModel() {
        // Schedule the actor unload but do not block — protocol callers must
        // see `isModelLoaded == false` immediately. The actor's serial
        // executor ensures any in-flight `embed` finishes before the unload
        // runs.
        stateLock.withLock {
            _isModelLoaded = false
            _dimensions = 0
        }
        let storage = storage
        Task.detached(priority: .utility) {
            await storage.unload()
        }
    }

    // MARK: - Loader

    /// Result of a successful embedding-model load. Mirrors the shape used by
    /// ``LlamaModelLoader/LoadedResources`` but is intentionally separate so
    /// the embedding loader can apply its own param defaults (embeddings mode,
    /// no GPU offload of the KV cache, smaller default context) without
    /// disturbing the generation-side loader contract.
    private struct LoadedEmbedder: @unchecked Sendable {
        let model: OpaquePointer
        let context: OpaquePointer
        let vocab: OpaquePointer
        let dimensions: Int
        let contextSize: Int32
        let poolingType: llama_pooling_type
    }

    /// Embedder-friendly subset of ``LlamaModelLoader/unsupportedArchitectures``.
    /// We need to *allow* the BERT-family architectures here even though they
    /// are denied by the generation-side loader — they are the canonical
    /// embedding model formats.
    private static let embeddingArchitectureAllowlist: Set<String> = [
        "bert",
        "nomic-bert",
        "jina-bert-v2",
        "t5encoder",
    ]

    /// Synchronously loads an embedding model under the embedding-load lock.
    /// Throws raw `Error` values; callers wrap into `EmbeddingError`.
    private static func serializedLoad(from url: URL) throws -> LoadedEmbedder {
        // We cannot reuse `LlamaModelLoader.serializedModelLoad` because its
        // architecture preflight rejects BERT-family weights. Instead, we
        // perform the same lock-then-load dance directly. The lock here only
        // serialises embedding loads against each other; the underlying GGML
        // init lock is process-global and protects against generation loads
        // implicitly.
        embeddingLoadLock.lock()
        defer { embeddingLoadLock.unlock() }

        var modelParams = llama_model_default_params()
        #if targetEnvironment(simulator)
        modelParams.n_gpu_layers = 0
        #else
        modelParams.n_gpu_layers = 99
        #endif

        guard let rawModel = llama_model_load_from_file(url.path, modelParams) else {
            throw InferenceError.modelLoadFailed(underlying: NSError(
                domain: "LlamaEmbeddingBackend",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to load embedding GGUF from \(url.lastPathComponent)"]
            ))
        }

        // Architecture check: explicitly allow embedder-family architectures.
        // For anything else, fall through to the generation-side denylist —
        // a non-embedding architecture loaded into an embedding context would
        // produce garbage at best, crash inside `llama_encode` at worst.
        if let architecture = LlamaModelLoader.readArchitectureMetadata(model: rawModel) {
            let normalized = architecture.lowercased()
            let isEmbedderAllowlisted = embeddingArchitectureAllowlist.contains(normalized)
            let isGenerationDenied = LlamaModelLoader.isUnsupportedArchitecture(architecture)
            if !isEmbedderAllowlisted && isGenerationDenied {
                llama_model_free(rawModel)
                throw InferenceError.unsupportedModelArchitecture(architecture)
            }
        }

        // Embedding context params:
        //   - `embeddings = true` flips the context into output-embeddings mode.
        //   - `n_ctx` is taken from the model's training context, clamped into
        //     [512, 8192]. BERT-family embedders are typically 512–2048;
        //     respecting the trained limit keeps memory usage bounded.
        //   - We deliberately do not set `pooling_type` — it is read from the
        //     model's GGUF metadata, and overriding it would change the
        //     semantics of `llama_get_embeddings_seq`.
        var ctxParams = llama_context_default_params()
        ctxParams.embeddings = true
        let trainCtx = llama_model_n_ctx_train(rawModel)
        let requestedCtx = max(Int32(512), min(trainCtx, Int32(8192)))
        ctxParams.n_ctx = UInt32(requestedCtx)
        ctxParams.n_batch = UInt32(requestedCtx)
        ctxParams.n_ubatch = UInt32(requestedCtx)
        ctxParams.n_threads = Int32(max(1, min(8, ProcessInfo.processInfo.processorCount - 2)))
        ctxParams.n_threads_batch = ctxParams.n_threads

        guard let ctx = llama_init_from_model(rawModel, ctxParams) else {
            llama_model_free(rawModel)
            throw InferenceError.modelLoadFailed(underlying: NSError(
                domain: "LlamaEmbeddingBackend",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create embedding context for \(url.lastPathComponent)"]
            ))
        }

        // Belt-and-braces: explicitly enable embeddings on the live context
        // even though the param flag was set above. Some llama.cpp builds
        // have historically required both, and the call is cheap.
        llama_set_embeddings(ctx, true)

        guard let vocab = llama_model_get_vocab(rawModel) else {
            llama_free(ctx)
            llama_model_free(rawModel)
            throw InferenceError.modelLoadFailed(underlying: NSError(
                domain: "LlamaEmbeddingBackend",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Embedding model has no vocabulary"]
            ))
        }

        let dim = Int(llama_model_n_embd(rawModel))
        let pooling = llama_pooling_type(ctx)

        return LoadedEmbedder(
            model: rawModel,
            context: ctx,
            vocab: vocab,
            dimensions: dim,
            contextSize: requestedCtx,
            poolingType: pooling
        )
    }

    /// Serializes embedding-load `llama_model_load_from_file` calls against
    /// each other. Generation loads use ``LlamaModelLoader``'s lock; embedding
    /// loads use this one. Both eventually go through GGML's process-global
    /// init lock so cross-pool serialisation is implicit.
    private static let embeddingLoadLock = NSLock()
}
#endif
