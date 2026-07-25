#!/usr/bin/env bash
#
# changelog-coverage-check.sh — verify the newest CHANGELOG.md section
# mentions every non-hidden-type commit merged since the previous release
# tag, so a release-please parse failure that silently drops a whole PR
# (#2380) is caught before publish instead of by hand.
#
# ── Why this exists ───────────────────────────────────────────────────────
#
# release-please's commit parser (@conventional-commits/parser) hard-fails
# on a squashed commit body whenever an identifier is immediately followed
# by nested parentheses — e.g. Swift code like
# `exit(FuzzReport.exitCode(for: report))` in a squash-merged commit's body.
# The failure is caught internally and logged only at debug level, so the
# ENTIRE commit — not just the offending paragraph — is silently omitted
# from the generated changelog with no warning anywhere in normal CI output.
# This is exactly what happened to PR #2375 in the 0.74.0 release; the
# omission was caught only because the mandatory Prisma-style rewrite is
# read line-by-line against the merge list by hand.
#
# This script is that cross-check, automated: it lists every non-hidden-type
# commit between the previous release tag and HEAD, and fails if any of
# their PR numbers do not appear anywhere in the changelog's newest section.
# It does not fix the underlying parser bug (a third-party dependency,
# pinned by SHA in .github/workflows/release-please.yml) — see AGENTS.md
# § Release workflow for the documented mitigation.
#
# Usage:
#   scripts/changelog-coverage-check.sh [CHANGELOG_PATH] [BASE_TAG] [HEAD_REF]
#
#   CHANGELOG_PATH  defaults to CHANGELOG.md
#   BASE_TAG        defaults to the previous version found in
#                   CHANGELOG_PATH's second `## [x.y.z]` header, prefixed
#                   with "v" (i.e. "check the newest section against
#                   everything merged since the section before it").
#                   Pass explicitly to check an arbitrary range.
#   HEAD_REF        defaults to HEAD. Pass explicitly (e.g. a past release
#                   tag) to re-check a historical range instead of the
#                   working tree's current position — this is how the
#                   fix for #2380 was demonstrated against a real red:
#                   `scripts/changelog-coverage-check.sh CHANGELOG.md v0.73.0 v0.74.0`
#
# Exit 0 = every non-hidden-type commit's PR number is mentioned somewhere
# in the newest changelog section. Exit 1 = at least one is missing (or the
# range/config could not be resolved — never silently short-circuits to a
# zero-commit "pass").
#
# Bash 3.2 compatible (CI runners ship Bash 3.2 — no `declare -A`, no
# `${var^^}`).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHANGELOG="${1:-CHANGELOG.md}"
BASE_TAG="${2:-}"
HEAD_REF="${3:-HEAD}"
CONFIG="${REPO_ROOT}/release-please-config.json"

if [ ! -f "$CHANGELOG" ]; then
  echo "::error::changelog-coverage-check: file not found: $CHANGELOG"
  exit 1
fi

if [ ! -f "$CONFIG" ]; then
  echo "::error::changelog-coverage-check: file not found: $CONFIG"
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "::error::changelog-coverage-check: jq is required but not on PATH"
  exit 1
fi

# Newest section: everything between the first "## [" header and the second.
newest_section="$(awk '/^## \[/{n++} n==1' "$CHANGELOG")"
if [ -z "$newest_section" ]; then
  echo "::error::changelog-coverage-check: could not find a version section in $CHANGELOG"
  exit 1
fi

if [ -z "$BASE_TAG" ]; then
  # Second "## [x.y.z]" header is the previous release.
  prev_version="$(awk '/^## \[/{n++; if (n==2) { match($0, /\[[0-9]+\.[0-9]+\.[0-9]+\]/); print substr($0, RSTART+1, RLENGTH-2); exit } }' "$CHANGELOG")"
  if [ -z "$prev_version" ]; then
    echo "::error::changelog-coverage-check: could not derive BASE_TAG from $CHANGELOG (pass it explicitly as \$2)"
    exit 1
  fi
  BASE_TAG="v${prev_version}"
fi

if ! git -C "$REPO_ROOT" rev-parse --verify --quiet "${BASE_TAG}^{commit}" >/dev/null; then
  echo "::error::changelog-coverage-check: BASE_TAG '$BASE_TAG' does not resolve to a commit"
  exit 1
fi

# Non-hidden changelog-sections types from release-please-config.json —
# read dynamically, not hardcoded, so this stays correct if the config's
# hidden flags change (a type flipping to hidden must not need this script
# updated in lockstep, and a type flipping to visible must be picked up
# automatically).
visible_types="$(jq -r '.packages["."]["changelog-sections"][] | select((.hidden // false) | not) | .type' "$CONFIG")"
if [ -z "$visible_types" ]; then
  echo "::error::changelog-coverage-check: no visible changelog-sections types found in $CONFIG"
  exit 1
fi

