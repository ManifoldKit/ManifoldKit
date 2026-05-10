# LlamaSwift xcframework — llama.cpp C API Contract

This document describes every `llama_*` C symbol called by
`Sources/ManifoldBackends/LlamaBackend.swift`, covering threading
constraints, ordering invariants, capacity limits, ownership semantics, and
known failure modes. It is generated from a careful read of both
`LlamaBackend.swift` and the vendored `docs/vendor/llama.h` (llama.cpp build
b8772, exposed through `mattt/llama.swift` 2.8772.0).

Use this document when upgrading the xcframework pin: diff `docs/vendor/llama.h`
against the new version's header, then review every section below for contract
changes before merging.

---

## Global Backend Lifecycle

### `llama_backend_init`

| Attribute | Detail |
|-----------|--------|
| Signature | `void llama_backend_init(void)` |
| Threading | Call exactly once before any other llama.cpp call. `LlamaBackend` enforces this with a process-global reference count and `backendLock`. |
| Ordering | Must precede all other `llama_*` calls. `llama_backend_free` must be the last call. |
| Limits | Single global call — calling more than once is undefined behaviour in llama.cpp internals (GGML/BLAS global init). |
| Ownership | Void — no return value to manage. |
| Failure modes | None exposed; failure inside GGML (e.g., Metal unavailable) is either silently degraded or aborts internally. |

### `llama_backend_free`

| Attribute | Detail |
|-----------|--------|
| Signature | `void llama_backend_free(void)` |
| Threading | Guarded by `backendLock`; only called when reference count drops to zero. |
| Ordering | Must be the last llama.cpp call. All contexts and models must already be freed. In `LlamaBackend`, `unloadModel()` spawns a detached cleanup task that awaits the generation task, then calls `llama_free` / `llama_model_free`, and only then calls `releaseBackend()`. This preserves the invariant without blocking the calling thread. |
| Limits | Symmetric with `llama_backend_init`. |
| Ownership | Void. |
| Failure modes | Calling when contexts or models are still alive can cause GGML internal assertion failures or resource leaks. |

---

## Model Loading

### `llama_model_default_params`

| Attribute | Detail |
|-----------|--------|
| Signature | `struct llama_model_params llama_model_default_params(void)` |
| Threading | Thread-safe; pure value return, no global state. |
| Ordering | Call before `llama_model_load_from_file`. |
| Limits | None. |
| Ownership | Returns a value type (struct), no heap allocation. |
| Failure modes | None. |

**Fields set by `LlamaBackend`:**
- `n_gpu_layers = 0` in simulator (Metal unreliable); `99` otherwise (offload all layers). On non-simulator hosts, setting `LLAMA_FORCE_CPU_ONLY=1` in the process environment forces `n_gpu_layers = 0` for memory-constrained loads of very large MoE models that cannot fit their Metal partial-weight buffers — the default `99` is ~8× faster on a 4B GGUF (measured 2.28 s vs 0.28 s on `test_countTokens_…` against Qwen3-4B-Q4_K_M, M5/24 GB).
- `progress_callback` / `progress_callback_user_data`: set when a load-progress handler is installed. The callback fires on the loader thread; `LlamaBackend` bridges to async Swift via an unstructured `Task`. The `Unmanaged` retain on `ProgressCallbackContext` is released in a `defer` block after `llama_model_load_from_file` returns, so the C callback cannot fire after that point.

### `llama_model_load_from_file`

| Attribute | Detail |
|-----------|--------|
| Signature | `struct llama_model * llama_model_load_from_file(const char * path_model, struct llama_model_params params)` |
| Threading | **Not safe to call concurrently with itself or `llama_model_free`.** `LlamaBackend` serialises calls with `loadSerializationLock`. |
| Ordering | `llama_backend_init` must have been called. Returns `NULL` on failure. |
| Limits | Reads the entire GGUF file from disk; respects `n_gpu_layers`. Can take several seconds on large models. |
| Ownership | Returns a heap-allocated `llama_model *`. **Caller owns it** and must eventually call `llama_model_free`. `LlamaBackend` wraps this in `LlamaModelHandle` for automatic RAII cleanup on error paths. |
| Failure modes | Returns `NULL` on file-not-found, corrupt GGUF, or memory exhaustion. `LlamaBackend` throws `InferenceError.modelLoadFailed` when `NULL` is returned. |

