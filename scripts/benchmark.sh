#!/usr/bin/env bash
# scripts/benchmark.sh — ManifoldKit backend throughput benchmark suite
#
# Measures TTFT (time-to-first-token) and tokens/sec across all available
# backends and surfaces the results as a Markdown table.
#
# Local developer use only — never run in CI.
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
#   LLAMA_MODEL_PATH      Absolute path to a GGUF file for LlamaBackend paths
#                         (default: auto-discover from ~/Documents/Models/)
#   LLAMA_MODEL_HINT      Name substring for GGUF discovery when LLAMA_MODEL_PATH
#                         is not set (default: "")
#   BENCH_RUNS            Warm runs per path (default: 4)
#   BENCH_SERVER_PORT     Port for the temporary ManifoldKit server (default: 18080)
#
# ## Flags
#
#   --mlx         Also benchmark ManifoldKit → MLXBackend (requires Xcode)
#   --no-raw      Skip the raw Ollama HTTP baseline
#   --only PATH   Run only one path:
#                   ollama-raw | sdk-ollama | sdk-llama | server-ollama | server-llama | mlx
#
# ## Examples
#
#   # Full suite with a specific llama3.1:8b GGUF:
#   LLAMA_MODEL_PATH=~/Documents/Models/llama3.1-8b-instruct-Q4_K_M.gguf \
#     scripts/benchmark.sh
#
#   # Llama paths only:
#   LLAMA_MODEL_HINT=llama3.1 scripts/benchmark.sh --only sdk-llama
#
#   # Include MLX:
#   scripts/benchmark.sh --mlx
#
# ## First-run note
#
# On a clean checkout, run `xcrun swift build --traits Ollama,Llama,MLX` once
# before invoking this script. The warm-up step below does this automatically.

set -euo pipefail
cd "$(dirname "$0")/.."

OLLAMA_URL="${OLLAMA_URL:-http://localhost:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-}"
LLAMA_MODEL_PATH="${LLAMA_MODEL_PATH:-}"
LLAMA_MODEL_HINT="${LLAMA_MODEL_HINT:-}"
BENCH_RUNS="${BENCH_RUNS:-4}"
BENCH_SERVER_PORT="${BENCH_SERVER_PORT:-18080}"
RUN_MLX=0
SKIP_RAW=0
ONLY_PATH=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mlx)     RUN_MLX=1 ;;
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
# Ensures _NumericsShims and all module interfaces are cached before the
# parallel xcrun swift test compilations start. No-op on subsequent runs.
log "Warming up build artifacts (xcrun swift build)…"
xcrun swift build --traits Ollama,Llama,MLX 2>&1 | { grep -E "Build complete|^error:" || true; } | head -3 || true

# ── Backend detection ─────────────────────────────────────────────────────────
OLLAMA_AVAILABLE=0
LLAMA_AVAILABLE=0
LLAMA_RESOLVED=""

if curl -sf "${OLLAMA_URL}/api/tags" > /dev/null 2>&1; then
    OLLAMA_AVAILABLE=1
    if [[ -z "$OLLAMA_MODEL" ]]; then
        OLLAMA_MODEL=$(curl -sf "${OLLAMA_URL}/api/tags" | \
            python3 -c "import json,sys; ms=json.load(sys.stdin)['models']; \
            print(ms[0]['name'] if ms else '')" 2>/dev/null || true)
    fi
    [[ -n "$OLLAMA_MODEL" ]] || OLLAMA_AVAILABLE=0
fi

if [[ -n "$LLAMA_MODEL_PATH" ]]; then
    expanded="${LLAMA_MODEL_PATH/#\~/$HOME}"
    if [[ -f "$expanded" && "$expanded" == *.gguf ]]; then
        LLAMA_AVAILABLE=1
        LLAMA_RESOLVED="$expanded"
    else
        log "LLAMA_MODEL_PATH=$LLAMA_MODEL_PATH not found or not a .gguf — skipping Llama paths"
    fi
else
    SEARCH_DIR="$HOME/Documents/Models"
    if [[ -d "$SEARCH_DIR" ]]; then
        HINT="${LLAMA_MODEL_HINT:-}"
        FOUND=$(find "$SEARCH_DIR" -maxdepth 1 -name "*${HINT}*.gguf" -size +50M \
            ! -name "nomic-*" ! -name "all-MiniLM-*" \
            -exec ls -1S {} + 2>/dev/null | head -1 || true)
        if [[ -n "$FOUND" ]]; then
            LLAMA_AVAILABLE=1
            LLAMA_RESOLVED="$FOUND"
        fi
    fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
