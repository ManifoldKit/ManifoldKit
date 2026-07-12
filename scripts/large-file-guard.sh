#!/bin/bash
# large-file-guard.sh — fail if a PR adds any file over 1MB.
#
# Usage: large-file-guard.sh <base-ref> <head-ref>
#
# Computes the merge base between base-ref and head-ref, diffs for ADDED
# files only (--diff-filter=A) so a rename/move of a pre-existing large file
# never false-positives, then checks each added file's blob size via
# `git cat-file -s`.
#
# Written for POSIX sh / Bash 3.2 (no `declare -A`, no associative arrays,
# no `mapfile`) — CI runners (ubuntu-latest) ship Bash 3.2 for
# non-interactive invocation. Tested locally under `/bin/bash`.
set -euo pipefail

BASE_REF="${1:?usage: large-file-guard.sh <base-ref> <head-ref>}"
HEAD_REF="${2:?usage: large-file-guard.sh <base-ref> <head-ref>}"

LIMIT_BYTES=$((1024 * 1024))

MERGE_BASE=$(git merge-base "$BASE_REF" "$HEAD_REF")

# Newly added files only. `-z` + `read -d ''` handles filenames with spaces;
# NUL-delimited output avoids any shell-quoting hazard.
violations=0
while IFS= read -r -d '' file; do
  # File may have been added then deleted later in the same diff range —
  # skip anything no longer present at HEAD.
  if ! git cat-file -e "${HEAD_REF}:${file}" 2>/dev/null; then
    continue
  fi
  size=$(git cat-file -s "${HEAD_REF}:${file}")
  if [ "$size" -gt "$LIMIT_BYTES" ]; then
    human=$((size / 1024 / 1024))
    echo "::error file=${file}::Added file '${file}' is ${human}MB (limit: 1MB). Large binary/artifact additions usually indicate a stray build output or run-artifact tree — remove it or use Git LFS if it must be tracked."
    violations=$((violations + 1))
  fi
done < <(git diff -z -M --diff-filter=A --name-only "${MERGE_BASE}" "${HEAD_REF}")

if [ "$violations" -gt 0 ]; then
  echo "::error::${violations} newly added file(s) exceed the 1MB limit."
  exit 1
fi

echo "OK: no newly added file exceeds 1MB."
