#!/usr/bin/env bash
# scripts/fuzz.sh — Run the BaseChatFuzz harness with a friendly preflight.
#
# Default behaviour (no args): runs `swift run --traits Fuzz,MLX,Llama,Ollama
# fuzz-chat --minutes 5` against Ollama. Discovers which backends are usable and
# prints a one-line summary before kicking off the harness.
#
# Local extensions:
#   --with-mlx    Also run the MLX XCTest fuzz suite via xcodebuild after the
#                 swift-run path completes. Shared campaign knobs are forwarded
#                 into xcodebuild via BASECHAT_FUZZ_* / MLX_TEST_MODEL env vars.
#   --backend mlx Skip the swift-run path entirely and run only the MLX XCTest
#                 host (same env forwarding as --with-mlx). Replay/shrink remain
#                 swift-run-only and are rejected for this path.

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

WITH_MLX=0
FORWARDED_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --with-mlx) WITH_MLX=1 ;;
        -h|--help)
            cd "$PACKAGE_DIR"
            echo "scripts/fuzz.sh — wrapper around \`swift run --traits Fuzz,MLX,Llama,Ollama fuzz-chat\`"
            echo ""
            echo "Local flags:"
            echo "  --with-mlx   Also run the MLX XCTest fuzz suite via xcodebuild"
            echo "  -h, --help   Show this help and forward to fuzz-chat -h"
            echo ""
            echo "Forwarding to: swift run --traits Fuzz,MLX,Llama,Ollama fuzz-chat -h"
            echo "─────────────────────────────────────────────────────────────"
            swift run --traits Fuzz,MLX,Llama,Ollama fuzz-chat -h || true
            exit 0
            ;;
        *) FORWARDED_ARGS+=("$arg") ;;
    esac
done

