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
# Backend-family suites (MLX / llama.cpp) moved to the manifold-mlx /
# manifold-llama companion packages in v0.48 (PR C2, #1749) — run their
# suites from those repos. Core has no default traits anymore; the only
# surviving opt-in traits are Server and Macros.
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

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# Default to a package-relative path, not $TMPDIR — on macOS, TMPDIR is
# per-USER (not per-invocation), so two concurrent local runs (e.g. two
# worktrees) clobber each other's output file and each parses the other's
# results (#2298). Mirrors scripts/ci-test-with-watchdog.sh's
# test-diagnostics/ convention.
OUTPUT_FILE="${MANIFOLD_TEST_OUTPUT_FILE:-$PACKAGE_DIR/test-diagnostics/test_output.txt}"

# ── Machine-wide gate lock ──────────────────────────────────────────────────
# 2026-08-09 incident: six concurrent worker gates wedged an xcodebuild for
# 2h via SwiftPM cache-lock contention — every worker was blocked on the same
# on-disk `.build`/package-cache lock, and none of them could tell the others
# were even there. This section serializes full gate runs on one machine so
# only one build-heavy `swift test` invocation is in flight at a time.
#
# The lock is a single regular FILE published via a hard link, not a
# directory built with `mkdir` + separate content writes. That two-step
# shape (an earlier version of this file used it) has an unavoidable gap
# between "the directory exists" and "the directory is populated" — and
# under real N-way contention (measured: 8 waiters against one dead-holder
# lock) a reclaimer can capture another process's still-populating
# directory in that gap, producing either silent double-acquisition or an
# orphaned lock attributed to a PID that has already abandoned that
# specific attempt (both reproduced empirically; see #2453 PR history for
# the two prior designs that didn't hold up under measurement). This design
# has no such gap: the lock's full content (holder PID + acquisition time,
# two lines) is written to a PRIVATE, uniquely-named candidate file first,
# and only published to the shared path afterward via `ln` (a hard link) —
# so the shared path never has an observable "exists but empty" state.
# `link(2)` gives the same "exactly one caller wins" guarantee `mkdir`
# does, verified empirically (30-way concurrent `ln` onto one path: exactly
# one winner) — unlike two alternatives that looked equally safe on paper
# and were not: `mv` onto an existing directory silently MERGES rather than
# failing, and macOS's `ln -s` silently no-ops on an existing destination
# instead of returning an error. Both surprises were caught by running the
# concurrent case, not by reading a man page.
#
# Reclaiming a dead holder's lock took three attempts to get right — see
# `acquire_gate_lock`'s reclaim branch below for the full account. The
# short version: a bare `rm` (any waiter that reads the same dead PID acts
# on it independently) and a "capture the file, verify its content, restore
# it if the diagnosis turns out to be stale" reclaim (the capture itself
# opens a fresh window a third process can win) both produced real,
# ground-truth-confirmed 2-3-way simultaneous "holders" under measurement —
# not reasoning, actual concurrent runs with a real-time marker, since
# 1-second-resolution timestamp comparison produced its own false
# positives/negatives along the way. The design that survived measurement
# serializes the whole "diagnose dead, then delete" decision behind its own
# `mkdir`-based mutex, so at most one process is ever mid-reclaim for a
# given generation of the lock.
#
# MANIFOLD_GATE_NO_LOCK=1 is a boot-time opt-out: read once, at invocation
# time, by whoever launches the script — never toggled mid-run — for the
# rare deliberate parallel run (e.g. intentionally racing two profiles
# against different modules on purpose). Everyone else gets serialized.
GATE_LOCK_FILE="${MANIFOLD_GATE_LOCK_FILE:-/tmp/manifoldkit-gate.lock}"
# Poll interval is overridable so the self-test below doesn't have to eat the
# production default in wall-clock time; production callers never set this.
GATE_LOCK_POLL_SECS="${MANIFOLD_GATE_LOCK_POLL_SECS:-5}"
GATE_LOCK_PROGRESS_INTERVAL_SECS=60
GATE_LOCK_WAIT_CEILING_SECS="${MANIFOLD_GATE_LOCK_CEILING_SECS:-10800}"  # 3h
# How old an ownerless `${GATE_LOCK_FILE}.reclaiming` mutex directory (mkdir'd
# but its pid file never written) must be before it is swept as an orphan
# rather than left alone as merely young. 60s is comfortably above the
# microsecond-scale window between a reclaimer's `mkdir` and its `printf`
# (the only source of a legitimate pid-less mutex) — overridable so the
# self-test below can exercise the sweep without a real 60s wait.
GATE_RECLAIM_MUTEX_ORPHAN_AGE_SECS="${MANIFOLD_GATE_RECLAIM_MUTEX_ORPHAN_AGE_SECS:-60}"
GATE_LOCK_HELD_BY_SELF=0
# Set for exactly the window this process holds ${GATE_LOCK_FILE}.reclaiming
# (between its own `mkdir` and `rm -rf`) — release_gate_lock's EXIT trap
# checks this to sweep the mutex on SIGINT/SIGTERM (any signal that still
# runs the EXIT trap). A SIGKILL mid-window skips the trap entirely; the
# age-based orphan sweep in acquire_gate_lock's reclaim branch is what
# recovers from that case instead.
GATE_RECLAIM_MUTEX_HELD_BY_SELF=0

# Blocks until this process holds $GATE_LOCK_FILE, or fails closed after the
# ceiling. A no-op when MANIFOLD_GATE_NO_LOCK=1, or when an ancestor
# invocation of this very script already holds the lock — the three-
# invocation profile shape below re-execs "$0" up to three times, and each
# child would otherwise deadlock waiting on a lock its own parent holds and
# cannot release until the child exits. The ancestor communicates "I already
# hold this" to its children via the exported MANIFOLD_GATE_LOCK_OWNER_PID
# sentinel, which children inherit automatically.
#
# The sentinel is exported, so it is NOT scoped to the three re-exec
# children alone — any descendant of a gate run (an interactive shell, an
# agent session spawned underneath one) inherits it too, and it survives in
# that descendant's environment after the ancestor gate has released the
# lock and exited. Trusting the sentinel's mere presence would let such a
# descendant run every future `scripts/test.sh` invocation completely
# unlocked, silently, forever — exactly the fail-open the lock exists to
# prevent. So a live sentinel is corroborated, not trusted outright: only
# skip acquisition when the recorded holder PID is (a) still alive AND
# (b) still the name written in the lock file itself (i.e. the lock this
# process would otherwise wait for is, right now, actually held by the
# ancestor that exported the sentinel — not a stale leftover from a run
# that has already finished). A widowed sentinel is dropped and this
# process acquires for real. See scenario C in run_gate_lock_selftest.

# Best-effort sweep of `.candidate.<random>` scratch files left behind by a
# process killed between building its (private, not-yet-published) claim
# and either publishing it (successful `ln`) or discarding it (a lost
# race) — e.g. `kill -9` mid-attempt. Each candidate's first line is the
# PID that created it; only removed when that PID is confirmed dead (a
# live candidate belongs to a process still mid-attempt, never orphaned
# while it runs). Safe to call with nothing to sweep: the glob simply fails
# to match and the loop body never runs.
sweep_orphaned_candidates() {
    local candidate candidate_owner_pid
    for candidate in "${GATE_LOCK_FILE}".candidate.*; do
        [[ -f "$candidate" ]] || continue
        candidate_owner_pid="$(head -n 1 "$candidate" 2>/dev/null)" || candidate_owner_pid=""
        if [[ "$candidate_owner_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$candidate_owner_pid" 2>/dev/null; then
            rm -f "$candidate" 2>/dev/null || true
        fi
    done
}

acquire_gate_lock() {
    if [[ "${MANIFOLD_GATE_NO_LOCK:-0}" == "1" ]]; then
        echo "[gate-lock] MANIFOLD_GATE_NO_LOCK=1 — skipping machine-wide gate serialization (deliberate parallel run)."
        return 0
    fi
    if [[ -n "${MANIFOLD_GATE_LOCK_OWNER_PID:-}" ]]; then
        local recorded_pid=""
        if [[ -f "$GATE_LOCK_FILE" ]]; then
            recorded_pid="$(head -n 1 "$GATE_LOCK_FILE" 2>/dev/null)" || recorded_pid=""
        fi
        if [[ "$recorded_pid" == "$MANIFOLD_GATE_LOCK_OWNER_PID" ]] && kill -0 "$MANIFOLD_GATE_LOCK_OWNER_PID" 2>/dev/null; then
            return 0
        fi
        echo "[gate-lock] inherited MANIFOLD_GATE_LOCK_OWNER_PID=$MANIFOLD_GATE_LOCK_OWNER_PID is stale (holder dead, or lock no longer held by it) — acquiring for real instead of skipping." >&2
        unset MANIFOLD_GATE_LOCK_OWNER_PID
    fi

    sweep_orphaned_candidates

    local waited=0
    local announced=0
    while true; do
        # Build the FULL claim privately, before it is ever visible to
        # anyone else. `mktemp` gives a name no other process can guess or
        # collide with; the two lines (PID, acquisition time) are written
        # to it while it is still nobody's business but ours.
        local candidate=""
        candidate="$(mktemp "${GATE_LOCK_FILE}.candidate.XXXXXX" 2>/dev/null)" || candidate=""
        if [[ -z "$candidate" ]]; then
            echo "[gate-lock] error: mktemp failed building a lock candidate at ${GATE_LOCK_FILE}.candidate.XXXXXX — check that $(dirname "$GATE_LOCK_FILE") is writable. Not a contention case; failing closed." >&2
            exit 74
        fi
        { printf '%s\n' "$$"; date +%s; } > "$candidate"

        # Publish by hard-linking the fully-formed candidate onto the
        # shared path. Exactly one concurrent `ln` can win here (verified
        # empirically); every loser gets ENOENT/EEXIST and simply discards
        # its own unpublished candidate below, re-reading fresh state on
        # its next loop iteration.
        if ln "$candidate" "$GATE_LOCK_FILE" 2>/dev/null; then
            rm -f "$candidate"  # two names, one inode — the link IS our claim now
            GATE_LOCK_HELD_BY_SELF=1
            export MANIFOLD_GATE_LOCK_OWNER_PID=$$
            if [[ $waited -gt 0 ]]; then
                echo "[gate-lock] acquired after waiting ${waited}s."
            fi
            return 0
        fi
        rm -f "$candidate"  # lost the race; never published, safe to discard

        local holder_pid="" holder_start="" holder_age="?"
        if [[ -f "$GATE_LOCK_FILE" ]]; then
            holder_pid="$(sed -n '1p' "$GATE_LOCK_FILE" 2>/dev/null)" || holder_pid=""
            holder_start="$(sed -n '2p' "$GATE_LOCK_FILE" 2>/dev/null)" || holder_start=""
        fi
        if [[ -n "$holder_start" ]]; then
            holder_age="$(( $(date +%s) - holder_start ))s"
        fi

        # Stale-lock reclaim: our FRESH, same-iteration read says the
        # holder PID is dead. Two earlier designs did NOT survive real
        # measurement here: a bare `rm` (any waiter that reads the same
        # dead PID acts on it independently, racing whichever `ln` is
        # mid-flight) and a "capture via `mv`, verify content, restore if
        # mismatched" step (closed that race, but capturing ANYTHING —
        # even briefly, even with a correct verify-and-restore — opens a
        # fresh window: while the capture is in a reclaimer's private
        # hands, ANOTHER process's independent `ln` can win the now-vacant
        # shared path, and if that captured content later turns out to
        # need restoring, the slot may already be legitimately occupied,
        # silently losing the captured holder's claim while it still
        # believes it holds the lock. Ground-truth confirmed via a
        # real-time concurrent-holder marker, not inferred from
        # timestamps: this produced real 2-3-way simultaneous "holders"
        # under ten concurrent 8-waiter runs.
        #
        # The actual fix: serialize the whole "diagnose dead, then delete"
        # decision behind its own exclusive mutex, using the same `mkdir`
        # atomicity this lock has relied on from the start. At most one
        # process at a time may even ATTEMPT a reclaim for this
        # generation; every other process that also independently
        # diagnosed the same dead PID just loses the mkdir race and falls
        # straight through to the normal wait/retry path below — it does
        # NOT duplicate the reclaim attempt, so there is no second actor
        # left to race the first one's decision. The mutex holder then
        # re-reads the lock file's content FRESH, now that it is the sole
        # party allowed to act on that read: no other reclaimer can have
        # changed the diagnosis out from under it, so this read cannot be
        # stale in the way that broke the capture-and-restore design — the
        # only remaining actor is a legitimate NEW `ln` winner, which the
        # retry loop already handles correctly (our own subsequent `ln`
        # simply loses to it, and we retry from scratch as a normal
        # waiter).
        if [[ -n "$holder_pid" ]] && ! kill -0 "$holder_pid" 2>/dev/null; then
            local reclaim_mutex="${GATE_LOCK_FILE}.reclaiming"
            if mkdir "$reclaim_mutex" 2>/dev/null; then
                GATE_RECLAIM_MUTEX_HELD_BY_SELF=1
                # This write is best-effort diagnostics only: if it fails,
                # the mutex (the `mkdir` above) still correctly serializes
                # reclaim attempts — the only loss is that a later process
                # can't identify and sweep THIS mutex if we die before
                # `rm -rf`'ing it below, leaving an orphan instead of an
                # auto-cleaned one.
                # fail-open-ok: best-effort diagnostics write, see above
                printf '%s\n' "$$" > "$reclaim_mutex/pid" 2>/dev/null || true
                local mutex_holder_pid=""
                if [[ -f "$GATE_LOCK_FILE" ]]; then
                    mutex_holder_pid="$(sed -n '1p' "$GATE_LOCK_FILE" 2>/dev/null)" || mutex_holder_pid=""
                fi
                if [[ -n "$mutex_holder_pid" ]] && ! kill -0 "$mutex_holder_pid" 2>/dev/null; then
                    rm -f "$GATE_LOCK_FILE"
                    echo "[gate-lock] STALE LOCK RECLAIMED: holder PID $mutex_holder_pid (age ${holder_age}) is dead — removing $GATE_LOCK_FILE and retrying." >&2
                fi
                rm -rf "$reclaim_mutex"
                GATE_RECLAIM_MUTEX_HELD_BY_SELF=0
                # We made real progress this iteration (reclaimed, or
                # confirmed the lock file had already changed out from
                # under us) — retry immediately, no pacing needed.
                continue
            fi

            # Someone else already holds the reclaim mutex for this
            # generation — unless THEY are dead too (crashed mid-reclaim),
            # in which case the mutex itself is an orphan that would
            # otherwise block every future reclaim forever. Only clear it
            # when its recorded owner is confirmed dead.
            local mutex_owner_pid=""
            mutex_owner_pid="$(cat "$reclaim_mutex/pid" 2>/dev/null)" || mutex_owner_pid=""
            if [[ -n "$mutex_owner_pid" ]]; then
                if ! kill -0 "$mutex_owner_pid" 2>/dev/null; then
                    rm -rf "$reclaim_mutex" 2>/dev/null || true
                fi
            else
                # No readable pid file. Two explanations, indistinguishable
                # from content alone: a YOUNG mutex (the owner `mkdir`'d but
                # hasn't `printf`'d its pid yet — a real but microsecond-
                # scale window) or an ORPHAN (the owner was SIGKILLed inside
                # that exact window, so no EXIT trap ever ran to remove it —
                # release_gate_lock's trap-based cleanup above only fires on
                # signals that still run EXIT traps). Age is what tells them
                # apart: a mutex is swept only once it is old enough that
                # "still forming" stops being a credible explanation, so a
                # merely-young mutex is never touched.
                local mutex_mtime=""
                mutex_mtime="$(stat -f %m "$reclaim_mutex" 2>/dev/null)" || mutex_mtime=""
                if [[ -n "$mutex_mtime" ]]; then
                    local mutex_age_secs=$(( $(date +%s) - mutex_mtime ))
                    if [[ $mutex_age_secs -ge $GATE_RECLAIM_MUTEX_ORPHAN_AGE_SECS ]]; then
                        rm -rf "$reclaim_mutex" 2>/dev/null || true
                        echo "[gate-lock] swept orphaned reclaim mutex $reclaim_mutex (age ${mutex_age_secs}s, no pid file — likely SIGKILLed mid-reclaim)." >&2
                    fi
                fi
            fi

            # We did NOT make progress this iteration — another process's
            # reclaim mutex is (as far as we can tell) still legitimately
            # in use. Without pacing here, this branch is reached again on
            # the very next loop iteration (the same dead holder_pid is
            # still on disk), so a bare `continue` would spin at ~100% CPU
            # indefinitely and GATE_LOCK_WAIT_CEILING_SECS would never
            # apply — `waited` is only ever incremented on the path below,
            # which this early `continue` always skipped. Duplicating the
            # sleep/waited/ceiling triplet here (rather than falling
            # through to share the code below) is what actually bounds
            # this path: it degrades to a normal paced wait and fails
            # closed at the ceiling instead of spinning forever.
            sleep "$GATE_LOCK_POLL_SECS"
            waited=$((waited + GATE_LOCK_POLL_SECS))
            if [[ $waited -ge $GATE_LOCK_WAIT_CEILING_SECS ]]; then
                echo "[gate-lock] error: waited ${waited}s for gate lock held by PID ${holder_pid:-unknown} (ceiling ${GATE_LOCK_WAIT_CEILING_SECS}s) — failing CLOSED rather than proceeding unlocked. Set MANIFOLD_GATE_NO_LOCK=1 to bypass deliberately." >&2
                exit 75
            fi
            continue
        fi

        if [[ $announced -eq 0 || $((waited % GATE_LOCK_PROGRESS_INTERVAL_SECS)) -eq 0 ]]; then
            echo "[gate-lock] waiting for gate lock held by PID ${holder_pid:-unknown} (age ${holder_age}) — waited ${waited}s so far"
            announced=1
        fi

        if [[ $waited -ge $GATE_LOCK_WAIT_CEILING_SECS ]]; then
            echo "[gate-lock] error: waited ${waited}s for gate lock held by PID ${holder_pid:-unknown} (ceiling ${GATE_LOCK_WAIT_CEILING_SECS}s) — failing CLOSED rather than proceeding unlocked. Set MANIFOLD_GATE_NO_LOCK=1 to bypass deliberately." >&2
            exit 75
        fi

        sleep "$GATE_LOCK_POLL_SECS"
        waited=$((waited + GATE_LOCK_POLL_SECS))
    done
}

# Only the process that actually acquired the lock releases it — a child
# that skipped acquisition (because an ancestor already held it) must not
# tear down the lock out from under that ancestor.
release_gate_lock() {
    if [[ $GATE_LOCK_HELD_BY_SELF -eq 1 ]]; then
        echo "[gate-lock] released (pid $$)."
        rm -f "$GATE_LOCK_FILE"
    fi
    # Covers SIGINT/SIGTERM arriving while this process is mid-reclaim
    # (between its own `mkdir "$GATE_LOCK_FILE.reclaiming"` and `rm -rf` of
    # the same path) — both still run the EXIT trap, so this sweeps the
    # mutex rather than leaving it for the age-based orphan sweep to find
    # later. A SIGKILL in that same window skips this trap entirely; that
    # case is what the orphan-age sweep in acquire_gate_lock exists for.
    if [[ $GATE_RECLAIM_MUTEX_HELD_BY_SELF -eq 1 ]]; then
        rm -rf "${GATE_LOCK_FILE}.reclaiming" 2>/dev/null || true
    fi
}
trap release_gate_lock EXIT

# Narrow self-test seam for scenario F's cleanup proof. The outer
# `--lock-selftest` never receives this variable: it is passed only to the
# nested bare invocation below, where ignoring TERM lets the observer prove
# its TERM/KILL/reap path remains bounded and still reaches its own result
# reporting. This is deliberately not a production control surface.
if [[ "${MANIFOLD_GATE_SELFTEST_F_CHILD_MODE:-}" == "ignore-release" ]]; then
    trap '' TERM
fi

# ── Lock self-test (hidden verbs, no swift test involved) ───────────────────
# The cheapest honest proof the lock does what it claims: exercise the real
# acquire/release code path above against an isolated lock directory (never
# the production $GATE_LOCK_FILE) via six subprocess scenarios. Wired into
# ManifoldCoreTests as GateLockSelfTestScriptTests, following the repo's
# existing pattern for scripts/*.sh behavior tests (FuzzCIGateScriptTests
# et al.).
#
# --lock-selftest-hold <seconds> [markers-dir]: acquire the lock, hold it
# for <seconds>, then exit (the EXIT trap releases it) — the reusable
# "holder" building block for four of the six scenarios below (scenarios E
# and F run the real orchestration end-to-end instead, against the two
# different acquire_gate_lock call sites). The optional third
# argument names a directory where this process drops a uniquely-named
# marker file (its own PID) for exactly the window it believes it holds
# the lock — scenario D's concurrency check polls that directory's entry
# count in real time, which is granularity-independent (unlike comparing
# ACQUIRED/releasing timestamps, which only have 1s resolution on macOS —
# two genuinely sequential, non-overlapping holds can land in the same
# integer second under heavy contention and look identical to a real
# double-acquisition from timestamps alone).
if [[ "${1:-}" == "--lock-selftest-hold" ]]; then
    hold_seconds="${2:?'--lock-selftest-hold requires a seconds argument'}"
    markers_dir="${3:-}"
    echo "[gate-lock-hold] pid=$$ requesting lock at $(date +%s)"
    acquire_gate_lock
    echo "[gate-lock-hold] pid=$$ ACQUIRED at $(date +%s)"
    [[ -n "$markers_dir" ]] && touch "$markers_dir/active.$$"
    sleep "$hold_seconds"
    [[ -n "$markers_dir" ]] && rm -f "$markers_dir/active.$$"
    echo "[gate-lock-hold] pid=$$ releasing at $(date +%s)"
    exit 0
fi

# Scenarios E and F run the real `scripts/test.sh` orchestration with a stub
# `swift` prepended to PATH, so three full invocations complete in
# milliseconds instead of starting a real build. That substitution is the
# load-bearing precondition of both scenarios, and it is exactly the shape of
# thing that fails OPEN: if `swift` ever resolved to something other than the
# stub (an absolute-path invocation, a shell that rebuilds PATH, a sandbox
# that strips it), the nested run would silently drive the REAL toolchain
# inside an already-running `swift test` and nothing in the scenario would
# say so. Principle 6 forbids that everywhere else in this repo; a self-test
# for a fail-open defect must not contain one.
#
# So the stub proves itself before it is relied on: resolution is checked in
# the same non-interactive `bash -c` shape the nested script uses, and the
# stub must actually execute and emit its own marker. A miss returns 1 and
# the caller SKIPS the nested invocation entirely rather than letting a real
# toolchain start.
assert_stub_swift_effective() {
    local stub_dir="$1"
    local label="$2"
    local resolved probe

    resolved="$(PATH="$stub_dir:$PATH" bash -c 'command -v swift' 2>/dev/null)" || resolved=""
    if [[ "$resolved" != "$stub_dir/swift" ]]; then
        echo "[lock-selftest] scenario $label: FAIL (stub \`swift\` NOT in effect — 'command -v swift' resolved to '${resolved:-<nothing>}', expected '$stub_dir/swift'; refusing to run the nested invocation against a real toolchain)"
        return 1
    fi

    probe="$(PATH="$stub_dir:$PATH" bash -c 'swift --stub-effectiveness-probe' 2>&1)" || probe=""
    case "$probe" in
        *"[stub-swift]"*) ;;
        *)
            echo "[lock-selftest] scenario $label: FAIL (stub \`swift\` resolved but did not execute as the stub — probe output was '${probe:-<empty>}', expected a '[stub-swift]' marker; refusing to run the nested invocation against a real toolchain)"
            return 1
            ;;
    esac

    echo "[lock-selftest] scenario $label: stub \`swift\` verified in effect at $stub_dir/swift (resolution + execution both checked)"
    return 0
}

