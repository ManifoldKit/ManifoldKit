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
# `cannot find type 'StructuredHistoryReceiver'`, v0.73.0 merged at 09:14:33Z
# and published 10s later anyway, and both companions were stranded a minor
# behind until their adaptation PRs landed. The detection worked; nothing was
# gated on it. This script is that gate.
#
# A canary failure means CORE MOVED A SEAM the companions still depend on. It
# does not necessarily block the release — the correct response is usually to
# land the companions' adaptation PRs in lockstep (see AGENTS.md § "Companion
# pin-bump releases") — but it must be a deliberate decision, not a surprise
# discovered by the post-release fan-out.
#
# FRESHNESS — the subtle part, and the reason a naive version of this gate
# would NOT have caught the incident above. The canary builds against core
# main HEAD *as of its own run time*, so "the canary is recent" and "the canary
# covered the commits I am about to release" are different claims, and only
# the second one matters. Replay the real incident one day earlier: the last
# green canary was 2026-07-19T06:42Z; the seam-moving commit (#2312) merged at
# 06:58Z, 21 minutes later; a release cut that evening would have read a green
# run 13h old — inside any sane wall-clock window — and passed on a tree that
# was already broken. The 07-20 red only existed because a nightly happened to
# re-run after the merge.
#
# So the primary check is COMMIT-RELATIVE: a canary that started before the tip
# commit of the branch being released is STALE no matter how recent it is.
# --max-age-hours (default 24) is kept as a secondary bound for the case where
# main is quiet but the canary has simply gone unrun. Use --dispatch to trigger
# fresh runs and wait for them.
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
        --dispatch)  DISPATCH=1; shift ;;
        --max-age-hours)
            # `shift 2` with only one arg left FAILS on bash 3.2 and does NOT
            # shift — without `set -e` that spins this loop forever. Guard it.
            if [ $# -lt 2 ]; then
                echo "ERROR: --max-age-hours requires a value." >&2
                exit 2
            fi
            MAX_AGE_HOURS="$2"
            # A non-numeric value would make the `-gt` comparison below error;
            # with `set -uo pipefail` (no -e) that falls through to the PASS
            # branch, turning the gate green on an arbitrarily stale canary.
            # Fail closed at parse time instead.
            case "$MAX_AGE_HOURS" in
                ''|*[!0-9]*)
                    echo "ERROR: --max-age-hours must be a whole number of hours (got '$MAX_AGE_HOURS')." >&2
                    exit 2
                    ;;
            esac
            shift 2
            ;;
        -h|--help)   sed -n '2,42p' "$0"; exit 0 ;;
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

latest_run_id() {
    gh run list --repo "ManifoldKit/$1" --workflow "$WORKFLOW" --limit 1 \
        --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null
}

if [ "$DISPATCH" -eq 1 ]; then
    echo "Dispatching fresh canary runs..."
    # Record the run each repo is on BEFORE dispatching. `workflow_dispatch`
    # registration routinely lags more than a few seconds, so polling `.[0]`
    # right after dispatch can observe the PREVIOUS run — already `completed` —
    # break instantly, and then grade that stale run as if it were the fresh
    # one. Waiting for the id to CHANGE is what makes --dispatch mean anything.
    prior_ids=""
    for repo in $COMPANIONS; do
        prior_ids="${prior_ids}${repo}=$(latest_run_id "$repo") "
        if gh workflow run "$WORKFLOW" --repo "ManifoldKit/$repo" >/dev/null 2>&1; then
            echo "  dispatched: $repo"
        else
            echo "  WARNING: could not dispatch $repo (checking last known result instead)" >&2
        fi
    done

    for repo in $COMPANIONS; do
        prior=$(printf '%s' "$prior_ids" | tr ' ' '\n' | sed -n "s/^${repo}=//p")
        printf '  waiting for %s' "$repo"
        i=0
        while [ "$i" -lt "$POLL_MAX" ]; do
            current=$(latest_run_id "$repo")
            if [ -n "$current" ] && [ "$current" != "$prior" ]; then
                status=$(gh run view "$current" --repo "ManifoldKit/$repo" \
                            --json status --jq '.status' 2>/dev/null)
                [ "$status" = "completed" ] && break
            fi
            printf '.'
            sleep "$POLL_SECONDS"
            i=$((i + 1))
        done
        printf '\n'
        if [ "$i" -ge "$POLL_MAX" ]; then
            echo "  WARNING: $repo canary did not produce a completed new run after $((POLL_MAX * POLL_SECONDS / 60))m" >&2
        fi
    done
fi

now_epoch=$(date -u "+%s")
failures=0
summary=""

# Tip commit of the tree being released. A canary that started before this
# commit did not test it — see FRESHNESS above. Prefer origin/main (what a
# release actually ships); fall back to HEAD when there is no remote ref.
# If neither resolves we cannot prove coverage, so fail closed rather than
# silently degrade to the weaker wall-clock check.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
git -C "$REPO_ROOT" fetch -q origin main 2>/dev/null || true
head_epoch=$(git -C "$REPO_ROOT" log -1 --format=%ct origin/main 2>/dev/null \
             || git -C "$REPO_ROOT" log -1 --format=%ct HEAD 2>/dev/null \
             || echo "")
head_desc="origin/main"
if [ -z "$head_epoch" ]; then
    echo "ERROR: could not resolve the tip commit of origin/main or HEAD in $REPO_ROOT." >&2
    echo "       Cannot prove the canary covered the commits being released." >&2
    exit 2
fi

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
    elif [ "$created_epoch" -lt "$head_epoch" ]; then
        # PRIMARY check: green, but it started before the tip commit — so it
        # never saw the code being released. This is the case a wall-clock
        # window silently passes.
        behind_mins=$(( (head_epoch - created_epoch) / 60 ))
        summary="${summary}  ${repo}  STALE (green, but ran ${behind_mins}m BEFORE ${head_desc} tip — did not test it) — re-run with --dispatch\n      ${url}\n"
        failures=$((failures + 1))
    elif [ "$age_hours" -gt "$MAX_AGE_HOURS" ]; then
        summary="${summary}  ${repo}  STALE (last green ${age_hours}h ago, max ${MAX_AGE_HOURS}h) — re-run with --dispatch\n      ${url}\n"
        failures=$((failures + 1))
    else
        summary="${summary}  ${repo}  PASS (green ${age_hours}h ago, covers ${head_desc} tip)\n"
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
