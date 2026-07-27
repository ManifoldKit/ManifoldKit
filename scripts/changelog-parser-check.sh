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
# Usage:  scripts/changelog-parser-check.sh [--per-pr] [--repo PATH] [BASE_TAG] [HEAD_REF]
#         (`--repo` points the history/config read at another git repository;
#         the pinned release-please install always comes from THIS script's
#         own directory. CI never passes it — it exists so this gate's own
#         test suite can run against a synthetic fixture repo instead of
#         this repo's real tags, which the `test` job's `fetch-depth: 2`
#         tagless checkout cannot resolve.)
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

# Every invocation shares one CHECK_DIR/node_modules, and every invocation
# re-runs `npm ci` against it (below). Two concurrent invocations racing on
# the same directory corrupt each other's install rather than failing
# cleanly — reproduced live: this repo's own test suite spawns this script
# from multiple XCTest methods, and under `swift test --parallel` (which
# CI always uses) that raced and produced truncated/interleaved npm output
# instead of either script's real result. `mkdir` is atomic on every
# platform this runs on (Linux CI, macOS CI, local dev) with no extra
# binary required, unlike `flock(1)` (not present on macOS by default) —
# a portable mutex, not a workaround for one caller.
LOCK_DIR="${CHECK_DIR}/.install.lock"
lock_acquired=false
for _ in $(seq 1 300); do
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    lock_acquired=true
    break
  fi
  sleep 0.2
done
if [ "$lock_acquired" != true ]; then
  echo "::error::changelog-parser-check: could not acquire the install lock at ${LOCK_DIR} after 60s — a concurrent invocation may be stuck; remove that directory by hand if it's stale"
  exit 1
fi
# Lock cleanup on exit — a failed rmdir (lock dir already gone,
# permissions) doesn't affect the check's own pass/fail verdict above; a
# genuinely stuck lock is caught by the NEXT invocation's 60s timeout, not
# silently.
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT  # fail-open-ok: cleanup-on-exit, not a correctness path

# `npm ci` is not wrapped in any tolerance — a failed install (registry
# unreachable, lockfile drift) must fail this check loudly, not silently
# skip past the parser it exists to run.
( cd "$CHECK_DIR" && npm ci --no-audit --no-fund )

node "${CHECK_DIR}/check.mjs" "$@"
