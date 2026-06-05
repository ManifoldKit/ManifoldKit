#!/usr/bin/env bash
# scripts/ci-tier0-dryrun-report.sh — aggregate Tier 0 selective-testing dry-run
# telemetry (issue #1588) across recent CI runs.
#
# The `Resolve affected suites (dry-run)` step in ci.yml emits one greppable
# `TIER0_DRYRUN full=<bool> selected=<n> total=<n>` marker per PR run. This
# script scans recent successful `test`-job logs for those markers and tallies:
#   - how many PRs would have run selectively vs forced-full,
#   - the distribution of selected-suite counts,
#   - the aggregate fraction of suite-executions that would have been skipped.
#
# That fraction is the validate-before-commit signal the issue requires before
# flipping Phase 2: the projected win is ~15-20% of CI minutes (execution half
# only — `swift test --filter` never prunes compile; see #1588 / #1590).
#
# Usage:
#   scripts/ci-tier0-dryrun-report.sh [--limit N] [--branch B]
#     --limit N   number of recent CI runs to scan (default 80)
#     --branch B  only runs for this base branch (default: all)
#
# Per [[feedback_gh_log_investigation]] each run's log is fetched ONCE into a
# cache dir and grepped locally; re-runs reuse the cache.

set -euo pipefail

LIMIT=80
BRANCH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --limit) LIMIT="$2"; shift 2 ;;
    --branch) BRANCH="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null || { echo "gh CLI required" >&2; exit 1; }

CACHE="${TMPDIR:-/tmp}/tier0-dryrun-cache"
mkdir -p "$CACHE"

echo "Fetching up to $LIMIT recent CI runs…" >&2
runs_json=$(gh run list --workflow CI --event pull_request --limit "$LIMIT" \
  --json databaseId,headBranch,conclusion,createdAt)

# Filter to runs we care about (optionally by base branch). We only need the run
# IDs; conclusion can be anything — the resolver step runs before the tests, so
# even a later-failed run carries a valid marker.
ids=$(echo "$runs_json" | jq -r --arg b "$BRANCH" \
  '.[] | select($b=="" or .headBranch==$b) | .databaseId')

total=0; full=0; selective=0
declare -a selected_counts=()
suite_total=0          # sum of `total` field (denominator: suites that ran today)
suite_would_run=0      # sum of selected (numerator: suites the resolver would run)

for id in $ids; do
  logf="$CACHE/$id.log"
  if [ ! -s "$logf" ]; then
    # Fetch once; some runs may have expired logs — skip those quietly.
    gh run view "$id" --log > "$logf" 2>/dev/null || { rm -f "$logf"; continue; }
  fi
  marker=$(grep -h "TIER0_DRYRUN" "$logf" | tail -n 1 || true)
  [ -n "$marker" ] || continue

  is_full=$(echo "$marker" | sed -E 's/.*full=([a-z]+).*/\1/')
  sel=$(echo "$marker" | sed -E 's/.*selected=([0-9]+).*/\1/')
  tot=$(echo "$marker" | sed -E 's/.*total=([0-9]+).*/\1/')

  total=$((total + 1))
  suite_total=$((suite_total + tot))
  suite_would_run=$((suite_would_run + sel))
  if [ "$is_full" = "true" ]; then
    full=$((full + 1))
  else
    selective=$((selective + 1))
    selected_counts+=("$sel")
  fi
done

if [ "$total" -eq 0 ]; then
  echo "No TIER0_DRYRUN markers found in the scanned runs." >&2
  echo "(Either the dry-run step hasn't landed yet, or logs have expired.)" >&2
  exit 0
fi

skipped=$((suite_total - suite_would_run))
pct_selective=$(( selective * 100 / total ))
pct_suites_skipped=$(( skipped * 100 / suite_total ))

echo "=========================================================="
echo " Tier 0 selective-testing — dry-run report (#1588)"
echo "=========================================================="
echo "PR runs analyzed:        $total"
echo "  would run selectively: $selective (${pct_selective}%)"
echo "  would force full:      $full"
echo ""
echo "Suite-executions (denominator = suites that actually ran today):"
echo "  ran today:             $suite_total"
echo "  resolver would run:    $suite_would_run"
echo "  would SKIP:            $skipped (${pct_suites_skipped}% of executions)"
echo ""
if [ "${#selected_counts[@]}" -gt 0 ]; then
  echo "Selected-suite count distribution (selective PRs only):"
  printf '%s\n' "${selected_counts[@]}" | sort -n | uniq -c \
    | awk '{printf "  %2d suite(s): %d PR(s)\n", $2, $1}'
fi
echo ""
echo "NOTE: % suites skipped ≈ upper bound on the EXECUTION-time win only."
echo "      Compile is never pruned by --filter (#1588/#1590), so wall-clock"
echo "      savings are smaller. Target signal: ~15-20% of total CI minutes."
