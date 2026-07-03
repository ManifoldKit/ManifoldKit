#!/usr/bin/env bash
#
# changelog-lint.sh — verify the newest CHANGELOG.md section has been rewritten
# into human prose (Prisma-style Highlights) rather than left as raw
# release-please auto-generated bullets.
#
# Extracted from the inline `changelog-lint` step in .github/workflows/lint.yml
# (issue #953 / Lever D) so it can be run locally before force-pushing a
# rewritten release-please branch, and so CI and the local gate share one
# source of truth. The CI step now calls this script.
#
# Usage:  bash scripts/changelog-lint.sh [path/to/CHANGELOG.md]
#         (defaults to CHANGELOG.md in the current directory)
#
# Exit 0 = the newest section is prose-clean; exit 1 = it still contains
# auto-generated bullets or lacks any prose-style entry.
#
# Bash 3.2 compatible (the CI runners ship Bash 3.2 — no `declare -A`, no
# `${var^^}`).
set -euo pipefail

CHANGELOG="${1:-CHANGELOG.md}"

if [ ! -f "$CHANGELOG" ]; then
  echo "::error::changelog-lint: file not found: $CHANGELOG"
  exit 1
fi

# Extract the newest version section from CHANGELOG.md
# (everything between the first ## [x.y.z] and the second ## [x.y.z])
newest_section=$(awk '/^## \[/{n++} n==1' "$CHANGELOG")

if [ -z "$newest_section" ]; then
  echo "::error::Could not find a version section in CHANGELOG.md"
  exit 1
fi

echo "=== Newest changelog section ==="
echo "$newest_section"
echo "================================"

# Check for auto-generated bullet entries (Release Please format).
# Two patterns to catch:
#   (a) "* lowercase" — old bare-bullet style
#   (b) "* **scope:** description" — scoped style (introduced when RP
#       started generating "* **runtime:** Glass Box P0 — …" entries);
#       these start with "* **" so the old "^\* [a-z]" regex missed them.
if echo "$newest_section" | grep -qE '^\* (\*\*[a-z]|[a-z])'; then
  echo ""
  echo "::error::CHANGELOG.md contains auto-generated bullet entries."
  echo "::error::Release notes must be rewritten in prose style before merging."
  echo "::error::"
  echo "::error::Expected format:  **Bold title** — Description of the change..."
  echo "::error::Found format:     * auto-generated commit message"
  echo ""
  echo "Auto-generated entries found:"
  echo "$newest_section" | grep -E '^\* (\*\*[a-z]|[a-z])'
  exit 1
fi

# Verify the section shows evidence of a human rewrite — either
#   (a) a prose bullet with a bold title and em-dash, or
#   (b) an H3 subheading (Prisma-style Highlights section).
# Check #1 above already rejects raw auto-generated `* lowercase`
# bullets, so either prose shape is sufficient proof the author
# reworked the auto-generated output.
if ! echo "$newest_section" | grep -qE '^(\*\*[^*]+\*\* —|### )'; then
  # Find the first candidate prose line so the author can see exactly
  # what tripped the regex. Common em-dash-format mistakes: period
  # inside the bold (**Title.** prose), colon after the bold
  # (**Title**: prose), or a hyphen/en-dash instead of "—".
  offending_line=$(echo "$newest_section" | grep -m1 -E '^\*\*' || true)

  echo ""
  echo "::error::No prose-style entries found in the newest changelog section."
  echo "::error::Accepted formats:"
  echo "::error::  (a) **Bold title** — Description…  (em-dash required, not period/colon/hyphen)"
  echo "::error::  (b) ### Subheading                  (Prisma-style Highlights)"
  if [ -n "$offending_line" ]; then
    echo "::error::Found:  $offending_line"
  else
    echo "::error::Found:  (no line starting with ** or ### in the newest section)"
  fi
  exit 1
fi

echo ""
echo "✓ Changelog entries are in prose style"
