#!/usr/bin/env bash
# Scaffold a DX walkthrough rerun: create per-run directories under
# scripts/dx-walkthrough/runs/<date>_v<version>_<label>/<archetype>/run-{1,2,3}/
# and print three self-contained dispatch prompts for the Agent tool.
#
# This script does NOT dispatch agents itself — the human (or the orchestrating
# Claude session) hands the printed prompts to the Agent tool.
#
# Usage: scripts/dx-walkthrough/run.sh <archetype> <label>
#   archetype: name of a brief under scripts/dx-walkthrough/briefs/<archetype>.md
#              (without the .md extension)
#   label:     free-form tag for the run dir (e.g. "iter5", "post-refactor",
#              "pre-0.34"). Spaces and slashes are normalized to underscores.

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <archetype> <label>" >&2
  echo "Example: $0 01-chat-cli iter5" >&2
  exit 2
fi

ARCHETYPE="$1"
LABEL="$(echo "$2" | tr ' /' '__')"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BRIEF="$SCRIPT_DIR/briefs/${ARCHETYPE}.md"

if [[ ! -f "$BRIEF" ]]; then
  echo "error: brief not found at $BRIEF" >&2
  echo "available briefs:" >&2
  ls "$SCRIPT_DIR/briefs" 2>/dev/null | sed 's/\.md$//' | sed 's/^/  /' >&2
  exit 1
fi

DATE="$(date +%Y-%m-%d)"
VERSION="$(cat "$REPO_ROOT/version.txt" 2>/dev/null | tr -d '[:space:]' || echo "unknown")"
RUN_BASE="$SCRIPT_DIR/runs/${DATE}_v${VERSION}_${LABEL}/${ARCHETYPE}"

mkdir -p "$RUN_BASE"/run-1 "$RUN_BASE"/run-2 "$RUN_BASE"/run-3

echo "Run directories:"
echo "  $RUN_BASE/run-1/"
echo "  $RUN_BASE/run-2/"
echo "  $RUN_BASE/run-3/"
echo

for i in 1 2 3; do
  RUN_DIR="$RUN_BASE/run-$i"
  cat <<EOF
========================================================================
Dispatch prompt for run-$i (paste into Agent tool, subagent_type=claude,
isolation=worktree, run_in_background=true):
========================================================================
You are participating in a DX walkthrough rerun of ManifoldKit.

Your job: act as a fresh Swift developer evaluating ManifoldKit by
following the brief at:

  $BRIEF

Read that brief carefully and follow it literally. The forced-blindness
rule (no reading Sources/Manifold*/**/*.swift or Tests/**) is the whole
point of the exercise — do not relax it even if you get stuck.

Your run directory is:

  $RUN_DIR

Place your app under \`$RUN_DIR/app/\`. Produce \`FRICTION.md\`,
\`NOTES.md\`, and \`session.log\` directly under \`$RUN_DIR/\` as the
brief specifies. Capture the final \`swift run\` session showing at least
two prompt/response cycles to \`session.log\`.

When you finish (success, partial, or time-up), report back with:
  - working / partial / not-working
  - the path \`$RUN_DIR/\`
  - your top 3 highest-severity friction entries verbatim
  - a one-line overall verdict

Methodology note: this is run $i of 3 parallel runs. If you have
discretion over which backend/model to pick, choose something different
from the obvious default — backend variation across runs is signal.

EOF
done

echo "After all three runs report back, synthesize:"
echo "  $RUN_BASE/SUMMARY.md         (cross-run synthesis)"
echo "  $RUN_BASE/ROOT_CAUSES.md     (optional: causal grouping)"
echo
echo "Then compare to a previous iteration with:"
echo "  scripts/dx-walkthrough/compare.sh <prev-iter-dir> $RUN_BASE"
