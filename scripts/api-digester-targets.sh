#!/usr/bin/env bash
# scripts/api-digester-targets.sh — shared --targets list for the API digester.
#
# Prints space-safe `--targets <Name>` pairs for every `.library()` product
# listed in scripts/api-digester-targets.txt. Sourced by ci.yml and
# nightly-slow-tests.yml so the two digester invocations cannot drift.
#
# Usage (bash 3.2-safe, CI runners ship Bash 3.2):
#   TARGETS=()
#   while IFS= read -r flag; do
#     TARGETS+=("$flag")
#   done < <(scripts/api-digester-targets.sh)
#   # TARGETS is now (--targets Name --targets Name2 ...)
#
# Or expand inline:
#   swift package diagnose-api-breaking-changes "$BASELINE" $(scripts/api-digester-targets.sh) \
#     --breakage-allowlist-path .github/api-breakage-allowlist.txt
#
# Exit 1 if the list file is missing or empty (fail closed — never silently
# digester zero targets).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIST_FILE="${SCRIPT_DIR}/api-digester-targets.txt"

if [[ ! -f "$LIST_FILE" ]]; then
  echo "error: missing $LIST_FILE" >&2
  exit 1
fi

count=0
while IFS= read -r line || [[ -n "$line" ]]; do
  # Strip CR (Windows checkouts) and leading/trailing whitespace.
  line="${line%$'\r'}"
  # Skip blank lines and comments.
  case "$line" in
    ''|\#*) continue ;;
  esac
  # First whitespace-delimited token is the product name.
  name="${line%%[[:space:]]*}"
  [[ -z "$name" ]] && continue
  printf '%s\n' "--targets"
  printf '%s\n' "$name"
  count=$((count + 1))
done < "$LIST_FILE"

if [[ "$count" -eq 0 ]]; then
  echo "error: $LIST_FILE produced zero targets" >&2
  exit 1
fi
