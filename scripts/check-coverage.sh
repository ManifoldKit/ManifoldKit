#!/usr/bin/env bash
# scripts/check-coverage.sh — Verify per-module line coverage against thresholds.
#
# Usage:
#   scripts/check-coverage.sh [--profdata <path>] [--binary <path>]
#
# When called with no arguments the script discovers the most recent profdata
# and xctest binary under .build/arm64-apple-macosx/debug (or .build/debug as
# a fallback).  Pass explicit paths when you want to check a specific run.
#
# Exit codes:
#   0   Every configured module has valid measured line coverage at or above
#       its threshold.
#   1   A complete, valid measurement found one or more modules below threshold.
#   2   Coverage could not be measured or parsed (missing tooling or inputs,
#       failed report, or invalid/incomplete module data).
#
# Thresholds are set 10 percentage points below the measured baseline at the
# time issue #1224 was implemented (2026-05-15).  Raise them as coverage
# improves.
#
# Baseline measurements (ManifoldCoreTests + ManifoldRuntimeTests +
# ManifoldPersistenceSwiftDataTests + ManifoldInferenceTests +
# ManifoldMCPTests, --enable-code-coverage):
#
#   ManifoldInference            84.0%  -> threshold 74%
#   ManifoldRuntime              84.2%  -> threshold 74%
#   ManifoldPersistenceSwiftData 84.7%  -> threshold 74%
#   ManifoldMCP                  85.5%  -> threshold 75%

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PACKAGE_DIR"

# ── Thresholds (integer percent) ─────────────────────────────────────────────
# Parallel arrays instead of `declare -A` — bash 3.2 (the default on macOS
# GitHub runners) parses `[ManifoldInference]=74` as arithmetic indexing and
# fails under `set -u` with "ManifoldInference: unbound variable".
MODULES=(ManifoldInference ManifoldRuntime ManifoldPersistenceSwiftData ManifoldMCP)
THRESHOLDS=(74 74 74 75)

# ── Argument parsing ──────────────────────────────────────────────────────────
PROFDATA_ARG=""
BINARY_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profdata)
      PROFDATA_ARG="${2:?'--profdata requires a path'}"
      shift 2
      ;;
    --binary)
      BINARY_ARG="${2:?'--binary requires a path'}"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

# ── Operational failures ─────────────────────────────────────────────────────
operational_failure() {
  echo "ERROR: coverage measurement unavailable: $*" >&2
  exit 2
}

# ── Tool availability check ──────────────────────────────────────────────────
if ! command -v xcrun &>/dev/null || ! xcrun --find llvm-cov &>/dev/null 2>&1; then
  operational_failure "xcrun could not locate llvm-cov"
fi

# ── Discover profdata and binary ─────────────────────────────────────────────
ARCH_DEBUG=""
for candidate in \
  .build/arm64-apple-macosx/debug \
  .build/x86_64-apple-macosx/debug \
  .build/debug; do
  if [[ -d "$candidate" ]]; then
    ARCH_DEBUG="$candidate"
    break
  fi
done

if [[ -z "$PROFDATA_ARG" ]]; then
  if [[ -n "$ARCH_DEBUG" ]]; then
    PROFDATA_ARG="$ARCH_DEBUG/codecov/default.profdata"
  fi
fi

if [[ -z "$BINARY_ARG" ]]; then
  if [[ -n "$ARCH_DEBUG" ]]; then
    XCTEST=$(find "$ARCH_DEBUG" -maxdepth 1 -name "*.xctest" 2>/dev/null | head -1)
    if [[ -n "$XCTEST" ]]; then
      BUNDLE_NAME=$(basename "$XCTEST" .xctest)
      BINARY_ARG="$XCTEST/Contents/MacOS/$BUNDLE_NAME"
    fi
  fi
fi

if [[ ! -f "$PROFDATA_ARG" ]]; then
  operational_failure "profdata not found at '${PROFDATA_ARG}' — run 'swift test --enable-code-coverage' first, or pass --profdata"
fi

if [[ ! -f "$BINARY_ARG" ]]; then
  operational_failure "xctest binary not found at '${BINARY_ARG}'"
fi

# ── Generate coverage report ──────────────────────────────────────────────────
if ! REPORT=$(xcrun llvm-cov report \
  "$BINARY_ARG" \
  --instr-profile="$PROFDATA_ARG" \
  --ignore-filename-regex="Tests|\.build" \
  2>&1); then
  operational_failure "llvm-cov report failed: ${REPORT}"
fi

# Consume the complete report in one linear pass. Bash 3.2's global
# whitespace substitution repeatedly copies a large report and makes this
# otherwise small check disproportionately slow.
if ! printf '%s\n' "$REPORT" | awk 'NF { found = 1 } END { exit !found }'; then
  operational_failure "llvm-cov report was empty"
fi