REQUESTED_BACKEND=""
for ((i = 0; i < ${#FORWARDED_ARGS[@]}; i++)); do
    arg="${FORWARDED_ARGS[$i]}"
    case "$arg" in
        --backend)
            if (( i + 1 < ${#FORWARDED_ARGS[@]} )); then
                REQUESTED_BACKEND="${FORWARDED_ARGS[$((i + 1))]}"
                ((i++))
            fi
            ;;
        --backend=*) REQUESTED_BACKEND="${arg#*=}" ;;
    esac
done

RUN_SWIFT=1
if [[ "$REQUESTED_BACKEND" == "mlx" ]]; then
    RUN_SWIFT=0
    WITH_MLX=1
    for arg in "${FORWARDED_ARGS[@]}"; do
        case "$arg" in
            --replay|--replay=*|--shrink|--shrink=*|--force)
                echo "scripts/fuzz.sh: MLX xcodebuild runs support campaign flags only; replay/shrink remain available via swift run backends." >&2
                exit 2
                ;;
        esac
    done
fi

LLAMA_HIT="miss"
MLX_HIT="miss"
OLLAMA_HIT="miss"
FOUNDATION_HIT="miss"

MODELS_DIR="$HOME/Documents/Models"
if [[ -d "$MODELS_DIR" ]]; then
    if find "$MODELS_DIR" -maxdepth 2 -type f -name "*.gguf" -print -quit 2>/dev/null | grep -q .; then
        LLAMA_HIT="hit"
    fi
    if find "$MODELS_DIR" -maxdepth 3 -type f -name "*.safetensors" -print -quit 2>/dev/null | grep -q .; then
        MLX_HIT="hit"
    fi
fi

if curl -s -m 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
    OLLAMA_HIT="hit"
fi

PRODUCT_VERSION="$(sw_vers -productVersion 2>/dev/null || echo 0)"
PRODUCT_MAJOR="${PRODUCT_VERSION%%.*}"
if [[ "$PRODUCT_MAJOR" =~ ^[0-9]+$ ]] && (( PRODUCT_MAJOR >= 26 )); then
    FOUNDATION_HIT="hit"
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  BaseChatFuzz preflight"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  Discovered: Llama=%s, MLX=%s, Ollama=%s, Foundation=%s\n" \
    "$LLAMA_HIT" "$MLX_HIT" "$OLLAMA_HIT" "$FOUNDATION_HIT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ "$LLAMA_HIT" == "miss" && "$MLX_HIT" == "miss" && "$OLLAMA_HIT" == "miss" && "$FOUNDATION_HIT" == "miss" ]]; then
    echo "No usable backends detected. Install hints:" >&2
    echo "  Ollama:     brew install ollama && ollama serve   (then: ollama pull qwen3.5:4b)" >&2
    echo "  Llama:      drop a *.gguf into ~/Documents/Models/ or ~/Documents/Models/<name>/" >&2
    echo "  MLX:        drop an MLX snapshot into ~/Documents/Models/<name>/ (config.json + *.safetensors + tokenizer)" >&2
    echo "  Foundation: requires macOS 26+" >&2
    exit 2
fi

HAS_BUDGET=0
for arg in "${FORWARDED_ARGS[@]+"${FORWARDED_ARGS[@]}"}"; do
    case "$arg" in
        --minutes|--minutes=*|--iterations|--iterations=*|--single)
            HAS_BUDGET=1 ;;
    esac
done

if [[ $HAS_BUDGET -eq 0 ]]; then
    FORWARDED_ARGS=("--minutes" "5" "${FORWARDED_ARGS[@]+"${FORWARDED_ARGS[@]}"}")
fi

build_mlx_env() {
    local args=("$@")
    local env=()
    local i=0
    while (( i < ${#args[@]} )); do
        local arg="${args[$i]}"
        case "$arg" in
            --minutes)
                ((i++))
                if (( i < ${#args[@]} )); then env+=("BASECHAT_FUZZ_MINUTES=${args[$i]}"); fi
                ;;
            --minutes=*) env+=("BASECHAT_FUZZ_MINUTES=${arg#*=}") ;;
            --iterations)
                ((i++))
                if (( i < ${#args[@]} )); then env+=("BASECHAT_FUZZ_ITERATIONS=${args[$i]}"); fi
                ;;
            --iterations=*) env+=("BASECHAT_FUZZ_ITERATIONS=${arg#*=}") ;;
            --single) env+=("BASECHAT_FUZZ_ITERATIONS=1") ;;
            --seed)
                ((i++))
                if (( i < ${#args[@]} )); then env+=("BASECHAT_FUZZ_SEED=${args[$i]}"); fi
                ;;
            --seed=*) env+=("BASECHAT_FUZZ_SEED=${arg#*=}") ;;
            --model)
                ((i++))
                if (( i < ${#args[@]} )); then env+=("MLX_TEST_MODEL=${args[$i]}"); fi
                ;;
            --model=*) env+=("MLX_TEST_MODEL=${arg#*=}") ;;
            --detector)
                ((i++))
                if (( i < ${#args[@]} )); then env+=("BASECHAT_FUZZ_DETECTOR=${args[$i]}"); fi
                ;;
            --detector=*) env+=("BASECHAT_FUZZ_DETECTOR=${arg#*=}") ;;
            --quiet) env+=("BASECHAT_FUZZ_QUIET=1") ;;
            --session-scripts) env+=("BASECHAT_FUZZ_SESSION_SCRIPTS=1") ;;
            --tools) env+=("BASECHAT_FUZZ_TOOLS=1") ;;
            --corpus-subset)
                ((i++))
                if (( i < ${#args[@]} )); then env+=("BASECHAT_FUZZ_CORPUS_SUBSET=${args[$i]}"); fi
                ;;
            --corpus-subset=*) env+=("BASECHAT_FUZZ_CORPUS_SUBSET=${arg#*=}") ;;
        esac
        ((i++))
    done
    printf '%s\n' "${env[@]}"
}

cd "$PACKAGE_DIR"

SWIFT_EXIT=0
if [[ $RUN_SWIFT -eq 1 ]]; then
    echo ""
    echo "Running: swift run --traits Fuzz,MLX,Llama,Ollama fuzz-chat ${FORWARDED_ARGS[*]+"${FORWARDED_ARGS[*]}"}"
    echo ""

    set +e
    swift run --traits Fuzz,MLX,Llama,Ollama fuzz-chat "${FORWARDED_ARGS[@]+"${FORWARDED_ARGS[@]}"}"
    SWIFT_EXIT=$?
    set -e
else
    echo ""
    echo "Skipping swift run: --backend mlx uses the Xcode-hosted MLX fuzz suite"
fi

MLX_EXIT=0
if [[ $WITH_MLX -eq 1 ]]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Running MLX XCTest fuzz suite"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # bash-3.2 compatible read loop (macOS still ships bash 3.2 by default;
    # `mapfile` is bash 4+ only).
    MLX_ENV=()
    while IFS= read -r line; do
        MLX_ENV+=("$line")
    done < <(build_mlx_env "${FORWARDED_ARGS[@]+"${FORWARDED_ARGS[@]}"}")
    set +e
    env "${MLX_ENV[@]}" xcodebuild test \
        -scheme BaseChatKit-Package \
        -only-testing BaseChatFuzzTests/MLXFuzzTests \
        -destination 'platform=macOS'
    MLX_EXIT=$?
    set -e
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  FUZZ SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $RUN_SWIFT -eq 1 ]]; then
    printf "  fuzz-chat exit:             %d\n" "$SWIFT_EXIT"
else
    printf "  fuzz-chat exit:             %s\n" "skipped (--backend mlx)"
fi
if [[ $WITH_MLX -eq 1 ]]; then
    printf "  xcodebuild MLXFuzzTests:    %d\n" "$MLX_EXIT"
fi
printf "  Findings index:             tmp/fuzz/INDEX.md\n"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

FINAL_EXIT=$SWIFT_EXIT
if [[ $RUN_SWIFT -eq 0 ]]; then
    FINAL_EXIT=$MLX_EXIT
elif [[ $WITH_MLX -eq 1 && $MLX_EXIT -ne 0 && $FINAL_EXIT -eq 0 ]]; then
    FINAL_EXIT=$MLX_EXIT
fi

if [[ $FINAL_EXIT -eq 0 ]]; then
    echo "  RESULT: OK (no crashes; review tmp/fuzz/INDEX.md for findings)"
else
    echo "  RESULT: FAILED (exit $FINAL_EXIT)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $FINAL_EXIT
