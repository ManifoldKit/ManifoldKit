# ManifoldLlama — Runtime Behaviour

Consumer-visible llama.cpp backend behaviour that isn't part of the
public Swift API but materially affects measurements, determinism, and
deployment. Pair with `docs/LLAMA_CONTRACT.md` (C-API surface) for the full
picture.

## Metal offload policy

`LlamaModelLoader` and `LlamaEmbeddingBackend` both default to **full Metal
offload** (`n_gpu_layers = 99`) on every Apple Silicon device. The simulator
target is forced to CPU (`n_gpu_layers = 0`) because Metal command buffers
are unreliable under the simulator and the FA kernel is unsupported.
Flash-attention is enabled (`LLAMA_FLASH_ATTN_TYPE_ENABLED`) on the device
path.

### `LLAMA_FORCE_CPU_ONLY=1` escape hatch

Setting `LLAMA_FORCE_CPU_ONLY=1` in the process environment forces
`n_gpu_layers = 0` on device. This exists for very large MoE models whose
partial-weight Metal buffers exceed available unified memory — those loads
fail with an opaque Metal allocation error rather than degrading
gracefully, and a CPU-only mmap-paged load is the only working path.

Trade-off measured on M5/24 GB against Qwen3-4B-Q4_K_M
(`test_countTokens_…`): default Metal path 0.28 s, CPU-forced path 2.28 s
— roughly **8× slower**. Only flip this for models you have actually
observed to OOM on Metal load.

## Prompt prefix KV reuse

When `generate()` is called and the new prompt shares a token-identical
prefix with the previous decoded prompt on the same context,
`LlamaBackend` trims the KV tail past that prefix via `llama_memory_seq_rm`
and re-decodes only the suffix. This is prompt caching; it ships
unconditionally and there is currently no knob to disable it.

Consumers should be aware of two implications:

1. **First-token latency depends on prompt overlap.** Two calls with the
   same prompt against a fresh context (cold) versus a context that
   already decoded the same prefix (warm) will differ in time-to-first-token
   by the cost of re-decoding the shared prefix. Benchmarks that measure
   "TTFT" without controlling for this will see wide variance.

2. **Seeded `dist` sampling is not bit-exact across reuse boundaries.**
   The partial re-decode of a suffix uses a different Metal accumulation
   order than a full-batch decode of the same prompt. Numerically-tied
   argmax candidates can resolve differently. Determinism at
   `temperature > 0` therefore holds **across runs with identical reuse
   boundaries**, not across all runs with the same seed. Temperature-zero
   callers are unaffected: `LlamaGenerationDriver` swaps in
   `llama_sampler_init_greedy()` at `temperature <= 0.0` and bypasses
   `dist` entirely.

`LlamaGenerationDriver` emits a `.kvCacheReuse(promptTokensReused: Int)`
event on the `GenerationStream` whenever `reuseLen > 0`, so consumers that
need to log or surface the optimisation can subscribe to it.

## Cancellation surface

`LlamaBackend.stopGeneration()` is safe to call from any thread or actor —
the `cancelled` flag is `Atomic<Bool>` (Swift 6 `Synchronization`) and uses
`.sequentiallyConsistent` ordering. The decode loop polls the flag every
iteration; in-flight `llama_decode` calls cannot be interrupted, so worst-
case latency is one decode step (~ one token of generation, plus any
remaining prompt-chunk in flight).

`LlamaEmbeddingBackend` does **not** participate in this protocol —
embedding runs are single-shot `llama_encode` calls with no cancellation
check. A UI-initiated cancel during a slow CPU embedding will not
interrupt the encode; it will only prevent the next one from starting.

## Memory-pressure response

`LlamaBackend` registers as a memory-pressure observer. On `.warning` it
calls `stopGeneration()` immediately; on `.critical` it additionally
schedules a `Task.detached` to call `unloadModel()` so the KV cache and
weights are released before the OS escalates to jetsam termination.
