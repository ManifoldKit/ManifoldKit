#!/usr/bin/env bash
# scripts/api-demotion-screen.sh — A.0 verification screen for a public -> package
# demotion candidate (docs/plans/api-v1-rationalisation-2026-07.md, item A.0).
#
# Usage:
#   scripts/api-demotion-screen.sh <TypeName> <Module>
#
#   <TypeName>  Top-level public type name (e.g. WedgeWatchdog).
#   <Module>    Module the baseline file lives under (e.g. ManifoldInference) —
#               used to locate Tests/APIFreezeTests/api-surface-baseline/<Module>.txt.
#
# Runs the three A.0 checks and prints a PASS / FAIL / NEEDS-HAND-ADJUDICATION
# verdict plus evidence, suitable for pasting into a demotion PR body:
#   1. source-restricted word-boundary grep of the type name AND its public
#      member names across the six consumer repos.
#   2. in-repo signature-anchor heuristic (does the type appear on another
#      public declaration's line, inside this repo's own Sources/?).
#   3. docs check (docs/*.md, README.md, DocC catalogs) — any hit is a hard FAIL,
#      since documented API is not a mechanical-demotion candidate.
#
# Bash 3.2 compatible (CI runners ship 3.2 — no associative arrays, no mapfile).

set -euo pipefail

if ! command -v rg >/dev/null 2>&1; then
  echo "error: ripgrep (rg) is required. Install with: brew install ripgrep" >&2
  exit 1
fi

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <TypeName> <Module>" >&2
  exit 1
fi

TYPE_NAME="$1"
MODULE="$2"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BASELINE_FILE="${REPO_ROOT}/Tests/APIFreezeTests/api-surface-baseline/${MODULE}.txt"

# Default consumer repo roots: the six known local checkouts (three
# first-party apps + the two companion backends + manifold-eval). Override
# with MK_CONSUMER_REPOS (colon-separated) for a different machine layout.
DEFAULT_CONSUMER_REPOS="${HOME}/Repos/basechat:${HOME}/Repos/idlewick:${HOME}/Repos/fireside:${HOME}/Repos/manifold-mlx:${HOME}/Repos/manifold-llama:${HOME}/Repos/manifold-eval"
CONSUMER_REPOS="${MK_CONSUMER_REPOS:-${DEFAULT_CONSUMER_REPOS}}"

STEP1_HITS=0
STEP1B_HITS=0
STEP2_HITS=0
STEP3_HITS=0

echo "## api-demotion-screen: ${TYPE_NAME} (${MODULE})"
echo

# ── Step 1: source-restricted word-boundary grep of the type name across ──
# ── consumer repos ─────────────────────────────────────────────────────────
echo "### Step 1 — consumer repos: type name (\`rg -w -t swift '${TYPE_NAME}'\`)"
echo

OLD_IFS="$IFS"
IFS=':'
for root in $CONSUMER_REPOS; do
  IFS="$OLD_IFS"
  if [ ! -d "$root" ]; then
    echo "- WARN: consumer repo root not found, skipping: ${root}"
    continue
  fi
  hits="$(rg -w -t swift -n "$TYPE_NAME" "$root" 2>/dev/null || true)"
  if [ -n "$hits" ]; then
    STEP1_HITS=$((STEP1_HITS + 1))
    echo "- HIT: ${root}"
    echo '  ```'
    echo "  ${hits//$'\n'/$'\n  '}"
    echo '  ```'
  else
    echo "- clean: ${root}"
  fi
  IFS=':'
done
IFS="$OLD_IFS"
echo

# ── Step 1b: public member names, derived from the baseline file ──────────
echo "### Step 1b — consumer repos: public member names of ${TYPE_NAME}"
echo

MEMBER_NAMES=""
if [ -f "$BASELINE_FILE" ]; then
  # Lines look like: TypeName.memberName(params:) Kind
  # Extract the identifier before "(" or before the first space after the dot,
  # skip operators, __derived_* synthesized members, and init.
  MEMBER_NAMES="$(rg -N "^${TYPE_NAME}\." "$BASELINE_FILE" 2>/dev/null \
    | sed -E "s/^${TYPE_NAME}\.//" \
    | sed -E 's/\(.*$//' \
    | sed -E 's/ .*$//' \
    | grep -Ev '^(init|__derived.*)$' \
    | grep -Ev '^[^A-Za-z_]' \
    | sort -u || true)"
