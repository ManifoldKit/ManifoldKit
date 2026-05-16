#!/usr/bin/env bash
# scripts/ci-test-with-watchdog.sh — run scripts/test.sh under a stall watchdog.
#
# Why this exists
# ---------------
# `swift test --parallel` parks every worker if one test hangs: SwiftPM's
# scheduler keeps the workers alive waiting for the stuck test to finish, and
# the job step's 30-min `timeout-minutes` is the only thing that eventually
# kills the run. By then the stdout buffer has been silent for ~28 minutes and
# the GitHub Actions log shows zero signal about which test hung. The XCTest
# step burns its 30-min budget, then the Swift Testing step burns another 30
# min, total 60 min wasted per push (last 5 main pushes all hit this).
#
# This wrapper:
#   1. Runs `scripts/test.sh "$@"` and tees its output to a log file (test.sh
#      already does this when MANIFOLD_TEST_OUTPUT_FILE is set; we point it at
#      our own file so we don't fight over it).
#   2. Monitors the log for SwiftPM's streaming "[N/M] Testing Module.Suite/test"
#      lines — under --parallel these are the only reliable per-worker progress
#      signal (per-case `Test Case '...' passed` lines are emitted only by some
#      workers, see scripts/test.sh comments).
#   3. If no progress line appears for $STALL_SECONDS (default 180s), sends
#      SIGABRT to every running swift-test / xctest / swift-testing process so
#      the OS dumps a stack trace into stderr before SwiftPM exits non-zero.
#      SIGABRT (not SIGTERM/SIGKILL) is deliberate: it triggers the Swift
#      runtime's crash handler, which prints a backtrace per thread for every
#      worker, naming the test case that was running on the stuck worker.
#   4. The wrapper exits with the same exit code scripts/test.sh would have
#      returned, so CI's existing failure plumbing (artifact upload, etc.)
#      keeps working unchanged.
#
# Why not `gtimeout`/`timeout`
# ----------------------------
# A flat `timeout 25m swift test ...` would still produce zero diagnostic
# signal — it'd just send SIGTERM at minute 25 and we'd be back to "the step
# was killed, no idea which test". The watchdog approach kills only on actual
# stall (no progress for N seconds), and uses SIGABRT so we get backtraces.
#
# Why not @Test(.timeLimit(...)) / a per-test wrapper
# ---------------------------------------------------
# Swift Testing's .timeLimit() trait works only on @Test-annotated tests, not
# XCTestCase; and even there it requires per-test annotation, not a global
# default. XCTest has no global per-test timeout knob at all. The XCTest
# bundle is most of what runs in CI (see ci.yml step 1), so a per-test
# annotation would miss the bundle most likely to hang.
#
# Configuration
# -------------
#   STALL_SECONDS=N     Kill the swift test process tree if no progress line
#                       has appeared in N seconds. Default: 180.
#   WATCHDOG_LOG=path   Path to the watchdog's progress log. Default:
#                       $MANIFOLD_TEST_OUTPUT_FILE if set, else a tmpfile.
#
# Exit codes
# ----------
# Whatever scripts/test.sh exited with. On watchdog-triggered abort, the
# wrapper exits 124 (matches `timeout(1)` convention) so CI can distinguish
# "test failed" (1/2/3) from "wrapper killed a hung process" (124).

set -uo pipefail

STALL_SECONDS="${STALL_SECONDS:-180}"
PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# The wrapper and test.sh both want to control the log path. Point test.sh at
# the same file we tail, so we don't duplicate the tee pipeline.
if [[ -z "${MANIFOLD_TEST_OUTPUT_FILE:-}" ]]; then
    MANIFOLD_TEST_OUTPUT_FILE="${TMPDIR:-/tmp}/test_output.txt"
    export MANIFOLD_TEST_OUTPUT_FILE
fi
WATCHDOG_LOG="${WATCHDOG_LOG:-$MANIFOLD_TEST_OUTPUT_FILE}"

# Pre-create the log so `tail -F` doesn't sit on a missing file. The trailing
# newline is intentional: it gives the wrapper a baseline mtime to compare.
mkdir -p "$(dirname "$WATCHDOG_LOG")"
: > "$WATCHDOG_LOG"

# Background-launch scripts/test.sh. We use the same shell-quoting shape the
# CI step uses so the wrapper is a drop-in replacement.
"$PACKAGE_DIR/scripts/test.sh" "$@" &
TEST_PID=$!

