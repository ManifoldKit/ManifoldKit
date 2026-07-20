#!/usr/bin/env bash
#
# Pre-release companion-canary gate.
#
# Reports whether each companion package (manifold-mlx, manifold-llama) still
# builds against THIS repo's main HEAD, and exits non-zero if any of them
# doesn't — or if the evidence is too old to mean anything.
#
# WHY THIS EXISTS:
# AGENTS.md Principle 9 requires known consumers to be built against a change
# before it ships. The example apps get that from `scripts/demo-apps-build.sh`;
# the companion packages had the signal but no gate. Each companion runs a
# `Canary (core main)` workflow that builds it against core main (nightly, on
# `core-release`, and on demand) — so a core seam move is detected within a
# day. On 2026-07-20 that canary went red at 07:29 with
# `cannot find type 'StructuredHistoryReceiver'`, v0.73.0 shipped at 09:14
# anyway, and both companions were stranded a minor behind until their
# adaptation PRs landed. The detection worked; nothing was gated on it. This
# script is that gate.
#
# A canary failure means CORE MOVED A SEAM the companions still depend on. It
# does not necessarily block the release — the correct response is usually to
# land the companions' adaptation PRs in lockstep (see AGENTS.md § "Companion
# pin-bump releases") — but it must be a deliberate decision, not a surprise
# discovered by the post-release fan-out.
#
# FRESHNESS: a green canary from before the commits you are about to release
# proves nothing. Runs older than --max-age-hours (default 24) are treated as
# STALE and fail the gate. Use --dispatch to trigger fresh runs and wait.
#
# Usage:
#   scripts/companion-canary-check.sh                     # check last known result
#   scripts/companion-canary-check.sh --dispatch          # trigger fresh runs, wait, then check
#   scripts/companion-canary-check.sh --max-age-hours 48  # loosen the freshness bound
#
# Requires: gh (authenticated). Bash 3.2 compatible — CI runners ship 3.2, so
# no associative arrays.

set -uo pipefail   # NOT -e: check every companion and report all failures

COMPANIONS="manifold-mlx manifold-llama"
WORKFLOW="canary.yml"
WORKFLOW_NAME="Canary (core main)"
MAX_AGE_HOURS=24
DISPATCH=0
POLL_SECONDS=30
POLL_MAX=40          # 40 * 30s = 20 min ceiling per wait loop

while [ $# -gt 0 ]; do
    case "$1" in
        --dispatch)       DISPATCH=1; shift ;;
        --max-age-hours)  MAX_AGE_HOURS="${2:-24}"; shift 2 ;;
        -h|--help)        sed -n '2,36p' "$0"; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 2 ;;
    esac
done

if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI not found — required to read companion canary results." >&2
    exit 2
fi

# Portable epoch-seconds from an ISO-8601 UTC timestamp (BSD date on macOS,
# GNU date on CI Linux runners).
iso_to_epoch() {
    date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$1" "+%s" 2>/dev/null \
        || date -u -d "$1" "+%s" 2>/dev/null \
        || echo ""
}

if [ "$DISPATCH" -eq 1 ]; then
    echo "Dispatching fresh canary runs..."
    for repo in $COMPANIONS; do
        if gh workflow run "$WORKFLOW" --repo "ManifoldKit/$repo" >/dev/null 2>&1; then
            echo "  dispatched: $repo"
        else
            echo "  WARNING: could not dispatch $repo (checking last known result instead)" >&2
        fi
    done
    # Give GitHub a moment to register the runs before polling for them.
    sleep 10
    for repo in $COMPANIONS; do
        printf '  waiting for %s' "$repo"
        i=0
        while [ "$i" -lt "$POLL_MAX" ]; do
            status=$(gh run list --repo "ManifoldKit/$repo" --workflow "$WORKFLOW" --limit 1 \
                        --json status --jq '.[0].status' 2>/dev/null)
            [ "$status" = "completed" ] && break
            printf '.'
            sleep "$POLL_SECONDS"
            i=$((i + 1))
        done
        printf '\n'
        [ "$i" -ge "$POLL_MAX" ] && echo "  WARNING: $repo canary still running after $((POLL_MAX * POLL_SECONDS / 60))m" >&2
    done
fi

now_epoch=$(date -u "+%s")
failures=0
summary=""

for repo in $COMPANIONS; do
    run_json=$(gh run list --repo "ManifoldKit/$repo" --workflow "$WORKFLOW" --limit 1 \
                  --json conclusion,status,createdAt,url --jq '.[0]' 2>/dev/null)

    if [ -z "$run_json" ] || [ "$run_json" = "null" ]; then
        summary="${summary}  ${repo}  NO RUNS FOUND — canary never ran\n"
        failures=$((failures + 1))
        continue
    fi

    conclusion=$(printf '%s' "$run_json" | sed -n 's/.*"conclusion":"\([^"]*\)".*/\1/p')
    created=$(printf '%s' "$run_json"    | sed -n 's/.*"createdAt":"\([^"]*\)".*/\1/p')
    url=$(printf '%s' "$run_json"        | sed -n 's/.*"url":"\([^"]*\)".*/\1/p')

    created_epoch=$(iso_to_epoch "$created")
    if [ -n "$created_epoch" ]; then
        age_hours=$(( (now_epoch - created_epoch) / 3600 ))
    else
        age_hours=-1
    fi

    if [ "$conclusion" != "success" ]; then
        summary="${summary}  ${repo}  FAIL (${conclusion:-in-progress}, ${age_hours}h ago)\n      ${url}\n"
        failures=$((failures + 1))
    elif [ "$age_hours" -lt 0 ]; then
        summary="${summary}  ${repo}  STALE (could not parse run timestamp '${created}')\n"
        failures=$((failures + 1))
    elif [ "$age_hours" -gt "$MAX_AGE_HOURS" ]; then
        summary="${summary}  ${repo}  STALE (last green ${age_hours}h ago, max ${MAX_AGE_HOURS}h) — re-run with --dispatch\n      ${url}\n"
        failures=$((failures + 1))
    else
        summary="${summary}  ${repo}  PASS (green ${age_hours}h ago)\n"
    fi
done

echo
echo "=================================================================="
echo "Companion canary summary  (${WORKFLOW_NAME} vs core main)"
echo "=================================================================="
printf "%b" "$summary"
echo "=================================================================="

if [ "$failures" -gt 0 ]; then
    cat <<'EOF'
Companion canary is not green against core main.

A red canary means core moved a seam the companions still depend on. Before
releasing, either:
  * land the companions' adaptation PRs in lockstep (AGENTS.md § "Companion
    pin-bump releases"), then re-run this gate; or
  * decide deliberately to ship anyway, knowing the post-release fan-out will
    fail and the companions will lag a minor until they adapt.

Do not bump the version on an unexamined red.
EOF
    exit 1
fi

echo "Companions build against core main. Safe to bump the release."
