# Cross-Backend Tool-Calling Conformance Matrix

Run: `20260622-232839` · 5 legs (Ollama, llama.cpp, MLX, OpenRouter) · 9-scenario reference toolset · scorer = `manifold-tools score --csv` (`ConformanceScorer`).

> **Note:** the raw per-run `.jsonl` transcripts (~12 MB), `.log` files, and the scored per-run `.csv` files were all pruned — this matrix is the only committed artifact for the run (curated-summaries-only convention; see `.gitignore`). Re-run the sweep to regenerate the transcripts and re-score from the raw JSONL to rebuild the CSVs.

## 1. Headline

A model's tool-calling capability is not a property of the *model* — it is a property of the **(model × quant × backend × renderer)** cell, and the only way to know a cell works is to measure it. This matrix runs the same reference toolset across four runtimes precisely to surface cells that diverge despite "same model." It worked: the #1 finding is an **(a)-class off-diagonal on Mistral-v0.3**. The *same weights* tool-call cleanly via **Ollama** (server-side template, F1 ≈ 0.875) but produce **prompt-only, tool-less transcripts via llama.cpp** — core's `JinjaPromptRenderer` prepended a `system` role that Mistral's alternation-strict template rejected (`Conversation roles must alternate`), so the renderer refused to send a tool-less prompt and emitted nothing. That is a real core bug the matrix caught by design, **fixed tonight in merged PR #2032** (fold the system turn into the first user turn). The llama/MLX Mistral cells below reflect the **pre-#2032** state and are flagged *re-measure pending*.

## 2. Main matrix (d0 — no decoys)

Means across available repeats. P/R/F1 = macro tool-selection over tool-bearing scenarios. "scen pass" = full-scenario verdict `pass` / total scored (stricter: requires every assertion, incl. exact-output checks). Verdicts: ✅ supported · ⚠️ renders-no-call · 🛑 render-fail · 💥 load-fail · — n/a.

