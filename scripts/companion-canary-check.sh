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
# So the primary check is LANDING-RELATIVE: a canary that started before the
# tip commit actually landed on main is STALE no matter how recent it is. The
# landing time is asked of GitHub (`/commits/{sha}/pulls` -> `merged_at`)
# rather than inferred from the commit date, because a commit's date is stamped
# when the merge queue builds the candidate and can precede the real merge by
# 13-44 minutes with no upper bound (it is CI duration under a concurrency cap).
# --max-age-hours (default 24) is a secondary bound for the case where main is
# quiet but the canary has simply gone unrun. Use --dispatch to trigger fresh
# runs and wait for them.
#
# Usage:
#   scripts/companion-canary-check.sh                     # check last known result
#   scripts/companion-canary-check.sh --dispatch          # trigger fresh runs, wait, then check
#   scripts/companion-canary-check.sh --max-age-hours 48  # loosen the secondary age bound
#
# Requires: gh (authenticated). Bash 3.2 compatible — CI runners ship 3.2, so
# no associative arrays.

set -uo pipefail   # fail-open-ok: NOT -e — check every companion and report all failures

COMPANIONS="manifold-mlx manifold-llama"
WORKFLOW="canary.yml"
WORKFLOW_NAME="Canary (core main)"
MAX_AGE_HOURS=24
DISPATCH=0
POLL_SECONDS=30
POLL_MAX=40          # 40 * 30s = 20 min ceiling per wait loop

while [ $# -gt 0 ]; do
    case "$1" in
        --dispatch)         DISPATCH=1; shift ;;
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
        -h|--help)
            # Print the whole leading comment block, however far it grows. A
            # fixed line range silently truncated the Usage section once the
            # header expanded — `-h` printed no invocation forms at all.
            awk 'NR==1 {next} /^#/ {sub(/^#[ ]?/, ""); print; next} {exit}' "$0"
            exit 0
            ;;
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
    dispatched=""
    dispatch_failed=""
    for repo in $COMPANIONS; do
        prior_ids="${prior_ids}${repo}=$(latest_run_id "$repo") "
        # Capture stderr: the usual cause of failure here is an under-scoped
        # token, and `gh`'s own message ("HTTP 403") is the only thing that
        # distinguishes that from the repo/workflow being missing.
        if dispatch_err="$(gh workflow run "$WORKFLOW" --repo "ManifoldKit/$repo" 2>&1 >/dev/null)"; then
            echo "  dispatched: $repo"
            dispatched="${dispatched}${repo} "
        else
            echo "  ERROR: could not dispatch $repo: ${dispatch_err:-<no output>}" >&2
            dispatch_failed="${dispatch_failed}${repo} "
        fi
    done

    # A failed dispatch used to warn and fall through to grading the PREVIOUS
    # run. That is a fail-open: on a quiet main the stale run can still satisfy
    # freshness, so --dispatch would exit 0 having dispatched nothing and
    # verified nothing — while both AGENTS.md and RELEASE.md promise the
    # opposite ("fails loudly rather than silently downgrading to a read that
    # could pass on stale evidence"). Callers asked for fresh evidence; if we
    # cannot produce it, say so instead of quietly answering a weaker question.
    #
    # The most likely cause is token scope: `gh workflow run` needs Actions
    # read+write on the target repo, which is a DIFFERENT permission from the
    # `contents: read+write` that repository_dispatch needs (see
    # release-please.yml's notify-companions job). A PAT minted only for that
    # job will 403 here.
    if [ -n "$dispatch_failed" ]; then
        echo "" >&2
        echo "ERROR: --dispatch could not trigger: ${dispatch_failed}" >&2
        echo "Refusing to grade the previous runs instead — you asked for fresh evidence." >&2
        echo "If this is HTTP 403, the token needs Actions: read+write on the companion repos" >&2
        echo "(distinct from the contents scope repository_dispatch uses)." >&2
        exit 2
    fi

    for repo in $COMPANIONS; do
        # Don't wait on a repo whose dispatch failed — no new run can appear,
        # so the poll would burn its full ceiling (20m each) for nothing.
        case " $dispatched " in
            *" $repo "*) ;;
            *) echo "  skipping wait for $repo (dispatch failed)"; continue ;;
        esac
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

# Timestamp of the tree being released. A canary that started before the code
# landed did not test it — see FRESHNESS above.
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# A failed fetch is NOT harmless: `origin/main` still resolves, to the stale
# local ref, so the comparison silently produces a plausible-but-wrong answer
# (offline laptop + three-day-old local ref + yesterday's canary => PASS over
# three days of untested commits). The `exit 2` below only catches the rare
# case where NO ref resolves. So fail closed on the fetch itself.
if ! git -C "$REPO_ROOT" fetch -q origin main 2>/dev/null; then
    echo "ERROR: could not fetch origin/main in $REPO_ROOT." >&2
    echo "       The local ref may be behind, which would silently pass a canary" >&2
    echo "       that never saw the commits being released." >&2
    # Deliberately no --allow-stale-ref escape: you cannot cut a release without
    # network anyway (merging the release PR, pushing the tag, and the
    # core-release fan-out all need it), so a flag here could only ever let the
    # gate assert coverage it cannot verify, in a situation where you can't
    # release regardless.
    exit 2
fi