### `llama_model_free`

| Attribute | Detail |
|-----------|--------|
| Signature | `void llama_model_free(struct llama_model * model)` |
| Threading | **Not safe to call concurrently with `llama_model_load_from_file`.** Call only after all contexts created from this model have been freed. |
| Ordering | All `llama_context *` objects derived from this model must already be freed before `llama_model_free`. In `LlamaBackend`, `unloadModel()` frees context first (`llama_free`), then model (`llama_model_free`). |
| Limits | None. |
| Ownership | Frees and invalidates the pointer. |
| Failure modes | Double-free or use-after-free if called while a context or generation task is still active — guarded by awaiting `capturedTask` in `unloadModel()`'s cleanup task. |

---

## Vocabulary

### `llama_model_get_vocab`

| Attribute | Detail |
|-----------|--------|
| Signature | `const struct llama_vocab * llama_model_get_vocab(const struct llama_model * model)` |
| Threading | Thread-safe; returns a pointer into model-owned memory. |
| Ordering | Model must be loaded. Pointer is valid as long as the model is alive. |
| Limits | None. |
| Ownership | **Borrowed reference** — do not free. `LlamaBackend` stores this in `vocab` and clears it alongside the model. |
| Failure modes | Returns `NULL` if the model has no vocabulary (rare; only affects embedding models). `LlamaBackend` guards `vocab != nil` before every tokenization call. |

---

## Context Lifecycle

### `llama_context_default_params`

| Attribute | Detail |
|-----------|--------|
| Signature | `struct llama_context_params llama_context_default_params(void)` |
| Threading | Thread-safe; pure value return. |
| Ordering | Call before `llama_init_from_model`. |
| Limits | Default `n_batch` is 2048; default `n_ctx` is 0 (inherits from model). |
| Ownership | Value type, no heap allocation. |
| Failure modes | None. |

**Fields set by `LlamaBackend`:**
- `n_ctx`: set from `plan.effectiveContextSize` — the `ModelLoadPlan` is authoritative; no in-backend clamping.
- `n_threads` / `n_threads_batch`: `max(1, min(8, processorCount - 2))`.
- `n_batch`: **not set** — inherits default (2048). See known violation history below.

### `llama_init_from_model`

| Attribute | Detail |
|-----------|--------|
| Signature | `struct llama_context * llama_init_from_model(struct llama_model * model, struct llama_context_params params)` |
| Threading | Not safe to call concurrently on the same model. |
| Ordering | Model must be loaded. Must precede any `llama_decode` / `llama_tokenize` / sampler calls. |
| Limits | Allocates KV cache for `n_ctx` tokens. The actual context used may differ from `params.n_ctx` — always query `llama_n_ctx(ctx)` for the real value (see header comment at line 546–548 of `llama.h`). `n_batch` must be ≤ `n_ctx`. |
| Ownership | Returns a heap-allocated `llama_context *`. **Caller owns it** and must call `llama_free`. Wrapped in `LlamaContextHandle` for RAII. |
| Failure modes | Returns `NULL` on memory exhaustion. `LlamaBackend` throws `InferenceError.modelLoadFailed` with a specific message asking the caller to retry with a smaller context size. |

### `llama_free`

| Attribute | Detail |
|-----------|--------|
| Signature | `void llama_free(struct llama_context * ctx)` |
| Threading | Must not be called while any generation task is using the context. `LlamaBackend` awaits `capturedTask` before calling. |
| Ordering | Must precede `llama_model_free`. |
| Limits | None. |
| Ownership | Frees and invalidates all resources allocated for the context, including the KV cache. |
| Failure modes | Use-after-free if called while `llama_decode` is executing on the same context — prevented by the task lifecycle protocol in `unloadModel()`. |

---

## Context Introspection

### `llama_n_batch`

