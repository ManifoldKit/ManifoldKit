# Model Management

A consolidated reference for quantization discovery, device-fit gating, and
residency policy. For first-run model discovery and the `ModelSelection` list
API, start at [`QUICKSTART-MODEL-SELECTION.md`](QUICKSTART-MODEL-SELECTION.md);
for GGUF file locations and load-error diagnostics, see [`LOCAL-GGUF.md`](LOCAL-GGUF.md).
This page covers the runtime policy surface — reading quant metadata, when the
engine refuses a load, and how long a loaded model stays resident.

---

## 1. Quantization: discovery, not selection

ManifoldKit reads quantization tags from GGUF metadata at discovery time and
surfaces them on `ModelInfo.quantization` (a raw string — `"Q4_K_M"`, `"Q8_0"`,
etc.). There is **no runtime chooser API** — quantization is a property of the
file on disk. What you can do is read it and let it inform recommendations or UI:

```swift,no-build
import ManifoldKit

@MainActor
func describeModel(_ model: ModelInfo) {
    let quant = model.quantization ?? "unknown"
    let size  = ByteCountFormatter.string(fromByteCount: Int64(model.sizeBytes),
                                          countStyle: .file)
    print("\(model.name) — \(quant) — \(size)")
}
```

The `rankedModels(useCase:)` scorer uses a composite `qualityScore` that weighs
model-size tier first and quantization width second — a Q4_K_M 7B still
outscores a Q8_0 1B on capability. Use the ranked list rather than rolling your
own quant filter.

**Quant tier quick-reference** (Apple Silicon, rough guidance):

| Quant | Bits/weight | Typical tradeoff |
|-------|-------------|------------------|
| `Q2_K` | ~2.6 | Fits the largest models; quality noticeably degraded |
| `Q4_K_M` | ~4.8 | Best quality-per-GB for most devices — default pick |
| `Q5_K_M` | ~5.8 | Marginal quality lift over Q4; worth it for reasoning tasks |
| `Q8_0` | ~8.5 | Near float16 quality; only practical on 32GB+ or sub-3B models |

> `Q4_K_M` is the practical default for 7B–13B models on a 16 GB device. Step
> up to `Q5_K_M` for reasoning or code when the model fits comfortably; reserve
> `Q8_0` for high-RAM devices or small parameter counts.

> **RAG note.** Chunk embeddings are produced by the *embedding* model, not the
> chat model. Switching the chat model's quant tier does not invalidate the index;
> switching the embedding backend does — re-ingest if you change embedders.

---

## 2. Device-fit: the load-plan gate

Before loading any model, ManifoldKit runs
`ModelLoadPlan.compute(for:requestedContextSize:strategy:)` as an admission
check. A load is refused (`.deny`) when the model's weights plus the KV cache
for the requested context window would exceed the device's resident memory
budget.

```swift,no-build
import ManifoldKit

@MainActor
func canLoad(_ model: ModelInfo, contextSize: Int = 8_192) -> Bool {
    let plan = ModelLoadPlan.compute(
        for: model,
        requestedContextSize: contextSize,
        strategy: .mappable
    )
    switch plan.verdict {
    case .allow:
        return true
    case .warn:
        // Tight fit — the model will load but memory pressure is likely.
        // Surface plan.reasons to the user:
        // e.g. .insufficientResident, .insufficientKVCache
        return true
    case .deny:
        // Refused. Inspect plan.reasons for the blocking constraint.
        return false
    }
}
```

The context window cap defaults to the model's declared `contextLength` (from
GGUF metadata), floored to `ManifoldConfiguration.shared.minimumContextSize`
(512 on the simulator). Passing a smaller `requestedContextSize` can flip a
`.deny` to `.warn` or `.allow` — useful when your use case only needs 4K context.

`ModelSelection.loadSelected()` runs this check internally and surfaces
`ModelLoadError.loadPlanDenied(plan:)` if the verdict is `.deny` — you only need
to call `ModelLoadPlan.compute` directly when building a pre-flight UI or a model
recommender that filters before displaying.

**Memory strategies:**

| Strategy | When to use |
|----------|-------------|
| `.mappable` | Default for GGUF. mmap-backed — only active pages + KV cache need RAM. Lower peak RSS, higher per-token latency variance on cold access. |
| `.resident` | Required for MLX (unified-memory backends). Weights must be fully resident in RAM before generation starts. Auto-selected by `compute(for:requestedContextSize:)` for `.mlx` model types — only pass explicitly if overriding the strategy for a custom backend. |

---

## 3. Residency and keep-alive

Once loaded, a model stays resident until explicitly unloaded, memory pressure
forces eviction, or an idle-timeout policy fires. Configure this on
`InferenceService.keepAlivePolicy`:

```swift,no-build
import ManifoldKit

// Unload after 5 minutes of idle time:
inferenceService.keepAlivePolicy = KeepAlivePolicy(idleTimeout: 5 * 60)

// Evict proactively on OS memory-pressure warning if idle > 10 s:
inferenceService.keepAlivePolicy = KeepAlivePolicy(
    idleTimeout: 5 * 60,
    evictOnMemoryWarning: true,
    memoryWarningGrace: 10
)

// Disable auto-unload (the default — model stays until you call unloadModel()):
inferenceService.keepAlivePolicy = .never
```

| Property | Default | Meaning |
|----------|---------|---------|
| `idleTimeout` | `nil` (disabled) | Seconds of no generation before auto-unload. Generation resets the clock; a busy model is never evicted mid-turn. |
| `evictOnMemoryWarning` | `false` | When `true`, an idle model may be evicted at OS `.warning` pressure (before `.critical`), freeing RAM earlier. Advisory: never interrupts generation. |
| `memoryWarningGrace` | 10 s | How long the model must have been idle before a `.warning` event can trigger eviction. Prevents eviction immediately after a turn completes. |

### Ollama advisory residency

For Ollama backends, ManifoldKit mirrors the `KeepAlivePolicy` idle timeout into
Ollama's server-side `keep_alive` field so the two timers agree. The default
`OllamaBackend.keepAlive` is `"30m"` (Ollama's own default is `"5m"`). When a
`KeepAlivePolicy.idleTimeout` is set, ManifoldKit overwrites `keepAlive`
automatically with the same duration — you don't need to set both.

To change the Ollama advisory residency independently (for example on a shared
server where you want to release GPU VRAM sooner), access the backend directly:

```swift,no-build
import ManifoldOllama

let backend = OllamaBackend()
backend.keepAlive = "5m"   // free server VRAM sooner on a shared machine
```

---

## 4. The Manifoldfile bundle (coming in #1932)

> **Not yet shipped.** The `Manifoldfile` — a declarative bundle format for
> packaging a GGUF model, a system prompt, default `GenerationConfig`, and tool
> definitions into a single distributable artifact — is tracked in
> [#1932](https://github.com/ManifoldKit/ManifoldKit/issues/1932). This section
> will be filled in when it lands.

---

## See also

- [`QUICKSTART-MODEL-SELECTION.md`](QUICKSTART-MODEL-SELECTION.md) — `ModelSelection`, the ranked-models API, and per-family load paths.
- [`LOCAL-GGUF.md`](LOCAL-GGUF.md) — where ManifoldKit looks for GGUF files and how to diagnose load errors.
- [`FeatureMatrix.md`](FeatureMatrix.md) — per-backend capability table.
