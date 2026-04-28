#!/usr/bin/env bash
# scripts/cleanup-merged-branches.sh — Remove stale local branches and
# clean up leftover worktree-agent branches.
#
# Two categories of branches are removed:
#
#   1. worktree-agent-* branches (pattern: worktree-agent-[a-z0-9]+)
#      These are always stale once the isolation worktree is gone. Deleted
#      unconditionally with `git branch -D` because they are never directly
#      pushed to origin and are safe to force-delete.
#
#   2. Branches whose upstream tracking ref has been deleted on origin
#      (i.e., the remote was auto-deleted after a squash-merge). Git reports
#      these as "[gone]" in `git branch -vv`. Deleted with `git branch -D`
#      since `git branch -d` refuses these even when the merge is complete.
#
# What this script does NOT do:
#   - Touch remote branches
#   - Delete `main` or the currently checked-out branch
#   - Touch branches with no upstream at all (untracked local branches)
#   - Require any arguments
#
# Usage:
#   scripts/cleanup-merged-branches.sh

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PACKAGE_DIR"

# ── Fetch + prune ─────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Fetching and pruning remote refs"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
git fetch --prune origin
echo ""

# ── Determine protected names ─────────────────────────────────────────────────
CURRENT_BRANCH="$(git rev-parse --abbrev-ref HEAD)"

# ── Collect branch info ───────────────────────────────────────────────────────
# `git branch -vv` format (examples):
#   * main              abc1234 [origin/main] commit msg
#     my-feature        def5678 [origin/my-feature: gone] commit msg
#     local-only        ghi9012 commit msg (no upstream)
#     worktree-agent-x  jkl3456 commit msg

DELETED_AGENT=()
DELETED_GONE=()
SKIPPED=()

while IFS= read -r line; do
    # Strip leading marker (* or space) and trim whitespace
    branch="$(printf '%s' "$line" | sed 's/^[* ]*//' | awk '{print $1}')"

    # Never touch main or the current branch
    if [[ "$branch" == "main" || "$branch" == "$CURRENT_BRANCH" ]]; then
        continue
    fi

    # ── Category 1: worktree-agent-* ──────────────────────────────────────────
    if [[ "$branch" =~ ^worktree-agent-[a-z0-9]+$ ]]; then
        if git branch -D "$branch" 2>/dev/null; then
            DELETED_AGENT+=("$branch")
        else
            SKIPPED+=("$branch  (delete failed)")
        fi
        continue
    fi

    # ── Category 2: upstream gone ─────────────────────────────────────────────
    # `git branch -vv` includes "[origin/foo: gone]" for deleted remotes.
    if printf '%s' "$line" | grep -qF ': gone]'; then
        if git branch -D "$branch" 2>/dev/null; then
            DELETED_GONE+=("$branch")
        else
            SKIPPED+=("$branch  (delete failed)")
        fi
        continue
    fi

    # ── Everything else: skip ─────────────────────────────────────────────────
    # Includes branches with no upstream and branches whose upstream still exists.

done < <(git branch -vv)

# ── Summary ───────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  CLEANUP SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ ${#DELETED_AGENT[@]} -gt 0 ]]; then
    printf "  Deleted worktree-agent branches (%d):\n" "${#DELETED_AGENT[@]}"
    for b in "${DELETED_AGENT[@]}"; do
        printf "    - %s\n" "$b"
    done
else
    echo "  Deleted worktree-agent branches: none"
fi
echo ""

if [[ ${#DELETED_GONE[@]} -gt 0 ]]; then
    printf "  Deleted gone-upstream branches (%d):\n" "${#DELETED_GONE[@]}"
    for b in "${DELETED_GONE[@]}"; do
        printf "    - %s\n" "$b"
    done
else
    echo "  Deleted gone-upstream branches: none"
fi
echo ""

if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    printf "  Skipped (%d):\n" "${#SKIPPED[@]}"
    for b in "${SKIPPED[@]}"; do
        printf "    - %s\n" "$b"
    done
    echo ""
fi

TOTAL_DELETED=$(( ${#DELETED_AGENT[@]} + ${#DELETED_GONE[@]} ))
printf "  Total deleted: %d\n" "$TOTAL_DELETED"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