run_gate_lock_selftest() {
    local selftest_root
    selftest_root="${TMPDIR:-/tmp}/manifoldkit-gate-selftest-$$-$(date +%s)"
    local scenario_a_lock="$selftest_root/scenario-a.lock"
    local scenario_b_lock="$selftest_root/scenario-b.lock"
    mkdir -p "$selftest_root"
    local failures=0
    # Bounds every subprocess spawned below to a fast, loud failure instead
    # of the production 10800s (3h) default. Without this, a genuinely
    # broken reclaim/acquire path (exactly the thing scenario D exists to
    # sabotage-test) can leave a self-test subprocess spinning for the full
    # production ceiling — turning "the cheapest honest proof the lock
    # works" into a run that can itself hang the gate for three hours. 20s
    # comfortably covers scenario D's worst-case ~8-10s of expected
    # sequential contention (8 waiters x ~1s hold each) with headroom for a
    # loaded machine, while still failing fast and loud if something is
    # actually wedged.
    local selftest_ceiling_secs=20

    # ── Enclosing-run log guard (scenario G's arming step) ─────────────────
    # This self-test runs INSIDE a `swift test`, which in CI runs inside
    # `scripts/ci-test-with-watchdog.sh`. That wrapper exports
    # MANIFOLD_TEST_OUTPUT_FILE and then polls that file for SwiftPM progress
    # lines to decide whether the run is alive. Every descendant inherits the
    # variable — including the nested `scripts/test.sh` invocations scenarios
    # E and F spawn, whose own `swift test ... | tee "$OUTPUT_FILE"` would
    # otherwise TRUNCATE the live watchdog log out from under the outer run.
    #
    # That is not hypothetical: it is the measured cause of this PR's two CI
    # failures. The outer `tee` keeps its file offset across the truncation,
    # so its next write lands past a 100KB+ hole of NUL bytes; BSD grep then
    # classifies the log as binary ("Binary file ... matches" — the literal
    # line CI printed) and the watchdog's `current_count > LAST_LINE_COUNT`
    # re-arm condition can never be satisfied again. The run keeps making
    # real progress and the watchdog SIGABRTs it exactly STALL_SECONDS later
    # regardless — a fixed ~230-243s stall, insensitive to how much work any
    # scenario is configured to do.
    #
    # So: every nested invocation below gets its own MANIFOLD_TEST_OUTPUT_FILE
    # inside $selftest_root, and scenario G asserts the enclosing run's log
    # was left alone. When the variable is NOT inherited (a developer running
    # `--lock-selftest` by hand), a seeded stand-in is synthesised and
    # exported so the guard is armed identically in both environments —
    # otherwise the one check that would have caught this defect would be
    # vacuous everywhere except the CI run it was written for.
    local enclosing_log="${MANIFOLD_TEST_OUTPUT_FILE:-}"
    local enclosing_log_synthesised=0
    if [[ -z "$enclosing_log" ]]; then
        enclosing_log="$selftest_root/enclosing-run-stand-in.log"
        enclosing_log_synthesised=1
        local g_seed_i=1
        : > "$enclosing_log"
        while [[ $g_seed_i -le 200 ]]; do
            echo "[$g_seed_i/200] Testing ManifoldCoreTests.EnclosingRunStandIn/test_$g_seed_i" >> "$enclosing_log"
            g_seed_i=$((g_seed_i + 1))
        done
        export MANIFOLD_TEST_OUTPUT_FILE="$enclosing_log"
    fi
    local enclosing_progress_pattern='^\[[0-9]+/[0-9]+\] (Testing|Compiling|Write|Emitting) |^Emitting module |^Building for |^Build complete|^Planning build|^Test Case .* (passed|failed|skipped)'
    local enclosing_size_before=0 enclosing_count_before=0
    if [[ -f "$enclosing_log" ]]; then
        enclosing_size_before="$(wc -c < "$enclosing_log" | tr -d ' ')"
        enclosing_count_before="$(grep -acE "$enclosing_progress_pattern" "$enclosing_log" 2>/dev/null)" || enclosing_count_before=0
    fi

    echo "[lock-selftest] scenario A: second acquirer waits for the holder, then acquires after release"
    local holder_log="$selftest_root/holder.log"
    local second_log="$selftest_root/second.log"
    MANIFOLD_GATE_LOCK_FILE="$scenario_a_lock" MANIFOLD_GATE_LOCK_CEILING_SECS="$selftest_ceiling_secs" \
        "$0" --lock-selftest-hold 3 > "$holder_log" 2>&1 &
    local holder_pid=$!
    # Poll for the holder to have actually acquired (a non-empty lock file),
    # rather than a flat `sleep 1` — on a busy machine (contended tonight by
    # construction) a fixed sleep can fire before the holder's `ln` even
    # lands, making the second attempt win the race instead of waiting,
    # which fails this scenario for reasons unrelated to the lock and costs
    # a full gate re-run to notice.
    local a_wait_i=0
    while [[ ! -s "$scenario_a_lock" && $a_wait_i -lt 100 ]]; do
        sleep 0.1
        a_wait_i=$((a_wait_i + 1))
    done
    local t0 t1 elapsed
    t0=$(date +%s)
    MANIFOLD_GATE_LOCK_FILE="$scenario_a_lock" MANIFOLD_GATE_LOCK_POLL_SECS=1 MANIFOLD_GATE_LOCK_CEILING_SECS="$selftest_ceiling_secs" \
        "$0" --lock-selftest-hold 0 > "$second_log" 2>&1
    t1=$(date +%s)
    elapsed=$((t1 - t0))
    wait "$holder_pid" 2>/dev/null || true
    # Always surface the child's real output (not just on failure) — the
    # aggregate --lock-selftest stdout this function produces is itself
    # consumed as evidence (GateLockSelfTestScriptTests asserts against it
    # directly), so the actual production log lines belong in it
    # unconditionally, not paraphrased into a summary line only reachable
    # via a FAIL branch.
    cat "$second_log"
    if grep -q "waiting for gate lock held by PID ${holder_pid}" "$second_log" && [[ $elapsed -ge 1 ]]; then
        echo "[lock-selftest] scenario A: PASS (waited ${elapsed}s, saw 'waiting for gate lock held by PID ${holder_pid}')"
    else
        echo "[lock-selftest] scenario A: FAIL (elapsed=${elapsed}s)"
        failures=$((failures + 1))
    fi

    echo "[lock-selftest] scenario B: stale lock (dead holder PID) is reclaimed loudly"
    sleep 0 &
    local dead_pid=$!
    wait "$dead_pid" 2>/dev/null || true
    { printf '%s\n' "$dead_pid"; date +%s; } > "$scenario_b_lock"
    local reclaim_log="$selftest_root/reclaim.log"
    if MANIFOLD_GATE_LOCK_FILE="$scenario_b_lock" MANIFOLD_GATE_LOCK_CEILING_SECS="$selftest_ceiling_secs" \
        "$0" --lock-selftest-hold 0 > "$reclaim_log" 2>&1; then
        cat "$reclaim_log"
        if grep -q "STALE LOCK RECLAIMED: holder PID ${dead_pid}" "$reclaim_log"; then
            echo "[lock-selftest] scenario B: PASS (dead PID ${dead_pid} reclaimed loudly)"
        else
            echo "[lock-selftest] scenario B: FAIL (acquired but no reclaim message logged)"
            failures=$((failures + 1))
        fi
    else
        cat "$reclaim_log"
        echo "[lock-selftest] scenario B: FAIL (subprocess exited non-zero)"
        failures=$((failures + 1))
    fi

    echo "[lock-selftest] scenario C: a widowed MANIFOLD_GATE_LOCK_OWNER_PID (dead holder, or a lock this PID no longer holds) is not trusted — the process acquires for real instead of silently skipping"
    local scenario_c_lock="$selftest_root/scenario-c.lock"
    sleep 0 &
    local widowed_pid=$!
    wait "$widowed_pid" 2>/dev/null || true
    local widow_log="$selftest_root/widow.log"
    # Hold for long enough that the poll below can observe the lock file
    # mid-hold, before the child's EXIT trap releases it.
    MANIFOLD_GATE_LOCK_FILE="$scenario_c_lock" MANIFOLD_GATE_LOCK_OWNER_PID="$widowed_pid" \
        MANIFOLD_GATE_LOCK_CEILING_SECS="$selftest_ceiling_secs" \
        "$0" --lock-selftest-hold 2 > "$widow_log" 2>&1 &
    local widow_child_pid=$!
    local observed_real_acquire=0
    local poll_i=0
    while [[ $poll_i -lt 40 ]]; do
        # `-s` (exists AND non-empty) — with the hard-link publish design
        # the lock file is only ever observable fully formed, but this
        # still guards the instant before the very first `ln` in this
        # scenario lands at all.
        if [[ -s "$scenario_c_lock" ]]; then
            local seen_pid
            seen_pid="$(sed -n '1p' "$scenario_c_lock" 2>/dev/null)" || seen_pid=""
            if [[ "$seen_pid" == "$widow_child_pid" ]]; then
                observed_real_acquire=1
            fi
            break
        fi
        sleep 0.1
        poll_i=$((poll_i + 1))
    done
    wait "$widow_child_pid" 2>/dev/null || true
    cat "$widow_log"
    if [[ $observed_real_acquire -eq 1 ]] && grep -q "inherited MANIFOLD_GATE_LOCK_OWNER_PID=${widowed_pid} is stale" "$widow_log"; then
        echo "[lock-selftest] scenario C: PASS (widowed sentinel PID ${widowed_pid} rejected; PID ${widow_child_pid} acquired for real)"
    else
        echo "[lock-selftest] scenario C: FAIL (observed_real_acquire=${observed_real_acquire})"
        failures=$((failures + 1))
    fi

    # Scenario D is the regression test for the concurrent-reclaim race: N
    # waiters hitting a single dead-holder lock at once. Two prior designs
    # did not hold up under this exact measurement: a bare `rm -rf` reclaim
    # (every waiter reads the same dead PID and independently decides to
    # reclaim, racing each other and whichever waiter's own acquire is
    # mid-flight — 2/5 trials at 8 waiters produced two simultaneous
    # "holders", the rest hit `set -e` aborts on "Directory not empty");
    # and an atomic-rename-based reclaim with a "verify, then restore if
    # ambiguous" fallback (closed the double-acquisition, but the restore
    # path could hand a live PID's abandoned attempt back out as an
    # unreclaimable "ghost" lock — reproduced under real parallel load as
    # 7/8 waiters hitting the ceiling after only one successful handoff).
    # The hard-link design above has no partially-formed state for a
    # reclaimer to ever restore, which is what makes this scenario finally
    # pass under genuine heavy contention, not just low-contention runs.
    echo "[lock-selftest] scenario D: N concurrent waiters against one dead-holder lock must serialize with zero overlap and zero failures"
    # Round count and waiter count are configurable, defaulting to the
    # CHEAP shape (1 round). A real CI incident forced this: a 3-round
    # default (added to improve detection odds against a load-dependent
    # race — see the docstring on the Swift side) pushed this self-test's
    # own wall time from ~17s to ~36-40s on this machine, and CI's
    # `ci-test-with-watchdog.sh` kills the whole `swift test` process after
    # 240s of no progress — a single XCTest method that runs for minutes
    # emits nothing to that watchdog until it returns, and on a
    # resource-constrained CI runner (fewer cores, and this scenario alone
    # spawns 8 waiters x N rounds of subprocesses that compete with every
    # other parallel test worker for the same box) that ~2x local slowdown
    # was enough to blow through 240s and abort the whole run — a false
    # test-infra "failure" with a misleading generic error, distinct from
    # any assertion actually failing. `MANIFOLD_GATE_SELFTEST_D_ROUNDS`
    # (default 1) lets someone investigating reclaim contention by hand
    # opt into the heavier repeated-round shape without paying for it on
    # every CI run: `MANIFOLD_GATE_SELFTEST_D_ROUNDS=3 scripts/test.sh
    # --lock-selftest`. The concurrent-reclaim race itself IS load-
    # dependent (measured: 1/6 reclaim rounds showed overlap under 6-way
    # concurrency, 0/4 sequentially) regardless of round count — see the
    # Swift-side docstring for why this scenario does not claim guaranteed
    # sequential detection either way.
    local scenario_d_rounds="${MANIFOLD_GATE_SELFTEST_D_ROUNDS:-1}"
    local scenario_d_any_overlap=0
    local scenario_d_any_corruption=0
    local scenario_d_total_waiter_failures=0
    local scenario_d_total_complete=0
    local scenario_d_worst_max_concurrent=0
    local scenario_d_failed_round_logs=""
    local scenario_d_round_summaries=""
    # 8 is the count that originally reproduced the reclaim-race bug, and
    # is still the default a human reaches for via the env override below
    # when deliberately reproducing that bug. The DEFAULT here is smaller
    # (4): cutting rounds alone (see MANIFOLD_GATE_SELFTEST_D_ROUNDS above)
    # fixed the wall-clock blowup that broke CI, but a shared,
    # resource-constrained CI runner is also the exact environment where 8
    # concurrent subprocesses can saturate the box and make "no test
    # progress" a global symptom (every other parallel test worker stalling
    # too), not just a local one — cutting the default waiter count too is
    # a second, independent lever on the same underlying risk. 4 still
    # exercises genuine concurrent contention (multiple overlapping
    # claims against one dead-holder lock); it does not reduce to the
    # single-waiter case scenario A already covers.
    local waiter_count="${MANIFOLD_GATE_SELFTEST_D_WAITERS:-4}"
    local scenario_d_round=1
    while [[ $scenario_d_round -le $scenario_d_rounds ]]; do
        local scenario_d_lock="$selftest_root/scenario-d-r${scenario_d_round}.lock"
        sleep 0 &
        local dead_pid_d=$!
        wait "$dead_pid_d" 2>/dev/null || true
        { printf '%s\n' "$dead_pid_d"; date +%s; } > "$scenario_d_lock"

        # Ground-truth concurrency check: each waiter drops a uniquely-named
        # marker file for exactly the window it believes it holds the lock
        # (see --lock-selftest-hold's third argument), and a background
        # observer polls that directory's entry count at high frequency for
        # the whole round, recording the maximum ever seen. This is
        # deliberately NOT based on comparing ACQUIRED/releasing timestamps:
        # macOS `date` has no sub-second format, and under enough parallel
        # load (measured: ten concurrent `--lock-selftest` runs at once) two
        # genuinely sequential, non-overlapping 1s holds can land in the same
        # integer second and look identical to a real double-acquisition
        # from timestamps alone — a false-positive class distinct from the
        # true bug this scenario exists to catch. The marker count has no
        # such ambiguity: it can only ever exceed 1 while two processes are
        # ACTUALLY concurrently between their own acquire and release.
        local scenario_d_markers_dir="$selftest_root/scenario-d-markers-r${scenario_d_round}"
        local scenario_d_stop_file="$selftest_root/scenario-d-observer-stop-r${scenario_d_round}"
        local scenario_d_max_concurrent_file="$selftest_root/scenario-d-max-concurrent-r${scenario_d_round}"
        mkdir -p "$scenario_d_markers_dir"
        echo 0 > "$scenario_d_max_concurrent_file"
        (
            max_seen=0
            while [[ ! -f "$scenario_d_stop_file" ]]; do
                count=$(find "$scenario_d_markers_dir" -maxdepth 1 -name 'active.*' 2>/dev/null | wc -l | tr -d ' ')
                [[ -z "$count" ]] && count=0
                [[ "$count" -gt "$max_seen" ]] && max_seen="$count"
                sleep 0.02
            done
            # One last check after the stop signal, in case the final
            # waiter's marker window briefly overlapped observing the stop
            # file itself.
            count=$(find "$scenario_d_markers_dir" -maxdepth 1 -name 'active.*' 2>/dev/null | wc -l | tr -d ' ')
            [[ -z "$count" ]] && count=0
            [[ "$count" -gt "$max_seen" ]] && max_seen="$count"
            echo "$max_seen" > "$scenario_d_max_concurrent_file"
        ) &
        local scenario_d_observer_pid=$!

        # 8 waiters matches the reproduction that surfaced the bug. Each
        # holds for 1s so there's a real, observable window for the
        # marker-based observer above to sample during.
        local waiter_pids="" waiter_log_list=""
        local wi=0
        while [[ $wi -lt $waiter_count ]]; do
            local wlog="$selftest_root/waiter-r${scenario_d_round}-$wi.log"
            # POLL_SECS must stay an integer: acquire_gate_lock's `waited`
            # accumulator uses `$(( ))` arithmetic, which errors on a
            # fractional value (discovered the hard way — a 0.2 override
            # here broke the production polling loop itself, not just this
            # scenario).
            MANIFOLD_GATE_LOCK_FILE="$scenario_d_lock" MANIFOLD_GATE_LOCK_POLL_SECS=1 \
                MANIFOLD_GATE_LOCK_CEILING_SECS="$selftest_ceiling_secs" \
                "$0" --lock-selftest-hold 1 "$scenario_d_markers_dir" > "$wlog" 2>&1 &
            waiter_pids="$waiter_pids $!"
            waiter_log_list="$waiter_log_list $wlog"
            wi=$((wi + 1))
        done

        local waiter_failures=0 wp
        for wp in $waiter_pids; do
            if ! wait "$wp"; then
                waiter_failures=$((waiter_failures + 1))
            fi
        done

        touch "$scenario_d_stop_file"
        wait "$scenario_d_observer_pid" 2>/dev/null || true
        local scenario_d_max_concurrent
        scenario_d_max_concurrent="$(cat "$scenario_d_max_concurrent_file" 2>/dev/null)" || scenario_d_max_concurrent=""
        [[ -z "$scenario_d_max_concurrent" ]] && scenario_d_max_concurrent=0
        local overlap_found=0
        [[ "$scenario_d_max_concurrent" -gt 1 ]] && overlap_found=1
        [[ "$scenario_d_max_concurrent" -gt "$scenario_d_worst_max_concurrent" ]] && scenario_d_worst_max_concurrent="$scenario_d_max_concurrent"

        # Sanity count only (not the overlap signal above): did every waiter
        # log both an ACQUIRED and a releasing line at all, regardless of
        # timing precision — a waiter missing either already shows up in
        # waiter_failures, so this mostly catches a waiter whose subprocess
        # exited 0 without ever logging a complete cycle.
        local wlog a_ts r_ts n=0
        for wlog in $waiter_log_list; do
            a_ts="$(grep -c 'ACQUIRED at' "$wlog")" || a_ts=0
            r_ts="$(grep -c 'releasing at' "$wlog")" || r_ts=0
            if [[ "$a_ts" -gt 0 && "$r_ts" -gt 0 ]]; then
                n=$((n + 1))
            fi
        done

        # A bare "No such file or directory" / "Directory not empty" from a
        # write racing a concurrent reclaim is now an EXPECTED, handled
        # outcome (each such line is immediately followed by a "[gate-lock]
        # warning: ...retrying." recovery and the process goes on to
        # acquire normally — see waiter_failures/n below for what actually
        # signals a real problem). What's never expected: a bash
        # syntax/runtime error the script itself doesn't recognize and
        # recover from (a regression in the arithmetic or argument
        # handling, not the lock's own contention path).
        local corruption_found=0
        for wlog in $waiter_log_list; do
            if grep -qE 'arithmetic syntax error|Unknown option|unbound variable' "$wlog"; then
                corruption_found=1
            fi
        done

        scenario_d_total_waiter_failures=$((scenario_d_total_waiter_failures + waiter_failures))
        scenario_d_total_complete=$((scenario_d_total_complete + n))
        scenario_d_round_summaries="${scenario_d_round_summaries}round ${scenario_d_round}: max_concurrent=${scenario_d_max_concurrent} waiter_failures=${waiter_failures} complete=${n}/${waiter_count} corruption=${corruption_found}; "
        if [[ $overlap_found -eq 1 || $waiter_failures -gt 0 || $corruption_found -eq 1 || $n -ne $waiter_count ]]; then
            [[ $overlap_found -eq 1 ]] && scenario_d_any_overlap=1
            [[ $corruption_found -eq 1 ]] && scenario_d_any_corruption=1
            for wlog in $waiter_log_list; do
                scenario_d_failed_round_logs="${scenario_d_failed_round_logs} $wlog"
            done
        fi

        scenario_d_round=$((scenario_d_round + 1))
    done

    local scenario_d_total_expected=$((waiter_count * scenario_d_rounds))
    if [[ $scenario_d_total_waiter_failures -eq 0 && $scenario_d_any_overlap -eq 0 \
          && $scenario_d_any_corruption -eq 0 && $scenario_d_total_complete -eq $scenario_d_total_expected ]]; then
        echo "[lock-selftest] scenario D: PASS (${scenario_d_rounds} rounds x ${waiter_count} waiters, 0 failures across all rounds, worst max-concurrent observed: ${scenario_d_worst_max_concurrent}, 0 corruption errors) — ${scenario_d_round_summaries}"
    else
        echo "[lock-selftest] scenario D: FAIL (total_waiter_failures=${scenario_d_total_waiter_failures} any_overlap=${scenario_d_any_overlap} any_corruption=${scenario_d_any_corruption} complete_cycles=${scenario_d_total_complete}/${scenario_d_total_expected}) — ${scenario_d_round_summaries}"
        for wlog in $scenario_d_failed_round_logs; do
            echo "---- $wlog ----"
            cat "$wlog"
        done
        failures=$((failures + 1))
    fi

    # Scenarios A-D all exercise acquire_gate_lock/release_gate_lock
    # directly and prove the PRIMITIVE is correct. None of them prove the
    # primitive is actually CALLED from the real --profile local shape —
    # deleting both call sites (the parent's acquire before the
    # three-invocation re-exec, and the fallthrough default-path acquire)
    # while leaving acquire_gate_lock itself untouched left every one of
    # them green, because they never touch that code path at all. Scenario
    # E closes that gap: it runs the REAL --profile local orchestration
    # (re-exec, exit-code propagation, the works) against a temp copy of
    # this very script, with a stub `swift` on PATH so three full
    # invocations complete in seconds with no actual build. A stub `swift`
    # test also makes this the concurrency-neutering detector: if
    # release_gate_lock's `rm -rf` were ever neutered, the lock directory
    # would still exist when this scenario checks at the end — the specific
    # assertion the reviewer named as the one that catches it.
    echo "[lock-selftest] scenario E: the lock is actually WIRED into the --profile local three-invocation shape (not just a working, unused primitive)"
    local scenario_e_root="$selftest_root/scenario-e"
    local scenario_e_copy="$scenario_e_root/scripts/test.sh"
    local scenario_e_watchdog_copy="$scenario_e_root/scripts/ci-test-with-watchdog.sh"
    local scenario_e_stub_dir="$scenario_e_root/stub-bin"
    local scenario_e_lock="$scenario_e_root/lock"
    mkdir -p "$scenario_e_root/scripts" "$scenario_e_stub_dir"
    cp "$0" "$scenario_e_copy"
    chmod +x "$scenario_e_copy"
    # scripts/test.sh resolves ci-test-with-watchdog.sh relative to $0's own
    # location (CI_TEST_WATCHDOG="$PACKAGE_DIR/scripts/ci-test-with-watchdog.sh",
    # PACKAGE_DIR derived from $0) — that resolution is correct, but scenario E
    # used to copy ONLY $0 here, leaving the wrapper missing at the resolved
    # path in this temp package. With the wrapper missing, the copy's own
    # fail-closed branch returned 127 for EVERY invocation `--profile local`
    # drives through run_leaf_with_local_watchdog(), and `wait` on that exit
    # code under `set -euo pipefail` aborted this whole self-test mid-scenario
    # (no "scenario E: FAIL" line, F and G never ran). Copy the real wrapper
    # alongside, unmodified, so the temp package has the same sibling layout
    # the real repo does — never a second implementation of the wrapper.
    cp "$PACKAGE_DIR/scripts/ci-test-with-watchdog.sh" "$scenario_e_watchdog_copy"
    chmod +x "$scenario_e_watchdog_copy"

    cat > "$scenario_e_stub_dir/swift" <<'STUB'
#!/usr/bin/env bash
# Stand-in for the real `swift` toolchain — scenario E is about proving the
# gate lock is wired into the --profile local re-exec shape, not about
# actually building or testing anything, so this exits 0 instantly whatever
# it's called with. Always emits one line matching test.sh's own
# ManifoldMCPTests pattern: invocation 1's real --filter list includes
# ManifoldMCPTests, and test.sh's own honest-summary check treats a
# requested MCP filter that matched zero test cases as a TRIPWIRE (exit 3)
# — without this line the stub would trip that check on every run, for
# reasons having nothing to do with the lock this scenario exists to test.
echo "[stub-swift] $*"
echo "Test Case '-[ManifoldMCPTests.StubTest testStub]' passed (0.001 seconds)."
exit 0
STUB
    chmod +x "$scenario_e_stub_dir/swift"

    local scenario_e_log="$selftest_root/scenario-e.log"
    local scenario_e_stub_ok=1
    assert_stub_swift_effective "$scenario_e_stub_dir" "E" || scenario_e_stub_ok=0
    if [[ $scenario_e_stub_ok -eq 0 ]]; then
        failures=$((failures + 1))
        rm -rf "$scenario_e_root"
    else
    # MANIFOLD_TEST_OUTPUT_FILE is overridden per nested invocation, NOT left
    # to inheritance: in CI it points at the live watchdog log, and this
    # child's own `tee "$OUTPUT_FILE"` would truncate it mid-run. See the
    # enclosing-run log guard at the top of this function and scenario G.
    PATH="$scenario_e_stub_dir:$PATH" MANIFOLD_GATE_LOCK_FILE="$scenario_e_lock" \
        MANIFOLD_TEST_OUTPUT_FILE="$scenario_e_root/nested-test-output.log" \
        "$scenario_e_copy" --profile local > "$scenario_e_log" 2>&1 &
    local scenario_e_pid=$!

    # Sample the lock file's content while the (stub-backed, so fast) run
    # is in flight. Every non-empty sample must be the TOP-LEVEL parent's
    # own PID (scenario_e_pid) — never anything else — proving the lock is
    # acquired once, before the first re-exec, and held for the whole
    # three-invocation shape rather than being re-acquired (or silently
    # absent) per invocation.
    local scenario_e_samples="" scenario_e_sample_count=0
    local scenario_e_poll_i=0
    while kill -0 "$scenario_e_pid" 2>/dev/null && [[ $scenario_e_poll_i -lt 200 ]]; do
        if [[ -s "$scenario_e_lock" ]]; then
            local scenario_e_sample
            scenario_e_sample="$(sed -n '1p' "$scenario_e_lock" 2>/dev/null)" || scenario_e_sample=""
            if [[ -n "$scenario_e_sample" ]]; then
                scenario_e_samples="$scenario_e_samples $scenario_e_sample"
                scenario_e_sample_count=$((scenario_e_sample_count + 1))
            fi
        fi
        sleep 0.05
        scenario_e_poll_i=$((scenario_e_poll_i + 1))
    done
    if kill -0 "$scenario_e_pid" 2>/dev/null; then
        # Still running after a 10s poll ceiling with a stub `swift` that
        # exits instantly — something is genuinely wrong (e.g. the stub was
        # never picked up and a real build started). Kill rather than block
        # on `wait` indefinitely; the Swift-side run() timeout is the final
        # backstop, but this keeps the shell-level self-test itself bounded.
        kill -TERM "$scenario_e_pid" 2>/dev/null || true
        sleep 1
        kill -KILL "$scenario_e_pid" 2>/dev/null || true
    fi
    wait "$scenario_e_pid" 2>/dev/null
    local scenario_e_exit=$?
    cat "$scenario_e_log"

    local scenario_e_invocation_count
    scenario_e_invocation_count="$(grep -c '^Running swift test in:' "$scenario_e_log")" || scenario_e_invocation_count=0
    local scenario_e_release_count
    scenario_e_release_count="$(grep -c '^\[gate-lock\] released' "$scenario_e_log")" || scenario_e_release_count=0
    # End-to-end proof the stub is what actually ran inside the nested
    # invocations — `Running swift test in:` is printed by the script whatever
    # `swift` turns out to be, so it alone cannot distinguish "stub ran three
    # times" from "the real toolchain ran three times". One stub line per
    # invocation.
    local scenario_e_stub_lines
    scenario_e_stub_lines="$(grep -c '^\[stub-swift\]' "$scenario_e_log")" || scenario_e_stub_lines=0

    local scenario_e_samples_ok=1
    if [[ $scenario_e_sample_count -eq 0 ]]; then
        scenario_e_samples_ok=0
    fi
    local scenario_e_s
    for scenario_e_s in $scenario_e_samples; do
        [[ "$scenario_e_s" == "$scenario_e_pid" ]] || scenario_e_samples_ok=0
    done

    local scenario_e_lock_gone=1
    [[ -e "$scenario_e_lock" ]] && scenario_e_lock_gone=0

    if [[ $scenario_e_exit -eq 0 && $scenario_e_invocation_count -eq 3 && $scenario_e_release_count -eq 1 \
          && $scenario_e_samples_ok -eq 1 && $scenario_e_lock_gone -eq 1 && $scenario_e_stub_lines -eq 3 ]]; then
        echo "[lock-selftest] scenario E: PASS (parent pid ${scenario_e_pid} held the lock across ${scenario_e_sample_count} sample(s), 3 invocations observed, all 3 against the stub \`swift\`, released once, lock file gone)"
    else
        echo "[lock-selftest] scenario E: FAIL (exit=${scenario_e_exit} invocations=${scenario_e_invocation_count}/3 stub_invocations=${scenario_e_stub_lines}/3 releases=${scenario_e_release_count}/1 samples_ok=${scenario_e_samples_ok} (n=${scenario_e_sample_count}, samples='${scenario_e_samples}', expected pid=${scenario_e_pid}) lock_gone=${scenario_e_lock_gone})"
        failures=$((failures + 1))
    fi

    rm -rf "$scenario_e_root"
    fi  # end scenario E (skipped wholesale when the stub `swift` is not in effect)

    # Scenario E proves ONE of the two acquire_gate_lock call sites is wired
    # in — the parent's pre-re-exec acquire, reached only via --profile
    # local/ci. It cannot see the OTHER call site (the fallthrough acquire
    # at the bottom of the script, reached by a bare invocation, --profile
    # spike, or a narrow --filter override): every child E spawns skips
    # acquisition via the inherited sentinel, so that code path is never
    # exercised. Deleting ONLY the fallthrough acquire — leaving the
    # --profile local/ci call site untouched — makes scenario E (and A-D,
    # which call acquire_gate_lock directly) all stay green while `swift
    # test` reached through a bare `scripts/test.sh` or `--profile spike`
    # runs completely unlocked with nothing noticing. This PR's own
    # AGENTS.md change widens when `--profile spike` is permissible, so
    # that path gets MORE traffic going forward, not less — this scenario
    # closes the gap.
    #
    # --profile spike takes a different branch through the profile-
    # resolution `if`/`elif` above but falls through to this exact same
    # line — there is only one fallthrough acquire_gate_lock call site in
    # the whole script — so proving it here structurally covers spike too;
    # a genuinely separate spike-specific bug would have to be a second,
    # independent call site, which does not exist.
    echo "[lock-selftest] scenario F: the lock is wired into the FALLTHROUGH acquire (bare invocation / --profile spike), not just the --profile local/ci pre-re-exec acquire"
    local scenario_f_root="$selftest_root/scenario-f"
    local scenario_f_copy="$scenario_f_root/scripts/test.sh"
    local scenario_f_stub_dir="$scenario_f_root/stub-bin"
    local scenario_f_lock="$scenario_f_root/lock"
    mkdir -p "$scenario_f_root/scripts" "$scenario_f_stub_dir"
    cp "$0" "$scenario_f_copy"
    chmod +x "$scenario_f_copy"

    # Same stub as scenario E: no real build, exits fast, emits the one
    # line test.sh's own MCP-filter tripwire would otherwise flag (moot for
    # a bare invocation — no --filter means MCP_FILTER_REQUESTED stays
    # 0 — but harmless to include). Unlike E, this stub deliberately pauses
    # at a ready/release handshake. It is only reached AFTER the bare nested
    # invocation's fallthrough acquire, so its ready marker lets the observer
    # inspect a stable lock owner instead of racing a fast acquire/run/release
    # lifecycle at a 50ms polling interval (#2479).
    cat > "$scenario_f_stub_dir/swift" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "--stub-effectiveness-probe" ]]; then
    echo "[stub-swift] $*"
    exit 0
