#!/usr/bin/env bash
# scripts/perf-audit/summarize.sh — Aggregate ManifoldFuzz RunRecord JSON
# files into a Markdown report. Reads from the default fuzz output dir
# (`tmp/fuzz/`) and produces one section per detector/scenario id.
#
# Intended to be piped into a transient file (`> /tmp/audit-ground-truth.md`)
# rather than committed — the JSON inputs are the source of truth, this
# script is a presentation layer.
#
# See also: scripts/perf-audit/README.md, scripts/fuzz.sh.

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT_DIR="${MANIFOLD_PERF_AUDIT_INPUT_DIR:-${PACKAGE_DIR}/tmp/fuzz}"

if ! command -v jq >/dev/null 2>&1; then
    echo "summarize.sh: jq is required but was not found in PATH" >&2
    exit 2
fi

if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo "No fuzz output found."
    exit 0
fi

# Find every record.json the fuzz sink wrote. NUL-separated to handle any
# pathological hash directory name without re-quoting headaches.
mapfile -d '' records < <(
    find "$OUTPUT_DIR" -type f -name 'record.json' -print0 2>/dev/null
)

if (( ${#records[@]} == 0 )); then
    echo "No fuzz output found."
    exit 0
fi

echo "# Perf Audit Summary"
echo
echo "Source: \`${OUTPUT_DIR}\`"
echo "Records: ${#records[@]}"
echo

# Group by detector / scenario id (the parent directory name two levels up
# from each record file: <output>/findings/<detectorId>/<hash>/record.json).
declare -A by_detector
for path in "${records[@]}"; do
    detector_dir="$(dirname "$(dirname "$path")")"
    detector_id="$(basename "$detector_dir")"
    by_detector["$detector_id"]+="${path}"$'\n'
done

for detector_id in "${!by_detector[@]}"; do
    echo "## ${detector_id}"
    echo
    echo "| run | model | backend | firstTokenMs | totalMs | peakBytes | stopReason |"
    echo "|-----|-------|---------|--------------|---------|-----------|------------|"
    while IFS= read -r path; do
        [[ -z "$path" ]] && continue
        # `// "n/a"` keeps a missing field from collapsing the column count.
        jq -r '
            [
                .runId // "?",
                .model.id // "?",
                .model.backend // "?",
                (.timing.firstTokenMs // "n/a" | tostring),
                (.timing.totalMs // "n/a" | tostring),
                (.memory.peakBytes // "n/a" | tostring),
                (.stopReason // "n/a")
            ] | "| " + join(" | ") + " |"
        ' "$path"
    done <<< "${by_detector[$detector_id]}"
    echo
done
