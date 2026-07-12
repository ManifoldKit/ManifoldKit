#!/usr/bin/env bash
# scripts/release-train-check.sh — release-train version-matrix tripwire (#2224)
#
# The core repo release-please -> repository_dispatch -> per-companion
# core-bump.yml chain (see ManifoldKit/.github RELEASE-PROCESS.md) has no
# single source of truth for whether the family is actually coherent right
# now. A drifted pin is invisible until a companion build fails or an eval
# run silently tests stale core behavior. This script asserts the invariants
# RELEASE-PROCESS.md describes; it does not redefine them.
#
# Checks four invariants against manifold-mlx, manifold-llama, manifold-eval:
#   1. Each companion's ManifoldKit core pin equals the latest core git tag.
#   2. manifold-eval pins with `exact:` (not a range) and is current.
#   3. No companion/eval release-please PR has sat open past --max-age-days.
#   4. This repo's README.md install-pin snippet matches the latest core tag.
#
# On ANY drift, prints "DRIFT: <repo> <invariant> — <detail>" and exits 1.
# Names the specific repo + invariant — never just "drift detected somewhere".
#
# Bash 3.2 compatible (CI/macOS default); no associative arrays, no ${var^}.
#
# Usage:
#   scripts/release-train-check.sh [--max-age-days N] [--fixture-dir DIR]
#
# --fixture-dir DIR lets a caller override individual data sources for
# testing, without touching the network for the parts under test. Recognized
# fixture files (all optional — anything absent falls back to a live fetch):
#   DIR/core-tag.txt                latest core tag override, e.g. "v0.70.0"
#   DIR/readme.md                   README.md content override
#   DIR/<repo>-package.swift        companion Package.swift content override
#   DIR/<repo>-open-prs.json        `gh pr list --json number,headRefName,createdAt` override
# where <repo> is one of manifold-mlx, manifold-llama, manifold-eval.
set -euo pipefail

max_age_days=4
fixture_dir=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --max-age-days)
      max_age_days="$2"
      shift 2
      ;;
    --fixture-dir)
      fixture_dir="$2"
      shift 2
      ;;
    *)
      echo "usage: $0 [--max-age-days N] [--fixture-dir DIR]" >&2
      exit 2
      ;;
  esac
done

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
drift_count=0

note_drift() {
  # note_drift <repo> <invariant> <detail>
  echo "::error::DRIFT: $1 $2 — $3"
  drift_count=$((drift_count + 1))
}

note_pass() {
  echo "PASS: $1 $2 — $3"
}

fixture_file() {
  # fixture_file <name> -> prints path if it exists under fixture_dir, else empty
  if [ -n "$fixture_dir" ] && [ -f "$fixture_dir/$1" ]; then
    printf '%s' "$fixture_dir/$1"
  fi
}

# ---------------------------------------------------------------------------
# Latest core tag
# ---------------------------------------------------------------------------
core_tag_fixture="$(fixture_file core-tag.txt)"
if [ -n "$core_tag_fixture" ]; then
  latest_core_tag="$(tr -d '[:space:]' < "$core_tag_fixture")"
else
  latest_core_tag="$(git -C "$repo_root" tag -l 'v*' | sort -V | tail -1)"
fi
if [ -z "$latest_core_tag" ]; then
  echo "::error::could not determine latest core tag (git tag -l 'v*' returned nothing; is this a full checkout with tags fetched?)" >&2
  exit 2
fi
latest_core_version="${latest_core_tag#v}"
echo "Latest core tag: $latest_core_tag (version $latest_core_version)"

# ---------------------------------------------------------------------------
# Invariant 4: README.md install-pin snippet
# ---------------------------------------------------------------------------
readme_fixture="$(fixture_file readme.md)"
if [ -n "$readme_fixture" ]; then
  readme_content="$(cat "$readme_fixture")"
else
  readme_content="$(cat "$repo_root/README.md")"
fi

readme_pin_line="$(printf '%s\n' "$readme_content" | grep -m1 'x-release-please-version' || true)"
readme_pin_version="$(printf '%s\n' "$readme_pin_line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"

if [ -z "$readme_pin_version" ]; then
  note_drift "ManifoldKit/ManifoldKit" "README-pin" "could not find an 'x-release-please-version' marked install-pin line in README.md"
elif [ "$readme_pin_version" != "$latest_core_version" ]; then
  note_drift "ManifoldKit/ManifoldKit" "README-pin" "README.md install pin is $readme_pin_version, latest core tag is $latest_core_version (release-please's extra-files bump may have broken)"