fi

ready_file="${MANIFOLD_GATE_SELFTEST_F_READY_FILE:?'scenario F stub needs MANIFOLD_GATE_SELFTEST_F_READY_FILE'}"
release_file="${MANIFOLD_GATE_SELFTEST_F_RELEASE_FILE:?'scenario F stub needs MANIFOLD_GATE_SELFTEST_F_RELEASE_FILE'}"
stub_pid_file="${MANIFOLD_GATE_SELFTEST_F_STUB_PID_FILE:?'scenario F stub needs MANIFOLD_GATE_SELFTEST_F_STUB_PID_FILE'}"
stub_invocation_file="${MANIFOLD_GATE_SELFTEST_F_STUB_INVOCATION_RECORD_FILE:?'scenario F stub needs MANIFOLD_GATE_SELFTEST_F_STUB_INVOCATION_RECORD_FILE'}"
stub_start_identity="$(ps -p "$$" -o lstart=)"
if [[ "${MANIFOLD_GATE_SELFTEST_F_STUB_MODE:-}" == "identity-mismatch" ]]; then
    stub_start_identity="deliberately-mismatched-start-identity"
fi
printf '%s\n%s\n%s\n' "$$" "$stub_start_identity" "$0" > "$stub_pid_file"
# Count real stub launches separately from diagnostic output. The stuck-child
# fixture intentionally logs both that it is ignoring release and that it saw
# force-exit; those are two messages from one process, not two invocations.
printf '%s\n' "$$" >> "$stub_invocation_file"