| Attribute | Detail |
|-----------|--------|
| Signature | `uint32_t llama_n_batch(const struct llama_context * ctx)` |
| Threading | Thread-safe read. |
| Ordering | Context must be initialised. |
| Limits | Returns the logical max batch size set at context creation (default 2048). `llama_decode` asserts `n_tokens <= n_batch`; exceeding this triggers an internal `GGML_ASSERT`. |
| Ownership | Returns a value. No allocation. |
| Failure modes | None; but the value directly constrains `llama_decode` — see violation history. |

---

## Memory / KV Cache

### `llama_get_memory`

| Attribute | Detail |
|-----------|--------|
| Signature | `llama_memory_t llama_get_memory(const struct llama_context * ctx)` |
| Threading | Thread-safe read. |
| Ordering | Context must be initialised. |
| Limits | May return `NULL` for contexts that have no memory (e.g., embedding-only contexts). |
| Ownership | Borrowed reference into context-owned memory. Do not free. |
| Failure modes | Callers must guard against `NULL`; `LlamaBackend` wraps in `if let memory = ...`. |

### `llama_memory_clear`

| Attribute | Detail |
|-----------|--------|
| Signature | `void llama_memory_clear(llama_memory_t mem, bool data)` |
| Threading | Must not be called concurrently with `llama_decode`. |
| Ordering | Requires a non-`NULL` memory handle. Called at the start of every generation run in `LlamaBackend` to prevent KV state from a prior (possibly cancelled) run from colliding with the new run's token positions. |
| Limits | When `data = false`, clears metadata (positions, sequence IDs) but not the raw weight buffers — this is what `LlamaBackend` uses. `data = true` also zeros the weight data, which is more expensive. |
| Ownership | Void. No new allocation. |
| Failure modes | None; incorrect use (not clearing after cancellation) is a correctness bug, not a crash — see violation history (PR #396). |

---

## Batching and Decoding

### `llama_batch_init`

| Attribute | Detail |
|-----------|--------|
| Signature | `struct llama_batch llama_batch_init(int32_t n_tokens, int32_t embd, int32_t n_seq_max)` |
| Threading | Thread-safe. |
| Ordering | Must be matched with `llama_batch_free`. |
| Limits | `n_tokens` must not exceed `llama_n_batch(ctx)` when passed to `llama_decode`. `LlamaBackend` queries `llama_n_batch` and processes prompts in chunks of at most that size. |
| Ownership | Allocates heap memory for all batch fields. Caller must free with `llama_batch_free`. `LlamaBackend` always calls `llama_batch_free` immediately after `llama_decode` in the prompt loop, and uses `defer` for the generation batch. |
| Failure modes | Passing `n_tokens > n_batch` to `llama_decode` triggers `GGML_ASSERT` and crashes the process. |

### `llama_batch_free`

| Attribute | Detail |
|-----------|--------|
| Signature | `void llama_batch_free(struct llama_batch batch)` |
| Threading | Thread-safe. |
| Ordering | Must be called for every batch created with `llama_batch_init`. |
| Limits | None. |
| Ownership | Frees batch-internal buffers. The struct is passed by value so the caller's copy is left dangling — do not use after `llama_batch_free`. |
| Failure modes | Memory leak if not called. |

### `llama_decode`

| Attribute | Detail |
|-----------|--------|
| Signature | `int32_t llama_decode(struct llama_context * ctx, struct llama_batch batch)` |
| Threading | **Not thread-safe on the same context.** `LlamaBackend` runs all decode calls from a single `Task`; the context pointer is captured under `stateLock` and never shared between tasks. |
| Ordering | KV cache must not be corrupt from a prior cancelled run — clear with `llama_memory_clear` first. `batch.n_tokens` must be ≤ `llama_n_batch(ctx)`. `batch.logits[i]` must be set correctly: only positions from which logits are needed should have `logits = 1`. |
| Limits | Returns `0` on success, `1` if no KV slot is available (non-fatal), `-1` for invalid input, `< -1` for fatal error. LlamaBackend treats any non-zero return as a failure. |
| Ownership | Does not take ownership of the batch. |
| Failure modes | `GGML_ASSERT` crash if `batch.n_tokens > n_batch` — the historic violation that PR #409 fixed by introducing chunked prompt decoding. Returns non-zero on KV slot exhaustion; this typically indicates context window overflow rather than a logic bug. |

---

## Sampling

### `llama_sampler_chain_default_params`

| Attribute | Detail |
|-----------|--------|
| Signature | `struct llama_sampler_chain_params llama_sampler_chain_default_params(void)` |
| Threading | Thread-safe; pure value. |
| Ordering | Call before `llama_sampler_chain_init`. |
| Limits | None. |
| Ownership | Value type. |
| Failure modes | None. |

### `llama_sampler_chain_init`

| Attribute | Detail |
|-----------|--------|
| Signature | `struct llama_sampler * llama_sampler_chain_init(struct llama_sampler_chain_params params)` |
| Threading | Thread-safe. |
| Ordering | Must precede `llama_sampler_chain_add` and `llama_sampler_sample`. Must be freed with `llama_sampler_free`. |
| Limits | Returns `NULL` on allocation failure (extremely rare). |
| Ownership | Returns a heap-allocated sampler chain. **Caller owns it.** `LlamaBackend` frees via `defer { llama_sampler_free(sampler) }`. |
| Failure modes | `NULL` return checked; `LlamaBackend` throws `InferenceError.inferenceFailure` if `NULL`. |

### `llama_sampler_chain_add`

| Attribute | Detail |
|-----------|--------|
| Signature | `void llama_sampler_chain_add(struct llama_sampler * chain, struct llama_sampler * smpl)` |
| Threading | Not safe to call concurrently on the same chain. |
| Ordering | Chain must be initialised. **Takes ownership of `smpl`** — the chain frees child samplers when `llama_sampler_free` is called on the chain. Do not call `llama_sampler_free` separately on any added sampler. |
| Limits | Order matters: penalties → top_k → top_p → min_p → temp → dist (as set in `LlamaBackend`). |
| Ownership | Transfer: chain owns `smpl` after this call. |
| Failure modes | None. |

### `llama_sampler_free`

| Attribute | Detail |
|-----------|--------|
| Signature | `void llama_sampler_free(struct llama_sampler * smpl)` |
| Threading | Must not be called while `llama_sampler_sample` is executing. |
| Ordering | For a chain, also frees all child samplers added via `llama_sampler_chain_add`. |
| Limits | **Do not call on a sampler that has been added to a chain** — that results in double-free. |
| Ownership | Frees and invalidates the sampler. |
| Failure modes | Double-free crash if called on a chain-owned sampler. |

### `llama_sampler_init_penalties`

| Attribute | Detail |
|-----------|--------|
| Signature | `struct llama_sampler * llama_sampler_init_penalties(int32_t penalty_last_n, float penalty_repeat, float penalty_freq, float penalty_present)` |
| Threading | Thread-safe construction. |
| Ordering | Add to chain before sampling. |
| Limits | `penalty_last_n`: window of recent tokens to penalise; `0` disables. Avoid on full vocabulary — O(vocab_size × penalty_last_n) per step. |
| Ownership | Returned pointer transferred to chain via `llama_sampler_chain_add`. |
| Failure modes | None. |

### `llama_sampler_init_top_k`

| Attribute | Detail |
|-----------|--------|
| Signature | `struct llama_sampler * llama_sampler_init_top_k(int32_t k)` |
| Threading | Thread-safe construction. |
| Ordering | Add to chain before sampling. Typically before top_p/min_p. |
| Limits | `k <= 0` makes this a no-op. `LlamaBackend` passes `40`. |
| Ownership | Transferred to chain. |
| Failure modes | None. |

### `llama_sampler_init_top_p`

| Attribute | Detail |
|-----------|--------|
| Signature | `struct llama_sampler * llama_sampler_init_top_p(float p, size_t min_keep)` |
| Threading | Thread-safe construction. |
| Ordering | After top_k, before temp. |
| Limits | `p = 1.0` is a no-op (all tokens kept). `min_keep` ensures at least that many candidates survive; `LlamaBackend` uses `1`. |
| Ownership | Transferred to chain. |
| Failure modes | None. |

### `llama_sampler_init_min_p`

| Attribute | Detail |
|-----------|--------|
| Signature | `struct llama_sampler * llama_sampler_init_min_p(float p, size_t min_keep)` |
| Threading | Thread-safe construction. |
| Ordering | After top_p, before temp. |
| Limits | Removes tokens with probability below `p * max_probability`. `LlamaBackend` uses `p = 0.05`, `min_keep = 1`. |
| Ownership | Transferred to chain. |
| Failure modes | None. |

### `llama_sampler_init_temp`

| Attribute | Detail |
|-----------|--------|
| Signature | `struct llama_sampler * llama_sampler_init_temp(float t)` |
| Threading | Thread-safe construction. |
| Ordering | After top_p/min_p, before dist. |
| Limits | `t = 1.0` is neutral. `t → 0` makes distribution increasingly deterministic. |
| Ownership | Transferred to chain. |
| Failure modes | None. |

### `llama_sampler_init_dist`

| Attribute | Detail |
|-----------|--------|
| Signature | `struct llama_sampler * llama_sampler_init_dist(uint32_t seed)` |
| Threading | Thread-safe construction. |
| Ordering | Must be last in the chain — it selects a token, not a filter. |
| Limits | `seed = LLAMA_DEFAULT_SEED` (0xFFFFFFFF) picks a random seed. `LlamaBackend` uses `UInt32.random(in: 0...UInt32.max)` for per-session variety. |
| Ownership | Transferred to chain. |
| Failure modes | None. |

### `llama_sampler_sample`

| Attribute | Detail |
|-----------|--------|
| Signature | `llama_token llama_sampler_sample(struct llama_sampler * smpl, struct llama_context * ctx, int32_t idx)` |
| Threading | Not thread-safe on the same context+sampler pair. |
| Ordering | Must be called after a successful `llama_decode`. `idx = -1` reads logits from the last token of the most recent decode (used on the first generation iteration); `idx = 0` reads from index 0 of a 1-token batch (used on subsequent iterations). |
| Limits | `idx` is relative to the logit matrix from the last decode; out-of-range values are undefined behaviour. |
| Ownership | Returns a `llama_token` (int32). No heap allocation. |
| Failure modes | Undefined behaviour if `llama_batch.logits[idx]` was `0` during decode (logits not requested for that position). `LlamaBackend` ensures `logits[last_token] = 1` in the prompt chunk and `logits[0] = 1` in every generation batch. |

---

## Tokenization

### `llama_tokenize`

| Attribute | Detail |
|-----------|--------|
| Signature | `int32_t llama_tokenize(const struct llama_vocab * vocab, const char * text, int32_t text_len, llama_token * tokens, int32_t n_tokens_max, bool add_special, bool parse_special)` |
| Threading | **Thread-safe** — pure vocabulary lookup, no context state. |
| Ordering | Vocabulary pointer must be valid (model loaded). |
| Limits | Returns the token count on success (≤ `n_tokens_max`); returns a negative number (negated required size) if the buffer is too small; returns `INT32_MIN` on overflow. `LlamaBackend` allocates `text.utf8CString.count + (addBos ? 1 : 0)` tokens — `utf8CString.count` is the null-terminated byte count (`text.utf8.count + 1`), and one extra slot is reserved for the BOS token when `addBos = true`. This is always sufficient. |
| Ownership | Writes into caller-provided `tokens` buffer. No heap allocation. |
| Failure modes | Negative return means buffer too small — `LlamaBackend` treats negative return as failure and returns an empty array (causing `InferenceError.inferenceFailure("Failed to tokenize prompt")`). |

### `llama_token_to_piece`

| Attribute | Detail |
|-----------|--------|
| Signature | `int32_t llama_token_to_piece(const struct llama_vocab * vocab, llama_token token, char * buf, int32_t length, int32_t lstrip, bool special)` |
| Threading | Thread-safe — pure vocabulary lookup. |
| Ordering | Vocabulary must be valid. |
| Limits | Returns byte count on success; returns negated required size if buffer too small. `LlamaBackend` starts with a 32-byte buffer and retries on negative return. |
| Ownership | Writes into caller-provided buffer. Does not write a null terminator. |
| Failure modes | Negative return on buffer too small — `LlamaBackend` retries with the correct size. Multi-byte UTF-8 sequences can span token boundaries; `LlamaBackend` accumulates incomplete bytes in `invalidUTF8Buffer` and defers emission until a valid UTF-8 string can be formed. |

### `llama_vocab_is_eog`

| Attribute | Detail |
|-----------|--------|
| Signature | `bool llama_vocab_is_eog(const struct llama_vocab * vocab, llama_token token)` |
| Threading | Thread-safe — pure vocabulary lookup. |
| Ordering | Vocabulary must be valid. |
| Limits | None. |
| Ownership | Returns a bool. No allocation. |
| Failure modes | None; returns `false` for non-EOG tokens including BOS. |

---

## Known Violations History

The following contract violations caused production crashes or silent
correctness bugs. Each entry links to the PR that fixed it.

### 1. `n_batch` limit overflow — fixed in PR #409

**Violation:** `llama_decode` asserts `n_tokens <= cparams.n_batch` inside
`llama-context.cpp` via `GGML_ASSERT`. Before PR #409, `LlamaBackend` passed
the entire tokenised prompt as a single batch. On models with a default
`n_batch` of 2048, prompts longer than 2048 tokens triggered the assert,
crashing the process with `SIGABRT`.

**Fix:** The prompt is now decoded in `n_batch`-sized chunks. `llama_n_batch(ctx)`
is queried once after context creation and used as the stride. Each chunk has
`logits = 0` except the last token of the final chunk, which has `logits = 1`.
Intermediate chunks are allocated and freed inside the loop to avoid
batch-reuse bugs.

**Detection signal:** `GGML_ASSERT(n_tokens_all <= cparams.n_batch)` in
llama.cpp source; SIGABRT in the host process.

### 2. `n_ctx` vs. available memory — fixed in PR #399 / `ModelLoadPlan`

**Violation:** `llama_init_from_model` allocates a KV cache sized for
`n_ctx × n_heads × head_dim × 2` (K + V). For large context sizes on devices
with limited VRAM, this caused either an out-of-memory `NULL` return or, worse,
a successful allocation followed by Metal command-buffer failures mid-generation.

**Fix:** `ModelLoadPlan` computes the maximum context size that fits in
available memory before calling the backend. `LlamaBackend.loadModel(from:plan:)`
uses `plan.effectiveContextSize` as the authoritative value and does **no
internal clamping** — the plan is the single source of truth. If
`llama_init_from_model` still returns `NULL` at that size, `LlamaBackend`
throws `InferenceError.modelLoadFailed` with an explicit message asking for a
smaller context, rather than silently retrying with a halved size (which was
the original broken behaviour).

**Detection signal:** `llama_init_from_model` returning `NULL`; Metal
`MTLDevice` allocation failures logged to the system console.

### 3. KV cache state after cancelled generation — fixed in PR #396

**Violation:** When generation was cancelled via `stopGeneration()`, the
`llama_context` KV cache retained token positions from the interrupted run.
The next call to `generate()` started filling the KV cache from position 0,
colliding with stale positions already resident. llama.cpp's KV slot allocator
could not find a valid slot, causing `llama_decode` to return `1`
(no KV slot available) immediately, producing a "Decode failed during
generation" error on the very first token.

**Fix:** `llama_memory_clear(memory, false)` is called at the start of every
generation task, after re-acquiring the context pointer under `stateLock`.
`data = false` clears metadata (positions, sequence IDs) without zeroing weight
buffers, making it fast. The call is guarded by `if let memory = llama_get_memory(context)`
to handle the rare case of a context with no memory.

**Detection signal:** `llama_decode` returning `1` immediately on the first
token of a new generation following any cancellation; "Decode failed during
generation" error in the `GenerationStream`.

### 4. `cancelled` flag data race between `stopGeneration()` and the decode loop — open in PR #456 (issue #418)

**Violation:** `stopped` is a plain `Bool` guarded by `stateLock`. When
`stopGeneration()` is called from the main actor, it acquires `stateLock` to
write `cancelled = true`. The decode loop reads `cancelled` via
`withStateLock { self.cancelled }` on a background task. Under Thread Sanitizer
the ordering guarantee is provided solely by `NSLock`, which TSan does not
always model as a sequentially-consistent barrier. Additionally,
`stopGeneration()` is documented as safe to call from any thread or actor (e.g.
a memory-pressure handler), but `NSLock` does not establish the
sequentially-consistent atomic ordering needed to make that guarantee airtight.

**Planned fix (PR #456, not yet merged as of this writing):** Replace
`private var cancelled = false` with `private let cancelled = Atomic<Bool>(false)`
from Swift 6's `Synchronization` stdlib. All reads and writes use
`.sequentiallyConsistent` ordering, making `stopGeneration()` safe to call from
any thread without acquiring `stateLock` for the flag itself.

**Current mitigation:** All existing reads and writes go through `withStateLock`
(or hold `stateLock` directly), so the race is not exploitable in practice — the
lock prevents concurrent access to the flag. TSan warnings remain possible on
systems where it does not recognise `NSLock` as a synchronisation primitive.

**Detection signal:** Thread Sanitizer reporting a data race on `cancelled`
between the `stopGeneration()` caller thread and the generation task background
thread.

### 5. Unsynchronized Metal command buffers between consecutive `generate()` calls — fixed in this PR

**Violation:** `llama_decode` enqueues Metal compute passes asynchronously.
When `LlamaGenerationDriver.run()` returned without calling `llama_synchronize`,
the GPU could still be executing the final batch's command buffers at the time
the *next* `generate()` call began.  The KV-cache clear at the top of the new
run (`llama_memory_clear` / `llama_memory_seq_rm`) enqueues fresh Metal
operations before the previous command buffers had committed.  That ordering
violation trips llama.cpp's internal render-set assertion:

```
GGML_ASSERT([rsets->data count] == 0)   (ggml-metal-device.m:618)
Signal 5 (SIGTRAP)
Swift/ContiguousArrayBuffer.swift:692: Fatal error: Index out of range
```

The crash was model-specific (observed on llama3.1:8b, not Qwen3-4B) because
larger models produce longer Metal command buffers that are more likely to still
be in flight when the second call begins.

**Fix:** `llama_synchronize(context)` is called at every exit path of
`LlamaGenerationDriver.run()`: the normal completion path, the mid-prompt
cancellation path, the prompt-decode-failure path, and the in-loop
decode-failure path.  `llama_synchronize` blocks the calling thread until the
GPU is idle — sub-millisecond when the GPU is already done — and is the
authoritative synchronization primitive for this purpose (see `llama.h` line 972).

**Detection signal:** `GGML_ASSERT([rsets->data count] == 0)` in
`ggml-metal-device.m` on the second consecutive `generate()` call; followed by
a Swift `Fatal error: Index out of range` in `ContiguousArrayBuffer.swift`.
Regression test: `test_consecutiveGenerateCalls_doesNotCrash` in
`Tests/ManifoldE2ETests/LlamaE2ETests.swift`.

---

## Security

### CVE-2026-2069 — Buffer overflow in `llama_grammar_advance_stack()`

| Attribute | Detail |
|-----------|--------|
| CVE | CVE-2026-2069 |
| Affected symbol | `llama_sampler_init_grammar` → internal `llama_grammar_advance_stack()` |
| Vulnerability | A buffer overflow in the grammar stack-advance logic allows a crafted GBNF grammar string (or a JSON Schema with certain constructs) to overflow an internal stack buffer, enabling potential arbitrary code execution. |
| Fixed in | llama.cpp build **b8774** |
| Vendored build | **b8772** (via `mattt/llama.swift` 2.8772.0) — **not fixed** |
| Status | ⚠️ **Unmitigated in the vendored binary.** The fix has not been picked up yet. |

#### Mitigation until the pin is bumped

`GBNFSchemaPreValidator` (introduced in this codebase alongside issue #609) runs
before every `llama_sampler_init_grammar` call that is driven by a tool-call
`ToolDefinition.parameters` schema. It rejects the schema constructs confirmed in
the CVE proof-of-concept to trigger the overflow:

- `anyOf`, `oneOf`, `allOf`, `not` — schema combiners
- Nullable union types: `"type": ["string", "null"]`
- `exclusiveMinimum` / `exclusiveMaximum` (Draft 2020-12 integer form)

**Callers that pass a GBNF string directly via `GenerationConfig.grammar` (not via tool definitions) are not covered by this pre-validator.** Those strings are already validated syntactically by `llama_sampler_init_grammar`'s own GBNF parser, but crafted inputs from untrusted sources could still trigger the overflow. Treat `GenerationConfig.grammar` as a trusted-input field until the pin is bumped.

#### Upgrade procedure for the CVE fix

1. Bump `mattt/llama.swift` to a version wrapping build ≥ b8774.
2. Confirm the xcframework version in `docs/vendor/llama.h` and update this section.
3. In `GBNFSchemaPreValidator.swift`, flip `CVEAuditRecord.isFixed` to `true` and
   update `vendoredBuild` to match.
4. Re-audit the rejection rules in `GBNFSchemaPreValidator.validate(_:path:)` —
   rules that were solely motivated by the overflow (rather than GBNF expressiveness
   limits) may be relaxed or removed.
5. Run `swift test --filter ManifoldBackendsTests --traits Llama` on Apple Silicon.

---

## Binary vs. Vendored Source

### Decision

`LlamaSwift` is consumed as a **pre-built xcframework binary** — specifically
`llama-b8772-xcframework.zip` distributed from the `ggml-org/llama.cpp` GitHub
releases and wrapped by `mattt/llama.swift`. ManifoldKit does **not** compile
llama.cpp from source.

### Tradeoffs

| Factor | Binary pin | Vendored source |
|--------|-----------|-----------------|
| Build time | Fast — no C/C++ compilation | Slow — full llama.cpp compile on every clean build |
| Metal shaders | Pre-compiled; consistent across machines | Compiled by Xcode; can diverge between Xcode versions |
| Diff on upgrade | Opaque — only `llama.h` changes are visible | Full diff available in git |
| CI compatibility | `swift test` works without Xcode | Metal shaders require Xcode for `swift test` |
| Reproducibility | Exact binary is pinned by `checksum` in `Package.swift` | Source is pinned by tag/commit |
| Debugging | Cannot step into llama.cpp internals | Full source available to debugger |

### Rationale for keeping the binary pin

The Metal shader pre-compilation is the decisive factor. Compiling llama.cpp
Metal shaders from source requires Xcode and the Metal shader compiler, which
is unavailable in headless CI environments and on non-Apple machines.
The pre-built xcframework ensures `swift test --disable-default-traits` (the
CI path) does not require Xcode, while Xcode integration tests (`ManifoldMLXIntegrationTests`)
continue to use the same pre-built binary.

The opacity of binary diffs is mitigated by two practices:
1. `docs/vendor/llama.h` is re-copied on each version bump and committed,
   giving a human-readable diff of the public API surface in code review.
2. This document (`LLAMA_CONTRACT.md`) is updated in the same PR as the
   version bump, forcing a review of every contract change against the
   sections above.

### Upgrade procedure

1. Update the `from:` constraint in `Package.swift` for `mattt/llama.swift`.
2. Run `swift package resolve` to update `Package.resolved`.
3. Copy the new `llama.h` from the resolved xcframework:
   ```
   find ~/Library/Developer/Xcode/DerivedData -path "*/ManifoldKit*/llama.xcframework/macos-arm64_x86_64*" -name "llama.h" | head -1
   ```
   Then prepend the read-only header comment (see `docs/vendor/llama.h`) and commit.
4. Diff `docs/vendor/llama.h` against the previous version and review every
   changed symbol against the tables in this document.
5. Update the pin comment on the `mattt/llama.swift` dependency line in
   `Package.swift`.
6. Update the version reference in the read-only header comment in
   `docs/vendor/llama.h`.
7. Update every section in this document (`LLAMA_CONTRACT.md`) that references
   the version number or whose contract has changed according to the `llama.h`
   diff from step 4. Commit `LLAMA_CONTRACT.md` in the same PR as the pin bump.
8. Run `swift test --filter ManifoldBackendsTests --traits Llama` locally on
   Apple Silicon before opening the PR.
