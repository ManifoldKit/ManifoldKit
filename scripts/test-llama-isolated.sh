#!/usr/bin/env bash
# scripts/test-llama-isolated.sh — Run each Llama-touching XCTestCase subclass
# in its own swift-test invocation (separate xctest process) to isolate
# llama.cpp / GGML / Metal global state across test classes.
#
# Why this exists
# ---------------
# `LlamaBackend` calls `llama_backend_init` / `llama_backend_free` through a
# process-global refcount (`LlamaBackendProcessLifecycle`). The llama.cpp C
# contract documents `llama_backend_init` as exactly-once-per-process — calling
# the init/free pair more than once is undefined behaviour in GGML / BLAS
# global init (see docs/LLAMA_CONTRACT.md "Global Backend Lifecycle").
#
# The test suite refcount can dip to zero between tests (every test allocates
# its own backend; deinit calls release()), which means the next test class
# triggers `llama_backend_init` a second time. Combined with detached cleanup
# tasks that free the previous test's `llama_context` / `llama_model` after
# the next test has already started, accumulated GGML state across many real
# model loads can stall the run on memory-pressured hosts.
#
# Splitting each XCTestCase subclass into its own xctest process gives the
# kernel a clean slate every time: the previous process's GGML globals and
# Metal command-buffer pools die with it, and `llama_backend_init` runs
# exactly once per child.
#
# Cost
# ----
# Each `swift test --filter <Class>` invocation pays the build-graph + test
# bundle link cost (~5–10 s on a warm cache). With ~15 Llama-touching test
# classes, total overhead is ~1–2 minutes wall-clock vs a single invocation.
# In exchange the suite is repeatable on hosts where the single-process run
# accumulates state.
#
# Usage
# -----
#   # Run with whichever GGUF you already have set up:
#   RUN_LLAMA_TESTS=1 BASECHAT_DISCOVER_LOCAL_MODELS=1 \
#     LLAMA_TEST_MODEL=$HOME/Documents/Models/<model>.gguf \
#     scripts/test-llama-isolated.sh
#
#   # Pass extra args through to swift test (after `--`):
#   scripts/test-llama-isolated.sh -- --skip-update --skip-build
#
# This is intentionally NOT wired into CI. CI runs `BaseChatBackendsTests`
# without hardware traits, so the Llama tests are excluded by `#if Llama`
# conditional compilation. Use this script when running on Apple Silicon
# locally with `RUN_LLAMA_TESTS=1` and a real GGUF.

set -euo pipefail

# ── Args ──────────────────────────────────────────────────────────────────────
# Everything after `--` is forwarded to each `swift test` call.
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --)
            shift
            EXTRA_ARGS+=("$@")
            break
            ;;
        *)
            echo "test-llama-isolated.sh: unexpected argument '$1'" >&2
            echo "usage: test-llama-isolated.sh [-- <swift test args>]" >&2
            exit 2
            ;;
    esac
done

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PACKAGE_DIR"

# ── Discover Llama-touching XCTestCase subclasses ─────────────────────────────
# Test classes that instantiate LlamaBackend or LlamaEmbeddingBackend.
# Listed explicitly (rather than grep-discovered at runtime) so the script
# stays predictable and fails loudly when a new Llama class appears without
# being added here.
LLAMA_TEST_CLASSES=(
    LlamaArchitecturePreflightTests
    LlamaBackendMemoryPressureTests
    LlamaBackendTests
    LlamaEmbeddingBackendTests
    LlamaGrammarSamplerTests
    LlamaKVCacheSecureWipeTests
    LlamaKVPersistenceTests
    LlamaSeedDeterminismTests
    LlamaThinkingMarkerAutoDiscoveryTests
    LlamaTokenizationTests
    LlamaToolCapabilityTests
)

# Sanity-check that every class above corresponds to a real test file. Catches
# typos and renames before we waste minutes invoking xctest with a dead filter.
for class in "${LLAMA_TEST_CLASSES[@]}"; do
    file="Tests/BaseChatBackendsTests/${class}.swift"
    if [[ ! -f "$file" ]]; then
        echo "test-llama-isolated.sh: expected test file '$file' not found." >&2
        echo "Update LLAMA_TEST_CLASSES in $0 if the class was renamed or removed." >&2
        exit 2
    fi
done

# ── Build once, reuse the bundle across invocations ───────────────────────────
# `swift test --skip-build` reads the existing test bundle from .build, so
# pre-building here saves the per-invocation compile-time check.
echo "[test-llama-isolated] Pre-building tests with traits MLX,Llama..."
swift build --build-tests --traits MLX,Llama
echo ""

# ── Run each class in its own invocation ──────────────────────────────────────
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0
FAILED_CLASSES=()
START=$(date +%s)

for class in "${LLAMA_TEST_CLASSES[@]}"; do
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ▶ ${class}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    LOG="${TMPDIR:-/tmp}/llama-iso-${class}.log"
    set +e
    swift test \
        --filter "BaseChatBackendsTests\.${class}/" \
        --traits MLX,Llama \
        --skip-build \
        "${EXTRA_ARGS[@]}" \
        2>&1 | tee "$LOG"
    rc=${PIPESTATUS[0]}
    set -e

    # `grep -c` returns 1 when there are zero matches; combined with `set -e`
    # this would kill the script on a class with no test events. The `|| true`
    # tolerates the no-match case. Use `tr -d '\n'` because some greps emit a
    # trailing newline that breaks arithmetic when the value is interpolated.
    pass=$(grep -c "^Test Case '.*' passed" "$LOG" 2>/dev/null | tr -d '\n' || true)
    fail=$(grep -c "^Test Case '.*' failed" "$LOG" 2>/dev/null | tr -d '\n' || true)
    skip=$(grep -c "^Test Case '.*' skipped" "$LOG" 2>/dev/null | tr -d '\n' || true)
    pass=${pass:-0}
    fail=${fail:-0}
    skip=${skip:-0}
    TOTAL_PASS=$((TOTAL_PASS + pass))
    TOTAL_FAIL=$((TOTAL_FAIL + fail))
    TOTAL_SKIP=$((TOTAL_SKIP + skip))

    if [[ $rc -ne 0 || $fail -gt 0 ]]; then
        FAILED_CLASSES+=("$class (rc=$rc fail=$fail)")
    fi
    echo ""
done

ELAPSED=$(( $(date +%s) - START ))

# ── Summary ───────────────────────────────────────────────────────────────────
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ISOLATED LLAMA TEST SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  Classes run:  %d\n" "${#LLAMA_TEST_CLASSES[@]}"
printf "  Passed:       %d\n" "$TOTAL_PASS"
printf "  Failed:       %d\n" "$TOTAL_FAIL"
printf "  Skipped:      %d\n" "$TOTAL_SKIP"
printf "  Wall clock:   %ds\n" "$ELAPSED"
if [[ ${#FAILED_CLASSES[@]} -gt 0 ]]; then
    echo ""
    echo "  FAILED CLASSES:"
    for entry in "${FAILED_CLASSES[@]}"; do
        echo "    - $entry"
    done
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
exit 0