commit_log="$(git -C "$REPO_ROOT" log --no-merges --format='%s' "${BASE_TAG}..${HEAD_REF}")"
if [ -z "$commit_log" ]; then
  echo "::error::changelog-coverage-check: no commits found in range ${BASE_TAG}..${HEAD_REF} — refusing to report a vacuous pass"
  exit 1
fi

# Does the newest changelog section mention PR/issue number $1? Anchored so
# a short number can't false-match as a substring of a longer one (e.g. a
# naive `grep -qF "#237"` is satisfied by the unrelated "#2375").
changelog_mentions() {
  printf '%s' "$newest_section" | grep -qE "#${1}([^0-9]|\$)"
}

missing=""
missing_count=0
checked=0

while IFS= read -r subject; do
  [ -z "$subject" ] && continue

  # Conventional-commit header: type[(scope)][!]: subject text (#PR)
  type="$(printf '%s' "$subject" | sed -nE 's/^([a-zA-Z]+)(\([^)]*\))?!?:.*/\1/p')"
  [ -z "$type" ] && continue

  is_visible=false
  for t in $visible_types; do
    if [ "$t" = "$type" ]; then
      is_visible=true
      break
    fi
  done
  [ "$is_visible" = false ] && continue

  # Extract every #NNNN in the subject, in order. GitHub squash-merge always
  # appends " (#NNNN)" for the merged PR as the LAST one — but a subject can
  # carry an earlier number too, e.g. "feat(ui)!: the 2026 UI refresh ...
  # (#2307) (#2324)", where #2307 is the umbrella tracking issue this team's
  # Prisma-style rewrite sometimes cites instead of the individual squashed
  # PR number #2324 (see AGENTS.md's "Highlights" entries).
  #
  # Deliberately NOT `grep -oE '#[0-9]+'`: grep exits 1 on zero matches, and
  # under `set -o pipefail` that status propagates through the trailing
  # `tr`/pipeline and (with `errexit`) kills the whole script — silently,
  # with no output — on the ordinary case of a subject with no #NNNN at all.
  # Confirmed: running this script with no arguments against this branch's
  # own commits died exactly this way before this fix (one of this branch's
  # own commit subjects has no #NNNN, since it isn't merged yet). awk always
  # exits 0, matched or not, so it can't have this failure mode.
  pr_numbers="$(printf '%s\n' "$subject" | awk '{ n=split($0,a,"#"); for (i=2;i<=n;i++) if (match(a[i],/^[0-9]+/)) print substr(a[i],RSTART,RLENGTH) }')"
  [ -z "$pr_numbers" ] && continue

  checked=$((checked + 1))

  # Check the actual PR number (the last one) FIRST — accepting a match on
  # any earlier number as an unconditional pass would let a genuinely
  # dropped PR hide behind an unrelated issue number quoted in its own
  # subject (e.g. "...does NOT close #2353) (#2359)" — #2353 being mentioned
  # elsewhere in the section says nothing about whether #2359 itself is).
  # An earlier number is accepted only as a fallback, and ONLY with a loud,
  # visible warning naming which number actually matched — never silently.
  primary_pr="$(printf '%s\n' "$pr_numbers" | tail -n1)"

  if changelog_mentions "$primary_pr"; then
    continue
  fi

  fallback_pr=""
  for n in $pr_numbers; do
    [ "$n" = "$primary_pr" ] && continue
    if changelog_mentions "$n"; then
      fallback_pr="$n"
      break
    fi
  done

  if [ -n "$fallback_pr" ]; then
    echo "::warning::changelog-coverage-check: #${primary_pr} is not itself mentioned in ${CHANGELOG}; it matched only via #${fallback_pr}, cited elsewhere in its own subject (umbrella-issue convention). Verify #${primary_pr}'s actual content is represented: ${subject}"
    continue
  fi

  missing="${missing}  #${primary_pr}: ${subject}
"
  missing_count=$((missing_count + 1))
done <<EOF
$commit_log
EOF

if [ "$checked" -eq 0 ]; then
  echo "::error::changelog-coverage-check: matched 0 releasable commits in ${BASE_TAG}..${HEAD_REF} — the header regex or visible-types list is likely broken, not that nothing shipped"
  exit 1
fi

if [ -n "$missing" ]; then
  echo "::error::changelog-coverage-check: ${CHANGELOG}'s newest section is missing entries for ${missing_count} of ${checked} releasable commit(s) merged in ${BASE_TAG}..${HEAD_REF}:"
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    echo "::error::${line}"
  done <<EOF2
$missing
EOF2
  echo ""
  echo "This is the #2380 failure class: release-please's commit parser can silently"
  echo "drop an entire commit (see AGENTS.md § Release workflow). Add the missing"
  echo "entry to the changelog by hand before merging the release PR."
  exit 1
fi

echo "✓ changelog-coverage-check: all ${checked} releasable commit(s) in ${BASE_TAG}..${HEAD_REF} are mentioned in ${CHANGELOG}'s newest section"
