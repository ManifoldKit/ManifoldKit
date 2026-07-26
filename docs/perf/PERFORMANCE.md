# Performance governance

**Audience:** contributor, release
**Status:** living
**Related:** [#2335](https://github.com/ManifoldKit/ManifoldKit/issues/2335) ·
[#2211](https://github.com/ManifoldKit/ManifoldKit/issues/2211) Policy 5 ·
[#2245](https://github.com/ManifoldKit/ManifoldKit/issues/2245) ·
[`PERF-MATRIX.md`](PERF-MATRIX.md) ·
[`docs/RELEASE-1.0.md`](../RELEASE-1.0.md) § Policy 5

This document is the **governance layer** for ManifoldKit's published local-
inference numbers. The harness and schema live in
[manifold-eval](https://github.com/ManifoldKit/manifold-eval)
(`Sources/ManifoldEval/Perf/`); this repo commits the **results** under
`docs/perf/` so core is the surface an evaluator scores (Principle 10 —
schema-without-producer in core is a dead read path).

## What "good" means

| Principle | Practice |
|-----------|----------|
| Same workload | One `BenchSpec` pins `model_family` + prompt + temperature + `max_tokens`. Results carry `specHash`; the collator **refuses** mixed hashes. |
| Same measurement point | One HTTP driver timestamps both `http-ollama` and `http-openai` — no `InferenceService` queue in the TTFT path. |
| Honest statistics | Median + min/max always. p90 only at `n ≥ 20`. p99 only at `n ≥ 100`. Never publish "p99 of 5 samples". |
| Prefill caveat | Wall TPS = `tokens ÷ total wall time` (**prefill included**), kept for continuity with retired in-process benches. Always pair with decode tok/s (`generateTps`) when comparing generation throughput. |
| Provenance | Chip, memory, OS, Ollama version, model digest, harness revision (markdown + filename date). Thermal/power and core pin are **not** yet on the JSON record — re-baseline notes should capture them by hand when claiming a hardware-matched comparison. |
| Sequential lanes | `runAlone: true` always — concurrent GPU lanes corrupt TPS. |

## Publication suite (minimum published baseline)

Two specs, not one undersampled hybrid. Re-runs are **manual** today — there
is no CI schedule that refreshes `docs/perf/`. Continuous / release-blocking
operation is a follow-up once the recipe is stable.

| Suite | Purpose | `timed_runs` | `max_tokens` | Cold? |
|-------|---------|--------------|--------------|-------|
| **Latency** | TTFT distribution + real p90 | ≥ 20 | tiny (16) | yes (`measure_cold`) |
| **Throughput** | Longer decode sample | 5 | target ≥ 256 (EOS may stop early) | optional (warm is enough once cold is measured on latency) |

Committed artifacts:

- `docs/perf/specs/*.json` — the exact specs
- `docs/perf/raw/*.json` — `BenchResult` arrays from `perf-bench --json-out`
- `docs/perf/PERF-MATRIX*.md` — human matrix (harness-rendered + summary)

Re-run command: see [`PERF-MATRIX.md`](PERF-MATRIX.md#how-to-re-run).

## Regression thresholds (advisory, not semver)

Per [RELEASE-1.0.md Policy 5](../RELEASE-1.0.md#policy-5--performance-as-a-10-property),
performance is **outside the semver contract**. These thresholds are
**investigation triggers** for a human re-run on the same hardware — not
automatic release blockers and not promises to app consumers.

Baselines below are the 2026-07-26 Ollama / `llama3.1:8b` / M5 Pro 64 GB
publication in [`PERF-MATRIX.md`](PERF-MATRIX.md). Absolute numbers **do not
transfer** to other chips or memory sizes; re-baseline when hardware changes.

| Metric | Baseline (med) | Investigate if… | Notes |
|--------|----------------|-----------------|-------|
| Warm TTFT (latency suite) | ~131 ms | > **+50%** vs baseline med on same hardware | Outliers to ~400 ms already seen (min/max in raw); flag sustained shift of the **median**, not a single max. |
| TTFT p90 (latency, n≥20) | ~140 ms | > **+50%** vs baseline p90 | Requires `timed_runs ≥ 20`. |
| Decode tok/s (throughput suite) | ~47 tok/s | < **−20%** vs baseline med | Prefer decode over wall TPS when `max_tokens` is large. |
| Wall TPS (throughput, prefill-included) | ~45 tok/s | < **−20%** vs baseline med | Prefill-included; short-prompt latency suite wall TPS is **not** comparable. |
| Cold load duration | ~1.4 s | > **+100%** vs baseline | Sensitive to disk cache / thermal; confirm with a second cold run before acting. |
| Prefill tok/s | ~1000+ tok/s | directional only | High variance; not a hard gate. |

Enforcement of threshold diffs (`perf-compare` subcommand) is a follow-up; until
then, re-runs are manual and PR authors attach the new raw JSON when claiming a
perf fix or regression.

### Streaming cadence (separate, in-core)

`IntegratedStreamingPerformanceTests` remains the only **asserted**
streaming-cadence tripwire in the core test suite. It fails only on a
*profoundly* broken cadence, not on baseline drift — complementary to this
HTTP matrix, not a substitute for it.

## Deferred (honest, not silent)

These were explicitly **re-scoped out** of the HTTP spine in #2335; they stay
listed until a producer exists:

| Metric | Why deferred | Unblock |
|--------|--------------|---------|
| Peak / steady-state memory | HTTP client cannot see server RSS; `/api/ps size_vram` is weights residency, not peak. | [#2245](https://github.com/ManifoldKit/ManifoldKit/issues/2245) `manifold-server-mlx` / `manifold-server-llama` hosts that own the process. |
| Cancellation latency | HTTP has no cancel verb; closing SSE says nothing about when decode stopped. | Core in-process E2E (`BackendBenchmarkE2ETests` style), separate PR. |
| Constrained-decode overhead | Feasible over HTTP (`format: json` / `response_format`) but not in the minimum suite. | Protocol variant on `BenchSpec` (phase 2). |
| Model-switch duration | Needs multi-model load orchestration. | Server hosts or dedicated driver path. |
| OMLX / MK-server lanes | Companion hosts not yet universal; OMLX pin must be a **released** pin in published provenance. | #2245 + careful pin recording. |

## Relationship to 1.0

- [#2211](https://github.com/ManifoldKit/ManifoldKit/issues/2211) / RELEASE-1.0
  **Policy 5**: performance is measured and fixed as a bug, never a major-version
  event.
- This directory is the **archived benchmark artifact** surface Policy 5 and
  the #2335 investigation point at — credibility via committed numbers with
  full provenance, not via a semver promise.
- Companion server measurement (#2245) extends the *lane set*; it does not
  change the governance rules above.
