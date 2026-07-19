#!/usr/bin/env bash
set -euo pipefail

# qa-telemetry.sh — self-instrumentation for CI cost / QA health.
#
# Closes the self-instrumentation gap (QA evaluation action A1, issue #1695):
# the repo optimises hard for "fewer, larger CI runs" (see CLAUDE.md "Issue &
# PR hygiene") but never measured the levers it tunes. This script queries the
# GitHub Actions API for
# the trailing window of CI runs and computes:
#
#   • total      — how many CI runs the window produced.
#   • rerun_tax  — fraction of runs whose latest attempt > 1 (the "re-run tax";
#                  ~half of CI compute has historically been failed retries).
#   • avg_ttg    — average time-to-green per commit (head SHA): wall-clock from
#                  the first run opened on a SHA to the first successful run on
#                  that SHA. Only computed where a success exists.
#   • selective_hit_rate (#2326 item 5) — fraction of sampled PR runs that took
#                  mode=selective vs mode=full (NONE/skip reported separately).
#                  Sampled from Actions logs; degrades to n/a on API failure.
#
# Output: a Markdown block appended to $GITHUB_STEP_SUMMARY (when set) and
# compact JSON row(s) appended to docs/ci-metrics.jsonl for longitudinal
# tracking (base metrics row + optional selective_hit_rate row).
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

# ── Selective-path hit rate (#2326 item 5) ──────────────────────────────────
# Sample recent pull_request runs' logs for the "Test mode: selective|full"
# line emitted by ci.yml's Compute test mode step. Degrades to nulls on any
# failure (rate limit, missing log, no matches) — never aborts the job.
#
# Tunables:
#   SELECTIVE_SAMPLE_LIMIT  max PR runs to pull logs for (default 12)
#   SELECTIVE_BUDGET_SECS   wall-clock budget for the whole sample loop
#                           (default 90). Stops early so a slow Actions log
#                           API cannot blow the 10-min telemetry job.
SELECTIVE_SAMPLE_LIMIT="${SELECTIVE_SAMPLE_LIMIT:-12}"
SELECTIVE_BUDGET_SECS="${SELECTIVE_BUDGET_SECS:-90}"
sel_selective=0
sel_full=0
sel_skip=0
sel_sampled=0
sel_ratio=""
sel_note="n/a"
sel_budget_hit=0

pr_run_ids="$(printf '%s' "$runs" | jq -r \
  --argjson cutoff "$cutoff_epoch" \
  --argjson limit "$SELECTIVE_SAMPLE_LIMIT" '
    (if (type == "array") then . else [] end)
    | map(select((.createdAt // "") != ""
                 and ((.createdAt | fromdateiso8601) >= $cutoff)
                 and (.event // "") == "pull_request"
                 and ((.conclusion // "") == "success" or (.conclusion // "") == "failure")))
    | .[:$limit]
    | .[].databaseId // empty
  ' 2>/dev/null || true)"

sel_started="$(date -u +%s)"
if [ -n "$pr_run_ids" ]; then
  while IFS= read -r rid; do
    [ -z "$rid" ] && continue
    now="$(date -u +%s)"
    if [ $((now - sel_started)) -ge "$SELECTIVE_BUDGET_SECS" ]; then
      sel_budget_hit=1
      break
    fi
    # Prefer the tiny job log over the full run log when possible; fall back
    # to --log. Tolerate missing logs / rate limits.
    mode_line="$(gh run view "$rid" --log 2>/dev/null \
      | grep -E 'Test mode: (selective|full)|Tier 0 returned NONE|No test-job suites affected' \
      | head -n 1 || true)"
    [ -z "$mode_line" ] && continue
    sel_sampled=$((sel_sampled + 1))
    case "$mode_line" in
      *"Test mode: selective"*) sel_selective=$((sel_selective + 1)) ;;
      *"Test mode: full"*)      sel_full=$((sel_full + 1)) ;;
      *NONE*|*"No test-job suites affected"*) sel_skip=$((sel_skip + 1)) ;;
    esac
  done <<EOF
$pr_run_ids
EOF
fi

sel_decided=$((sel_selective + sel_full + sel_skip))
if [ "$sel_decided" -gt 0 ]; then
  # Hit rate = selective / (selective + full). NONE/skip is reported separately
  # — it is a win, not a selective miss.
  sel_base=$((sel_selective + sel_full))
  if [ "$sel_base" -gt 0 ]; then
    sel_ratio="$(awk -v s="$sel_selective" -v b="$sel_base" 'BEGIN { printf "%.3f", s/b }')"
  else
    sel_ratio="0"
  fi
  sel_note="sampled=${sel_sampled} selective=${sel_selective} full=${sel_full} none_skip=${sel_skip}"
  if [ "$sel_budget_hit" -eq 1 ]; then
    sel_note="${sel_note} budget_hit"
  fi
else
  sel_ratio=""
  sel_note="no Test-mode lines in sampled PR logs"
fi

# Longitudinal sink: ONE compact JSON object per invocation. Selective fields
# are folded into the base row so qa-telemetry.yml's `tail -n 1` still captures
# the full series (a sibling row would clobber the base metrics on the
# ci-metrics branch).
row="$(printf '%s' "$metrics" | jq -c \
        --arg at "$generated_at" \
        --arg wf "$WORKFLOW_FILE" \
        --argjson days "$DAYS" \
        --arg scope "$scope" \
        --argjson sel_sampled "$sel_sampled" \
        --argjson sel_selective "$sel_selective" \
        --argjson sel_full "$sel_full" \
        --argjson sel_none_skip "$sel_skip" \
        --arg sel_ratio "${sel_ratio}" \
        --arg sel_note "$sel_note" \
        '{generated_at:$at, workflow:$wf, window_days:$days, branch_scope:$scope} + .
         + {
             selective_sampled:$sel_sampled,
             selective_count:$sel_selective,
             selective_full_count:$sel_full,
             selective_none_skip:$sel_none_skip,
             selective_ratio:(if $sel_ratio == "" then null else ($sel_ratio|tonumber) end),
             selective_note:$sel_note
           }')"
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
  echo "| Selective hit rate | ${sel_ratio:-n/a} (${sel_note}) |"
  echo ""
  echo "Appended to \`${METRICS_FILE}\`."
  echo ""
  echo "_Selective hit rate (#2326 item 5): fraction of PR runs that took"
  echo "\`mode=selective\` among those that decided selective-vs-full. If"
  echo "sustained &lt;~0.25, tighten hub expansion in \`affected-suites.sh\` or"
  echo "accept full-as-default and simplify Tier 2._"
} >> "$summary_out"

echo "qa-telemetry: total=${total} rerun=${rerun_count}/${total} (${rerun_ratio}) avg_ttg=${avg_ttg_human} selective_ratio=${sel_ratio:-n/a} (${sel_note})"