else
  echo "- WARN: baseline file not found: ${BASELINE_FILE} (skipping member-name derivation)"
fi

if [ -z "$MEMBER_NAMES" ]; then
  echo "- no public member names derived (baseline missing, or type has none besides init/operators)"
else
  echo "- derived members: $(echo "$MEMBER_NAMES" | tr '\n' ' ')"
  echo
  while IFS= read -r member; do
    [ -z "$member" ] && continue
    OLD_IFS="$IFS"
    IFS=':'
    for root in $CONSUMER_REPOS; do
      IFS="$OLD_IFS"
      [ -d "$root" ] || { IFS=':'; continue; }
      hits="$(rg -w -t swift -n "$member" "$root" 2>/dev/null || true)"
      if [ -n "$hits" ]; then
        STEP1B_HITS=$((STEP1B_HITS + 1))
        echo "- HIT: member \`${member}\` in ${root}"
        echo '  ```'
        echo "  ${hits//$'\n'/$'\n  '}"
        echo '  ```'
      fi
      IFS=':'
    done
    IFS="$OLD_IFS"
  done <<EOF
$MEMBER_NAMES
EOF
  if [ "$STEP1B_HITS" -gt 0 ]; then
    echo "- ${STEP1B_HITS} member-name hit(s) found — common identifiers are noisy, hand-adjudicate (see evidence above)."
  else
    echo "- clean: no member-name hits across consumer repos."
  fi
fi
echo

# ── Step 2: in-repo signature-anchor heuristic ─────────────────────────────
echo "### Step 2 — in-repo signature-anchor heuristic (\`rg -n\` on \`public\` lines under Sources/)"
echo

anchor_hits="$(rg -n "$TYPE_NAME" "${REPO_ROOT}/Sources" 2>/dev/null | rg 'public' || true)"
if [ -n "$anchor_hits" ]; then
  STEP2_HITS="$(echo "$anchor_hits" | wc -l | tr -d ' ')"
  echo "- ${STEP2_HITS} line(s) — review for use as a parameter/return/thrown/associated-value type on another public declaration:"
  echo '```'
  echo "$anchor_hits"
  echo '```'
else
  echo "- no anchor hits found under Sources/."
fi
echo

# ── Step 3: docs check ──────────────────────────────────────────────────────
echo "### Step 3 — docs check (docs/*.md, README.md, DocC catalogs)"
echo

docs_hits=""
for pattern in "${REPO_ROOT}"/docs/*.md "${REPO_ROOT}"/README.md; do
  [ -f "$pattern" ] || continue
  h="$(rg -w -n "$TYPE_NAME" "$pattern" 2>/dev/null || true)"
  [ -n "$h" ] && docs_hits="${docs_hits}
${pattern}:
${h}"
done
docc_hits="$(rg -w -n -g '**/*.docc/**' "$TYPE_NAME" "${REPO_ROOT}/Sources" 2>/dev/null || true)"
[ -n "$docc_hits" ] && docs_hits="${docs_hits}
DocC:
${docc_hits}"

if [ -n "$docs_hits" ]; then
  STEP3_HITS=1
  echo "- HIT — documented API, not a mechanical-demotion candidate:"
  echo '```'
  echo "$docs_hits"
  echo '```'
else
  echo "- clean: no docs/README/DocC hits."
fi
echo

# ── Verdict ──────────────────────────────────────────────────────────────
echo "### Verdict"
echo

if [ "$STEP3_HITS" -gt 0 ] || [ "$STEP1_HITS" -gt 0 ]; then
  echo "**FAIL** — ${TYPE_NAME} is not a mechanical-demotion candidate."
  [ "$STEP3_HITS" -gt 0 ] && echo "- Step 3 (docs) found a hit."
  [ "$STEP1_HITS" -gt 0 ] && echo "- Step 1 (type-name grep) found a hit in a consumer repo."
  exit_code=1
elif [ "$STEP1B_HITS" -gt 0 ]; then
  echo "**NEEDS-HAND-ADJUDICATION** — no type-name or docs hits, but ${STEP1B_HITS} public-member-name hit(s) require review (common identifiers are noisy; confirm none are actually calls into ${TYPE_NAME})."
  exit_code=2
else
  echo "**PASS** — no consumer, member-name, or docs hits found. Step 2 anchor hits (if any, see above) still need reviewer eyes before demotion."
  exit_code=0
fi

exit "$exit_code"
