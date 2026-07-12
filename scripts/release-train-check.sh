#!/usr/bin/env bash
# scripts/release-train-check.sh — release-train version-matrix tripwire (#2224)
#
# The core repo release-please -> repository_dispatch -> per-companion
# core-bump.yml chain (see ManifoldKit/.github RELEASE-PROCESS.md and this
# repo's own RELEASE.md) has no single source of truth for whether the
# family is actually coherent right now. A drifted pin is invisible until a
# companion build fails or an eval run silently tests stale core behavior.
# This script asserts the invariants those docs describe; it does not
# redefine them.
#
# Checks four invariants against manifold-mlx, manifold-llama, manifold-eval:
#   1. manifold-mlx / manifold-llama pin `.upToNextMinor(from:)` and float
#      automatically on core PATCH releases (RELEASE.md: "PATCH bump:
#      llama/mlx float automatically ... no companion release needed") — so
#      their pin is compared against the latest core MINOR (X.Y.0), not the
#      literal latest tag, to avoid a false DRIFT on every patch release.
#   2. manifold-eval pins with `exact:` (not a range) and tracks the literal
#      latest core tag (RELEASE.md: "manifold-eval has no release-please and
#      needs no tagged release; it only re-resolves its exact core pin").
#   3. No open bump PR has sat past --max-age-days: manifold-mlx / llama via
#      their `release-please--branches--main` branch, manifold-eval via its
#      `auto/bump-manifoldkit-*` core-bump.yml branch (eval has NO
#      release-please branch for core-pin bumps — checking for one there
#      would always vacuously pass; see manifold-eval's core-bump.yml).
#   4. This repo's README.md install-pin snippet matches the latest core tag.
#
# On ANY drift, prints "DRIFT: <repo> <invariant> — <detail>" and exits 1.
# Names the specific repo + invariant — never just "drift detected somewhere".
# A transient network failure while checking an invariant is reported as a
# distinct "CHECK-ERROR" (still a non-zero exit, so it's never silently
# swallowed) rather than masquerading as either a PASS or a real DRIFT.
#
# Bash 3.2 compatible (CI/macOS default); no associative arrays, no ${var^}.
#
# Note: invariant 4 overlaps with scripts/check-readme.sh's own README
# version-pin check — that's fine (redundant-safe, different failure mode:
# check-readme.sh compares README against version.txt at PR time,
# this compares README against the actual latest git tag nightly), but this
# script is not the only README-pin gate.
#
# Usage:
#   scripts/release-train-check.sh [--max-age-days N] [--fixture-dir DIR]
#
# --fixture-dir DIR lets a caller override individual data sources for
# testing, without touching the network for the parts under test. Recognized
# fixture files (all optional — anything absent falls back to a live fetch):
#   DIR/version.txt                 latest core version override, e.g. "0.70.0"
#   DIR/readme.md                   README.md content override
#   DIR/<repo>-package.swift        companion Package.swift content override
#   DIR/<repo>-open-prs.json        pre-filtered `gh pr list` JSON array override
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