if [[ "${MANIFOLD_GATE_SELFTEST_F_STUB_MODE:-}" != "withhold-ready" ]]; then
    touch "$ready_file"
else
    echo "[stub-swift] scenario F: deliberately withholding the ready signal"
fi

wait_i=0
while [[ ! -e "$release_file" && $wait_i -lt 200 ]]; do
    sleep 0.05
    wait_i=$((wait_i + 1))
done
if [[ ! -e "$release_file" ]]; then
    echo "[stub-swift] scenario F: FAIL (timed out after 10s waiting for the observer release signal)" >&2
    exit 76
fi

# XCTest's bounded-reap fixture needs the nested test.sh process itself to
# survive TERM, then leaves this direct child alive until the observer has
# sent KILL and dropped the force-exit marker. That makes the cleanup path
# real without leaking a long-running orphan if the nested shell is killed.
if [[ "${MANIFOLD_GATE_SELFTEST_F_STUB_MODE:-}" == "ignore-release" ]]; then
    force_exit_file="${MANIFOLD_GATE_SELFTEST_F_FORCE_EXIT_FILE:?'scenario F ignore-release fixture needs MANIFOLD_GATE_SELFTEST_F_FORCE_EXIT_FILE'}"
    trap '' TERM
    echo "[stub-swift] scenario F: deliberately ignoring observer release and TERM until cleanup"
    while [[ ! -e "$force_exit_file" ]]; do
        sleep 0.05
    done
    echo "[stub-swift] scenario F: cleanup force-exit observed"
    exit 77
fi

# This deliberately records a mismatched start identity while retaining the
# real PID. The observer must report the mismatch and refuse to signal that
# PID; the marker below makes this a deterministic XCTest proof rather than a
# PID-reuse race that is hard to reproduce intentionally.
if [[ "${MANIFOLD_GATE_SELFTEST_F_STUB_MODE:-}" == "identity-mismatch" ]]; then
    identity_observed_file="${MANIFOLD_GATE_SELFTEST_F_IDENTITY_MISMATCH_OBSERVED_FILE:?'scenario F identity fixture needs MANIFOLD_GATE_SELFTEST_F_IDENTITY_MISMATCH_OBSERVED_FILE'}"
    force_exit_file="${MANIFOLD_GATE_SELFTEST_F_FORCE_EXIT_FILE:?'scenario F identity fixture needs MANIFOLD_GATE_SELFTEST_F_FORCE_EXIT_FILE'}"
    term_seen_file="${MANIFOLD_GATE_SELFTEST_F_TERM_SEEN_FILE:?'scenario F identity fixture needs MANIFOLD_GATE_SELFTEST_F_TERM_SEEN_FILE'}"
    trap 'touch "$term_seen_file"; exit 79' TERM
    echo "[stub-swift] scenario F: deliberately reporting a mismatched process identity"
    wait_i=0
    while [[ ! -e "$identity_observed_file" && $wait_i -lt 300 ]]; do
        sleep 0.05
        wait_i=$((wait_i + 1))
    done
    if [[ ! -e "$identity_observed_file" ]]; then
        echo "[stub-swift] scenario F: FAIL (identity mismatch was not observed before 15s timeout)" >&2
        exit 80
    fi
    while [[ ! -e "$force_exit_file" ]]; do
        sleep 0.05
    done
    echo "[stub-swift] scenario F: identity mismatch cleanup observed"
    exit 77
