# Ollama Tool-Calling Conformance — soak 20260626 (5 models × 3 repeats + decoy ladder)

Rendered from 189 `ConformanceRecord`(s) across 5 cell(s) · backends: ollama · core: 5a0de5cd.

## Main matrix (d0 — no decoys)
Means of tool-selection precision/recall/F1 over the cell's *measured* records; `Runs` is the record count. Holes render as their own rows (🚫 not measured · 💥 load-fail · 🛑 render-fail) — never as a measured `0.000`. Verdicts: ✅ pass · ⚠️ partial / renders-no-call / low-precision · ❌ fail · 💥 errored.

| Backend | Model | Quant | Renderer | Runs | Prec | Recall | F1 | Verdict |
|---------|-------|-------|----------|------|------|--------|----|---------|
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
