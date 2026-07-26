# Local-inference performance matrix (published baseline)

**Audience:** contributor, release
**Status:** living baseline — re-run with manifold-eval `perf-bench` and replace
the raw JSON + matrix files when hardware or the harness changes meaningfully.

This is the **committed, human-readable** view of the first continuously-operated
Ollama baseline for [ManifoldKit #2335](https://github.com/ManifoldKit/ManifoldKit/issues/2335).
Raw machine-readable records live under [`raw/`](raw/); the specs that produced
them under [`specs/`](specs/). Governance, thresholds, and deferred metrics:
[`PERFORMANCE.md`](PERFORMANCE.md).

## Provenance (this publication)

| Field | Value |
|-------|-------|
| Date (UTC) | 2026-07-26T09:52:58Z |
| Hardware | Apple M5 Pro, 64 GB, macOS 26.5.2 (Build 25F84) |
| Engine | Ollama **0.32.0** at `http://localhost:11434` |
| Model | `llama3.1:8b` (Q4_K_M), digest `46e0c10c039e0191…` |
| Harness | [manifold-eval](https://github.com/ManifoldKit/manifold-eval) `d04399b` (schema v2 native metrics + cold-start; PR pending on `ship-2335-eval`) |
| Transport | `http-ollama` `/api/generate` only (no OMLX / companion server hosts in this publication) |

## Summary table

Wall **TPS is prefill-included** (`tokens ÷ total wall time`). Prefer
**Decode tok/s** for generation-only throughput. Cold columns come from
`measure_cold: true` (Ollama `keep_alive: 0` unload + one measured reload).

| Suite | Spec | Runs | TTFT med (ms) | TTFT min–max | TTFT p90 | Wall TPS med | Decode tok/s | Cold load (ms) | Cold TTFT (ms) |
|-------|------|------|---------------|--------------|----------|--------------|--------------|----------------|----------------|
| Latency | [`specs/latency-ollama-llama31-8b.json`](specs/latency-ollama-llama31-8b.json) | 20 | 130.6 | 127.7–394.8 | 140.1 | 35.35† | 49.70 | 1437.6 | 1529.9 |
| Throughput | [`specs/throughput-ollama-llama31-8b.json`](specs/throughput-ollama-llama31-8b.json) | 5 | 130.3 | 128.4–138.3 | —‡ | 44.86 | 47.29 | — | — |

† Latency suite uses `max_tokens: 16` — wall TPS is prefill-dominated and **not**
a steady-state generation figure. Use the throughput suite / decode column.
‡ p90 not published at `n < 20` (see percentile policy).

### Percentile policy

- **median + min/max** always.
- **p90** only when `timed_runs ≥ 20`.
- **p99** only when `timed_runs ≥ 100` (never presented below that — nearest-rank
  p99 is the sample max).

### Full rendered reports

- [PERF-MATRIX-latency.md](PERF-MATRIX-latency.md) — n=20, `max_tokens: 16`, cold-start on
- [PERF-MATRIX-throughput.md](PERF-MATRIX-throughput.md) — n=5, `max_tokens: 256`

### Raw JSON

- [`raw/ollama-llama31-8b-latency-2026-07-26.json`](raw/ollama-llama31-8b-latency-2026-07-26.json)
- [`raw/ollama-llama31-8b-throughput-2026-07-26.json`](raw/ollama-llama31-8b-throughput-2026-07-26.json)

## How to re-run

Requires a live Ollama with `llama3.1:8b` and a manifold-eval checkout that
includes schema-v2 native metrics (`loadDurationMs` / `prefillTps` / `generateTps`
+ `measure_cold`):

```sh
swift run -c release manifold-eval perf-bench \
  --spec docs/perf/specs/latency-ollama-llama31-8b.json \
  --out docs/perf/PERF-MATRIX-latency.md \
  --json-out docs/perf/raw/ollama-llama31-8b-latency-$(date -u +%Y-%m-%d).json \
  --title "Ollama latency (llama-3.1-8b-instruct, n=20)"

swift run -c release manifold-eval perf-bench \
  --spec docs/perf/specs/throughput-ollama-llama31-8b.json \
  --out docs/perf/PERF-MATRIX-throughput.md \
  --json-out docs/perf/raw/ollama-llama31-8b-throughput-$(date -u +%Y-%m-%d).json \
  --title "Ollama throughput (llama-3.1-8b-instruct, n=5)"
```

Then rewrite the summary table above and note harness revision + hardware in
the provenance block. Do **not** silently overwrite historical raw JSON — add a
dated file so regressions stay comparable.

## Out of scope (this matrix)

See [PERFORMANCE.md § Deferred](PERFORMANCE.md#deferred-honest-not-silent) —
memory, cancellation latency, constrained-decode, model-switch, and
MK-server / OMLX lanes. Those wait on [#2245](https://github.com/ManifoldKit/ManifoldKit/issues/2245)
companion hosts or an in-process core E2E suite.
