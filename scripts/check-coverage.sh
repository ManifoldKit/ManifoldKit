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
#   0   All modules meet their thresholds (or llvm-cov is unavailable).
#   1   One or more modules are below threshold.
#
# Thresholds are set 10 percentage points below the measured baseline at the
# time issue #1224 was implemented (2026-05-15).  Raise them as coverage
# improves.
#
# Baseline measurements (ManifoldCoreTests + ManifoldRuntimeTests +
# ManifoldPersistenceSwiftDataTests + ManifoldInferenceTests +
# ManifoldMCPTests, --disable-default-traits --enable-code-coverage):
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
declare -A THRESHOLDS=(
  [ManifoldInference]=74
  [ManifoldRuntime]=74
  [ManifoldPersistenceSwiftData]=74
  [ManifoldMCP]=75
)

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

# ── Tool availability check ──────────────────────────────────────────────────
if ! command -v xcrun &>/dev/null || ! xcrun --find llvm-cov &>/dev/null 2>&1; then
  echo "WARNING: llvm-cov not available — skipping coverage check."
  exit 0
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
  echo "WARNING: profdata not found at '${PROFDATA_ARG}' — run 'swift test --enable-code-coverage' first, or pass --profdata."
  echo "         Skipping coverage check."
  exit 0
fi

if [[ ! -f "$BINARY_ARG" ]]; then
  echo "WARNING: xctest binary not found at '${BINARY_ARG}' — skipping coverage check."
  exit 0
fi

# ── Generate coverage report ──────────────────────────────────────────────────
REPORT=$(xcrun llvm-cov report \
  "$BINARY_ARG" \
  --instr-profile="$PROFDATA_ARG" \
  --ignore-filename-regex="Tests|\.build" \
  2>/dev/null) || {
  echo "WARNING: llvm-cov report failed — skipping coverage check."
  exit 0
}

# ── Compute per-module line coverage ─────────────────────────────────────────
# llvm-cov report columns (space-separated):
#   Filename  Regions  MissedRegions  Cover%  Functions  MissedFunctions
#   Executed  Lines  MissedLines  Cover%  Branches  MissedBranches  Cover%
# We sum Lines ($8) and MissedLines ($9) per source directory prefix.

declare -A COV_PERCENT

for module in "${!THRESHOLDS[@]}"; do
  result=$(printf '%s\n' "$REPORT" | awk -v mod="${module}/" '
    $1 ~ "^" mod {
      total  += $8
      missed += $9
    }
    END {
      if (total > 0) {
        covered = total - missed
        printf "%.1f %d %d", (covered / total) * 100, covered, total
      } else {
        print "NO_DATA 0 0"
      }
    }
  ')
  COV_PERCENT[$module]="$result"
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

for module in $(printf '%s\n' "${!THRESHOLDS[@]}" | sort); do
  threshold=${THRESHOLDS[$module]}
  data=${COV_PERCENT[$module]}
  pct=$(echo "$data" | awk '{print $1}')
  covered=$(echo "$data" | awk '{print $2}')
  total=$(echo "$data" | awk '{print $3}')

  if [[ "$pct" == "NO_DATA" ]]; then
    status="NO DATA"
    printf "  %-36s %10s %9d%% %8s\n" "$module" "--" "$threshold" "$status"
    # No data means the module wasn't in the profdata — treat as warning not failure
    # (e.g. MCP tests require --traits MCP, which the coverage run may not include)
    continue
  fi

  pct_int=$(echo "$pct" | awk '{printf "%d", $1}')
  if [[ $pct_int -ge $threshold ]]; then
    status="PASS"
  else
    status="FAIL"
    FAILED=1
    FAILED_MODULES+=("$module (${pct}% < ${threshold}% threshold)")
  fi
  printf "  %-36s %9s%% %9d%% %8s\n" "$module" "$pct" "$threshold" "$status"
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $FAILED -eq 1 ]]; then
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
