# Perf Audit Harness

Aggregates ManifoldFuzz RunRecord JSON into a single Markdown table.

## Usage

    scripts/fuzz.sh --scenario warmup-cost --backend ollama --duration 30
    scripts/perf-audit/summarize.sh > /tmp/audit-ground-truth.md

(MLX / llama.cpp perf campaigns moved to the manifold-mlx / manifold-llama
companion packages in v0.48 — run those scenarios from the companion repos
and point `MANIFOLD_PERF_AUDIT_INPUT_DIR` at their findings directory.)

The summarize script reads JSON from `MANIFOLD_PERF_AUDIT_INPUT_DIR`
(default: `tmp/fuzz`) and produces one section per detector/scenario id.