fi

if [[ "${MANIFOLD_GATE_SELFTEST_F_STUB_MODE:-}" == "extra-diagnostic" ]]; then
    # Narrow XCTest seam: output has no bearing on how many times this stub
    # was launched. Scenario F must keep passing with this second message.
    echo "[stub-swift] scenario F: deliberately emitting an extra diagnostic line"
fi

echo "[stub-swift] $*"
echo "Test Case '-[ManifoldMCPTests.StubTest testStub]' passed (0.001 seconds)."
exit 0
STUB
    chmod +x "$scenario_f_stub_dir/swift"

    local scenario_f_log="$selftest_root/scenario-f.log"
    local scenario_f_stub_ok=1
    assert_stub_swift_effective "$scenario_f_stub_dir" "F" || scenario_f_stub_ok=0
    if [[ $scenario_f_stub_ok -eq 0 ]]; then
        failures=$((failures + 1))
        rm -rf "$scenario_f_root"
    else
    # Bare invocation — no --profile, no --filter. This is exactly the
    # "plain scripts/test.sh" shape: PROFILE stays empty, so the entire
    # --profile resolution block is skipped and execution falls straight
    # through to the single acquire_gate_lock call at the bottom of the
    # script — the call site this scenario exists to prove is live.
    # MANIFOLD_TEST_OUTPUT_FILE overridden for the same reason as scenario E.
    # The default PID record lives under scenario F's temp root. XCTest can
    # request a separate record so it can verify the fixture stub is gone
    # after this self-test has returned.
    local scenario_f_stub_pid_file="${MANIFOLD_GATE_SELFTEST_F_STUB_PID_RECORD_FILE:-$scenario_f_root/stub.pid}"
    local scenario_f_stub_invocation_file="$scenario_f_root/stub-invocations"
    local scenario_f_identity_observed_file="$scenario_f_root/identity-mismatch-observed"
    local scenario_f_term_seen_file="${MANIFOLD_GATE_SELFTEST_F_TERM_SEEN_FILE:-$scenario_f_root/stub-term-seen}"
    local scenario_f_parent_hold_file="$scenario_f_root/parent-hold-release"
    rm -f "$scenario_f_stub_pid_file" "$scenario_f_stub_invocation_file"
    rm -f "$scenario_f_identity_observed_file" "$scenario_f_term_seen_file"
    PATH="$scenario_f_stub_dir:$PATH" MANIFOLD_GATE_LOCK_FILE="$scenario_f_lock" \
        MANIFOLD_TEST_OUTPUT_FILE="$scenario_f_root/nested-test-output.log" \
        MANIFOLD_GATE_SELFTEST_F_READY_FILE="$scenario_f_root/ready" \
        MANIFOLD_GATE_SELFTEST_F_RELEASE_FILE="$scenario_f_root/release" \
        MANIFOLD_GATE_SELFTEST_F_FORCE_EXIT_FILE="$scenario_f_root/force-exit" \
        MANIFOLD_GATE_SELFTEST_F_PARENT_HOLD_FILE="$scenario_f_parent_hold_file" \
        MANIFOLD_GATE_SELFTEST_F_STUB_PID_FILE="$scenario_f_stub_pid_file" \
        MANIFOLD_GATE_SELFTEST_F_STUB_INVOCATION_RECORD_FILE="$scenario_f_stub_invocation_file" \
        MANIFOLD_GATE_SELFTEST_F_IDENTITY_MISMATCH_OBSERVED_FILE="$scenario_f_identity_observed_file" \
        MANIFOLD_GATE_SELFTEST_F_TERM_SEEN_FILE="$scenario_f_term_seen_file" \
        MANIFOLD_GATE_SELFTEST_F_CHILD_MODE="${MANIFOLD_GATE_SELFTEST_F_STUB_MODE:-}" \
        "$scenario_f_copy" > "$scenario_f_log" 2>&1 &
    local scenario_f_pid=$!

    # The stub reaches its ready marker only after the nested invocation has
    # passed the fallthrough acquire. Wait for that bounded handshake, then
    # inspect the lock exactly once while the stub is deliberately held. This
    # avoids the old n=0 false-red: a successful stub used to acquire, run,
    # and release entirely between two 50ms observer samples.
    local scenario_f_ready_file="$scenario_f_root/ready"
    local scenario_f_release_file="$scenario_f_root/release"
    local scenario_f_ready=0 scenario_f_handshake_status="ready"
    local scenario_f_lock_owner="<not-observed>"
    local scenario_f_poll_i=0
    while [[ ! -e "$scenario_f_ready_file" ]] && kill -0 "$scenario_f_pid" 2>/dev/null && [[ $scenario_f_poll_i -lt 100 ]]; do
        sleep 0.05
        scenario_f_poll_i=$((scenario_f_poll_i + 1))
    done
    if [[ -e "$scenario_f_ready_file" ]]; then
        scenario_f_ready=1
        if [[ -s "$scenario_f_lock" ]]; then
            scenario_f_lock_owner="$(sed -n '1p' "$scenario_f_lock" 2>/dev/null)" || scenario_f_lock_owner=""
            [[ -z "$scenario_f_lock_owner" ]] && scenario_f_lock_owner="<empty>"
        else
            scenario_f_lock_owner="<missing>"
        fi
    elif [[ $scenario_f_poll_i -ge 100 ]]; then
        scenario_f_handshake_status="timed out waiting 5s for ready marker"
    else
        scenario_f_handshake_status="child exited before ready marker"
    fi

    # Always release the stub, including when the ready marker or lock is
    # absent. A sabotaged call site must report a deterministic failure, not
    # strand a child until an outer timeout happens to clean it up.
    touch "$scenario_f_release_file"

    # The nested run should exit immediately once released. If it does not,
    # clean it up with two separately bounded grace periods. Do NOT call an
    # unconditional `wait` after TERM/KILL: under `set -e`, a non-zero wait
    # could abort before scenario F and the aggregate RESULT are printed, and
    # a pathological child could make that wait hang forever.
    local scenario_f_exit_timeout=0 scenario_f_exit=125
    local scenario_f_reap_status="reaped-normally"
    local scenario_f_cleanup_stage="none"
    local scenario_f_parent_reaped=0
    scenario_f_poll_i=0
    while kill -0 "$scenario_f_pid" 2>/dev/null && [[ $scenario_f_poll_i -lt 200 ]]; do
        sleep 0.05
        scenario_f_poll_i=$((scenario_f_poll_i + 1))
    done
    if kill -0 "$scenario_f_pid" 2>/dev/null; then
        scenario_f_exit_timeout=1
        scenario_f_cleanup_stage="TERM"
        if ! kill -TERM "$scenario_f_pid" 2>/dev/null; then
            scenario_f_reap_status="TERM-send-failed"
        fi
        scenario_f_poll_i=0
        while kill -0 "$scenario_f_pid" 2>/dev/null && [[ $scenario_f_poll_i -lt 20 ]]; do
            sleep 0.05
            scenario_f_poll_i=$((scenario_f_poll_i + 1))
        done
        if kill -0 "$scenario_f_pid" 2>/dev/null; then
            scenario_f_cleanup_stage="KILL"
            # Let the known direct stub exit while its known parent remains
            # alive and waiting. KILLing the parent first would orphan that
            # stub and turn its normal post-exit state into a PID-identity
            # race. This is only a marker; it never signals a PID.
            touch "$scenario_f_root/force-exit"
            local scenario_f_pre_kill_stub_pid
            scenario_f_pre_kill_stub_pid="$(sed -n '1p' "$scenario_f_stub_pid_file" 2>/dev/null)" || scenario_f_pre_kill_stub_pid=""
            if [[ "$scenario_f_pre_kill_stub_pid" =~ ^[0-9]+$ ]]; then
                scenario_f_poll_i=0
                while kill -0 "$scenario_f_pre_kill_stub_pid" 2>/dev/null && [[ $scenario_f_poll_i -lt 20 ]]; do
                    sleep 0.05
                    scenario_f_poll_i=$((scenario_f_poll_i + 1))
                done
            fi
            if ! kill -KILL "$scenario_f_pid" 2>/dev/null; then
                scenario_f_reap_status="KILL-send-failed"
            fi
            scenario_f_poll_i=0
            while kill -0 "$scenario_f_pid" 2>/dev/null && [[ $scenario_f_poll_i -lt 20 ]]; do
                sleep 0.05
                scenario_f_poll_i=$((scenario_f_poll_i + 1))
            done
        fi
    fi
    if kill -0 "$scenario_f_pid" 2>/dev/null; then
        scenario_f_exit=124
        scenario_f_reap_status="still-live-after-${scenario_f_cleanup_stage}"
    elif wait "$scenario_f_pid" 2>/dev/null; then
        scenario_f_parent_reaped=1
        scenario_f_exit=0
        case "$scenario_f_cleanup_stage" in
            TERM) scenario_f_reap_status="reaped-after-TERM" ;;
            KILL) scenario_f_reap_status="reaped-after-KILL" ;;
        esac
    else
        scenario_f_exit=$?
        scenario_f_parent_reaped=1
        case "$scenario_f_cleanup_stage" in
            TERM) scenario_f_reap_status="reaped-after-TERM" ;;
            KILL) scenario_f_reap_status="reaped-after-KILL" ;;
        esac
    fi
    # KILL skips the lock owner's EXIT trap. Scenario F's lock is private to
    # this self-test, and this removal is permitted only after reaping the
    # direct owner, confirming no process currently holds its PID, and reading
    # the unchanged owner record immediately before unlinking. A live/reused
    # PID or changed record stays loud and untouched.
    local scenario_f_lock_cleanup="not-needed"
    if [[ -e "$scenario_f_lock" ]]; then
        scenario_f_lock_cleanup="unvalidated-stale-lock"
        local scenario_f_stale_owner
        scenario_f_stale_owner="$(sed -n '1p' "$scenario_f_lock" 2>/dev/null)" || scenario_f_stale_owner=""
        if [[ $scenario_f_parent_reaped -eq 1 && "$scenario_f_stale_owner" == "$scenario_f_pid" ]] && ! kill -0 "$scenario_f_pid" 2>/dev/null; then
            scenario_f_stale_owner="$(sed -n '1p' "$scenario_f_lock" 2>/dev/null)" || scenario_f_stale_owner=""
            if [[ "$scenario_f_stale_owner" == "$scenario_f_pid" ]] && ! kill -0 "$scenario_f_pid" 2>/dev/null; then
                rm -f "$scenario_f_lock"
                if [[ ! -e "$scenario_f_lock" ]]; then
                    scenario_f_lock_cleanup="reclaimed-validated-dead-parent"
                else
                    scenario_f_lock_cleanup="validated-parent-remove-failed"
                fi
            else
                scenario_f_lock_cleanup="owner-changed-or-pid-reused-before-reclaim"
            fi
        elif kill -0 "$scenario_f_pid" 2>/dev/null; then
            scenario_f_lock_cleanup="parent-pid-still-live-or-reused"
        fi
    fi
    # The ignore-release fixture normally exits its direct stub before its
    # TERM-ignoring parent is KILLed. Keep the force-exit marker and the temp
    # root alive until that exact recorded identity has gone away; the guarded
    # fallback below remains necessary if that bounded pre-KILL wait fails.
    # A numeric PID alone is unsafe: it can be reused after the stub exits.
    # Before every TERM/KILL, corroborate PID + process start identity + the
    # unique scenario-F stub command path; a mismatch is loud and NEVER gets
    # signalled. This remains a poll protocol rather than `wait`, since the
    # stub is no longer our direct child once the nested shell is KILLed.
    local scenario_f_stub_pid="" scenario_f_stub_start_identity="" scenario_f_stub_pid_recorded=0
    local scenario_f_stub_reap_complete=0 scenario_f_stub_identity_mismatch=0
    local scenario_f_stub_reap_status="missing-pid-record"
    if [[ -s "$scenario_f_stub_pid_file" ]]; then
        scenario_f_stub_pid="$(sed -n '1p' "$scenario_f_stub_pid_file" 2>/dev/null)" || scenario_f_stub_pid=""
        scenario_f_stub_start_identity="$(sed -n '2p' "$scenario_f_stub_pid_file" 2>/dev/null)" || scenario_f_stub_start_identity=""
    fi

    scenario_f_stub_identity_state() {
        local current_start_identity current_command current_state
        if ! kill -0 "$scenario_f_stub_pid" 2>/dev/null; then
            return 1  # gone
        fi
        # A zombie has terminated and cannot touch the marker/root or receive
        # a signal. `kill -0` still succeeds until its reaper runs, so do not
        # misclassify that normal post-exit state as a reused PID.
        if ! current_state="$(ps -p "$scenario_f_stub_pid" -o stat= 2>/dev/null)"; then
            return 1
        fi
        case "$current_state" in
            Z*|*Z*) return 1 ;;
        esac
        if ! current_start_identity="$(ps -p "$scenario_f_stub_pid" -o lstart= 2>/dev/null)"; then
            return 2  # identity cannot be corroborated
        fi
        if ! current_command="$(ps -p "$scenario_f_stub_pid" -o command= 2>/dev/null)"; then
            return 2
        fi
        if [[ "$current_start_identity" == "$scenario_f_stub_start_identity" \
              && "$current_command" == *"$scenario_f_stub_dir/swift"* ]]; then
            return 0  # the exact fixture stub is still alive
        fi
        return 2  # PID reuse or a non-fixture process: never signal it
    }

    touch "$scenario_f_root/force-exit"
    if [[ "$scenario_f_stub_pid" =~ ^[0-9]+$ && -n "$scenario_f_stub_start_identity" ]]; then
        scenario_f_stub_pid_recorded=1
        scenario_f_poll_i=0
        while [[ $scenario_f_poll_i -lt 20 ]]; do
            if scenario_f_stub_identity_state; then
                scenario_f_stub_state=0
            else
                scenario_f_stub_state=$?
            fi
            [[ $scenario_f_stub_state -ne 0 ]] && break
            sleep 0.05
            scenario_f_poll_i=$((scenario_f_poll_i + 1))
        done
        if [[ $scenario_f_stub_state -eq 2 ]]; then
            scenario_f_stub_identity_mismatch=1
            scenario_f_stub_reap_status="identity-mismatch"
            touch "$scenario_f_identity_observed_file"
        elif [[ $scenario_f_stub_state -eq 0 ]]; then
            # Revalidate immediately before signalling: a reused PID must
            # take the mismatch branch above, never receive TERM or KILL.
            if scenario_f_stub_identity_state; then
                scenario_f_stub_state=0
            else
                scenario_f_stub_state=$?
            fi
            if [[ $scenario_f_stub_state -eq 0 ]] && kill -TERM "$scenario_f_stub_pid" 2>/dev/null; then
                scenario_f_stub_reap_status="TERM-sent"
            elif [[ $scenario_f_stub_state -eq 0 ]]; then
                scenario_f_stub_reap_status="TERM-send-failed"
            else
                scenario_f_stub_identity_mismatch=1
                scenario_f_stub_reap_status="identity-mismatch-before-TERM"
                touch "$scenario_f_identity_observed_file"
            fi
            scenario_f_poll_i=0
            while [[ $scenario_f_stub_identity_mismatch -eq 0 && $scenario_f_poll_i -lt 20 ]]; do
                if scenario_f_stub_identity_state; then
                    scenario_f_stub_state=0
                else
                    scenario_f_stub_state=$?
                fi
                [[ $scenario_f_stub_state -ne 0 ]] && break
                sleep 0.05
                scenario_f_poll_i=$((scenario_f_poll_i + 1))
            done
            if [[ $scenario_f_stub_state -eq 2 ]]; then
                scenario_f_stub_identity_mismatch=1
                scenario_f_stub_reap_status="identity-mismatch-before-KILL"
                touch "$scenario_f_identity_observed_file"
            elif [[ $scenario_f_stub_state -eq 0 ]]; then
                if scenario_f_stub_identity_state; then
                    scenario_f_stub_state=0
                else
                    scenario_f_stub_state=$?
                fi
                if [[ $scenario_f_stub_state -eq 0 ]] && kill -KILL "$scenario_f_stub_pid" 2>/dev/null; then
                    scenario_f_stub_reap_status="KILL-sent"
                elif [[ $scenario_f_stub_state -eq 0 ]]; then
                    scenario_f_stub_reap_status="KILL-send-failed"
                else
                    scenario_f_stub_identity_mismatch=1
                    scenario_f_stub_reap_status="identity-mismatch-before-KILL"
                    touch "$scenario_f_identity_observed_file"
                fi
            fi
        fi

        # A mismatch fixture has now received its observation marker and the
        # force-exit marker, but no signal. Wait boundedly for that known stub
        # to terminate before deleting its root. A zombie is terminated even
        # though `kill -0` still reports it until its parent reaps it; a PID
        # reuse remains loud and is never touched.
        scenario_f_poll_i=0
        while [[ $scenario_f_poll_i -lt 20 ]]; do
            if scenario_f_stub_identity_state; then
                scenario_f_stub_state=0
            else
                scenario_f_stub_state=$?
            fi
            if [[ $scenario_f_stub_state -eq 1 ]]; then
                scenario_f_stub_reap_complete=1
                break
            fi
            sleep 0.05
            scenario_f_poll_i=$((scenario_f_poll_i + 1))
        done
        if [[ $scenario_f_stub_reap_complete -eq 1 ]]; then
            if [[ $scenario_f_stub_identity_mismatch -eq 1 ]]; then
                scenario_f_stub_reap_status="identity-mismatch-reaped-after-force-exit"
            else
                scenario_f_stub_reap_status="reaped-after-force-exit"
            fi
        else
            scenario_f_stub_reap_status="still-live-after-${scenario_f_stub_reap_status}"
        fi
    fi
    cat "$scenario_f_log"

    local scenario_f_owner_ok=0
    [[ "$scenario_f_lock_owner" == "$scenario_f_pid" ]] && scenario_f_owner_ok=1

    local scenario_f_lock_gone=1
    [[ -e "$scenario_f_lock" ]] && scenario_f_lock_gone=0

    # This is an invocation record, not a log-line count. The stuck-child and
    # extra-diagnostic fixtures legitimately emit more than one `[stub-swift]`
    # line from their one process; counting those messages made Scenario F
    # false-red under CI's cleanup timing.
    local scenario_f_stub_invocations
    scenario_f_stub_invocations="$(wc -l < "$scenario_f_stub_invocation_file" 2>/dev/null | tr -d '[:space:]')" || scenario_f_stub_invocations=0
    [[ "$scenario_f_stub_invocations" =~ ^[0-9]+$ ]] || scenario_f_stub_invocations=0

    if [[ $scenario_f_exit -eq 0 && $scenario_f_exit_timeout -eq 0 && $scenario_f_ready -eq 1 && $scenario_f_owner_ok -eq 1 && $scenario_f_lock_gone -eq 1 \
          && $scenario_f_stub_pid_recorded -eq 1 && $scenario_f_stub_reap_complete -eq 1 \
          && $scenario_f_stub_invocations -eq 1 ]]; then
        echo "[lock-selftest] scenario F: PASS (bare invocation pid ${scenario_f_pid} held the lock via the fallthrough call site at the ready/release handshake, ran once against the stub \`swift\`, released cleanly, lock file gone)"
    else
        echo "[lock-selftest] scenario F: FAIL (exit=${scenario_f_exit} exit_timeout=${scenario_f_exit_timeout} reap_status=${scenario_f_reap_status} stub_pid=${scenario_f_stub_pid:-<missing>} stub_reap_status=${scenario_f_stub_reap_status} handshake_ready=${scenario_f_ready} (${scenario_f_handshake_status}) lock_owner=${scenario_f_lock_owner} (expected pid=${scenario_f_pid}) stub_invocations=${scenario_f_stub_invocations}/1 lock_cleanup=${scenario_f_lock_cleanup} lock_gone=${scenario_f_lock_gone})"
        failures=$((failures + 1))
    fi

    rm -rf "$scenario_f_root"
    fi  # end scenario F (skipped wholesale when the stub `swift` is not in effect)

    # ── Scenario G ────────────────────────────────────────────────────────
    # The self-test must leave the ENCLOSING run's artifacts alone. Scenarios
    # E and F are the only ones that reach `scripts/test.sh`'s main path (and
    # therefore its `tee "$OUTPUT_FILE"`), and MANIFOLD_TEST_OUTPUT_FILE is
    # inherited by default — so without the per-invocation override each of
    # them truncates whatever log the outer run is writing to. In CI that log
    # is `ci-test-with-watchdog.sh`'s liveness signal. That watchdog re-arms
    # only when the log's progress-line count EXCEEDS its previous high-water
    # mark, so a truncation destroying those counted lines makes the count
    # restart near zero and climb from there — a BOUNDED stall of roughly
    # `high_water / line_rate` seconds, long enough to blow the 240s threshold
    # and SIGABRT a perfectly healthy run. (Measured on the second CI failure:
    # high-water 3809 lines, only 2656 accumulated before the abort.) It is the
    # TRUNCATION that does this, not the NUL hole the outer `tee`'s retained
    # offset then leaves behind — `grep -c` counts the same either way
    # (measured: `-c` and `-a -c` both return 1999 on the clobbered file). The
    # NUL bytes only garble the human-readable stall dump, which is where CI's
    # "Binary file ... matches" line came from: a symptom worth matching on,
    # not the mechanism.
    #
    # The three sub-checks are COMPLEMENTARY, not redundant — each environment
    # carries a different two of them:
    #   - live CI (an outer writer holding an offset): the sparse hole makes
    #     `wc -c` GROW across a clobber, so the size check is inert there; the
    #     progress-line and NUL checks carry it.
    #   - stand-in mode (no concurrent writer): nothing re-extends the file, so
    #     no NUL hole forms and the NUL check is inert; the size and
    #     progress-line checks carry it.
    # Known residual gap, stated rather than papered over: an APPEND-style
    # regression (a nested run switching to `tee -a`) slips past all three —
    # size grows, progress lines only increase, no NULs — while still
    # corrupting the outer run's own summary parsing. Nothing here detects it.
    echo "[lock-selftest] scenario G: the self-test never writes to the ENCLOSING run's MANIFOLD_TEST_OUTPUT_FILE (CI watchdog liveness log)"
    local enclosing_size_after=0 enclosing_count_after=0 enclosing_nul_bytes=0
    if [[ -f "$enclosing_log" ]]; then
        enclosing_size_after="$(wc -c < "$enclosing_log" | tr -d ' ')"
        enclosing_count_after="$(grep -acE "$enclosing_progress_pattern" "$enclosing_log" 2>/dev/null)" || enclosing_count_after=0
        enclosing_nul_bytes="$(LC_ALL=C tr -dc '\000' < "$enclosing_log" | wc -c | tr -d ' ')"
    fi
    if [[ "$enclosing_size_after" -ge "$enclosing_size_before" \
          && "$enclosing_count_after" -ge "$enclosing_count_before" \
          && "$enclosing_nul_bytes" -eq 0 ]]; then
        echo "[lock-selftest] scenario G: PASS (enclosing log $(if [[ $enclosing_log_synthesised -eq 1 ]]; then echo 'stand-in'; else echo 'inherited'; fi) '$enclosing_log' intact: size ${enclosing_size_before}->${enclosing_size_after}, progress lines ${enclosing_count_before}->${enclosing_count_after}, 0 NUL bytes)"
    else
        echo "[lock-selftest] scenario G: FAIL (enclosing log '$enclosing_log' was clobbered: size ${enclosing_size_before}->${enclosing_size_after}, progress lines ${enclosing_count_before}->${enclosing_count_after}, NUL bytes=${enclosing_nul_bytes} — a nested scripts/test.sh inherited MANIFOLD_TEST_OUTPUT_FILE and tee'd over the outer run's log)"
        failures=$((failures + 1))
    fi

    rm -rf "$selftest_root"

    if [[ $failures -eq 0 ]]; then
        echo "[lock-selftest] RESULT: PASS"
        return 0
    else
        echo "[lock-selftest] RESULT: FAIL ($failures scenario(s) failed)"
        return 1
    fi
}

