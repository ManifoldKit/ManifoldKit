#!/usr/bin/env bash
# scripts/ci-selective-test.sh — Tier 2 compile-pruned selective CI runner.
#
# Receives the space-separated affected-suite list from Tier 0
# (affected-suites.sh) and routes each suite to the fastest correct test path.
#
# Routing rules:
#   - Suite has a .xcscheme AND is not trait-gated
#       → xcodebuild test -scheme (compiles only the subgraph, not the full bundle)
#   - ManifoldBackendsTests
#       → swift test --parallel (own process: target mixes XCTest + Swift
#         Testing, so it cannot join a multi-target XCTest batch — #681.
#         --parallel is safe within the target now that the claims registry
#         is instance-scoped per test case.)
#   - ManifoldInferenceSwiftTestingTests
#       → xcodebuild test -scheme (separate scheme = separate process; avoids the
#         libmalloc SIGABRT that fires when XCTest + Swift Testing share one process)
#
# Usage:
#   scripts/ci-selective-test.sh <suite1> [suite2] ...
#
# Exit codes:
#   0 — all suites passed
#   1 — one or more suites failed

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCHEMES_DIR="$PACKAGE_DIR/.swiftpm/xcode/xcshareddata/xcschemes"
DESTINATION="platform=macOS,arch=arm64"

PASSED=()
FAILED=()

run_xcodebuild() {
  local suite="$1"
  local scheme="$SCHEMES_DIR/${suite}.xcscheme"
  if [[ ! -f "$scheme" ]]; then
    echo "::error::No xcscheme found for $suite — expected $scheme"
    FAILED+=("$suite (no-scheme)")
    return
  fi
  echo ""
  echo "══════ xcodebuild test -scheme $suite ══════"
  local exit_code=0
  xcodebuild test -scheme "$suite" -destination "$DESTINATION" 2>&1 || exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    PASSED+=("$suite")
  else
    FAILED+=("$suite")
  fi
}

run_swift_test() {
  local suite="$1"
  shift
  echo ""
  echo "══════ swift test --filter $suite ══════"
  local exit_code=0
  "$PACKAGE_DIR/scripts/test.sh" \
    --filter "$suite" \
    --skip-update \
    "$@" || exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    PASSED+=("$suite")
  else
    FAILED+=("$suite")
  fi
}

for record in "$@"; do
  suite="${record%%@*}"
  role="direct"
  if [[ "$record" == *"@"* ]]; then
    role_part="${record#*@}"
    role="${role_part%%@*}"
  fi
  case "$role" in direct|anchor) ;; *) echo "::error::Unknown suite role: $record"; exit 1 ;; esac
  case "$suite" in
    ManifoldBackendsTests)
      run_swift_test "$suite" --parallel
      ;;
    ManifoldVoiceTests|ManifoldAgentInstructionsTests|ManifoldToolsTests|ManifoldFuzzTests|ManifoldAppIntentsTests|ManifoldAppEvalTests|APIFreezeTests|ManifoldSnapshotTests|ManifoldTelemetryOTLPTests|ManifoldKitTests|ManifoldHuggingFaceTests)
      # No .xcscheme for these suites; their traits were retired in v0.48
      # (PR A3) so they compile under the shared core lane shape and reuse
      # its .build. swift test routing avoids the no-scheme failure path.
      # ManifoldAppEvalTests (estate#1 wave 1) is trait-free and hermetic —
      # same shape, same routing. APIFreezeTests (wave-2 0.A) is trait-free,
      # fast, and hermetic — same routing. ManifoldSnapshotTests (.dump-strategy
      # view-hierarchy snapshots, no rendering) and ManifoldTelemetryOTLPTests
      # (hermetic, MockURLProtocol) are both trait-free too — same routing.
      # ManifoldFuzzTests (#2367) is likewise trait-free and hermetic (no live
      # backend needed) — same routing.
      run_swift_test "$suite"
      ;;
    *)
      run_xcodebuild "$suite"
      ;;
  esac
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  SELECTIVE RESULTS"
echo "  Passed ${#PASSED[@]}: ${PASSED[*]:-(none)}"
echo "  Failed ${#FAILED[@]}: ${FAILED[*]:-(none)}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ ${#FAILED[@]} -gt 0 ]]; then
  exit 1
fi
