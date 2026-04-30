#!/usr/bin/env bash
# scripts/test.sh — Run swift test and report an honest summary.
#
# swift test's built-in summary lies: it prints "0 failures" even when suites
# crash with signal 11 (silently dropping those tests) and does not surface
# XCTSkip counts in the final line.
#
# This script:
#   1. Runs swift test and captures all output (stdout + stderr) to a temp file
#      while also streaming it to your terminal.
#   2. Parses the captured output for XCTest and Swift Testing events.
#   3. Counts: passed, failed, skipped (XCTSkip / Swift Testing skip), and
#      suites that crashed (started but never completed).
#   4. Prints a clear summary and exits non-zero if there are failures or crashes.
#
# Output format understood:
#   XCTest:
#     Test Case '-[Module.Suite testFoo]' passed (0.001 seconds).
#     Test Case '-[Module.Suite testFoo]' failed (0.001 seconds).
#     Test Case '-[Module.Suite testFoo]' skipped (0.001 seconds).
#     Test Suite 'SuiteName' started at ...
#     Test Suite 'SuiteName' passed at ...   /   ... failed at ...
#     error: Process '...' exited with unexpected signal code N
#   Swift Testing:
#     ✔ Test foo() passed after N seconds.
#     ✘ Test foo() failed after N seconds.
#     ↩ Test foo() skipped after N seconds.
#     ◇ Suite "SuiteName" started.
#     ✔ Suite "SuiteName" passed after N seconds.
#     ✘ Suite "SuiteName" failed after N seconds.

set -euo pipefail

OUTPUT_FILE="${BASECHAT_TEST_OUTPUT_FILE:-${TMPDIR:-/tmp}/test_output.txt}"
PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ── Arguments ────────────────────────────────────────────────────────────────
MIN_PASSED=0
SWIFT_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --min-passed)
            MIN_PASSED="${2:?'--min-passed requires an integer argument'}"
            shift 2
            ;;
        *)
            SWIFT_ARGS+=("$1")
            shift
            ;;
    esac
done

# ── Run ──────────────────────────────────────────────────────────────────────
echo "Running swift test in: $PACKAGE_DIR"
echo "Output captured to: $OUTPUT_FILE"
echo ""

# swift PM writes build progress + error lines to stderr; test output to stdout.
# We merge both so signal-crash lines (stderr) land alongside test lines (stdout).
cd "$PACKAGE_DIR"
mkdir -p "$(dirname "$OUTPUT_FILE")"
set +e
swift test "${SWIFT_ARGS[@]}" 2>&1 | tee "$OUTPUT_FILE"
SWIFT_EXIT=${PIPESTATUS[0]}
set -e

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  TEST SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Parse XCTest events ───────────────────────────────────────────────────────
# Individual test-case results
xctest_passed=$(grep -c "^Test Case '.*' passed" "$OUTPUT_FILE" || true)
xctest_failed=$(grep -c "^Test Case '.*' failed" "$OUTPUT_FILE" || true)
xctest_skipped=$(grep -c "^Test Case '.*' skipped" "$OUTPUT_FILE" || true)

# Suites that started but never emitted a 'passed' or 'failed' line are crash victims.
# Exclude the two top-level container lines ("All tests" and the .xctest bundle).
xctest_suites_started=$(grep "^Test Suite '" "$OUTPUT_FILE" \
    | grep " started at " \
    | grep -v "^Test Suite 'All tests'" \
    | grep -v "\.xctest'" \
    | sed "s/^Test Suite '//; s/' started at .*//" \
    || true)

# Find XCTest suites that started but did not complete.
xctest_crashed_suites=""
xctest_crashed_count=0
if [[ -n "$xctest_suites_started" ]]; then
    while IFS= read -r suite; do
        [[ -z "$suite" ]] && continue
        suite_pat=$(printf '%s' "$suite" | sed 's/[][(){}.*+?^$|\\]/\\&/g')
        if ! grep -qE "^Test Suite '${suite_pat}' (passed|failed) at" "$OUTPUT_FILE" 2>/dev/null; then
            xctest_crashed_suites="${xctest_crashed_suites}  - ${suite} (XCTest)"$'\n'
            xctest_crashed_count=$((xctest_crashed_count + 1))
        fi
    done <<< "$xctest_suites_started"
fi

# ── Parse Swift Testing events ────────────────────────────────────────────────
# Lines: "✔ Test foo() passed after N seconds."
#        "✘ Test foo() failed after N seconds."
#        "↩ Test foo() skipped after N seconds."
st_passed=$(grep -c "^✔ Test .* passed after " "$OUTPUT_FILE" || true)
st_failed=$(grep -c "^✘ Test .* failed after " "$OUTPUT_FILE" || true)
st_skipped=$(grep -c "^↩ Test .* skipped after " "$OUTPUT_FILE" || true)

