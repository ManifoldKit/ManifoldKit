#!/usr/bin/env bash
#
# changelog-parser-check.sh — install the pinned release-please dependency
# and run scripts/changelog-parser-check/check.mjs, which re-runs
# release-please's own commit parser over every releasable commit in range
# and reds on any commit release-please itself would silently drop (#2380).
#
# This is the CI-side gate: unlike scripts/changelog-coverage-check.sh (which
# compares against CHANGELOG.md's text and therefore only means anything
# while that text is release-please's own generated bullets, not the
# hand-rewritten Highlights — see AGENTS.md § Release workflow), this check
# never looks at CHANGELOG.md's content, has no editorial-omission
# false-positive surface, and fires on ANY push by ANY actor to the release
# PR — including the operator's own Prisma-rewrite pushes, which is what
# makes it immune to the `action_required` blockade documented in
# AGENTS.md § Release workflow (bot-triggered workflow runs on the
# release-please branch never execute under this repo's current Actions
# settings; runs by a human actor do).
#
# Usage:  scripts/changelog-parser-check.sh [--per-pr] [BASE_TAG] [HEAD_REF]
#         (all optional — see check.mjs's own header for the defaults and
#         what --per-pr changes). Run with NO arguments today, this reds
#         unfixably on a historical commit: BASE_TAG defaults to v0.73.0
#         (derived from CHANGELOG.md's second header), and that range still
#         contains f95f6428, the already-published #2375 defect. That's
#         expected for a human poking at the bare form by hand — it
#         self-heals at the next real release, and CI never invokes this
#         script without an explicit range (see lint.yml).
#
# Exit 0 = every releasable commit in range parses cleanly (or, with
# --per-pr, there were none to check). Exit 1 = at least one doesn't, or the
# npm install itself failed — an install failure is a hard failure here,
# never a silent skip, so a broken/unreachable registry can't turn this
# into inert machinery that looks like a gate.
#
# Bash 3.2 compatible (CI runners ship Bash 3.2 — no `declare -A`, no
# `${var^^}`).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK_DIR="${REPO_ROOT}/scripts/changelog-parser-check"

if ! command -v node >/dev/null 2>&1; then
  echo "::error::changelog-parser-check: node is required but not on PATH"
  exit 1
fi

if ! command -v npm >/dev/null 2>&1; then
  echo "::error::changelog-parser-check: npm is required but not on PATH"
  exit 1
fi

if [ ! -f "${CHECK_DIR}/package-lock.json" ]; then
  echo "::error::changelog-parser-check: ${CHECK_DIR}/package-lock.json not found — pinned dependency install would be non-reproducible"
  exit 1
fi

# `npm ci` is not wrapped in any tolerance — a failed install (registry
# unreachable, lockfile drift) must fail this check loudly, not silently
# skip past the parser it exists to run.
( cd "$CHECK_DIR" && npm ci --no-audit --no-fund )

node "${CHECK_DIR}/check.mjs" "$@"
