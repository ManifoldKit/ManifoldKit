#!/usr/bin/env bash
# scripts/benchmark.sh — ManifoldKit backend throughput benchmark suite
#
# Measures TTFT (time-to-first-token) and tokens/sec across all available
# backends and surfaces the results as a Markdown table.
#
# Local developer use only — never run in CI.
#
# Since v0.48 PR C2 the MLX and llama.cpp families live in companion packages
# (https://github.com/roryford/manifold-mlx, https://github.com/roryford/manifold-llama).
# Benchmark those backends from the companion repos' own tooling; this script
# covers the core graph only: raw Ollama HTTP, SDK→Ollama, server→Ollama, and
# SDK→FoundationBackend.
#
# ## Quick start
#
#   scripts/benchmark.sh
#
# Auto-detects available backends and skips paths that aren't configured.
#
# ## Configuration (environment variables)
#
#   OLLAMA_URL            Ollama base URL (default: http://localhost:11434)
#   OLLAMA_MODEL          Model for Ollama paths (default: auto-select)
#   BENCH_RUNS            Warm runs per path (default: 4)
#   BENCH_SERVER_PORT     Port for the temporary ManifoldKit server (default: 18080)
#
# ## Flags
#
#   --no-raw      Skip the raw Ollama HTTP baseline
#   --only PATH   Run only one path:
#                   ollama-raw | sdk-ollama | server-ollama | sdk-foundation
#
# ## Examples
#
#   # Ollama SDK path only:
#   scripts/benchmark.sh --only sdk-ollama
#
# ## First-run note
#
# On a clean checkout, run `xcrun swift build` once before invoking this
# script. The warm-up step below does this automatically.

set -euo pipefail
cd "$(dirname "$0")/.."

OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-}"
BENCH_RUNS="${BENCH_RUNS:-4}"
BENCH_SERVER_PORT="${BENCH_SERVER_PORT:-18080}"
SKIP_RAW=0
ONLY_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-raw)  SKIP_RAW=1 ;;
        --only=*)  ONLY_PATH="${1#*=}" ;;
        --only)    shift; ONLY_PATH="$1" ;;
        -h|--help)
            grep "^#" "$0" | sed 's/^# \?//' | sed 's/^#//'
            exit 0
            ;;
    esac
    shift
done

# ── Colours ───────────────────────────────────────────────────────────────────
BOLD=""; DIM=""; RESET=""
if [[ -t 1 ]]; then BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"; fi

log()  { echo -e "${DIM}[bench]${RESET} $*"; }
head_() { echo -e "\n${BOLD}$*${RESET}"; }

# ── Dependency checks ─────────────────────────────────────────────────────────
if ! command -v python3 &>/dev/null; then
    echo "error: python3 required" >&2; exit 1
fi
BENCH_PY="$(dirname "$0")/bench/http-bench.py"
if [[ ! -f "$BENCH_PY" ]]; then
    echo "error: scripts/bench/http-bench.py not found" >&2; exit 1
fi

# ── First-run warm-up ─────────────────────────────────────────────────────────
# Ensures module interfaces are cached before the parallel xcrun swift test
# compilations start. No-op on subsequent runs.
log "Warming up build artifacts (xcrun swift build)…"
xcrun swift build 2>&1 | { grep -E "Build complete|^error:" || true; } | head -3 || true

# ── Backend detection ─────────────────────────────────────────────────────────
OLLAMA_AVAILABLE=0

if curl -sf "${OLLAMA_URL}/api/tags" > /dev/null 2>&1; then
    OLLAMA_AVAILABLE=1
    if [[ -z "$OLLAMA_MODEL" ]]; then
        OLLAMA_MODEL=$(curl -sf "${OLLAMA_URL}/api/tags" | \
            python3 -c "import json,sys; ms=json.load(sys.stdin)['models']; \
            print(ms[0]['name'] if ms else '')" 2>/dev/null || true)
    fi
    [[ -n "$OLLAMA_MODEL" ]] || OLLAMA_AVAILABLE=0
fi

# ── Summary ───────────────────────────────────────────────────────────────────
head_ "ManifoldKit benchmark suite"
[[ $OLLAMA_AVAILABLE -eq 1 ]] && log "Ollama : $OLLAMA_URL  model=$OLLAMA_MODEL" \
                               || log "Ollama : not available (skipping Ollama paths)"
log "Foundation: Apple Intelligence (skips gracefully if unavailable)"
log "MLX/Llama: benchmark via the manifold-mlx / manifold-llama companion repos"
log "Runs   : $BENCH_RUNS warm runs per path"

TABLE_ROWS=()
add_row() { TABLE_ROWS+=("$1"); }

# Extract a BENCH_RESULT sentinel line from swift test output and format it as
# a Markdown table row.
extract_sdk_result() {
    local output="$1" label="$2"
    local line
    line=$(echo "$output" | grep "^BENCH_RESULT label=${label}" | tail -1)
    if [[ -z "$line" ]]; then
        echo "| ${label} | — | — | (skipped or failed) |"
        return
    fi
    local ttft tps model
    ttft=$(echo "$line"  | grep -o 'median_ttft_ms=[0-9.]*' | cut -d= -f2)
    tps=$(echo  "$line"  | grep -o 'median_tps=[0-9.]*'     | cut -d= -f2)
    model=$(echo "$line" | grep -o 'model=[^ ]*'            | cut -d= -f2)
    printf "| %s | %s ms | %s tok/s | %s |\n" "$label" "${ttft%.}" "${tps%.}" "$model"
}