# Swift Testing suites: "◇ Suite "Name" started." vs "✔ Suite "Name" passed after N seconds."
st_suites_started=$(grep '^◇ Suite "' "$OUTPUT_FILE" \
    | sed 's/^◇ Suite "//; s/" started\.//' \
    || true)

st_crashed_suites=""
st_crashed_count=0
if [[ -n "$st_suites_started" ]]; then
    while IFS= read -r suite; do
        [[ -z "$suite" ]] && continue
        suite_pat=$(printf '%s' "$suite" | sed 's/[][(){}.*+?^$|\\]/\\&/g')
        if ! grep -qE "^[✔✘] Suite \"${suite_pat}\" (passed|failed) after" "$OUTPUT_FILE" 2>/dev/null; then
            st_crashed_suites="${st_crashed_suites}  - ${suite} (Swift Testing)"$'\n'
            st_crashed_count=$((st_crashed_count + 1))
        fi
    done <<< "$st_suites_started"
fi

# ── Combined crash accounting ─────────────────────────────────────────────────
all_crashed_suites="${xctest_crashed_suites}${st_crashed_suites}"
total_crashed_count=$((xctest_crashed_count + st_crashed_count))

# Number of distinct processes that emitted a signal-exit error line.
signal_count=$(grep -c "exited with unexpected signal code" "$OUTPUT_FILE" || true)

# ── Totals ────────────────────────────────────────────────────────────────────
total_passed=$((xctest_passed + st_passed))
total_failed=$((xctest_failed + st_failed))
total_skipped=$((xctest_skipped + st_skipped))
total_run=$((total_passed + total_failed + total_skipped))

printf "  XCTest (classic runner)\n"
printf "    Passed:     %d\n" "$xctest_passed"
printf "    Failed:     %d\n" "$xctest_failed"
printf "    Skipped:    %d  (XCTSkip)\n" "$xctest_skipped"
if [[ $xctest_crashed_count -gt 0 ]]; then
    printf "    CRASHED:    %d suite(s) below never completed\n" "$xctest_crashed_count"
    printf "%s" "$xctest_crashed_suites"
fi
echo ""
printf "  Swift Testing (parallel runner)\n"
printf "    Passed:     %d\n" "$st_passed"
printf "    Failed:     %d\n" "$st_failed"
printf "    Skipped:    %d\n" "$st_skipped"
if [[ $st_crashed_count -gt 0 ]]; then
    printf "    CRASHED:    %d suite(s) below never completed\n" "$st_crashed_count"
    printf "%s" "$st_crashed_suites"
fi
echo ""
echo "  ─────────────────────────────────────────────────"
printf "  TOTAL RUN:    %d  (excludes tests in crashed suites)\n" "$total_run"
printf "  Passed:       %d\n" "$total_passed"
printf "  Failed:       %d\n" "$total_failed"
printf "  Skipped:      %d\n" "$total_skipped"
if [[ $total_crashed_count -gt 0 ]]; then
    printf "  Crashed:      %d suite(s) across %d process(es) — results incomplete\n" \
        "$total_crashed_count" "$signal_count"
    printf "%s" "$all_crashed_suites"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Exit code ─────────────────────────────────────────────────────────────────
# Fail if swift test itself reported a failure, or if we detected crashes
# (which means some tests were silently dropped and the run is untrustworthy).
FINAL_EXIT=0
if [[ $total_failed -gt 0 ]]; then
    echo "  RESULT: FAILED ($total_failed test failure(s))"
    FINAL_EXIT=1
elif [[ $total_crashed_count -gt 0 ]]; then
    echo "  RESULT: INCOMPLETE — $total_crashed_count suite(s) crashed (signal 11)"
    FINAL_EXIT=2
elif [[ $SWIFT_EXIT -ne 0 ]]; then
    echo "  RESULT: FAILED (swift test exit code $SWIFT_EXIT)"
    FINAL_EXIT=$SWIFT_EXIT
elif [[ $total_passed -eq 0 && $total_skipped -gt 0 && $total_failed -eq 0 && $total_crashed_count -eq 0 ]]; then
    echo "  RESULT: TRIPWIRE — 0 tests passed, $total_skipped skipped (entire suite silently skipped)"
    FINAL_EXIT=3
elif [[ $MIN_PASSED -gt 0 && $total_passed -lt $MIN_PASSED ]]; then
    echo "  RESULT: TRIPWIRE — only $total_passed test(s) passed, expected at least $MIN_PASSED"
    FINAL_EXIT=3
else
    echo "  RESULT: PASSED"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $FINAL_EXIT
