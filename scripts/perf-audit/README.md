# Perf Audit Harness

Aggregates ManifoldFuzz RunRecord JSON into a single Markdown table.

## Usage

    scripts/fuzz.sh --scenario warmup-cost --backend mlx --duration 30
    scripts/fuzz.sh --scenario kv-reuse-coverage --backend llama --duration 60
    scripts/perf-audit/summarize.sh > /tmp/audit-ground-truth.md

The summarize script reads JSON from `MANIFOLD_PERF_AUDIT_INPUT_DIR`
(default: `tmp/fuzz`) and produces one section per detector/scenario id.