# ── Compute per-module line coverage ─────────────────────────────────────────
# llvm-cov report columns (space-separated):
#   Filename  Regions  MissedRegions  Cover%  Functions  MissedFunctions
#   Executed  Lines  MissedLines  Cover%  Branches  MissedBranches  Cover%
# We sum Lines ($8) and MissedLines ($9) for each module. llvm-cov reports
# source paths relative to the package in some invocations and absolute paths
# in others, so match the module as a path component with an optional Sources/
# prefix rather than assuming a single report-root spelling.

COV_RESULTS=()
# Keep every count within signed 32-bit range before it reaches awk's `%d`
# formatter or the Bash threshold multiplication below. Coverage reports this
# package's source lines, not an unbounded input protocol; a larger value is
# malformed measurement data, never evidence that a threshold passed.
MAX_SAFE_LINE_COUNT=2147483647

for module in "${MODULES[@]}"; do
  result=$(printf '%s\n' "$REPORT" | awk -v mod="$module" -v max="$MAX_SAFE_LINE_COUNT" '
    function isModulePath(path) {
      return path ~ ("(^|/)(Sources/)?" mod "/")
    }

    isModulePath($1) {
      matched = 1
      if (NF < 9 || $8 !~ /^[0-9]+$/ || $9 !~ /^[0-9]+$/) {
        invalid = 1
        next
      }

      lines = $8 + 0
      missedLines = $9 + 0
      # A declaration-only source file can legitimately have zero executable
      # lines. The module aggregate below must still have a nonzero denominator.
      if (lines > max || missedLines > max || missedLines > lines) {
        invalid = 1
        next
      }

      total += lines
      missed += missedLines
    }

    END {
      if (!matched) {
        print "NO_DATA 0 0"
      } else if (invalid || total <= 0 || total > max || missed > max || missed > total) {
        print "INVALID 0 0"
      } else {
        covered = total - missed
        printf "%.1f %d %d", (covered / total) * 100, covered, total
      }
    }
  ')
  COV_RESULTS+=("$result")
done

# ── Print summary table ───────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  CODE COVERAGE THRESHOLDS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  %-36s %10s %10s %8s\n" "Module" "Coverage" "Threshold" "Status"
echo "  ─────────────────────────────────────────────────────────────────"

FAILED=0
FAILED_MODULES=()
INVALID_MODULES=()

# Build sorted index list so output matches the previous alphabetical order.
SORTED_INDEXES=$(for i in "${!MODULES[@]}"; do printf '%s\t%d\n' "${MODULES[$i]}" "$i"; done | sort | awk '{print $2}')

for i in $SORTED_INDEXES; do
  module=${MODULES[$i]}
  threshold=${THRESHOLDS[$i]}
  data=${COV_RESULTS[$i]}
  pct=$(echo "$data" | awk '{print $1}')
  covered=$(echo "$data" | awk '{print $2}')
  total=$(echo "$data" | awk '{print $3}')

  if [[ "$pct" == "NO_DATA" || "$pct" == "INVALID" ]]; then
    status="INVALID"
    printf "  %-36s %10s %9d%% %8s\n" "$module" "--" "$threshold" "$status"
    if [[ "$pct" == "NO_DATA" ]]; then
      INVALID_MODULES+=("$module (no report rows)")
    else
      INVALID_MODULES+=("$module (malformed or impossible line counts)")
    fi
    continue
  fi

  # Compare the raw line counts, not the one-decimal display value: 73.96%
  # must not pass a 74% threshold merely because it renders as 74.0%.
  if (( covered * 100 >= total * threshold )); then
    status="PASS"
  else
    status="FAIL"
    FAILED=1
    FAILED_MODULES+=("$module (${pct}% < ${threshold}% threshold)")
  fi
  printf "  %-36s %9s%% %9d%% %8s\n" "$module" "$pct" "$threshold" "$status"
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ ${#INVALID_MODULES[@]} -gt 0 ]]; then
  echo ""
  echo "  COVERAGE MEASUREMENT INVALID in ${#INVALID_MODULES[@]} module(s):"
  for m in "${INVALID_MODULES[@]}"; do
    echo "    - $m"
  done
  echo ""
  echo "  A successful coverage check requires valid nonzero line counts for every configured module."
  echo ""
  exit 2
elif [[ $FAILED -eq 1 ]]; then
  echo ""
  echo "  COVERAGE BELOW THRESHOLD in ${#FAILED_MODULES[@]} module(s):"
  for m in "${FAILED_MODULES[@]}"; do
    echo "    - $m"
  done
  echo ""
  echo "  To investigate: xcrun llvm-cov report <binary> --instr-profile=<profdata>"
  echo "                  --ignore-filename-regex='Tests|\.build'"
  echo ""
  exit 1
else
  echo "  RESULT: All modules meet coverage thresholds."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi
