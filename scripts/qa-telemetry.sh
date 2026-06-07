#!/usr/bin/env bash
set -euo pipefail

# qa-telemetry.sh — self-instrumentation for CI cost / QA health.
#
# Closes the self-instrumentation gap (QA evaluation action A1, issue #1695):
# the repo optimises hard for "fewer, larger CI runs" (see CLAUDE.md "Issue &
# PR hygiene") but never measured the levers it tunes. This script queries the
# GitHub Actions API for
# the trailing window of CI runs and computes three numbers:
#
#   • total      — how many CI runs the window produced.
#   • rerun_tax  — fraction of runs whose latest attempt > 1 (the "re-run tax";
#                  ~half of CI compute has historically been failed retries).
#   • avg_ttg    — average time-to-green per commit (head SHA): wall-clock from
#                  the first run opened on a SHA to the first successful run on
#                  that SHA. Only computed where a success exists.
#
# Output: a Markdown block appended to $GITHUB_STEP_SUMMARY (when set) and one
# compact JSON row appended to docs/ci-metrics.jsonl for longitudinal tracking.
#
# Resilience is deliberate: a missing field, an empty API response, or a
# never-green SHA must NOT abort the run. Every derived metric degrades to a
# null/0 rather than failing — a telemetry job that fails CI would be worse
# than no telemetry.
#
# Requirements: gh (authenticated via GH_TOKEN / GITHUB_TOKEN) and jq.
#
# Tunables (env):
#   WORKFLOW_FILE  workflow to measure        (default: ci.yml)
#   DAYS           trailing window in days     (default: 14)
#   BRANCH         restrict to a head branch   (default: unset = all branches)
#   METRICS_FILE   JSONL sink                   (default: docs/ci-metrics.jsonl)
#   RUN_LIMIT      max runs to pull from the API (default: 1000)

WORKFLOW_FILE="${WORKFLOW_FILE:-ci.yml}"
DAYS="${DAYS:-14}"
BRANCH="${BRANCH:-}"
METRICS_FILE="${METRICS_FILE:-docs/ci-metrics.jsonl}"
RUN_LIMIT="${RUN_LIMIT:-1000}"

if ! command -v gh >/dev/null 2>&1; then
  echo "qa-telemetry: gh not found — skipping (no failure)." >&2
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "qa-telemetry: jq not found — skipping (no failure)." >&2
  exit 0
fi

now_epoch="$(date -u +%s)"
cutoff_epoch=$(( now_epoch - DAYS * 86400 ))
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Pull the run list. Tolerate any gh failure (rate limit, no perms) by falling
# back to an empty array so the rest of the pipeline still produces a row.
runs="$(gh run list \
          --workflow "$WORKFLOW_FILE" \
          --limit "$RUN_LIMIT" \
          --json databaseId,headBranch,headSha,status,conclusion,createdAt,updatedAt,attempt,event \
          2>/dev/null || echo '[]')"
runs="${runs:-[]}"

# Compute everything in one jq pass. fromdateiso8601 parses the trailing-Z
# timestamps GitHub returns. Empty arrays -> min == null, which we treat as
# "not derivable" rather than an error.
metrics="$(
  printf '%s' "$runs" | jq -c \
    --argjson cutoff "$cutoff_epoch" \
    --arg branch "$BRANCH" '
      ( if (type == "array") then . else [] end )
      | map(select((.createdAt // "") != ""
                   and ((.createdAt | fromdateiso8601) >= $cutoff)
                   and ($branch == "" or (.headBranch // "") == $branch)))
      as $w
      | ($w | length) as $total
      | ([ $w[] | select((.attempt // 1) > 1) ] | length) as $rerun
      | ( $w
          | group_by(.headSha)
          | map({
              opened:  ([ .[].createdAt | fromdateiso8601 ] | min),
              greened: ([ .[] | select(.conclusion == "success") | .updatedAt | fromdateiso8601 ] | min)
            })
          | map(select(.greened != null) | (.greened - .opened))
          | map(select(. >= 0))
        ) as $ttgs
      | {
          total: $total,
          rerun_count: $rerun,
          rerun_ratio: (if $total > 0 then (($rerun / $total * 1000 | round) / 1000) else 0 end),
          green_commits: ($ttgs | length),
          avg_ttg_seconds: (if ($ttgs | length) > 0 then (($ttgs | add) / ($ttgs | length) | round) else null end)
        }
    ' 2>/dev/null || echo '{"total":0,"rerun_count":0,"rerun_ratio":0,"green_commits":0,"avg_ttg_seconds":null}'
)"
metrics="${metrics:-'{"total":0,"rerun_count":0,"rerun_ratio":0,"green_commits":0,"avg_ttg_seconds":null}'}"

# Pull scalars back out for human formatting (jq -r, all null-tolerant).
total="$(printf '%s' "$metrics"     | jq -r '.total // 0')"
rerun_count="$(printf '%s' "$metrics" | jq -r '.rerun_count // 0')"
rerun_ratio="$(printf '%s' "$metrics" | jq -r '.rerun_ratio // 0')"
green_commits="$(printf '%s' "$metrics" | jq -r '.green_commits // 0')"
avg_ttg_seconds="$(printf '%s' "$metrics" | jq -r '.avg_ttg_seconds // empty')"

if [ -n "$avg_ttg_seconds" ]; then
  avg_ttg_human="$(printf '%s' "$avg_ttg_seconds" | awk '{printf "%.1f min", $1/60}')"
else
  avg_ttg_human="n/a (no green commit in window)"
fi
scope="${BRANCH:-all branches}"

# Longitudinal sink: one compact JSON object per invocation.
row="$(printf '%s' "$metrics" | jq -c \
        --arg at "$generated_at" \
        --arg wf "$WORKFLOW_FILE" \
        --argjson days "$DAYS" \
        --arg scope "$scope" \
        '{generated_at:$at, workflow:$wf, window_days:$days, branch_scope:$scope} + .')"
mkdir -p "$(dirname "$METRICS_FILE")"
printf '%s\n' "$row" >> "$METRICS_FILE"

# Human summary -> GitHub step summary (or stdout when run locally).
summary_out="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
{
  echo "## CI / QA telemetry"
  echo ""
  echo "Window: last **${DAYS} days** · workflow \`${WORKFLOW_FILE}\` · scope: ${scope}"
  echo ""
  echo "| Metric | Value |"
  echo "| --- | --- |"
  echo "| Total CI runs | ${total} |"
  echo "| Re-run tax (attempt > 1) | ${rerun_count} (${rerun_ratio}) |"
  echo "| Commits reaching green | ${green_commits} |"
  echo "| Avg time-to-green | ${avg_ttg_human} |"
  echo ""
  echo "Appended to \`${METRICS_FILE}\`."
} >> "$summary_out"

echo "qa-telemetry: total=${total} rerun=${rerun_count}/${total} (${rerun_ratio}) avg_ttg=${avg_ttg_human}"
