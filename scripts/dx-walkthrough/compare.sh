#!/usr/bin/env bash
# Heuristic diff between two walkthrough iterations.
#
# Usage: scripts/dx-walkthrough/compare.sh <prev-dir> <curr-dir>
#   where each <dir> is a path like
#     scripts/dx-walkthrough/runs/2026-05-23_v0.33.0/01-chat-cli
#   containing run-1/FRICTION.md, run-2/FRICTION.md, run-3/FRICTION.md
#   (any subset is fine — missing runs are skipped).
#
# Findings are fingerprinted by the first sentence of their "Trying to:"
# line. The output is a markdown report grouping fingerprints as:
#   - Disappeared (in prev only)   — likely fixed
#   - Persisted   (in both)        — still open
#   - New         (in curr only)   — regression or next-layer discovery

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <prev-iter-dir> <curr-iter-dir>" >&2
  exit 2
fi

PREV="$1"
CURR="$2"

if [[ ! -d "$PREV" ]] || [[ ! -d "$CURR" ]]; then
  echo "error: both arguments must be directories" >&2
  exit 1
fi

# Extract a fingerprint per Entry: the "Trying to:" first sentence, lowercased,
# with a SEVERITY tag appended. One fingerprint per line on stdout.
extract_fingerprints() {
  local dir="$1"
  local label="$2"
  for f in "$dir"/run-*/FRICTION.md; do
    [[ -f "$f" ]] || continue
    awk -v src="$label/$(basename "$(dirname "$f")")" '
      /^- \*\*Trying to\*\*:/ {
        sub(/^- \*\*Trying to\*\*:[ \t]*/, "")
        # first sentence: chop at first ". " or end of line
        n = index($0, ". ")
        if (n > 0) { trying = substr($0, 1, n-1) } else { trying = $0 }
        # strip trailing period
        sub(/\.$/, "", trying)
        # lowercase
        trying_lc = tolower(trying)
        severity = ""
        next_entry = 0
        # save until severity or next entry
        getline_buf = trying_lc
        # collect rest of entry to find severity
        while ((getline line) > 0) {
          if (line ~ /^## /) break
          if (line ~ /^- \*\*Severity\*\*:/) {
            sev = line
            sub(/^- \*\*Severity\*\*:[ \t]*/, "", sev)
            severity = sev
            break
          }
        }
        print trying_lc "\t" severity "\t" src "\t" trying
      }
    ' "$f"
  done
}

TMP_PREV=$(mktemp)
TMP_CURR=$(mktemp)
trap 'rm -f "$TMP_PREV" "$TMP_CURR"' EXIT

extract_fingerprints "$PREV" "prev" > "$TMP_PREV"
extract_fingerprints "$CURR" "curr" > "$TMP_CURR"

# Build keysets (first column = fingerprint).
PREV_KEYS=$(cut -f1 "$TMP_PREV" | sort -u)
CURR_KEYS=$(cut -f1 "$TMP_CURR" | sort -u)

DISAPPEARED=$(comm -23 <(echo "$PREV_KEYS") <(echo "$CURR_KEYS") || true)
PERSISTED=$(comm -12 <(echo "$PREV_KEYS") <(echo "$CURR_KEYS") || true)
NEW=$(comm -13 <(echo "$PREV_KEYS") <(echo "$CURR_KEYS") || true)

# Format a section: takes a keyset and a tmpfile to look up source+display.
render_section() {
  local keys="$1"
  local src_file="$2"
  if [[ -z "$keys" ]]; then
    echo "_(none)_"
    return
  fi
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    # find first matching row
    row=$(awk -F'\t' -v k="$key" '$1 == k { print; exit }' "$src_file")
    sev=$(echo "$row" | cut -f2)
    src=$(echo "$row" | cut -f3)
    disp=$(echo "$row" | cut -f4)
    printf -- "- **%s** _(sev: %s, first seen in %s)_\n" "$disp" "${sev:-?}" "${src:-?}"
  done <<< "$keys"
}

cat <<EOF
# DX Walkthrough Diff

- **Previous**: \`$PREV\`
- **Current**:  \`$CURR\`

## Disappeared (likely fixed)

$(render_section "$DISAPPEARED" "$TMP_PREV")

## Persisted (still open)

$(render_section "$PERSISTED" "$TMP_CURR")

## New (regression or next-layer discovery)

$(render_section "$NEW" "$TMP_CURR")

---
_Heuristic fingerprint: first sentence of "Trying to:" line, lowercased.
False positives possible when an entry is rephrased between iterations._
EOF