# Watchdog loop. We wake every $POLL_INTERVAL seconds and check whether any
# progress line has appeared in the last $STALL_SECONDS. Using mtime is
# deterministic across log rotations and survives the `tee` buffering that
# would otherwise hide writes from `wc -l` polling.
POLL_INTERVAL=15
LAST_PROGRESS_TS=$(date +%s)
LAST_LINE_COUNT=0

aborted_by_watchdog=0

# Pattern matches BOTH SwiftPM's streaming line ("[N/M] Testing ...") and the
# Swift Testing harness's per-test pass/fail/skip lines ("✔/✘/↩ Test ...").
# XCTest's classic "Test Case '...' passed" lines also count. Any one of
# these proves a worker is alive and making forward progress.
progress_pattern='^\[[0-9]+/[0-9]+\] Testing |^Test Case .* (passed|failed|skipped)|^[✔✘↩] (Test|Suite) '

# Snapshot the descendant swift-test / xctest pid set so we can SIGABRT them
# all on stall. macOS lacks `pgrep -P --recursive`; walking the tree by name
# is good enough because the wrapper itself is the only thing in this job
# launching swift test.
collect_test_descendants() {
    # Match the binaries SwiftPM spawns: `swift-test` driver, the per-target
    # `xctest` runners, and the Swift Testing executable. Strip the wrapper's
    # own pid from the list defensively (it shouldn't match, but be safe).
    pgrep -lf 'swift-test|xctest|swift-testing' 2>/dev/null \
        | awk -v me=$$ '$1 != me { print $1 }'
}

while kill -0 "$TEST_PID" 2>/dev/null; do
    sleep "$POLL_INTERVAL"

    # Has any new progress line appeared since the last poll?
    if [[ -f "$WATCHDOG_LOG" ]]; then
        # grep -c can exit 1 on zero matches under set -e; we already disabled
        # -e at the top so this is fine, but `|| true` keeps intent obvious.
        current_count=$(grep -cE "$progress_pattern" "$WATCHDOG_LOG" 2>/dev/null || true)
        if [[ "$current_count" -gt "$LAST_LINE_COUNT" ]]; then
            LAST_PROGRESS_TS=$(date +%s)
            LAST_LINE_COUNT="$current_count"
        fi
    fi

    now=$(date +%s)
    silent_for=$(( now - LAST_PROGRESS_TS ))

    if (( silent_for >= STALL_SECONDS )); then
        echo ""
        echo "::error::ci-test-with-watchdog: no test progress for ${silent_for}s (threshold ${STALL_SECONDS}s)."
        echo "::error::Sending SIGABRT to swift-test / xctest descendants so the Swift runtime dumps a per-thread backtrace identifying the hung test."

        # Print the last 50 progress lines so the CI log shows which test was
        # the *last* to start before the silence — that's almost always the
        # culprit (the next test in the suite never got to print its line).
        echo ""
        echo "─── last 50 progress lines before stall ───"
        grep -E "$progress_pattern" "$WATCHDOG_LOG" 2>/dev/null | tail -50 || true
        echo "───────────────────────────────────────────"
        echo ""

        descendants=$(collect_test_descendants)
        if [[ -n "$descendants" ]]; then
            echo "ci-test-with-watchdog: SIGABRT -> $(echo "$descendants" | tr '\n' ' ')"
            # shellcheck disable=SC2086
            kill -ABRT $descendants 2>/dev/null || true
            # Give the runtime a few seconds to dump backtraces, then SIGKILL
            # any that ignored SIGABRT so we don't deadlock the job step.
            sleep 10
            # shellcheck disable=SC2086
            kill -KILL $descendants 2>/dev/null || true
        else
            echo "ci-test-with-watchdog: no swift-test/xctest descendants found to abort."
        fi

        # Also SIGTERM the scripts/test.sh wrapper so its `wait` returns.
        kill -TERM "$TEST_PID" 2>/dev/null || true
        aborted_by_watchdog=1
        break
    fi
done

# Reap the foreground job. `wait` returns the test process's exit code, even
# after we SIGTERM'd it, so CI gets a real signal-aware exit code.
wait "$TEST_PID" 2>/dev/null
TEST_EXIT=$?

if (( aborted_by_watchdog == 1 )); then
    # 124 == GNU `timeout` convention for "process killed by watchdog". This
    # is distinct from scripts/test.sh's own exit codes (0/1/2/3) so a CI log
    # reader can immediately tell apart "test bug" from "test hang".
    echo "::error::ci-test-with-watchdog: aborted by stall watchdog (no progress for ${STALL_SECONDS}s)."
    exit 124
fi

exit "$TEST_EXIT"
