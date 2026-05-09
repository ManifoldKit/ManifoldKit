# Perf Audit Harness

Runs ManifoldFuzz scenarios from the perf-audit plan and aggregates
their RunRecord JSON into a single Markdown table.

## Usage

    scripts/fuzz.sh --scenario warmup-cost --backend mlx --duration 30
    scripts/fuzz.sh --scenario kv-reuse-coverage --backend llama --duration 60
    scripts/perf-audit/summarize.sh > /tmp/audit-ground-truth.md

The summarize script reads JSON from <fuzz output dir> and produces
one section per scenario.
