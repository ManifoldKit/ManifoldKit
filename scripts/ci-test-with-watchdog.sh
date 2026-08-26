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
#   1. Runs `scripts/test.sh "$@"` and captures stdout + stderr to a log file
#      (test.sh already does this when MANIFOLD_TEST_OUTPUT_FILE is set; we
#      point it at our own file so we don't fight over it).
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
#      The wrapper also writes process snapshots and log tails into
#      test-diagnostics/ so failure artifacts preserve stall evidence even
#      when the live Actions log is truncated.
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
#                       $MANIFOLD_TEST_OUTPUT_FILE.
#   WATCHDOG_DIAGNOSTICS_DIR=path
#                       Directory for watchdog-specific process snapshots.
#                       Default: directory containing WATCHDOG_LOG.
#   WATCHDOG_POLL_INTERVAL=N
#                       Seconds between liveness checks (`kill -0` on the
#                       wrapped process) and progress-count re-checks.
#                       Default: 15, unchanged — CI never sets this, so CI's
#                       own timing (and every threshold this file's header
#                       comment and STALL_SECONDS reasoning is calibrated
#                       against) is provably identical to before. A lower
#                       value shrinks the "up to N seconds after the child
#                       already exited before this loop notices" latency tax
#                       every wrapped invocation pays. Not free per tick —
#                       lowering this to 1 means ~15x more `kill -0`/`grep -cE`
#                       scans over a monotonically growing log for the
#                       duration of the run, not just at the end — but the
#                       shape is still cheap in absolute terms at real log
#                       scale: measured ~43ms per scan over a 3 MB log,
#                       ~1.6s of extra CPU per 40s of wall time, extrapolating
#                       to ~20s of one-core CPU across a 20-minute gate.
#                       Against the ~45s of wall clock a caller reclaims per
#                       gate invocation by lowering this (felt on every local
#                       iteration, unlike CI's multi-minute real builds,
#                       where the 15s default is comparatively free), that
#                       trade is worth it — but it is a trade, not a free
#                       lunch, and a caller lowering this further than
#                       scripts/test.sh's local-gate driver does should size
#                       it against their own log growth rate.
#   MANIFOLD_WATCHDOG_ACTIVE / MANIFOLD_WATCHDOG_WRAPPER_PID
#                       Set together by this wrapper before it launches
#                       scripts/test.sh. test.sh accepts the already-watched
#                       passthrough only when the recorded PID is an actual
#                       ancestor running this wrapper; a caller-supplied or
#                       stale environment value is ignored. Without this
#                       authenticated sentinel,
#                       `ci-test-with-watchdog.sh --profile local` (an outer
#                       wrap of the documented local gate) redirected every
#                       leaf log and the outer watchdog SIGABRT'd a healthy
#                       run at STALL_SECONDS. Not a user knob.
#
# Exit codes
# ----------
# Whatever scripts/test.sh exited with. On watchdog-triggered abort, the
# wrapper exits 124 (matches `timeout(1)` convention) so CI can distinguish
# "test failed" (1/2/3) from "wrapper killed a hung process" (124).

set -uo pipefail  # fail-open-ok: NOT -e — the watchdog must survive probe hiccups to kill and report the wedged run

STALL_SECONDS="${STALL_SECONDS:-180}"
PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# The wrapper and test.sh both want to control the log path. Point test.sh at
# the same file we tail, so we don't duplicate the tee pipeline.
if [[ -z "${MANIFOLD_TEST_OUTPUT_FILE:-}" ]]; then
    MANIFOLD_TEST_OUTPUT_FILE="$PACKAGE_DIR/test-diagnostics/test-output.txt"
    export MANIFOLD_TEST_OUTPUT_FILE
fi
WATCHDOG_LOG="${WATCHDOG_LOG:-$MANIFOLD_TEST_OUTPUT_FILE}"
WATCHDOG_DIAGNOSTICS_DIR="${WATCHDOG_DIAGNOSTICS_DIR:-$(dirname "$WATCHDOG_LOG")}"
WATCHDOG_LOG_BASENAME="$(basename "$WATCHDOG_LOG")"
WATCHDOG_DIAGNOSTICS_FILE="$WATCHDOG_DIAGNOSTICS_DIR/watchdog-${WATCHDOG_LOG_BASENAME%.log}.diagnostics.txt"