if [[ "${1:-}" == "--lock-selftest" ]]; then
    run_gate_lock_selftest
    exit $?
fi

# ── Arguments ────────────────────────────────────────────────────────────────
# Profile precedence
# ------------------
# `--profile <name>` selects a canned invocation shape. Two profiles ship today:
#
#   ci      — mirrors CI's no-traits three-invocation shape. This is the
#             default when --profile is omitted (back-compat). Since v0.48
#             (PR C2) there are no default traits, so this is simply the
#             plain `swift test` shape.
#   local   — Apple-Silicon pre-push: the surviving opt-in traits (Macros;
#             Server runs in its own CI job and stays out of the batch, as
#             before). The XCTest filter list is identical to `ci`'s — see
#             PROFILE_LOCAL_XCTEST_FILTERS below.
#
# Profile defaults are applied AFTER caller flags are parsed, but only fill
# slots the caller did not set:
#   - --traits from the caller wins outright (we never append or override).
#   - --filter from the caller wins outright (we don't union with the default
#     suite list — passing one filter means "just that one suite").
#   - --disable-default-traits / --num-workers / --skip-update from the caller
#     win outright.
#
# So `--profile local --filter ManifoldCoreTests` runs *only* ManifoldCoreTests,
# but under the local profile's trait set and worker count.
MIN_PASSED=0
PARALLEL_MODE=0
MINIMAL_MODE=0
PROFILE=""
SWIFT_ARGS=()
FILTERS_SEEN=()
DISABLE_DEFAULT_TRAITS_PRESENT=0
NUM_WORKERS_PRESENT=0
SKIP_UPDATE_PRESENT=0
MCP_FILTER_REQUESTED=0
TRAITS_ARG_INDEX=-1
SPIKE_MODULE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            PROFILE="${2:?'--profile requires a name (local|ci|spike)'}"
            shift 2
            ;;
        --profile=*)
            PROFILE="${1#--profile=}"
            shift
            ;;
        --spike-module)
            # Used with --profile spike to name the affected suite.
            SPIKE_MODULE="${2:?'--spike-module requires a suite name'}"
            shift 2
            ;;
        --min-passed)
            MIN_PASSED="${2:?'--min-passed requires an integer argument'}"
            shift 2
            ;;
        --minimal)
            # Deprecated no-op since v0.48 (PR C2): there are no default
            # traits left to disable — a plain build is already minimal.
            MINIMAL_MODE=1
            shift
            ;;
        --enable-code-coverage)
            # Explicit passthrough (rather than relying on the catch-all `*`
            # case below) so callers — notably nightly-slow-tests.yml's
            # coverage-thresholds step (issue #2277) — get this script's
            # suite-completion crash detection instead of reimplementing a
            # weaker copy around a bare `swift test --enable-code-coverage`.
            SWIFT_ARGS+=("$1")
            shift
            ;;
        --parallel)
            # Track parallel mode separately so the parser can fall back to
            # SwiftPM's `[N/M] Testing` streaming format when XCTest workers
            # don't emit per-case pass/fail lines (or only emit them for some
            # workers — see the parsing block below).
            PARALLEL_MODE=1
            SWIFT_ARGS+=("$1")
            shift
            ;;
        --filter)
            filter="${2:?'--filter requires a test filter argument'}"
            if [[ "$filter" == *ManifoldMCPTests* || "$filter" == *ManifoldMCPE2ETests* || "$filter" == *ManifoldMCPE2ESmokeTests* ]]; then
                MCP_FILTER_REQUESTED=1
            fi
            FILTERS_SEEN+=("$filter")
            SWIFT_ARGS+=("$1" "$filter")
            shift 2
            ;;
        --filter=*)
            filter="${1#--filter=}"
            if [[ "$filter" == *ManifoldMCPTests* || "$filter" == *ManifoldMCPE2ETests* || "$filter" == *ManifoldMCPE2ESmokeTests* ]]; then
                MCP_FILTER_REQUESTED=1
            fi
            FILTERS_SEEN+=("$filter")
            SWIFT_ARGS+=("$1")
            shift
            ;;
        --disable-default-traits)
            DISABLE_DEFAULT_TRAITS_PRESENT=1
            SWIFT_ARGS+=("$1")
            shift
            ;;
        --num-workers)
            NUM_WORKERS_PRESENT=1
            SWIFT_ARGS+=("$1" "${2:?'--num-workers requires an integer'}")
            shift 2
            ;;
        --num-workers=*)
            NUM_WORKERS_PRESENT=1
            SWIFT_ARGS+=("$1")
            shift
            ;;
        --skip-update)
            SKIP_UPDATE_PRESENT=1
            SWIFT_ARGS+=("$1")
            shift
            ;;
        --traits)
            traits="${2:?'--traits requires a comma-separated trait list'}"
            TRAITS_ARG_INDEX=$((${#SWIFT_ARGS[@]} + 1))
            SWIFT_ARGS+=("$1" "$traits")
            shift 2
            ;;
        --traits=*)
            TRAITS_ARG_INDEX=${#SWIFT_ARGS[@]}
            SWIFT_ARGS+=("$1")
            shift
            ;;
        *)
            SWIFT_ARGS+=("$1")
            shift
            ;;
    esac
done

# ── Profile resolution ──────────────────────────────────────────────────────
# Profiles are sugar over swift test flags. We resolve them here, *after* arg
# parsing, so explicit caller flags always win (see precedence comment above).
#
# Three-invocation shape: the CI and local profiles run the XCTest filter set
# in one swift-test call, ManifoldBackendsTests alone in a second (own process
# + --parallel — mirrors ci.yml; kept out of the multi-target XCTest batch
# because the target mixes ~9 Swift Testing files with XCTestCase suites),
# and ManifoldInferenceSwiftTestingTests in a third, separate process — mixing
# Swift Testing with XCTest in a single process triggers libmalloc SIGABRT
# (#681). When the caller has not narrowed with their own --filter, we re-exec
# this script three times with the resolved flags.

# XCTest suite list for the main batch. Source of truth for the pre-push gate.
# ManifoldBackendsTests is deliberately excluded — it gets its own invocation
# below (PROFILE_BACKENDS_FILTER), matching ci.yml.
PROFILE_CI_XCTEST_FILTERS=(
    ManifoldCoreTests
    ManifoldRuntimeTests
    ManifoldPersistenceSwiftDataTests
    ManifoldUITests
    ManifoldUIModelManagementTests
    ManifoldMCPTests
    ManifoldInferenceTests
    ManifoldNetworkingTests
    ManifoldSecretsTests
    ManifoldHardwareTests
    ManifoldModelCatalogTests
    ManifoldTestSupportTests
    ManifoldAppIntentsTests
    ManifoldServerTests
    ManifoldTurnLoopCharacterizationTests
    # Voice / Tools traits retired in v0.48 (PR A3): these suites
    # compile in every trait shape now, so they run in the CI shape too.
    ManifoldVoiceTests
    # ManifoldSkills retired 2026-08-06 (#2434); the AGENTS.md loader half
    # survives as ManifoldAgentInstructions.
    ManifoldAgentInstructionsTests
    ManifoldToolsTests
    # Fuzz harness unit/integration tests (corpus, detectors, sink, the
    # fuzz-ci-gate.sh contract). Unconditional since the Fuzz trait retired
    # in v0.48 — hermetic, no live backend needed (#2367: this suite existed
    # with zero CI coverage until this line).
    ManifoldFuzzTests
    # App-eval harness (estate#1 wave 1): schema/mapper/scorer/renderer/ledger
    # unit tests + the MK-compression-golden dogfood, all hermetic.
    ManifoldAppEvalTests
    # Public-API freeze suite: compile-time surface fixtures + the
    # public-surface baseline well-formedness tripwire
    # (PublicSurfaceBaselineTests). Fast (<1s) and hermetic — the heavy
    # digester-backed check stays behind RUN_API_SURFACE_BASELINE_CHECK=1
    # and the nightly api-surface-baseline job (wave-2 item 0.A).
    APIFreezeTests
    # View-control + .dump-strategy snapshot coverage (ViewSnapshotTests
    # dumps the SwiftUI view hierarchy to text, not a rendered bitmap — no
    # retina/font/OS-version pixel dependency). This target has never been
    # in any gate since it was created (git log -S confirms it), and the
    # Download-tab control tests rotted unnoticed for a month as a result.
    ManifoldSnapshotTests
    # Hermetic: MockURLProtocol with UUID-per-suite endpoints, no live OTLP
    # collector needed.
    ManifoldTelemetryOTLPTests
    # Umbrella quickStart()/_quickStart() coverage (ManifoldKitTests) and
    # HuggingFace download/persistence coverage (ManifoldHuggingFaceTests):
    # both fully hermetic (in-memory SwiftData, MockURLProtocol-stubbed
    # huggingface.co calls) and fast (<1s combined). `swift test --filter`
    # already compiles the whole test tree regardless of filter, so both
    # were already paid for at build time in every CI run — they were just
    # never scheduled to execute. Moved out of local-only in the same audit
    # sweep that caught ManifoldSnapshotTests/ManifoldTelemetryOTLPTests
    # above.
    ManifoldKitTests
    ManifoldHuggingFaceTests
)
# Local profile currently has no suites of its own — it is a pure inherit of
# the CI list. Kept as a separate array (rather than aliased directly to
# PROFILE_CI_XCTEST_FILTERS) because other call sites reference it by name;
# if a genuinely local-only suite (e.g. one needing a resource CI can't
# provide) shows up later, add it here.
PROFILE_LOCAL_XCTEST_FILTERS=(
    "${PROFILE_CI_XCTEST_FILTERS[@]}"
)
# Own invocation + --parallel — see the "Three-invocation shape" comment
# above and ci.yml's "ManifoldBackendsTests (own process, parallel)" step.
PROFILE_BACKENDS_FILTER="ManifoldBackendsTests"
PROFILE_SWIFT_TESTING_FILTER="ManifoldInferenceSwiftTestingTests"

# Local profile trait set: the surviving opt-in traits exercised by the batch
# (Macros only — Server has its own CI job/filter shape). The MLX / Llama /
# HuggingFace / Fuzz traits retired in v0.48 (PR C2, #1749).
PROFILE_LOCAL_TRAITS="Macros"

# ── Stall watchdog for the driving (--profile) invocations ─────────────────
# CI wraps every swift-test invocation in scripts/ci-test-with-watchdog.sh,
# which SIGABRTs a stalled swift-test/xctest process after $STALL_SECONDS of
# no forward progress and captures a per-thread backtrace + process snapshot
# before exiting 124. scripts/test.sh had no equivalent, which is how four
# locally-green `--profile local` runs failed to predict a CI-red stall in
# one night: a hang that trips CI's watchdog just looks slow on a dev
# machine, which absorbs subprocess load differently than a CI runner.
#
# This reuses scripts/ci-test-with-watchdog.sh itself — never a second copy.
# A duplicate watchdog drifts from the original (this repo's known-issues
# buffer has more than one entry about exactly that shape of mistake), and
# the reuse is structurally cheap here: each of the three leaf invocations
# below already has the resolved swift-test arg list this script's own
# recursive re-exec was going to pass to itself, so routing through the
# wrapper instead of straight to "$SCRIPT_PATH" costs one indirection, not a
# reimplementation.
#
# Threshold: CI's default is 240s (ci.yml's STALL_SECONDS). A dev machine can
# legitimately run slower under contention — an unrelated concurrent gate,
# an indexing Xcode, SwiftPM cache-lock contention (see AGENTS.md's
# "Machine contention" guidance) — so "--profile local" defaults to 2x CI's
# threshold: 480s (8 min). That is deliberate headroom for legitimate local
# slowness, not "make it huge" — a genuine hang is silent forever, so even
# an 8-minute threshold still catches it, just later than CI would.
# "--profile ci" (local CI-repro) keeps CI's own 240s default instead: its
# whole purpose is reproducing a CI failure, so it should trip at the same
# point CI did, not a looser one. Both defaults are overridable with the
# same STALL_SECONDS env var ci-test-with-watchdog.sh already reads — no new
# env var invented for a knob that already exists.
#
# Fail-closed, not fail-open: MANIFOLD_DISABLE_LOCAL_WATCHDOG=1 is the only
# way to skip the wrapper, and every skip prints a loud, repeated warning —
# a watchdog nobody notices is disabled manufactures false confidence, which
# is worse than no watchdog at all. If the wrapper script itself is missing
# or not executable, this refuses to run the invocation at all rather than
# silently falling back to an unprotected `swift test` — a degraded
# progress-detection path must be visible, never quietly absorbed.
CI_TEST_WATCHDOG="$PACKAGE_DIR/scripts/ci-test-with-watchdog.sh"
LOCAL_STALL_SECONDS_DEFAULT=480
CI_STALL_SECONDS_DEFAULT=240

# Runs one swift-test invocation (the remaining args, already fully resolved
# — filters/traits/--skip-update/--parallel) through ci-test-with-watchdog.sh.
#   $1 = label, used to give this invocation its own output/diagnostics path.
#        The three-invocation shape below shares one process tree across
#        three sequential swift-test runs; `tee` truncates its target file on
#        open, so without distinct paths the second invocation would erase
#        the first invocation's diagnostics before anyone could read them.
#   $2 = default STALL_SECONDS for this invocation if the caller didn't set
#        the env var explicitly.
run_leaf_with_local_watchdog() {
    local label="$1"
    local default_stall="$2"
    shift 2
    local rc

    if [[ "${MANIFOLD_DISABLE_LOCAL_WATCHDOG:-0}" == "1" ]]; then
        echo "⚠️⚠️⚠️  MANIFOLD_DISABLE_LOCAL_WATCHDOG=1 — running '${label}' WITHOUT the stall watchdog. ⚠️⚠️⚠️" >&2
        echo "⚠️⚠️⚠️  A hang here will NOT be caught the way CI would catch it. ⚠️⚠️⚠️" >&2
        # Same per-label MANIFOLD_TEST_OUTPUT_FILE as the protected path below
        # — this fallback used to omit it (three invocations sharing one
        # test_output.txt, each truncating the last), which was fine before
        # this file had a #2464-style ambient-inheritance hazard to avoid.
        # The opt-out shouldn't be the one path lacking the isolation the
        # protected path is careful about.
        set +e
        MANIFOLD_TEST_OUTPUT_FILE="$PACKAGE_DIR/test-diagnostics/test_output_${label}.txt" \
            "$SCRIPT_PATH" "$@"
        rc=$?
        set -e
        return $rc
    fi

    if [[ ! -x "$CI_TEST_WATCHDOG" ]]; then
        echo "::error::scripts/test.sh: stall watchdog '$CI_TEST_WATCHDOG' is missing or not executable — refusing to run '${label}' unprotected." >&2
        echo "::error::Fix the wrapper, or set MANIFOLD_DISABLE_LOCAL_WATCHDOG=1 to proceed deliberately without stall protection." >&2
        return 127
    fi

    local stall="${STALL_SECONDS:-$default_stall}"
    set +e
    STALL_SECONDS="$stall" \
        MANIFOLD_TEST_OUTPUT_FILE="$PACKAGE_DIR/test-diagnostics/test_output_${label}.txt" \
        WATCHDOG_DIAGNOSTICS_DIR="$PACKAGE_DIR/test-diagnostics" \
        "$CI_TEST_WATCHDOG" "$@"
    rc=$?
    set -e
    return $rc
}

if [[ -n "$PROFILE" ]]; then
    case "$PROFILE" in
        ci|local|spike)
            ;;
        *)
            echo "error: unknown --profile '$PROFILE' (expected: local | ci | spike)" >&2
            exit 64
            ;;
    esac

    # If the caller passed their own --filter, we run a single invocation
    # under the profile's traits/workers (not the three-invocation default
    # suite list). This is the "narrow override" path.
    HAS_USER_FILTER=0
    if [[ ${#FILTERS_SEEN[@]} -gt 0 ]]; then
        HAS_USER_FILTER=1
    fi
    # Needed by run_leaf_with_local_watchdog's MANIFOLD_DISABLE_LOCAL_WATCHDOG
    # fallback (re-exec self) in every branch below, not just the
    # three-invocation one — declared once here so it's in scope everywhere.
    SCRIPT_PATH="$0"
    if [[ "$PROFILE" == "local" ]]; then
        PROFILE_DEFAULT_STALL=$LOCAL_STALL_SECONDS_DEFAULT
    else
        PROFILE_DEFAULT_STALL=$CI_STALL_SECONDS_DEFAULT
    fi

    if [[ "$PROFILE" == "spike" ]]; then
        if [[ -z "$SPIKE_MODULE" && $HAS_USER_FILTER -eq 0 ]]; then
            echo "error: --profile spike requires --spike-module <suite> or an explicit --filter" >&2
            exit 64
        fi
        # Spike: minimal traits (no MLX shader compile), one suite only.
        if [[ $DISABLE_DEFAULT_TRAITS_PRESENT -eq 0 && $TRAITS_ARG_INDEX -lt 0 ]]; then
            SWIFT_ARGS+=("--disable-default-traits")
            DISABLE_DEFAULT_TRAITS_PRESENT=1
        fi
        if [[ -n "$SPIKE_MODULE" && $HAS_USER_FILTER -eq 0 ]]; then
            SWIFT_ARGS+=("--filter" "$SPIKE_MODULE")
            FILTERS_SEEN+=("$SPIKE_MODULE")
            HAS_USER_FILTER=1
        fi
        if [[ $SKIP_UPDATE_PRESENT -eq 0 ]]; then
            SWIFT_ARGS+=("--skip-update")
            SKIP_UPDATE_PRESENT=1
        fi
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  PROFILE: spike (minimal traits, single suite — pre-push gate still mandatory)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        # Fall through to the single swift-test invocation at the bottom.
    elif [[ $HAS_USER_FILTER -eq 1 ]]; then
        # Narrow override: apply the profile's traits + worker count to a
        # single invocation with the caller's filter.
        if [[ "$PROFILE" == "ci" ]]; then
            # No trait injection: since v0.48 there are no default traits, so
            # the CI shape is the plain build.
            :
        else
            # local: inject the local trait set if no traits were specified.
            if [[ $TRAITS_ARG_INDEX -lt 0 && $DISABLE_DEFAULT_TRAITS_PRESENT -eq 0 ]]; then
                TRAITS_ARG_INDEX=$((${#SWIFT_ARGS[@]} + 1))
                SWIFT_ARGS+=("--traits" "$PROFILE_LOCAL_TRAITS")
            fi
        fi
        if [[ $SKIP_UPDATE_PRESENT -eq 0 ]]; then
            SWIFT_ARGS+=("--skip-update")
            SKIP_UPDATE_PRESENT=1
        fi
        # We deliberately do NOT inject `--parallel` here. swift-test's
        # implicit scheduling without the flag is the baseline that works —
        # keep it. (Historically this also avoided pre-existing process-global
        # state races in `BackendContractChecks` — each per-backend conformance
        # suite's `test_z_contract_metaContract` read a shared claims registry,
        # and explicit `--parallel` interleaved test classes enough that 57
        # normally-skipped tests registered as runs with 7 false failures. The
        # capability-claims registry is now instance-scoped per test case
        # (arch-plan item 4.2), so that specific hazard no longer applies —
        # see ManifoldBackendTestKit's DocC catalog. `--parallel` stays off
        # here as a conservative default, not a correctness requirement.)
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  PROFILE: $PROFILE (single-invocation override — caller passed --filter)"
        printf "  Filters: %s\n" "${FILTERS_SEEN[*]}"
        if [[ "$PROFILE" == "local" ]]; then
            echo "  Traits:  $PROFILE_LOCAL_TRAITS"
        else
            echo "  Traits:  (none — plain build; no default traits since v0.48)"
        fi
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        # A documented flag the caller set is not a swift-test flag, so it is
        # deliberately excluded from SWIFT_ARGS by the arg parser above (see
        # --min-passed's case block) — the OLD in-process fall-through relied
        # on MIN_PASSED still being in scope when this same process reached
        # the bottom Run section's check. Routing through
        # run_leaf_with_local_watchdog() now spawns a genuinely separate
        # child process (nested test.sh, via ci-test-with-watchdog.sh or its
        # disabled-watchdog fallback) that re-parses its own argv from
        # scratch — MIN_PASSED=0 there unless re-threaded explicitly. Thread
        # it back in as a real --min-passed flag so the child's own honest-
        # summary check applies the floor the caller asked for.
        if [[ $MIN_PASSED -gt 0 ]]; then
            SWIFT_ARGS+=("--min-passed" "$MIN_PASSED")
        fi
        # Single leaf invocation — route it through the same stall watchdog
        # the three-invocation shape below uses, then exit with its result.
        # (Not a "fall through": that only works when nothing upstream has
        # already resolved --profile into a leaf swift-test call, and this
        # branch has.)
        #
        # Acquire the gate lock HERE, in the parent, before the watchdog-
        # wrapped call — mirrors the three-invocation branch below and for
        # the identical reason: lock queueing is unbounded by design (up to
        # a 3h ceiling), and if it happened inside the watchdog-monitored
        # child instead, "[gate-lock] waiting for gate lock held by PID N"
        # doesn't match ci-test-with-watchdog.sh's progress pattern and
        # doesn't go through its tee, so the watchdog's timer never re-arms
        # and SIGABRTs a perfectly healthy queued run at the stall threshold
        # (480s default) instead of letting it wait its turn — the exact
        # phantom-stall failure mode #2464 just finished root-causing for
        # MANIFOLD_TEST_OUTPUT_FILE, reintroduced here via a different
        # mechanism if the lock wait sat on the wrong side of the watchdog.
        # The child inherits MANIFOLD_GATE_LOCK_OWNER_PID via export and
        # skips its own acquisition, same as every other call site.
        acquire_gate_lock
        set +e
        run_leaf_with_local_watchdog "narrow" "$PROFILE_DEFAULT_STALL" \
            ${SWIFT_ARGS[@]+"${SWIFT_ARGS[@]}"}
        NARROW_RC=$?
        set -e
        exit $NARROW_RC
    else
        # No caller filter — run the canonical three-invocation pre-push gate.
        # Re-exec self three times with the resolved flag sets, each routed
        # through the stall watchdog (run_leaf_with_local_watchdog). This
        # keeps the parsing surface single-pass and the summary printer
        # authoritative per call (each invocation prints its own summary).
        #
        # Acquire the machine-wide gate lock HERE, once, before any of the
        # three (build-heavy) re-invocations below — not inside each child.
        # The children inherit MANIFOLD_GATE_LOCK_OWNER_PID via export, and
        # that export survives the extra ci-test-with-watchdog.sh layer each
        # child is now routed through (env vars propagate through exec
        # regardless of how many process layers sit in between), so each
        # child's own acquire_gate_lock call at the bottom of this script
        # still sees the sentinel and no-ops. Verified after this rebase —
        # see the PR body. The lock is held for the whole three-invocation
        # shape and released exactly once, when this parent process exits.
        acquire_gate_lock
        SCRIPT_PATH="$0"
        EXTRA_ARGS=(${SWIFT_ARGS[@]+"${SWIFT_ARGS[@]}"})
        # Build the per-profile flag sets.
        if [[ "$PROFILE" == "ci" ]]; then
            TRAIT_FLAGS=()
            FILTERS=("${PROFILE_CI_XCTEST_FILTERS[@]}")
            BANNER_TRAITS="(none — plain build; no default traits since v0.48)"
        else
            TRAIT_FLAGS=(--traits "$PROFILE_LOCAL_TRAITS")
            FILTERS=("${PROFILE_LOCAL_XCTEST_FILTERS[@]}")
            BANNER_TRAITS="$PROFILE_LOCAL_TRAITS"
        fi
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  PROFILE: $PROFILE (three-invocation pre-push gate)"
        echo "  Traits:  $BANNER_TRAITS"
        printf "  XCTest filters (%d): %s\n" "${#FILTERS[@]}" "${FILTERS[*]}"
        echo "  Backends filter: $PROFILE_BACKENDS_FILTER (own process + --parallel — #681 isolation, mirrors ci.yml)"
        echo "  Swift Testing filter: $PROFILE_SWIFT_TESTING_FILTER (separate process — #681)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        # Build the --filter args.
        XCTEST_FILTER_ARGS=()
        for f in "${FILTERS[@]}"; do
            XCTEST_FILTER_ARGS+=(--filter "$f")
        done

        # Invocation 1: XCTest filters, --parallel — matching ci.yml's
        # "XCTest suites (…, parallel)" step's parallel execution. (Not
        # flag-identical: CI wraps in ci-test-with-watchdog.sh and omits
        # the Macros trait this profile adds; both deliberate.)
        #
        # Counting caveat: the parallel runner does not reliably emit
        # per-case "Test Case '…' skipped" lines, so XCTSkip results fold
        # into the streaming passed count — invocation 1's "0 skipped" is
        # a parallel-reporting artifact, not a skip audit. CI's identical
        # batch has the same property; TestSuiteSilentSkipAuditTest is
        # the skip tripwire, not this summary.
        #
        # This invocation historically omitted `--parallel` as a
        # conservative default while CI ran the same batch WITH it, so
        # parallel-only races (SwiftData teardown, process-global state)
        # passed the local gate and failed CI — #2329 is the canonical
        # bite. The one known hazard behind the conservatism is gone: the
        # capability-claims registry is instance-scoped per test case
        # (arch-plan item 4.2; see ManifoldBackendTestKit's DocC catalog).
        # The local gate must fail where CI fails — keep the flags aligned
        # with ci.yml, and if a parallel-only race appears here, fix the
        # test's isolation, don't remove the flag.
        set +e
        run_leaf_with_local_watchdog "xctest" "$PROFILE_DEFAULT_STALL" \
            "${XCTEST_FILTER_ARGS[@]}" \
            ${TRAIT_FLAGS[@]+"${TRAIT_FLAGS[@]}"} \
            --skip-update \
            --parallel \
            ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
        RC1=$?
        set -e
        if [[ $RC1 -ne 0 ]]; then
            echo "[--profile $PROFILE] XCTest invocation failed (exit $RC1) — skipping ManifoldBackendsTests and Swift Testing runs." >&2
            exit $RC1
        fi

        # Invocation 2: ManifoldBackendsTests, own process + --parallel.
        #
        # Kept out of the multi-target XCTest batch above: ManifoldBackendsTests
        # contains ~9 Swift Testing files (see SwiftTestingAuditTest's allowlist)
        # coexisting with XCTestCase suites in the same target — folding it into
        # invocation 1 would mix both harnesses in one process (#681 libmalloc
        # SIGABRT). --parallel is safe within this target now that the
        # capability-claims registry is instance-scoped (arch-plan item 4.2);
        # mirrors ci.yml's "ManifoldBackendsTests (own process, parallel)" step.
        set +e
        run_leaf_with_local_watchdog "backends" "$PROFILE_DEFAULT_STALL" \
            --filter "$PROFILE_BACKENDS_FILTER" \
            ${TRAIT_FLAGS[@]+"${TRAIT_FLAGS[@]}"} \
            --skip-update \
            --parallel \
            ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
        RC2=$?
        set -e
        if [[ $RC2 -ne 0 ]]; then
            echo "[--profile $PROFILE] ManifoldBackendsTests invocation failed (exit $RC2) — skipping Swift Testing run." >&2
            exit $RC2
        fi

        # Invocation 3: Swift Testing in a separate process (#681).
        set +e
        run_leaf_with_local_watchdog "swifttesting" "$PROFILE_DEFAULT_STALL" \
            --filter "$PROFILE_SWIFT_TESTING_FILTER" \
            ${TRAIT_FLAGS[@]+"${TRAIT_FLAGS[@]}"} \
            --skip-update \
            ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
        RC3=$?
        set -e
        exit $RC3
    fi
fi

# ── --minimal resolution ──────────────────────────────────────────────────────
# Deprecated no-op since v0.48 (PR C2): the heavy MLX/Llama source deps left
# for the companion packages and there are no default traits, so every build
# is already the minimal shape.
if [[ $MINIMAL_MODE -eq 1 ]]; then
    echo "[--minimal] no-op since v0.48: no default traits exist; the plain build is already minimal."
fi

# ── Run ──────────────────────────────────────────────────────────────────────
# Covers every path that reaches here directly (a bare invocation, or
# --profile spike) AND every child re-invocation spawned by --profile
# local/ci — both the three-invocation shape's three children and the
# narrow-override branch's single child (reached via the watchdog wrapper,
# or its MANIFOLD_DISABLE_LOCAL_WATCHDOG=1 fallback). A narrow `--filter`
# override itself never reaches here directly any more: it now acquires the
# lock and `exit`s right after handing off to run_leaf_with_local_watchdog();
# only its re-exec'd child does. Every child sees MANIFOLD_GATE_LOCK_OWNER_PID
# already exported by its parent and returns immediately without
# re-acquiring (see acquire_gate_lock's doc comment).
# FALLTHROUGH_GATE_LOCK_ACQUIRE: scenario F's sabotage test removes exactly
# this call site and must make --lock-selftest fail deterministically.
acquire_gate_lock
echo "Running swift test in: $PACKAGE_DIR"
echo "Output captured to: $OUTPUT_FILE"
echo ""

# swift PM writes build progress + error lines to stderr; test output to stdout.
# We merge both so signal-crash lines (stderr) land alongside test lines (stdout).
cd "$PACKAGE_DIR"
mkdir -p "$(dirname "$OUTPUT_FILE")"
set +e
swift test ${SWIFT_ARGS[@]+"${SWIFT_ARGS[@]}"} 2>&1 | tee "$OUTPUT_FILE"
SWIFT_EXIT=${PIPESTATUS[0]}
set -e

# Scenario F's stuck-child fixture keeps the lock-owning nested shell alive
# after its stub exits. The observer can then reap that known owner itself,
# rather than orphaning the stub by KILLing its parent first. This variable is
# passed only by --lock-selftest; it is never a production control surface.
if [[ "${MANIFOLD_GATE_SELFTEST_F_CHILD_MODE:-}" == "ignore-release" ]]; then
    parent_hold_file="${MANIFOLD_GATE_SELFTEST_F_PARENT_HOLD_FILE:?'scenario F ignore-release fixture needs MANIFOLD_GATE_SELFTEST_F_PARENT_HOLD_FILE'}"
    echo "[lock-selftest child] scenario F: holding lock-owning parent for observer cleanup"
    parent_hold_i=0
    while [[ ! -e "$parent_hold_file" && $parent_hold_i -lt 300 ]]; do
        sleep 0.05
        parent_hold_i=$((parent_hold_i + 1))
    done
    if [[ ! -e "$parent_hold_file" ]]; then
        echo "[lock-selftest child] scenario F: FAIL (parent hold timed out after 15s)" >&2
        exit 81
    fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  TEST SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# ── Check for stale .build desync landmine ────────────────────────────────────
# If swift test failed, check for known stale-build-artifact error signatures.
# This is a preflight hint only — we don't auto-wipe .build, which would hide
# real breaks and burn ~8min. Just point at the documented fix.
if [[ $SWIFT_EXIT -ne 0 ]]; then
    # Patterns that signal a .build cache desync rather than a real source bug:
    # - "missing required module" (the _NumericsShims case from #2181)
    # - "build.db" / "workspace-state.json" (SwiftPM metadata corruption)
    # - "module cache" (Clang incremental-build desync)
    if grep -qiE "(missing required module|build\.db|workspace-state\.json|module cache)" "$OUTPUT_FILE"; then
        echo ""
        echo "  ⚠️  DETECTED: Stale .build artifact error"
        echo ""
        echo "  This looks like a .build directory desync (not a source bug)."
        echo "  Fix: Run 'scripts/clean-build.sh' to wipe .build and resolve cleanly."
        echo ""
    fi
fi

# ── Parse XCTest events ───────────────────────────────────────────────────────
# Individual test-case results
xctest_passed=$(grep -c "^Test Case '.*' passed" "$OUTPUT_FILE" || true)
xctest_failed=$(grep -c "^Test Case '.*' failed" "$OUTPUT_FILE" || true)
xctest_skipped=$(grep -c "^Test Case '.*' skipped" "$OUTPUT_FILE" || true)

# `swift test --parallel` runs each XCTest worker in its own process and
# multiplexes their output through SwiftPM's xcodebuild-style streaming line:
#   [N/M] Testing Module.Suite/test_foo
# Per-worker, the classic `Test Case '...' passed` lines may also appear, but
# crash victims, signal exits, and silent-skip cases vary worker-to-worker.
# Use the streaming line count as the authoritative test-ran count when
# --parallel is in play, and fall back to swift test's exit code for
# pass/fail (any worker non-zero exit propagates).
xctest_parallel_count=$(grep -cE "^\[[0-9]+/[0-9]+\] Testing " "$OUTPUT_FILE" || true)
if [[ $PARALLEL_MODE -eq 1 ]]; then
    # If the streaming runner emitted more tests than the classic counters
    # observed (typical when worker output is interleaved or truncated),
    # trust the streaming count. Per-case pass/fail lines aren't emitted
    # for every worker under --parallel, so the classic counters undercount.
    if [[ $xctest_parallel_count -gt $((xctest_passed + xctest_failed + xctest_skipped)) ]]; then
        if [[ $SWIFT_EXIT -eq 0 ]]; then
            xctest_passed=$xctest_parallel_count
            xctest_failed=0
        else
            # Some worker failed — keep observed `Test Case '... failed` hits
            # if any, otherwise synthesise one failure so RESULT shows FAILED.
            if [[ $xctest_failed -eq 0 ]]; then
                xctest_failed=1
            fi
            xctest_passed=$((xctest_parallel_count - xctest_failed - xctest_skipped))
            [[ $xctest_passed -lt 0 ]] && xctest_passed=0
        fi
    fi
fi

mcp_test_events=0
if [[ $MCP_FILTER_REQUESTED -eq 1 ]]; then
    mcp_test_events=$(grep -cE "(Test Case '-\[ManifoldMCP(E2E)?Tests\.|^\[[0-9]+/[0-9]+\] Testing ManifoldMCP(E2E)?Tests\.)" "$OUTPUT_FILE" || true)
fi

# Suites that started but never emitted a 'passed' or 'failed' line are crash victims.
# Exclude the two top-level container lines ("All tests" and the .xctest bundle).
xctest_suites_started=$(grep "^Test Suite '" "$OUTPUT_FILE" \
    | grep " started at " \
    | grep -v "^Test Suite 'All tests'" \
    | grep -v "\.xctest'" \
    | sed "s/^Test Suite '//; s/' started at .*//" \
    || true)  # fail-open-ok: no suites started → empty → crash detection reports 0 below

# Find XCTest suites that started but did not complete.
xctest_crashed_suites=""
xctest_crashed_count=0
if [[ -n "$xctest_suites_started" ]]; then
    while IFS= read -r suite; do
        [[ -z "$suite" ]] && continue
        suite_pat=$(printf '%s' "$suite" | sed 's/[][(){}.*+?^$|\\]/\\&/g')
        if ! grep -qE "^Test Suite '${suite_pat}' (passed|failed) at" "$OUTPUT_FILE" 2>/dev/null; then
            # Under --parallel, worker output is interleaved across processes
            # and SwiftPM may swallow the trailing "Test Suite '...' passed"
            # line for some workers. If the streaming runner emitted at least
            # one test from this suite, it ran — only flag as crashed if
            # SwiftPM itself reported a non-zero exit.
            if [[ $PARALLEL_MODE -eq 1 ]]; then
                if grep -qE "^\[[0-9]+/[0-9]+\] Testing .*\.${suite_pat}/" "$OUTPUT_FILE" 2>/dev/null; then
                    continue
                fi
            fi
            xctest_crashed_suites="${xctest_crashed_suites}  - ${suite} (XCTest)"$'\n'
            xctest_crashed_count=$((xctest_crashed_count + 1))
        fi
    done <<< "$xctest_suites_started"
fi

# ── Parse Swift Testing events ────────────────────────────────────────────────
# Lines: "✔ Test foo() passed after N seconds."
#        "✘ Test foo() failed after N seconds."
#        "↩ Test foo() skipped after N seconds."
st_passed=$(awk '/^✔ Test .* passed after / && $0 !~ /^✔ Test run / { count++ } END { print count + 0 }' "$OUTPUT_FILE")
st_failed=$(awk '/^✘ Test .* failed after / && $0 !~ /^✘ Test run / { count++ } END { print count + 0 }' "$OUTPUT_FILE")
st_skipped=$(awk '/^↩ Test .* skipped after / && $0 !~ /^↩ Test run / { count++ } END { print count + 0 }' "$OUTPUT_FILE")

# Swift Testing suites: "◇ Suite "Name" started." vs "✔ Suite "Name" passed after N seconds."
st_suites_started=$(grep '^◇ Suite "' "$OUTPUT_FILE" \
    | sed 's/^◇ Suite "//; s/" started\.//' \
    || true)  # fail-open-ok: a run with no Swift Testing suites is a valid outcome

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
elif [[ $MCP_FILTER_REQUESTED -eq 1 && $mcp_test_events -eq 0 ]]; then
    echo "  RESULT: TRIPWIRE — MCP filter matched 0 MCP test cases (target dropped from the build, or filter typo)"
    FINAL_EXIT=3
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