| Backend | Model | Quant | Runs | Prec | Recall | F1 | scen pass | Verdict |
|---------|-------|-------|------|------|--------|----|-----------|---------|
| Ollama | mistral-7b-tools | server | 5 | 0.875 | 0.875 | **0.875** | 15/45 | ✅ |
| Ollama | gemma3-4b-tools | server | 5 | 0.000 | 0.000 | **0.000** | 0/45 | ⚠️ renders-no-call |
| Ollama | gemma4-e4b | server | 5 | 1.000 | 1.000 | **1.000** | 35/45 | ✅ |
| Ollama | llama3.1-8b | server | 5 | 0.667 | 0.667 | **0.667** | 10/45 | ✅ |
| Ollama | qwen3.5-9b | server | 5 | 1.000 | 1.000 | **1.000** | 35/45 | ✅ |
| llama.cpp | mistral | Q4 | 5 | 0.000 | 0.000 | **0.000** | 0/45 | 🛑 render-fail *(pre-#2032)* |
| llama.cpp | llama31-8b | Q4 | 5 | 0.622 | 0.622 | **0.622** | 18/45 | ✅ |
| llama.cpp | gemma3-4b-tools | Q4 | 5 | 0.000 | 0.000 | **0.000** | 0/45† | ⚠️ renders-no-call |
| llama.cpp | gemma4-e4b | Q4 | 5 | — | — | **—** | 0/0 | 💥 load-fail (arch `gemma4` unsupported) |
| llama.cpp | qwen35-9b | Q4 | 5 | 0.000 | 0.000 | **0.000** | 0/45† | ⚠️ renders-no-call |
| MLX | mistral-v0.3 | 4bit | 5 | 0.000 | 0.000 | **0.000** | 0/45 | ⚠️ renders-no-call *(pre-#2032)* |
| MLX | llama32-3b | 4bit | 5 | 0.900 | 0.900 | **0.900** | 0/45‡ | ✅ |
| MLX | qwen3-8b | 4bit | 5 | 1.000 | 0.875 | **0.917** | 0/45‡ | ✅ |
| OpenRouter | gpt-oss-120b | cloud | 3 | 1.000 | 0.979 | **0.986** | 22/27 | ✅ (cloud anchor) |
| OpenRouter | owl-alpha | cloud | 3 | 0.960 | 0.900 | **0.920** | 18/27 | ✅ |
| OpenRouter | gemma4-31b | cloud | 3 | 0.750 | 0.667 | **0.694** | 8/27 | ✅ (noisy) |
| OpenRouter | nemotron3-super | cloud | 3 | 1.000 | 1.000 | **1.000** | 24/27 | ✅ |
| OpenRouter | laguna | cloud | 3 | 1.000 | 1.000 | **1.000** | 21/27 | ✅ |

† The single non-zero `pass` in these cells is `structured-json-extraction`, a **non-tool** scenario (no tool required) — so tool-selection F1 is genuinely 0.000.
‡ MLX scenario-`pass` shows 0/45 because the MLX scorer's full-scenario assertions include exact-output checks the local model misses; **tool-selection** P/R/F1 (the matrix's primary signal) is high, hence ✅.

## 3. Cross-runtime twins (same weights, different renderer)

The point of the matrix. Mistral is the gold 3-way; the GGUF families give Ollama-vs-llama.cpp pairs.

| Model | Ollama F1 | llama.cpp F1 | MLX F1 | Divergence |
|-------|-----------|--------------|--------|------------|
| **Mistral** | **0.875** ✅ | **0.000** 🛑 render-fail | **0.000** ⚠️ no-call | **3-way split, same weights.** Ollama's server template works; core's `JinjaPromptRenderer` (llama.cpp) refused (alternation) → fixed #2032; MLX renders via swift-transformers but emits 0 tool calls — a *distinct* failure mode from the llama render-refusal. |
| **gemma3-4b-tools** | 0.000 ⚠️ | 0.000 ⚠️ | — n/a | Fails **both** local backends as renders-no-call. Not a renderer divergence — the model itself never emits tool calls under either template (MLX gemma unavailable: VL crash / system-role template). |
| **gemma4-e4b** | **1.000** ✅ | — 💥 load-fail | — n/a | Ollama tool-calls perfectly; llama.cpp **can't load** `gemma4` arch at all. Pure backend-support gap. |
| **qwen35 / qwen3** | **1.000** ✅ (qwen3.5-9b) | 0.000 ⚠️ (qwen35-9b) | **0.917** ✅ (qwen3-8b, MLX) | Ollama + MLX tool-call cleanly; the llama.cpp GGUF renders-no-call. Same family, backend-dependent. |
| **llama3.x** | 0.667 ✅ (3.1-8b) | 0.622 ✅ (3.1-8b) | 0.900 ✅ (3.2-3b) | The one family that tool-calls on **all three** local backends. Ollama≈llama.cpp on identical 3.1-8b weights; MLX's smaller 3.2-3b scores highest. |

## 4. Decoy-pressure ceiling

Macro tool-selection F1 vs distractor-tool count D (1 run each; d0 = repeat mean). "Ceiling K" = largest D where the model still selects correctly near its d0 baseline before recall collapses. Cells with `—` were not run.

| Backend / Model | d0 | d1 | d3 | d5 | d10 | d20 | Ceiling |
|-----------------|----|----|----|----|-----|-----|---------|
| llama.cpp llama31-8b | 0.622 | 0.500 | 0.400 | 0.309 | 0.130 | 0.000 | **~K=1** (recall decays from d1; precision holds ~0.75, recall tanks 0.43→0.07; d10+ hits `contextExhausted` at 4096 ctx) |
| MLX llama32-3b | 0.900 | 0.682 | 0.434 | 0.289 | 0.196 | 0.098 | **~K=1** (tool-*selection* precision stays 0.83–0.94 throughout — it picks right when it calls — but recall falls 1.0→0.18 by d5; the headline decoy-collapse) |
| llama.cpp mistral | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | **K=0** (render-fail floor — pre-#2032; re-measure pending) |
| MLX mistral-v0.3 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | **K=0** (no-call floor) |
| llama.cpp gemma3-4b-tools | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | **K=0** (no-call floor) |
| llama.cpp qwen35-9b | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | **K=0** (no-call floor) |
| MLX qwen3-8b | 0.917 | *partial* | — | — | — | — | **≥0** — decoy ladder **still running**; only d0 scored. d1 transcript exists (188 records, tool_calls present) but unscored. |
| OpenRouter (gpt-oss/owl/nemotron/laguna) | 0.92–1.00 | — | — | 0.96–0.96 | — | — | **≥5** — cloud anchors hold F1 ≈ 0.94–0.96 at d5 (only decoy level run); gemma4-31b weaker (0.625 @ d5). |

**Takeaway:** decoy pressure is real and bites recall first — even the clean local models (llama31-8b, llama32-3b) lose ~half their recall by a single distractor and are near-useless by d10–d20; cloud models absorb d5 with minimal loss.

## 5. Failure taxonomy (Lane 3d — transcript-derived from JSONL `kind` records)

Classification rule: **render-fail** = only `prompt` records, no `token_delta`/`final` (renderer refused, nothing generated); **no-call** = `final` present but **0 `tool_call`** records when tools required; **load-fail** = empty transcript / model didn't load; **low-precision** = `tool_call`s present but precision<1; **truncation** = `final` missing/cut.

| Backend | Dominant failure class | Detail |
|---------|------------------------|--------|
| **llama.cpp** | **render-fail (Mistral)** + **no-call (gemma3, qwen35)** + **load-fail (gemma4-e4b)** | Mistral = prompt-only (9 `prompt`, 0 generation) → `JinjaPromptRenderer` alternation refusal (fixed #2032). gemma3/qwen35 = full `final` answers, 0 `tool_call`. gemma4-e4b = `LOAD FAILED: Unsupported model architecture: gemma4` (0 rows). High-decoy llama31-8b adds **context-exhaustion** errors (`contextExhausted` at 4096 ctx, d10/d20). Spread is the widest of any leg. |
| **MLX** | **no-call (Mistral)** | Mistral-v0.3 renders fine (via swift-transformers, not core) — full `token_delta`+`final` — but emits **0 `tool_call`**. Distinct from llama.cpp's render-refusal. llama32-3b & qwen3-8b are clean. gemma unavailable (VL crash / system-role template). |
| **Ollama** | **no-call (gemma3-4b-tools)** | The one failing Ollama cell: gemma3-4b-tools answers but never tool-calls (server template; 0 across all 5 repeats). Everything else ✅. Cleanest leg. |
| **OpenRouter** | **low-precision (gemma4-31b)** | No render/load failures. gemma4-31b is the noisy outlier (P 0.625–0.875 across repeats, run-to-run variance). gpt-oss-120b/nemotron/laguna near-perfect. No truncation observed (laguna, a reasoning model, completed all `final`s cleanly). |

## 6. Deferred / caveats

- **llama.cpp + MLX Mistral cells are pre-#2032.** Both reflect the rendering bug fixed tonight (llama = render-refusal; MLX = no-call). **Re-measure pending** — these cells should flip after re-running against the fixed renderer (llama.cpp expected to recover; MLX no-call may be a separate model/template issue, not the same bug).
- **gemma4-e4b GGUF load-fail is a backend gap, not a tool-calling result** — llama.cpp doesn't support the `gemma4` architecture. The model tool-calls perfectly on Ollama, so this is purely a llama.cpp loader limitation.
- **MLX qwen3-8b decoy ladder is incomplete** — the MLX eval was **still running** at synthesis time. Only d0 (5 repeats, F1=0.917) is scored; `mlx_qwen3-8b_d1_r1.jsonl` exists (188 records, tool_calls present) but has no CSV/SUMMARY yet. d3–d20 not present.
- **OpenRouter laguna** (reasoning model) showed **no truncation** — all three d0 repeats and the d5 run completed with clean `final`s and F1=1.0 (d0) / 0.958 (d5). The expected reasoning-model cut-off did not materialize here.
- **Decoy ladders are 1 run each** (d0 is the only multi-repeat level) — single-run decoy F1s carry sampling noise; ceilings are directional, not tight.
- **OpenRouter `_d5_` files are labeled `d5` in the log as a bare run** (not `d5_r1`); only one decoy level was run for the cloud leg.