head_ "ManifoldKit benchmark suite"
[[ $OLLAMA_AVAILABLE -eq 1 ]] && log "Ollama : $OLLAMA_URL  model=$OLLAMA_MODEL" \
                               || log "Ollama : not available (skipping Ollama paths)"
[[ $LLAMA_AVAILABLE  -eq 1 ]] && log "Llama  : $LLAMA_RESOLVED" \
                               || log "Llama  : no GGUF found (skipping Llama paths)"
[[ $RUN_MLX          -eq 1 ]] && log "MLX    : enabled (requires Xcode build)" \
                               || log "MLX    : disabled (pass --mlx to enable)"
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
        xcrun swift test --traits Ollama \
            --filter OllamaBackendBenchmark \
            --skip-update 2>&1)
    echo "$SDK_OUT" | grep -E "ManifoldKit→Ollama run|BENCH_RESULT" || true
    add_row "$(extract_sdk_result "$SDK_OUT" "ManifoldKit→Ollama")"
fi

# ── Path 3: ManifoldKit SDK → LlamaBackend ────────────────────────────────────
if [[ $LLAMA_AVAILABLE -eq 1 ]] && \
   [[ -z "$ONLY_PATH" || "$ONLY_PATH" == "sdk-llama" ]]; then
    head_ "ManifoldKit SDK → LlamaBackend"
    SDK_OUT=$(MANIFOLD_BENCH_LLAMA_MODEL="$LLAMA_RESOLVED" \
        xcrun swift test --traits Llama \
            --filter LlamaBackendBenchmark \
            --skip-update 2>&1)
    echo "$SDK_OUT" | grep -E "ManifoldKit→Llama run|BENCH_RESULT" || true
    add_row "$(extract_sdk_result "$SDK_OUT" "ManifoldKit→Llama")"
fi

# ── Paths 4 & 5: ManifoldKit server ──────────────────────────────────────────
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
    run_server_bench "Server,Ollama" "ollama" \
        "--model $OLLAMA_MODEL --ollama-base-url $OLLAMA_URL" \
        "ManifoldKit server→Ollama"
fi

if [[ $LLAMA_AVAILABLE -eq 1 ]] && \
   [[ -z "$ONLY_PATH" || "$ONLY_PATH" == "server-llama" ]]; then
    head_ "ManifoldKit server → LlamaBackend"
    run_server_bench "Server,Llama" "llama" \
        "--model-path $LLAMA_RESOLVED" \
        "ManifoldKit server→Llama"
fi

# ── Path 6: ManifoldKit SDK → MLXBackend ─────────────────────────────────────
if [[ $RUN_MLX -eq 1 ]] && \
   [[ -z "$ONLY_PATH" || "$ONLY_PATH" == "mlx" ]]; then
    head_ "ManifoldKit SDK → MLXBackend (via xcodebuild)"
    MLX_HINT="${MLX_MODEL_HINT:-}"
    MLX_OUT=$(scripts/test-mlx-integration.sh "$MLX_HINT" 2>&1 | \
        grep -E "(MLX run|MLX summary)" || true)
    echo "$MLX_OUT"
    TTFT=$(echo "$MLX_OUT"  | grep "MLX summary" | grep -o 'median TTFT=[0-9.]*ms' | grep -o '[0-9.]*')
    TPS=$(echo  "$MLX_OUT"  | grep "MLX summary" | grep -o 'median TPS=[0-9.]*'    | grep -o '[0-9.]*')
    MODEL=$(echo "$MLX_OUT" | grep "MLX summary" | grep -o 'model=[^ ]*'           | cut -d= -f2)
    if [[ -n "$TTFT" ]]; then
        add_row "| ManifoldKit→MLX | ${TTFT} ms | ${TPS} tok/s | $MODEL |"
    else
        add_row "| ManifoldKit→MLX | — | — | (no results) |"
    fi
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
    echo "> server paths from SSE chunk count (1 chunk ≈ 1 token for llama.cpp/Ollama)."
fi