# Pre-create the log so `tail -F` doesn't sit on a missing file. The trailing
# newline is intentional: it gives the wrapper a baseline mtime to compare.
mkdir -p "$(dirname "$WATCHDOG_LOG")" "$WATCHDOG_DIAGNOSTICS_DIR"
: > "$WATCHDOG_LOG"
: > "$WATCHDOG_DIAGNOSTICS_FILE"
{
    echo "ci-test-with-watchdog diagnostics"
    echo "started-at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "stall-seconds=$STALL_SECONDS"
    echo "watchdog-log=$WATCHDOG_LOG"
    echo "arguments=$*"
    echo ""
} >> "$WATCHDOG_DIAGNOSTICS_FILE"

# Background-launch scripts/test.sh. We use the same shell-quoting shape the
# CI step uses so the wrapper is a drop-in replacement.
#
# MANIFOLD_WATCHDOG_ACTIVE tells a nested `--profile local|ci` driver it is
# already being watched: do not wrap again, and do not point
# MANIFOLD_TEST_OUTPUT_FILE at a per-label file this loop cannot see.
export MANIFOLD_WATCHDOG_ACTIVE=1
export MANIFOLD_WATCHDOG_WRAPPER_PID="$$"
export MANIFOLD_WATCHDOG_STALL_SECONDS="$STALL_SECONDS"
"$PACKAGE_DIR/scripts/test.sh" "$@" &
TEST_PID=$!

# Watchdog loop. We wake every $POLL_INTERVAL seconds and check whether any
# progress line has appeared in the last $STALL_SECONDS. The mechanism is a
# count-based high-water mark (grep -cE against the progress pattern, below),
# not mtime: mtime would be weaker than what's actually implemented here —
# any output at all (a hung process's stderr chatter, a retry loop with no
# real progress) refreshes mtime and would falsely re-arm the timer, whereas
# the count only advances on a line that actually matches the progress
# pattern, so a stall with unrelated chatter still gets caught.
POLL_INTERVAL="${WATCHDOG_POLL_INTERVAL:-15}"
LAST_PROGRESS_TS=$(date +%s)
LAST_LINE_COUNT=0

aborted_by_watchdog=0

# Pattern matches forward progress in BOTH phases of `swift test`:
#
#   1. Build phase — SwiftPM streams "Building for debugging...",
#      "[N/M] Compiling ...", "Emitting module ...", "[N/M] Write ...", and
#      "Build complete!". A cold build of the full parallel test bundle can run
#      several minutes with *no* test-execution output; without counting these
#      the watchdog mistakes an advancing-but-slow compile for a stall and
#      SIGABRTs before a single test starts (TOTAL RUN: 0). A genuinely stuck
#      build still emits no new "[N/M]" line, so it still trips the watchdog.
#   2. Test phase — SwiftPM's streaming "[N/M] Testing Module.Suite/test" line
#      (the only reliable per-worker signal under --parallel), the Swift Testing
#      harness's per-test "✔/✘/↩ Test ..." lines, and XCTest's classic
#      "Test Case '...' passed" lines.
#
# Any one of these proves a worker is alive and making forward progress.
progress_pattern='^\[[0-9]+/[0-9]+\] (Testing|Compiling|Write|Emitting) |^\[gate-lock\] (waiting for gate lock|waiting for gate-lock reclaim|acquired after waiting) |^Emitting module |^Building for |^Build complete|^Planning build|^Test Case .* (passed|failed|skipped)|^[✔✘↩] (Test|Suite) '