else
  note_pass "ManifoldKit/ManifoldKit" "README-pin" "$readme_pin_version matches latest core tag"
fi

# ---------------------------------------------------------------------------
# Invariants 1 + 2: companion / eval core pins
# ---------------------------------------------------------------------------
fetch_package_swift() {
  # fetch_package_swift <repo> -> prints Package.swift content to stdout
  repo="$1"
  pkg_fixture="$(fixture_file "${repo}-package.swift")"
  if [ -n "$pkg_fixture" ]; then
    cat "$pkg_fixture"
    return
  fi
  gh api "repos/ManifoldKit/${repo}/contents/Package.swift" -q .content | base64 -d
}

check_companion_pin() {
  # check_companion_pin <repo> <require_exact: yes|no>
  repo="$1"
  require_exact="$2"

  content="$(fetch_package_swift "$repo")"
  # Companions differ on the trailing ".git" (manifold-eval has it, manifold-mlx/
  # manifold-llama don't) — match the url: prefix, not a specific suffix.
  pin_line="$(printf '%s\n' "$content" | grep -m1 'url: "https://github.com/ManifoldKit/ManifoldKit' || true)"

  if [ -z "$pin_line" ]; then
    note_drift "$repo" "core-pin" "no 'ManifoldKit/ManifoldKit' package dependency line found in Package.swift"
    return
  fi

  pin_version="$(printf '%s\n' "$pin_line" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
  if [ -z "$pin_version" ]; then
    note_drift "$repo" "core-pin" "found a ManifoldKit dependency line but could not extract a version: $pin_line"
    return
  fi

  if [ "$require_exact" = "yes" ]; then
    if ! printf '%s\n' "$pin_line" | grep -q 'exact:'; then
      note_drift "$repo" "exact-pin" "expected an 'exact:' pin per RELEASE-PROCESS.md, found: $pin_line"
    else
      note_pass "$repo" "exact-pin" "pins with exact:"
    fi
  fi

  if [ "$pin_version" != "$latest_core_version" ]; then
    note_drift "$repo" "core-pin" "Package.swift core pin is $pin_version, latest core tag is $latest_core_version"
  else
    note_pass "$repo" "core-pin" "$pin_version matches latest core tag"
  fi
}

check_companion_pin manifold-mlx no
check_companion_pin manifold-llama no
check_companion_pin manifold-eval yes

# ---------------------------------------------------------------------------
# Invariant 3: no stale open release-please PR
# ---------------------------------------------------------------------------
check_release_pr_age() {
  # check_release_pr_age <repo>
  repo="$1"

  prs_fixture="$(fixture_file "${repo}-open-prs.json")"
  if [ -n "$prs_fixture" ]; then
    prs_json="$(cat "$prs_fixture")"
  else
    prs_json="$(gh pr list --repo "ManifoldKit/${repo}" --state open \
      --json number,headRefName,createdAt \
      --jq '[.[] | select(.headRefName == "release-please--branches--main")]')"
  fi

  pr_count="$(printf '%s' "$prs_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
  if [ "$pr_count" -eq 0 ]; then
    note_pass "$repo" "release-pr-age" "no open release-please PR"
    return
  fi

  created_at="$(printf '%s' "$prs_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["createdAt"])')"
  pr_number="$(printf '%s' "$prs_json" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["number"])')"

  age_days="$(python3 -c "
import sys
from datetime import datetime, timezone
created = datetime.strptime('$created_at', '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
now = datetime.now(timezone.utc)
print((now - created).days)
")"

  if [ "$age_days" -gt "$max_age_days" ]; then
    note_drift "$repo" "release-pr-age" "PR #${pr_number} (release-please--branches--main) has been open ${age_days}d, exceeds --max-age-days ${max_age_days}"
  else
    note_pass "$repo" "release-pr-age" "PR #${pr_number} open ${age_days}d, within ${max_age_days}d budget"
  fi
}

check_release_pr_age manifold-mlx
check_release_pr_age manifold-llama
check_release_pr_age manifold-eval

# ---------------------------------------------------------------------------
echo ""
if [ "$drift_count" -gt 0 ]; then
  echo "::error::release-train-check: ${drift_count} invariant(s) drifted — see DRIFT lines above."
  exit 1
fi
echo "release-train-check: all invariants green."
