# feat(catalog): measured tool-call conformance — a (model × quant × backend) matrix, superseding #2001's static flag

> **Supersedes #2001.** That issue asked for a static, renderer-honest tool-call capability flag on `ModelInfo`. The investigation below concludes it specs the wrong artifact on the wrong layer: it asks a *discovery-time* type to assert a *verdict* that is only knowable by *measurement*. This issue keeps the host need intact and reframes the deliverable around it.

> **Status (2026-06-22 — reconciliation; analysis below is retained as-is):**
> - **Layer 1 — SHIPPED (PR #2009).** `ChatTemplateToolDescriptor` (in `Sources/ManifoldModelCatalog/`) + `ModelInfo.toolCallClaim`. Note it landed as a **heuristic substring/regex parser**, *not* the minja trial-render the analysis below proposed; and it deliberately put the *claim* on `ModelInfo` — the discovery-time layer this doc argued against. Reframed honestly: the field is a **necessary-but-not-sufficient claim** (does the template even mention tools?), not the capability *verdict*. It does not assert the model can actually tool-call.
> - **Layer 2 — SHIPPED (PR #2022).** `RenderConsistencyChecker` / `RenderConsistency` (`Sources/ManifoldInference/Services/RenderConsistencyChecker.swift`) — a static render round-trip that flags the #1909 class (template *claims* tools but silently *drops* them on render). Presence-only check; full per-family parse-back stays in the companion targets.
> - **Layer 3 — DEFERRED.** Live soak + the `ToolCallConformance` SwiftData cache (measured per-(model × quant × backend) verdicts). Tracked by the still-open issue **#2005**; build only when a consumer needs measured verdicts.

## The host need (unchanged from #2001)

A host (Idlewick) wants to steer users toward models that can actually drive an agentic, tool-calling workload and grey out the ones that can't. Today the only honest host-visible signal is a name heuristic (`"instruct"` / `"-it-"` in the filename), which is wrong in exactly the cases that matter. The need is real. The question is what MK should expose.

## Why #2001 as written is the wrong shape

Three findings from the design thread, each narrowing the answer:

1. **The motivating bug is already fixed.** #2001's canonical example — gemma-4 silently dropping `tools` (#1909) — was fixed by #1912 (merged 2026-06-19, two days before #2001 was filed). `JinjaPromptRenderer` now threads `tools`/`tool_calls`/`tool_call_id`. The dramatic "looks capable, isn't" case no longer reproduces via that path. The *principle* survives; the proof point is stale.

2. **The field is on the wrong layer.** #2001 puts the flag on `ModelInfo`, which is a **discovery-time** artifact in the catalog leaf (`ManifoldModelCatalog`), populated entirely from static GGUF/HF metadata *before any backend loads*. It has zero access to a backend or renderer. But the capability is (correctly, per #2001) **model × backend × renderer**. A model-only type cannot honestly carry it. Every population strategy is broken: `declaredByTemplate` is the misleading signal #1909 disavowed; `measuredByMK` needs a harness that doesn't exist; `curated` is a rotting allowlist.

3. **"Genuine support" is irreducibly empirical.** Whether a model tool-calls is a property of its *weights*, not derivable from any static signal:
   - A base/merge/distill can inherit a tool-bearing chat template and still emit prose — the template travels with the tokenizer config; the training doesn't. (Confirmed: `Qwen2.5-7B` **base** ships the *identical* tool-aware template as `-Instruct`.)
   - Quantization can degrade a real tool-caller below usable. Same weights, different file, different answer.
   - A perfect render path in front of untrained weights still yields ~0% parseable calls.

   So `declaredByTemplate` doesn't just fail in the bug case — it fails in the *normal* case. The only honest source for the positive verdict is **measurement** through the real render+parse path.

## The principle: assess, don't declare

There are three different questions, each with exactly one honest source. #2001 collapses them into one flag; this issue separates them:

| Question | Honest source | Confidence |
|---|---|---|
| Which **dialect** does this model emit? | the chat template (or the backend, which already picks one) | authoritative, static |
| **Can** it express tools at all? | the chat template (`{% if tools %}` present) | authoritative *negative*, necessary-not-sufficient *positive* |
| Does it **genuinely** tool-call? | a measured soak through the real path | the only verdict source |

## Evidence: the chat template is a reliable dialect descriptor (mostly)

A cross-family study of six chat templates (verbatim extraction). The template — which MK already downloads and stores as `chatTemplateRaw` and then barely parses — is a machine-readable interface contract:

| Family | tools guard | call dialect | arg encoding | extractability |
|---|---|---|---|---|
| gemma-4 | `{% if tools %}` | `<\|tool_call>call:NAME{…}<tool_call\|>` | **custom `key:value`** | clean |
| Qwen2.5-Instruct | `{%- if tools %}` | `<tool_call>\n{json}\n</tool_call>` | JSON | clean |
| Hermes-2-Pro | `{% for tool %}` | `<tool_call>\n{json}\n</tool_call>` | JSON | clean |
| Llama-3.1-Instruct | `Environment: ipython` | bare `{"name","parameters"}` **or** `<\|python_tag\|>name.call(…)` | JSON / `key="val"` | **buried** |
| Mistral-v0.3 | `tools is not none` | `[TOOL_CALLS] [{…}]` | JSON | clean |
| Phi-4 | **none** | — | — | tool-less |

Conclusions:
- **Dialect is statically derivable for 4/6 cleanly.** This makes issue field #2 (dialect) a parse, not a measurement — and it should replace MK's hand-wired `ToolCallMarker` tuples and name-substring `ThinkingMarkers` guessing with derived-from-source truth.
- **"Dialect" is two-dimensional** — `{delimiters, argEncoding}`. gemma's custom `key:value` and Llama's `python_tag` `key="val"` mean a naive "scan `<tool_call>` + parse JSON" silently mis-parses two of six.
- **`extractability` is itself a predictive signal.** Llama-3.1's custom-tool call has no opening delimiter (bare JSON) and a prose instruction — the configuration most prone to parse failure. "Buried" → soak first, expect salvage burden.
- **The negative gate is asymmetric and honest only one way.** No template / no tools block ⇒ trustworthy `unsupported` (Phi-4, Mistral base). Tools block present ⇒ **not** a verdict (Qwen base carries the instruct template).

## The deliverable: a conformance matrix, not a flag

Template-derived **theoretical** capability × soak-measured **actual** capability. The off-diagonal *is* the work backlog — which is the whole point: gaps you close incrementally instead of production bugs you react to.

| | soak: works | soak: fails | soak: n/a |
|---|---|---|---|
| **template: expressible** | ✅ ship `supported` + dialect | ⚠️ **THE GAP** — auto-surfaced | — |
| **template: not expressible** | (investigate — odd) | — | ⛔ honest `unsupported`, skip soak |

The ⚠️ quadrant (template says yes, model says no) is the #1909 quadrant. It splits into two causes the matrix **localizes** rather than discovers in production:
- **(a) MK render/parse bug** — template declares dialect X, MK's renderer for that (model, backend) doesn't emit it. **Statically diffable** (template-declared markers vs MK's actual output) — catchable *without a soak*. This diff alone would have caught #1909 the day the model was added.
- **(b) weights don't honor it** — legitimately `unsupported`. Only the soak distinguishes (a) from (b).

So the artifact is a continuously-populated matrix keyed by **(model × quant × backend)**: every entry gets a *free, static, theoretical* row the instant it's added, and a *lazy, measured* actual cell from the soak. #1909 stops being a 3,400-failure fire and becomes a red cell with a pointer to the cause.

## Prior art / build-vs-borrow

The machinery splits into four layers; three have strong upstream prior art, the fourth is a genuine ecosystem gap.

| Layer | Prior art | Verdict |
|---|---|---|
| Template → capability/dialect | **minja `chat-template.hpp`** (trial-renders dummy messages → `supports_tools`, `requires_object_arguments`, polyfills); **llama.cpp `common/chat.cpp`** (per-family detection + GBNF/PEG grammar + reverse-parse) | Reference impls exist. `swift-jinja` (MK's dep) is **render-only** — carries none of minja's detection. |
| Per-family parsers | **vLLM `tool_parsers/`** (~30 families); **Ollama** `tools.Parser` | Reusable *catalogs* of which-family→how-to-parse. |
| Static capability table | **LiteLLM** `model_prices_and_context_window.json` (`supports_function_calling`) | Declared/curated, cloud-leaning, spotty on local. A *seed*, not a verdict. |
| **Measured soak per artifact** | BFCL/Gorilla, τ-bench, ToolBench | **GAP.** All run local OSS only via vLLM/sglang full-precision GPU — **none run GGUF/MLX/Ollama quantized artifacts**; all leaderboard-shaped. No per-(artifact × backend) cacheable conformance library exists. |

**Critical packaging finding:** manifold-llama links llama.cpp as a **prebuilt xcframework** (`b9553`) shipping **only `libllama`** — `common/chat.cpp` + minja are **not compiled**. The `LLAMA_CONTRACT.md` 56-symbol list contains no `common_chat_*`. So "borrow llama.cpp's chat layer" would require a **custom xcframework build** (a real fork of the packaging), not a thin call-through. For now MK reimplements the dialects in Swift (`LlamaToolMarkers.swift`, four families). Two consequences:
- `chat.cpp` / vLLM stay as **reference catalogs** to keep `LlamaToolMarkers` in sync, not as dependencies.
- The **capability-by-trial-render** approach (minja) should be **ported to Swift**, since adopting it via the C binary is off the table without re-packaging.

## Design: three layers

1. **`ChatTemplateDescriptor`** over `chatTemplateRaw` (which MK already stores). Emits `{ toolsExpressible, toolDialect: {delimiters, argEncoding}, extractability, multimodalMarkers, reasoningChannel }`. Port minja's `chat-template.hpp` trial-render detection rather than hand-rolling regex. Replaces hardcoded `ToolCallMarker` / `ThinkingMarkers`. Free, static; honest for *interface*.
2. **Static render-consistency check.** Diff template-declared dialect vs MK's actual rendered/parsed output per (model, backend). Catches the (a)-class bugs (#1909) with no model run.
3. **Tool-call soak + cache.** Reuse the existing `ManifoldTools` `ScenarioRunner`; borrow BFCL's *metrics* (AST/parseable accuracy, irrelevance detection) as the eval design. Produce a `ToolCallConformance` result mirroring `ModelBenchmarkResult` — but note the distinction:
   - `ModelBenchmarkResult` (tokens/sec) is **device-specific**, must be measured locally, decays (7-day `isStale`).
   - `ToolCallConformance` is a property of the **weights** — measure on any machine, holds on every machine, doesn't decay. Key by **(model × quant × backend)**, not just file name (temperature/sampler and backend both move the rate). This makes it **shippable as catalog data** / poolable later, not re-measured per device.
   New port + SwiftData adapter, analog of `BenchmarkCache`. Lazy/backgrounded — never a cold-start tax; `unknown` until measured.

The off-diagonal of (1)×(3), pre-localized by (2), is the incremental gap list.

## Smallest first step (two edits, both in manifold-llama)

The investigation found the #2001 root cause as concrete code, and a near-free win:
1. **`LlamaBackend.swift:461-474` hardcodes `supportsTools: true, supportsToolCalling: true` unconditionally** — the exact dishonest signal #2001 was filed against. Make it conditional.
2. **The dialect is already selected inside the backend** (`LlamaToolMarkers.markers()`) but discarded at the boundary — only `supportsThinking`/`thinkingMarkers` cross to core. **Surface the chosen dialect** to the capability surface. This delivers issue field #2 for the llama backend with no template parsing and no soak.

These two are independently shippable and unblock the host's dialect-aware parser immediately, ahead of the full matrix.

## Acceptance

- A `ToolCallConformance` result (capability `supported | unsupported | unknown`, observed `dialect`, `source: templateExpressible | renderConsistent | measured`, `measuredAt`, sample count) is queryable per **(model × quant × backend)** — additive/optional for forward compatibility.
- For a model whose template has no tools block (Phi-4) or no template (Mistral base): `capability == unsupported` from the static layer, **without** running a soak.
- For a known-good tool-caller (Qwen2.5-Instruct via the GGUF backend): `capability == supported` with a populated `dialect`, sourced `measured`.
- For a (model, backend) where the template declares a dialect MK's renderer doesn't emit: the render-consistency check flags it (the #1909 class) **without** a soak.
- The chosen dialect is exposed for the llama backend (first-step edit) and `supportsToolCalling` is no longer hardcoded `true`.
- Doc note: a host treats `unknown` as "recommend = no; allow with warning = host's call"; the soak threshold (e.g. ≥95% parseable) stays host-side.

## Non-goals

- Re-packaging the llama.cpp xcframework to compile `common/chat.cpp` (tracked separately if ever justified).
- A general local-evals platform. Scope is tool-calling first; the descriptor's multimodal/reasoning fields are recorded but not yet acted on.
- Replacing the host's product threshold — MK owns the measured fact; the host owns the cutoff and the UX.

## References

- #2001 — static renderer-honest flag on `ModelInfo` (superseded by this)
- #1782 — `ModelSelectionProfile` + recommender (the disclosure-surface precedent; litmus: MK owns formats/quants/fit, host owns the product call)
- #1909 / #1912 — gemma-4 native template dropped `tools`; fixed (the motivating "template says yes, reality says no" case)
- Prior art: [minja `chat-template.hpp`](https://github.com/google/minja/blob/main/include/minja/chat-template.hpp) · [llama.cpp function-calling](https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md) · [vLLM tool_parsers](https://github.com/vllm-project/vllm/tree/main/vllm/tool_parsers) · [LiteLLM model DB](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json) · [BFCL/Gorilla](https://github.com/ShishirPatil/gorilla)