# Snapshot the descendant swift-test / xctest pid set so we can SIGABRT them
# all on stall without touching unrelated Swift work that may be running on the
# same host.
collect_descendant_pids() {
    local root="$1"
    local queue=("$root")
    local pid
    local child

    while ((${#queue[@]} > 0)); do
        pid="${queue[0]}"
        queue=("${queue[@]:1}")
        while read -r child; do
            [[ -z "$child" ]] && continue
            echo "$child"
            queue+=("$child")
        done < <(ps -axo pid=,ppid= 2>/dev/null | awk -v parent="$pid" '$2 == parent { print $1 }')
    done
}

collect_test_descendants() {
    local pid
    local command

    while read -r pid; do
        [[ -z "$pid" ]] && continue
        command=$(ps -p "$pid" -o command= 2>/dev/null || true)
        case "$command" in
            *swift-test*|*xctest*|*swift-testing*|*"swift test"*)
                echo "$pid"
                ;;
        esac
    done < <(collect_descendant_pids "$TEST_PID")
}

append_process_snapshot() {
    local label="$1"

    {
        echo "## $label"
        echo "captured-at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "test-pid=$TEST_PID"
        echo ""
        echo "### descendant process tree"
        local descendants
        descendants=$(collect_descendant_pids "$TEST_PID" || true)  # fail-open-ok: diagnostics capture — a vanished process tree is itself the signal
        if [[ -n "$descendants" ]]; then
            while read -r pid; do
                [[ -z "$pid" ]] && continue
                ps -p "$pid" -o pid=,ppid=,pgid=,stat=,etime=,command= 2>/dev/null || true
            done <<< "$descendants"
        else
            echo "(no descendants)"
        fi
        echo ""
        echo "### matching test processes"
        ps -axo pid=,ppid=,pgid=,stat=,etime=,command= 2>/dev/null \
            | awk '/swift-test|xctest|swift-testing|swift test/ && $0 !~ /awk/ { print }' \
            || true  # fail-open-ok: diagnostics capture — zero matching processes is a valid outcome
        echo ""
    } >> "$WATCHDOG_DIAGNOSTICS_FILE"
}

append_log_tail() {
    local label="$1"
    local lines="${2:-200}"

    {
        echo "## $label"
        echo "captured-at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "source=$WATCHDOG_LOG"
        echo ""
        if [[ -f "$WATCHDOG_LOG" ]]; then
            tail -"$lines" "$WATCHDOG_LOG" || true
        else
            echo "(watchdog log missing)"
        fi
        echo ""
    } >> "$WATCHDOG_DIAGNOSTICS_FILE"
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

        append_process_snapshot "processes before SIGABRT"
        append_log_tail "log tail before SIGABRT" 200

        descendants=$(collect_test_descendants)
        if [[ -n "$descendants" ]]; then
            echo "ci-test-with-watchdog: SIGABRT -> $(echo "$descendants" | tr '\n' ' ')"
            {
                echo "## signals"
                echo "sigabrt-at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
                echo "pids=$(echo "$descendants" | tr '\n' ' ')"
                echo ""
            } >> "$WATCHDOG_DIAGNOSTICS_FILE"
            # shellcheck disable=SC2086
            kill -ABRT $descendants 2>/dev/null || true
            # Give the runtime a few seconds to dump backtraces, then SIGKILL
            # any that ignored SIGABRT so we don't deadlock the job step.
            sleep 10
            append_process_snapshot "processes after SIGABRT grace period"
            append_log_tail "log tail after SIGABRT grace period" 400
            # shellcheck disable=SC2086
            kill -KILL $descendants 2>/dev/null || true
        else
            echo "ci-test-with-watchdog: no swift-test/xctest descendants found to abort."
            {
                echo "## signals"
                echo "no swift-test/xctest descendants found to abort"
                echo ""
            } >> "$WATCHDOG_DIAGNOSTICS_FILE"
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
    append_process_snapshot "processes after scripts/test.sh wait"
    append_log_tail "final log tail after watchdog abort" 400
    echo "::error::ci-test-with-watchdog: aborted by stall watchdog (no progress for ${STALL_SECONDS}s)."
    echo "::error::watchdog diagnostics captured at ${WATCHDOG_DIAGNOSTICS_FILE}"
    exit 124
fi

exit "$TEST_EXIT"
