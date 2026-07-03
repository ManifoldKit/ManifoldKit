#!/usr/bin/env bash
# companion-release-notes.sh — rewrite a companion's newest CHANGELOG section
# into Prisma-Highlights style for a ManifoldKit pin-bump release.
#
# Usage:  scripts/companion-release-notes.sh <companion-checkout> <mk-version>
#   <companion-checkout>  path to the companion repo/worktree (contains CHANGELOG.md)
#   <mk-version>          the ManifoldKit version this release tracks, e.g. 0.65.0
#
# What it does (to the NEWEST "## [x.y.z]" section only):
#   - inserts a "### Highlights" block with a "Tracks ManifoldKit <ver>" paragraph
#     right after the version header, and
#   - capitalizes the first letter of any bare "* lowercase" bullet.
# Scoped "* **scope:** ..." bullets are left as-is (companions have no changelog-lint,
# so they need no rewrite; a pure pin-bump section comes out fully lint-clean anyway).
# It does NOT touch commit-hash links, extra bullets (e.g. vendored-dep bumps are
# preserved under their existing heading), or any older section. It does NOT
# commit or push — review the diff, then amend + force-push per the release runbook.
# Idempotent: if the newest section already has "### Highlights", it no-ops.
#
# Bash 3.2 compatible (CI/macOS default); no associative arrays, no ${var^}.
set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <companion-checkout> <mk-version>" >&2
  echo "  e.g. $0 /Users/me/Repos/.worktrees/llama-rel 0.65.0" >&2
  exit 2
fi

checkout="$1"
mk_version="$2"
changelog="${checkout%/}/CHANGELOG.md"

if [ ! -f "$changelog" ]; then
  echo "::error:: no CHANGELOG.md at $changelog" >&2
  exit 1
fi
if ! printf '%s' "$mk_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "::error:: mk-version '$mk_version' is not X.Y.Z" >&2
  exit 1
fi

# Does the newest section already carry Highlights? (bounded by the 2nd "## [")
newest_section=$(awk '/^## \[/{n++} n==1' "$changelog")
if [ -z "$newest_section" ]; then
  echo "::error:: could not find a '## [x.y.z]' section in $changelog" >&2
  exit 1
fi
if printf '%s\n' "$newest_section" | grep -q '^### Highlights'; then
  echo "Newest section already has ### Highlights — nothing to do."
  exit 0
fi

tmp=$(mktemp)
# Rewrite in one awk pass:
#   - track when we're inside the FIRST version section (between 1st and 2nd "## [")
#   - right after the 1st "## [" header line, emit the Highlights block
#   - inside that section, capitalize a leading-lowercase "* x" bullet -> "* X"
awk -v ver="$mk_version" '
  BEGIN { n = 0; injected = 0 }
  /^## \[/ {
    n++
    print
    if (n == 1) {
      print ""
      print "### Highlights"
      print ""
      print "**Tracks ManifoldKit " ver "** — re-resolved, built, and tested green against the new core."
      injected = 1
    }
    next
  }
  {
    # Only transform lines inside the newest section.
    if (n == 1) {
      # Bare "* lowercase..." -> capitalize first letter. Leave "* **scope:**" alone.
      if ($0 ~ /^\* [a-z]/) {
        first = substr($0, 3, 1)
        rest  = substr($0, 4)
        print "* " toupper(first) rest
        next
      }
    }
    print
  }
' "$changelog" > "$tmp"

mv "$tmp" "$changelog"
echo "Rewrote newest section of $changelog to Highlights (tracks ManifoldKit $mk_version)."
echo "Review the diff, then amend the release commit + force-push (do NOT edit the PR body)."
