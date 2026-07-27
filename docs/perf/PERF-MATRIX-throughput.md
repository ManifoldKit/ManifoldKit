# Ollama throughput (llama-3.1-8b-instruct, n=5)

## Hardware

- **Chip:** Apple M5 Pro
- **Memory:** 64 GB
- **OS:** Version 26.5.2 (Build 25F84)
- **Spec hash:** `393fa25cc6e6…`
- **Engine version(s):** 0.32.0
- **Model digest(s):** 46e0c10c039e0191…

## Percentile policy

Publication policy (ManifoldKit #2335):

- **median + min/max** always — the honest summary at small `n`.
- **p90** only when `timed_runs ≥ 20` (nearest-rank otherwise collapses toward the max).
- **p99** only when `timed_runs ≥ 100` (below that, nearest-rank p99 **is** the sample maximum).

This run's largest sample count is **5** — report median + min/max only; p90/p99 are stored on the JSON record but not presented as publication figures.

## Transport × engine grid
Medians over the timed runs (warmup discarded). TTFT = wall-clock to first streamed token. TPS = tokens ÷ total wall time, **prefill included** (see native-split table for decode-only tok/s).

| Lane | Transport | Engine | Model | Quant | Runs | TTFT med (ms) | TTFT min/max | TPS med | TPS min/max |
|------|-----------|--------|-------|-------|------|---------------|--------------|---------|-------------|
| ollama | http-ollama | ollama | llama3.1:8b | Q4_K_M | 5 | 130.3 | 128.4–138.3 | 44.86 | 43.94–46.63 |

## Native split (load / prefill / decode)
Ollama reports `load_duration`, `prompt_eval_*`, and `eval_*` on the final chunk — captured per run. OpenAI-compatible lanes derive **decode** tok/s as `tokens / (wall − TTFT)`; load + prefill stay blank. Wall TPS above remains **prefill-included** for continuity.

| Lane | Load med (ms) | Prefill tok/s | Decode tok/s | Cold load (ms) | Cold TTFT (ms) |
|------|---------------|---------------|--------------|----------------|----------------|
| ollama | 106.1 | 1069.57 | 47.29 | — | — |

## Caveats

- Lanes were run **strictly sequentially** (never concurrently) to avoid GPU-contention corrupting throughput numbers — see `BenchResult.runAlone`.
- A quant-camp mismatch (flagged above, if present) means the compared weights are not bit-identical; treat deltas as directional.
- **Wall TPS is prefill-included** (`tokens ÷ total wall time`). Use the native-split **Decode tok/s** column for generation-only throughput.
- `http-openai` token counts prefer the server's `usage.completion_tokens` when the endpoint honors `stream_options.include_usage`; otherwise they fall back to counting non-empty SSE delta chunks, which assumes ~1 token per chunk and may undercount a server that batches multiple tokens per event.
- Cold-start uses Ollama `keep_alive: 0` to force unload, then one measured reload. OpenAI-compatible lanes have no unload verb — cold columns stay blank.
- Peak/steady-state memory and cancellation latency are **out of scope** for the HTTP spine (client cannot see server RSS; HTTP has no cancel verb). Those metrics gate on ManifoldKit #2245 companion server hosts / in-process E2E.
- This spine measures HTTP-fronted lanes only. Companion server hosts (manifold-server-mlx / manifold-server-llama) and in-process control lanes are follow-ups, not yet wired into this matrix.
