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

OUTPUT_FILE="${MANIFOLD_TEST_OUTPUT_FILE:-${TMPDIR:-/tmp}/test_output.txt}"
PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# ── Arguments ────────────────────────────────────────────────────────────────
# Profile precedence
# ------------------
# `--profile <name>` selects a canned invocation shape. Two profiles ship today:
#
#   ci      — mirrors CI's no-traits two-invocation shape. This is the
#             default when --profile is omitted (back-compat). Since v0.48
#             (PR C2) there are no default traits, so this is simply the
#             plain `swift test` shape.
#   local   — Apple-Silicon pre-push: the surviving opt-in traits (Macros;
#             Server runs in its own CI job and stays out of the batch, as
#             before), plus the extended suite list (ManifoldKitTests /
#             ManifoldHuggingFaceTests).
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
# Two-invocation shape: the CI and local profiles both run the XCTest filter
# set in one swift-test call and ManifoldInferenceSwiftTestingTests in a second
# separate process — mixing Swift Testing with XCTest in a single process
# triggers libmalloc SIGABRT (#681). When the caller has not narrowed with
# their own --filter, we re-exec this script twice with the resolved flags.

# Two-invocation XCTest suite list. Source of truth for the pre-push gate.
PROFILE_CI_XCTEST_FILTERS=(
    ManifoldCoreTests
    ManifoldRuntimeTests
    ManifoldPersistenceSwiftDataTests
    ManifoldUITests
    ManifoldUIModelManagementTests
    ManifoldMCPTests
    ManifoldBackendsTests
    ManifoldInferenceTests
    ManifoldNetworkingTests
    ManifoldSecretsTests
    ManifoldHardwareTests
    ManifoldModelCatalogTests
    ManifoldTestSupportTests
    ManifoldAppIntentsTests
    ManifoldServerTests
    ManifoldTurnLoopCharacterizationTests
    # Voice / Skills / Tools traits retired in v0.48 (PR A3): these suites
    # compile in every trait shape now, so they run in the CI shape too.
    ManifoldVoiceTests
    ManifoldSkillsTests
    ManifoldToolsTests
    # App-eval harness (estate#1 wave 1): schema/mapper/scorer/renderer/ledger
    # unit tests + the MK-compression-golden dogfood, all hermetic.
    ManifoldAppEvalTests
    # Public-API freeze suite: compile-time surface fixtures + the
    # public-surface baseline well-formedness tripwire
    # (PublicSurfaceBaselineTests). Fast (<1s) and hermetic — the heavy
    # digester-backed check stays behind RUN_API_SURFACE_BASELINE_CHECK=1
    # and the nightly api-surface-baseline job (wave-2 item 0.A).
    APIFreezeTests
)
# Local-profile filters extend the CI list with the umbrella + HuggingFace
# suites.
PROFILE_LOCAL_XCTEST_FILTERS=(
    "${PROFILE_CI_XCTEST_FILTERS[@]}"
    ManifoldKitTests
    ManifoldHuggingFaceTests
)
PROFILE_SWIFT_TESTING_FILTER="ManifoldInferenceSwiftTestingTests"

# Local profile trait set: the surviving opt-in traits exercised by the batch
# (Macros only — Server has its own CI job/filter shape). The MLX / Llama /
# HuggingFace / Fuzz traits retired in v0.48 (PR C2, #1749).
PROFILE_LOCAL_TRAITS="Macros"

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
    # under the profile's traits/workers (not the two-invocation default
    # suite list). This is the "narrow override" path.
    HAS_USER_FILTER=0
    if [[ ${#FILTERS_SEEN[@]} -gt 0 ]]; then
        HAS_USER_FILTER=1
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
        # Fall through to the single swift-test invocation at the bottom.
    else
        # No caller filter — run the canonical two-invocation pre-push gate.
        # Re-exec self twice with the resolved flag sets. This keeps the
        # parsing surface single-pass and the summary printer authoritative
        # per call (each invocation prints its own summary).
        SCRIPT_PATH="$0"
        EXTRA_ARGS=("${SWIFT_ARGS[@]}")
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
        echo "  PROFILE: $PROFILE (two-invocation pre-push gate)"
        echo "  Traits:  $BANNER_TRAITS"
        printf "  XCTest filters (%d): %s\n" "${#FILTERS[@]}" "${FILTERS[*]}"
        echo "  Swift Testing filter: $PROFILE_SWIFT_TESTING_FILTER (separate process — #681)"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        # Build the --filter args.
        XCTEST_FILTER_ARGS=()
        for f in "${FILTERS[@]}"; do
            XCTEST_FILTER_ARGS+=(--filter "$f")
        done

        # Invocation 1: XCTest filters.
        #
        # We deliberately do NOT pass `--parallel` or `--num-workers` here.
        # swift-test's implicit scheduling without the flag is the baseline
        # that's passed historically; keep it. (Historically explicit
        # `--parallel` also surfaced process-global state races in
        # `BackendContractChecks` — each per-backend conformance suite's
        # `test_z_contract_metaContract` read a shared claims registry, and
        # interleaving backend test classes left it partial when meta-contract
        # ran: 4395/0/57 pass under implicit scheduling vs 4445/7/0 with
        # explicit --parallel, measured locally. The capability-claims
        # registry is now instance-scoped per test case (arch-plan item 4.2),
        # so that specific hazard is gone — see ManifoldBackendTestKit's DocC
        # catalog. `--parallel` stays off here as a conservative default.)
        set +e
        "$SCRIPT_PATH" \
            "${XCTEST_FILTER_ARGS[@]}" \
            ${TRAIT_FLAGS[@]+"${TRAIT_FLAGS[@]}"} \
            --skip-update \
            ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
        RC1=$?
        set -e
        if [[ $RC1 -ne 0 ]]; then
            echo "[--profile $PROFILE] XCTest invocation failed (exit $RC1) — skipping Swift Testing run." >&2
            exit $RC1
        fi

        # Invocation 2: Swift Testing in a separate process (#681).
        set +e
        "$SCRIPT_PATH" \
            --filter "$PROFILE_SWIFT_TESTING_FILTER" \
            ${TRAIT_FLAGS[@]+"${TRAIT_FLAGS[@]}"} \
            --skip-update \
            ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}
        RC2=$?
        set -e
        exit $RC2
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
    || true)

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
