# Local-inference performance matrix (published baseline)

**Audience:** contributor, release
**Status:** archived one-shot baseline — re-run **manually** with
manifold-eval `perf-bench` and *add* dated raw JSON when hardware or the
harness changes. There is **no** scheduled workflow that refreshes these
numbers yet; “continuously-operated” is a follow-up, not a claim about this
directory.

This is the **committed, human-readable** view of the first **published**
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

Two checkouts. Specs and published artifacts live in **ManifoldKit**; the CLI
lives in **manifold-eval**. Schema-v2 fields (`loadDurationMs` /
`prefillTps` / `generateTps` / `measure_cold`) require a manifold-eval
revision that includes [manifold-eval#56](https://github.com/ManifoldKit/manifold-eval/pull/56)
(or later main once that lands). Pin the harness SHA you actually run in the
provenance block.

```sh
# Paths assume sibling checkouts:
#   ~/Repos/ManifoldKit/ManifoldKit
#   ~/Repos/ManifoldKit/manifold-eval
CORE="$HOME/Repos/ManifoldKit/ManifoldKit"
EVAL="$HOME/Repos/ManifoldKit/manifold-eval"
DATE=$(date -u +%Y-%m-%d)

cd "$EVAL"
swift run -c release manifold-eval perf-bench \
  --spec "$CORE/docs/perf/specs/latency-ollama-llama31-8b.json" \
  --out "$CORE/docs/perf/PERF-MATRIX-latency.md" \
  --json-out "$CORE/docs/perf/raw/ollama-llama31-8b-latency-${DATE}.json" \
  --title "Ollama latency (llama-3.1-8b-instruct, n=20)"

swift run -c release manifold-eval perf-bench \
  --spec "$CORE/docs/perf/specs/throughput-ollama-llama31-8b.json" \
  --out "$CORE/docs/perf/PERF-MATRIX-throughput.md" \
  --json-out "$CORE/docs/perf/raw/ollama-llama31-8b-throughput-${DATE}.json" \
  --title "Ollama throughput (llama-3.1-8b-instruct, n=5)"
```

Requires a live Ollama with `llama3.1:8b`. Then rewrite the summary table above
and note harness revision + hardware in the provenance block. Do **not**
silently overwrite historical raw JSON — add a dated file so regressions stay
comparable.

**Throughput note (this publication):** the prompt often stops early via EOS
(~117 tokens vs `max_tokens: 256`). Decode tok/s is still meaningful; do not
read the suite as “always filled 256 tokens.”

## Out of scope (this matrix)

See [PERFORMANCE.md § Deferred](PERFORMANCE.md#deferred-honest-not-silent) —
memory, cancellation latency, constrained-decode, model-switch, and
MK-server / OMLX lanes. Those wait on [#2245](https://github.com/ManifoldKit/ManifoldKit/issues/2245)
companion hosts or an in-process core E2E suite.