note_check_error() {
  # note_check_error <repo> <invariant> <detail> — a transient failure of the
  # check itself (e.g. a flaky gh api call), not a confirmed invariant
  # violation. Still fails the run (nothing here should be silently
  # swallowed) but is labeled distinctly so a human doesn't treat it as a
  # confirmed drift.
  echo "::error::CHECK-ERROR: $1 $2 — $3"
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
# Latest core version — version.txt is this repo's existing single source of
# truth (also used by scripts/check-readme.sh and scripts/generate-sbom.sh);
# deriving it independently from `git tag` risked the two notions of
# "current version" drifting apart. Sanity-check that a matching tag exists
# (warn, don't drift — a tag can lag version.txt by the few seconds between
# release-please's manifest commit and its tag push).
# ---------------------------------------------------------------------------
version_txt_fixture="$(fixture_file version.txt)"
if [ -n "$version_txt_fixture" ]; then
  latest_core_version="$(tr -d '[:space:]' < "$version_txt_fixture")"
else
  latest_core_version="$(tr -d '[:space:]' < "$repo_root/version.txt")"
fi
if ! printf '%s' "$latest_core_version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "::error::version.txt did not yield an X.Y.Z version (got: '$latest_core_version')" >&2
  exit 2
fi
latest_core_tag="v${latest_core_version}"
latest_core_minor_floor="$(printf '%s' "$latest_core_version" | awk -F. '{print $1"."$2".0"}')"

if [ -z "$version_txt_fixture" ]; then
  if ! git -C "$repo_root" tag -l "$latest_core_tag" | grep -q .; then
    echo "::warning::no local git tag '$latest_core_tag' matching version.txt — checkout may be shallow or the tag push is still in flight; not treated as drift" >&2
  fi
fi

echo "Latest core version: $latest_core_version (minor floor $latest_core_minor_floor)"

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
  note_drift "ManifoldKit/ManifoldKit" "README-pin" "README.md install pin is $readme_pin_version, latest core version is $latest_core_version (release-please's extra-files bump may have broken)"
else
  note_pass "ManifoldKit/ManifoldKit" "README-pin" "$readme_pin_version matches latest core version"
fi

# ---------------------------------------------------------------------------
# Invariants 1 + 2: companion / eval core pins
# ---------------------------------------------------------------------------
fetch_package_swift() {
  # fetch_package_swift <repo> -> prints Package.swift content to stdout;
  # returns non-zero (after one retry) on a live-fetch failure.
  repo="$1"
  pkg_fixture="$(fixture_file "${repo}-package.swift")"
  if [ -n "$pkg_fixture" ]; then
    cat "$pkg_fixture"
    return 0
  fi
  if gh api "repos/ManifoldKit/${repo}/contents/Package.swift" -q .content 2>/dev/null | base64 -d 2>/dev/null; then
    return 0
  fi
  sleep 2
  gh api "repos/ManifoldKit/${repo}/contents/Package.swift" -q .content 2>/dev/null | base64 -d 2>/dev/null
}

check_companion_pin() {
  # check_companion_pin <repo> <require_exact: yes|no>
  repo="$1"
  require_exact="$2"

  if [ "$require_exact" = "yes" ]; then
    expected_version="$latest_core_version"
    expected_label="latest core version"
  else
    expected_version="$latest_core_minor_floor"
    expected_label="latest core minor floor (.upToNextMinor floats on patch releases)"
  fi

  if ! content="$(fetch_package_swift "$repo")"; then
    note_check_error "$repo" "core-pin" "gh api fetch of Package.swift failed after retry (transient error?) — could not verify core-pin invariant this run"
    return
  fi

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
      note_drift "$repo" "exact-pin" "expected an 'exact:' pin per RELEASE.md, found: $pin_line"
    else
      note_pass "$repo" "exact-pin" "pins with exact:"
    fi
  fi

  if [ "$pin_version" != "$expected_version" ]; then
    note_drift "$repo" "core-pin" "Package.swift core pin is $pin_version, expected $expected_version ($expected_label)"
  else
    note_pass "$repo" "core-pin" "$pin_version matches $expected_label"
  fi
}

check_companion_pin manifold-mlx no
check_companion_pin manifold-llama no
check_companion_pin manifold-eval yes

# ---------------------------------------------------------------------------
# Invariant 3: no stale open bump PR
# ---------------------------------------------------------------------------
fetch_open_prs() {
  # fetch_open_prs <repo> <branch_match> <match_type: exact|prefix> -> prints
  # a JSON array to stdout; returns non-zero (after one retry) on failure.
  repo="$1"
  branch_match="$2"
  match_type="$3"

  if [ "$match_type" = "prefix" ]; then
    jq_filter='[.[] | select(.headRefName | startswith("'"$branch_match"'"))]'
  else
    jq_filter='[.[] | select(.headRefName == "'"$branch_match"'")]'
  fi

  if gh pr list --repo "ManifoldKit/${repo}" --state open \
      --json number,headRefName,createdAt --jq "$jq_filter" 2>/dev/null; then
    return 0
  fi
  sleep 2
  gh pr list --repo "ManifoldKit/${repo}" --state open \
    --json number,headRefName,createdAt --jq "$jq_filter" 2>/dev/null
}

check_release_pr_age() {
  # check_release_pr_age <repo> <branch_match> <match_type: exact|prefix> <label>
  repo="$1"
  branch_match="$2"
  match_type="$3"
  label="$4"

  prs_fixture="$(fixture_file "${repo}-open-prs.json")"
  if [ -n "$prs_fixture" ]; then
    prs_json="$(cat "$prs_fixture")"
  elif ! prs_json="$(fetch_open_prs "$repo" "$branch_match" "$match_type")"; then
    note_check_error "$repo" "release-pr-age" "gh pr list failed after retry (transient error?) — could not verify stale-$label-PR invariant this run"
    return
  fi

  pr_count="$(printf '%s' "$prs_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
  if [ "$pr_count" -eq 0 ]; then
    note_pass "$repo" "release-pr-age" "no open $label PR"
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
    note_drift "$repo" "release-pr-age" "$label PR #${pr_number} has been open ${age_days}d, exceeds --max-age-days ${max_age_days}"
  else
    note_pass "$repo" "release-pr-age" "$label PR #${pr_number} open ${age_days}d, within ${max_age_days}d budget"
  fi
}

# manifold-mlx / manifold-llama have their own release-please (RELEASE.md:
# "llama and mlx have release-please, so they get a tagged release the same
# way core does"), so their stale-bump signal is the standard
# release-please--branches--main PR.
check_release_pr_age manifold-mlx "release-please--branches--main" exact "release-please"
check_release_pr_age manifold-llama "release-please--branches--main" exact "release-please"
# manifold-eval has NO release-please branch for core-pin bumps — its pin is
# rewritten by its own core-bump.yml, which opens (and normally
# auto-merges) a PR on an "auto/bump-manifoldkit-<tag>" branch. Checking the
# release-please branch name here would always vacuously pass since eval
# never opens one for this purpose (eval's separate release-please, added
# for its own feat:/fix: work, is out of scope for the core-pin invariant).
check_release_pr_age manifold-eval "auto/bump-manifoldkit-" prefix "core-bump"

# ---------------------------------------------------------------------------
echo ""
if [ "$drift_count" -gt 0 ]; then
  echo "::error::release-train-check: ${drift_count} issue(s) found — see DRIFT/CHECK-ERROR lines above."
  exit 1
fi
echo "release-train-check: all invariants green."