# ── Path 1: Raw Ollama HTTP ───────────────────────────────────────────────────
if [[ $OLLAMA_AVAILABLE -eq 1 && $SKIP_RAW -eq 0 ]] && \
   [[ -z "$ONLY_PATH" || "$ONLY_PATH" == "ollama-raw" ]]; then
    head_ "Raw Ollama HTTP (baseline)"
    ROW=$(python3 "$BENCH_PY" \
        --url "${OLLAMA_URL}/api/generate" \
        --model "$OLLAMA_MODEL" \
        --mode ollama \
        --runs "$BENCH_RUNS" \
        --label "Raw Ollama HTTP" \
        --markdown)
    echo "$ROW"
    add_row "$ROW"
fi

# ── Path 2: ManifoldKit SDK → OllamaBackend ───────────────────────────────────
if [[ $OLLAMA_AVAILABLE -eq 1 ]] && \
   [[ -z "$ONLY_PATH" || "$ONLY_PATH" == "sdk-ollama" ]]; then
    head_ "ManifoldKit SDK → OllamaBackend"
    SDK_OUT=$(MANIFOLD_BENCH_OLLAMA_MODEL="$OLLAMA_MODEL" \
        xcrun swift test \
            --filter OllamaBackendBenchmark \
            --skip-update 2>&1)
    echo "$SDK_OUT" | grep -E "ManifoldKit→Ollama run|BENCH_RESULT" || true
    add_row "$(extract_sdk_result "$SDK_OUT" "ManifoldKit→Ollama")"
fi

# ── Path 3: ManifoldKit server ────────────────────────────────────────────────
run_server_bench() {
    local traits="$1" backend_flag="$2" model_arg="$3" label="$4"
    local server_bin=".build/arm64-apple-macosx/debug/ManifoldServer"

    log "Building ManifoldServer (traits: $traits)…"
    xcrun swift build --traits "$traits" --product ManifoldServer 2>&1 | tail -1 || true

    log "Starting ManifoldServer on port $BENCH_SERVER_PORT (backend=$backend_flag)…"
    local log_file="/tmp/manifold-bench-server-$$.log"
    # shellcheck disable=SC2086
    "$server_bin" --backend "$backend_flag" $model_arg \
        --port "$BENCH_SERVER_PORT" --unsafe-cors > "$log_file" 2>&1 &
    local server_pid=$!

    local ready=0
    for i in $(seq 1 60); do
        if curl -sf "http://localhost:${BENCH_SERVER_PORT}/v1/models" > /dev/null 2>&1; then
            ready=1; log "Server ready after ${i}s"; break
        fi
        sleep 1
    done

    if [[ $ready -eq 0 ]]; then
        log "Server failed to start — see $log_file"
        kill "$server_pid" 2>/dev/null || true
        return
    fi

    # Use the model path as the model id for the OpenAI request
    local model_id
    model_id=$(curl -sf "http://localhost:${BENCH_SERVER_PORT}/v1/models" | \
        python3 -c "import json,sys; print(json.load(sys.stdin)['data'][0]['id'])" 2>/dev/null || echo "unknown")

    ROW=$(python3 "$BENCH_PY" \
        --url "http://localhost:${BENCH_SERVER_PORT}/v1/chat/completions" \
        --model "$model_id" \
        --mode openai \
        --runs "$BENCH_RUNS" \
        --label "$label" \
        --markdown)
    echo "$ROW"
    add_row "$ROW"

    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
    rm -f "$log_file"
}

if [[ $OLLAMA_AVAILABLE -eq 1 ]] && \
   [[ -z "$ONLY_PATH" || "$ONLY_PATH" == "server-ollama" ]]; then
    head_ "ManifoldKit server → OllamaBackend"
    run_server_bench "Server" "ollama" \
        "--model $OLLAMA_MODEL --ollama-base-url $OLLAMA_URL" \
        "ManifoldKit server→Ollama"
fi

# ── Path 4: ManifoldKit SDK → FoundationBackend (Apple Intelligence) ─────────
if [[ -z "$ONLY_PATH" || "$ONLY_PATH" == "sdk-foundation" ]]; then
    head_ "ManifoldKit SDK → FoundationBackend"
    SDK_OUT=$(xcrun swift test \
            --filter FoundationBackendBenchmark \
            --skip-update 2>&1)
    echo "$SDK_OUT" | grep -E "ManifoldKit→Foundation run|BENCH_RESULT" || true
    add_row "$(extract_sdk_result "$SDK_OUT" "ManifoldKit→Foundation")"
fi

# ── Results table ─────────────────────────────────────────────────────────────
if [[ ${#TABLE_ROWS[@]} -gt 0 ]]; then
    head_ "Results"
    echo ""
    echo "| Path | TTFT | Throughput | Model |"
    echo "|------|-----:|------------|-------|"
    for row in "${TABLE_ROWS[@]}"; do
        echo "$row"
    done
    echo ""
    echo "> Prompt: \"Write a short story about a robot learning to paint. Be concise.\""
    echo "> Runs: $BENCH_RUNS warm runs per path. Medians reported."
    echo "> Token count: Ollama \`eval_count\` (exact); SDK paths from stream event count (exact);"
    echo "> server paths from SSE chunk count (1 chunk ≈ 1 token for Ollama)."
fi
