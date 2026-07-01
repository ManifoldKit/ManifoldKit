# Cross-Runtime Tool-Calling Conformance (Ollama + llama.cpp)

Rendered from 244 `ConformanceRecord`(s) across 8 cell(s) · backends: llama.cpp, ollama · core: 5a0de5cd.

## Main matrix (d0 — no decoys)
Means of tool-selection precision/recall/F1 over the cell's *measured* records; `Runs` is the record count. Holes render as their own rows (🚫 not measured · 💥 load-fail · 🛑 render-fail) — never as a measured `0.000`. Verdicts: ✅ pass · ⚠️ partial / renders-no-call / low-precision · ❌ fail · 💥 errored.

| Backend | Model | Quant | Renderer | Runs | Prec | Recall | F1 | Verdict |
|---------|-------|-------|----------|------|------|--------|----|---------|
| llama.cpp | gemma3-4b-it | Q4_K_M | jinja-prompt | 27 | 0.000 | 0.000 | 0.000 | ⚠️ renders-no-call |
| llama.cpp | gemma4-e4b | Q4_K_M | jinja-prompt | 0 | — | — | — | 💥 load-fail (Unsupported model architecture: gemma4) |
| llama.cpp | mistral-7b-instruct | Q4_K_M | jinja-prompt | 27 | 0.857 | 0.786 | 0.810 | ✅ pass |
| ollama | gemma3-4b-tools | unknown | ollama-server | 27 | 0.000 | 0.000 | 0.000 | ⚠️ renders-no-call |
| ollama | gemma4-e4b | unknown | ollama-server | 27 | 1.000 | 1.000 | 1.000 | ✅ pass |
| ollama | llama3.1-8b | unknown | ollama-server | 27 | 0.750 | 0.750 | 0.750 | ⚠️ partial |
| ollama | mistral-7b-tools | unknown | ollama-server | 27 | 0.875 | 0.875 | 0.875 | ⚠️ partial |
| ollama | qwen3.5-9b | unknown | ollama-server | 27 | 1.000 | 1.000 | 1.000 | ✅ pass |

## Decoy ladder (mean F1 per decoy level)
F1 under distractor pressure. `+N` = N decoy tools advertised alongside the real set. Blank cells weren't measured at that level.

| Backend | Model | Quant | Renderer | d0 | +1 | +3 | +5 |
|---|---|---|---|---|---|---|---|
| ollama | mistral-7b-tools | unknown | ollama-server | 0.875 | 0.208 | 0.225 | 0.250 |
| ollama | qwen3.5-9b | unknown | ollama-server | 1.000 | 0.917 | 0.958 | 0.917 |

## Cross-runtime view (same logical model, side by side)
> **Read this as a prompt for inspection, not a verdict.** Cells in a group are matched only on a *normalized model name* — they may differ in quant, checkpoint, or renderer. A verdict difference here is therefore **not, on its own, evidence of a backend bug**: without a same-bytes control a divergence is confounded. Use it to decide what to spot-check, then read the transcripts.

| Logical model | Backend | Quant | Renderer | Runs | F1 | Verdict |
|---------------|---------|-------|----------|------|----|---------|
| gemma3-4b | llama.cpp | Q4_K_M | jinja-prompt | 27 | 0.000 | ⚠️ renders-no-call |
| gemma3-4b | ollama | unknown | ollama-server | 27 | 0.000 | ⚠️ renders-no-call |
| gemma4-e4b | llama.cpp | Q4_K_M | jinja-prompt | 0 | — | 💥 load-fail (Unsupported model architecture: gemma4) |
| gemma4-e4b | ollama | unknown | ollama-server | 27 | 1.000 | ✅ pass |
| mistral-7b | llama.cpp | Q4_K_M | jinja-prompt | 27 | 0.810 | ✅ pass |
| mistral-7b | ollama | unknown | ollama-server | 27 | 0.875 | ⚠️ partial |