# Use the NEWEST commit date in recent history, not just the tip's. A tip whose
# date is older than an ancestor's (rebase, cherry-pick, clock skew, a bot
# commit authored earlier) would otherwise understate how fresh the tree is and
# let a canary that predates real work pass.
head_desc="origin/main"
head_epoch=$(git -C "$REPO_ROOT" log --format=%ct -50 origin/main 2>/dev/null | sort -rn | head -1)
if [ -z "$head_epoch" ]; then
    head_desc="HEAD"
    head_epoch=$(git -C "$REPO_ROOT" log --format=%ct -50 HEAD 2>/dev/null | sort -rn | head -1)
fi
if [ -z "$head_epoch" ]; then
    echo "ERROR: could not resolve a commit date from origin/main or HEAD in $REPO_ROOT." >&2
    echo "       Cannot prove the canary covered the commits being released." >&2
    exit 2
fi

# Merge-queue skew. A commit's committer date is stamped when the queue BUILDS
# the candidate; it lands on main only after validation. That lag is systematic
# and UNBOUNDED — it is CI duration, and ci.yml fans out up to 5 macOS jobs
# against an org-wide ~5-concurrent cap, so a busy queue stretches it. Measured
# over 25 consecutive main commits: mostly 13-18m, but with a tail at 37m, 41m
# and 44m. A canary starting inside that window clones a tree WITHOUT the
# commit, goes green, and would be credited with covering it.
#
# Since the lag has no ceiling, NO constant margin is provably safe. So don't
# guess: ask GitHub when the tip actually merged. `/commits/{sha}/pulls` gives
# the exact `merged_at` for a PR-merged commit, which is every commit here
# (main is protected — direct pushes are blocked). That turns the check exact
# and removes the spurious-STALE window a large margin would create.
#
# The margin below survives only as a fallback for the cases where merge time
# can't be resolved (a direct push, or the API being unavailable), sized past
# the observed 44m tail.
MERGE_LAND_MARGIN_SECONDS=3600

head_sha=$(git -C "$REPO_ROOT" rev-parse "$head_desc" 2>/dev/null || echo "")
merged_at=""
if [ -n "$head_sha" ]; then
    # Take the LATEST merge among any PRs containing this commit. `.[0]` would
    # be fine for every commit on main today (a 40-commit sweep returned
    # exactly one PR each), but the API permits several — a cherry-picked
    # commit belongs to more than one — and their order is unspecified. Picking
    # an arbitrary one could yield an EARLIER deadline and let a stale canary
    # pass, so take the max explicitly.
    merged_at=$(gh api "repos/ManifoldKit/ManifoldKit/commits/${head_sha}/pulls" \
                   --jq '[.[] | select(.merged_at != null) | .merged_at] | max // empty' 2>/dev/null || true)  # fail-open-ok: API-failure garbage is caught by the two-stage validation below
fi

# TWO STAGES ON PURPOSE — do not collapse these into one.
# `gh api` writes HTTP error bodies to STDOUT, not stderr, so on a 404/422
# `merged_at` is not empty: it holds a JSON blob like
#   [{"message":"No commit found for SHA: ...","status":"422"}]
# Parsing it through `iso_to_epoch` is what turns that garbage into an empty
# `merged_epoch` and routes us to the margin fallback. Collapsing this into
# `head_epoch_effective=$(iso_to_epoch "$merged_at")` would set it to the empty
# string, make the `-lt` comparison below error, and — with `set -uo pipefail`
# and no `-e` — fall through the elif chain to PASS. That is the exact
# fail-open class this gate exists to prevent.
merged_epoch=""
if [ -n "$merged_at" ]; then
    merged_epoch=$(iso_to_epoch "$merged_at")
fi

if [ -n "$merged_epoch" ]; then
    head_epoch_effective="$merged_epoch"
    head_basis="merged ${merged_at}"
else
    head_epoch_effective=$((head_epoch + MERGE_LAND_MARGIN_SECONDS))
    head_basis="newest commit date +$((MERGE_LAND_MARGIN_SECONDS / 60))m (merge time unavailable)"
    # Say so on stderr as well as in the summary line: every defect found in
    # this script's review was a silent degradation that read as success, and a
    # note tucked into a PASS banner is easy to skim past.
    echo "WARNING: could not determine the merge time for ${head_sha:-<unknown>};" >&2
    echo "         falling back to the newest commit date +$((MERGE_LAND_MARGIN_SECONDS / 60))m, which is an ESTIMATE." >&2
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
    elif [ "$created_epoch" -lt "$head_epoch_effective" ]; then
        # PRIMARY check: green, but it started before the newest commit had
        # demonstrably landed — so it never saw the code being released. This
        # is the case a wall-clock window silently passes.
        behind_mins=$(( (head_epoch_effective - created_epoch) / 60 ))
        # If the deadline is still in the future, an immediate re-dispatch would
        # fail identically and burn a second full companion build. Say how long
        # to wait rather than inviting the pointless retry.
        wait_mins=$(( (head_epoch_effective - now_epoch + 59) / 60 ))
        if [ "$wait_mins" -gt 0 ]; then
            retry_hint="wait ~${wait_mins}m, then re-run with --dispatch"
        else
            retry_hint="re-run with --dispatch"
        fi
        summary="${summary}  ${repo}  STALE (green, but started ${behind_mins}m before ${head_desc} ${head_basis} — did not test it) — ${retry_hint}\n      ${url}\n"
        failures=$((failures + 1))
    elif [ "$age_hours" -gt "$MAX_AGE_HOURS" ]; then
        summary="${summary}  ${repo}  STALE (last green ${age_hours}h ago, max ${MAX_AGE_HOURS}h) — re-run with --dispatch\n      ${url}\n"
        failures=$((failures + 1))
    else
        summary="${summary}  ${repo}  PASS (green ${age_hours}h ago, started after ${head_desc} ${head_basis})\n"
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
