#!/usr/bin/env bash
# scripts/fuzz.sh — Run the ManifoldFuzz harness with a friendly preflight.
#
# Default behaviour (no args): runs `swift run fuzz-chat --minutes 5` against
# Ollama. Discovers which backends are usable and prints a one-line summary
# before kicking off the harness.
#
# v0.48 (PR C2, #1749): the MLX and llama.cpp fuzz factories moved to the
# manifold-mlx / manifold-llama companion packages with the backends — run
# `--backend mlx` / `--backend llama` campaigns from those repos. The
# `--with-mlx` xcodebuild path and the Fuzz/MLX/Llama trait flags are gone;
# fuzz-chat compiles unconditionally now.
#
# Local extensions:
#   --workers N   Forwarded to fuzz-chat for process-level parallel workers.

set -euo pipefail

PACKAGE_DIR="$(cd "$(dirname "$0")/.." && pwd)"

FORWARDED_ARGS=()
for arg in "$@"; do
    case "$arg" in
        --with-mlx)
            echo "scripts/fuzz.sh: --with-mlx was removed in v0.48 — the MLX fuzz factory lives in the manifold-mlx companion package (#1749). Run the MLX campaign from that repo." >&2
            exit 2
            ;;
        -h|--help)
            cd "$PACKAGE_DIR"
            echo "scripts/fuzz.sh — wrapper around \`swift run fuzz-chat\` (default backend: ollama)"
            echo ""
            echo "Local flags:"
            echo "  --workers N  Run N process-level fuzz-chat workers"
            echo "  -h, --help   Show this help and forward to fuzz-chat -h"
            echo ""
            echo "MLX / llama.cpp campaigns moved to the companion packages (v0.48, #1749):"
            echo "  https://github.com/ManifoldKit/manifold-mlx"
            echo "  https://github.com/ManifoldKit/manifold-llama"
            echo ""
            echo "Cloud (OpenAI-compatible, e.g. OpenRouter):"
            echo "  export OPENROUTER_API_KEY=sk-or-...   # preferred; or OPENAI_API_KEY"
            echo "  scripts/fuzz.sh --backend openai --base-url https://openrouter.ai/api \\"
            echo "                  --model deepseek/deepseek-r1:free --minutes 5"
            echo "  Caveats: replay/shrink unavailable"
            echo "  (non-deterministic); free models are rate-limited (429) and ':free' slugs may"
            echo "  404 on data-policy gating; --base-url must omit /v1 (backend appends it)."
            echo "  --request-timeout N   per-request HTTP idle timeout in seconds (default 90)."
            echo "                        Slow/free models otherwise hang the 300s session default"
            echo "                        per request; detectors flag >60s, so 90s loses no signal"
            echo "                        while protecting throughput. openai path only."
            echo ""
            echo "Forwarding to: swift run fuzz-chat -h"
            echo "─────────────────────────────────────────────────────────────"
            swift run fuzz-chat -h || true
            exit 0
            ;;
        *) FORWARDED_ARGS+=("$arg") ;;
    esac
done

REQUESTED_BACKEND=""
REQUESTED_WORKERS=1
for ((i = 0; i < ${#FORWARDED_ARGS[@]}; i++)); do
    arg="${FORWARDED_ARGS[$i]}"
    case "$arg" in
        --backend)
            if (( i + 1 < ${#FORWARDED_ARGS[@]} )); then
                REQUESTED_BACKEND="${FORWARDED_ARGS[$((i + 1))]}"
                # `i=$((i+1))` not `((i++))`: post-increment returns the old
                # value, so when i=0 the `((i++))` exit status is 1 and `set -e`
                # would abort the script (bites `--backend` as the first arg).
                i=$((i + 1))
            fi
            ;;
        --backend=*) REQUESTED_BACKEND="${arg#*=}" ;;
        --workers)
            if (( i + 1 < ${#FORWARDED_ARGS[@]} )); then
                REQUESTED_WORKERS="${FORWARDED_ARGS[$((i + 1))]}"
                i=$((i + 1))
            fi
            ;;
        --workers=*) REQUESTED_WORKERS="${arg#*=}" ;;
    esac
done

if ! [[ "$REQUESTED_WORKERS" =~ ^[0-9]+$ ]] || (( REQUESTED_WORKERS < 1 )); then
    echo "scripts/fuzz.sh: --workers requires a positive integer" >&2
    exit 2
fi

if [[ "$REQUESTED_BACKEND" == "mlx" || "$REQUESTED_BACKEND" == "llama" ]]; then
    echo "scripts/fuzz.sh: --backend $REQUESTED_BACKEND moved to the companion packages in v0.48 (#1749):" >&2
    echo "  mlx   → https://github.com/ManifoldKit/manifold-mlx" >&2
    echo "  llama → https://github.com/ManifoldKit/manifold-llama" >&2
    echo "Run the campaign from that repo, or use --backend ollama|openai|foundation|mock|chaos here." >&2
    exit 2
fi

CLOUD_BACKEND=0
if [[ "$REQUESTED_BACKEND" == "openai" ]]; then
    CLOUD_BACKEND=1
fi

if [[ $CLOUD_BACKEND -eq 1 ]]; then
    # Cloud (OpenAI-compatible) backend: no local model discovery. Require an
    # API key in the environment (keys on argv leak into ps/shell history) and
    # surface the free-tier caveats up front.
    CLOUD_KEY="${OPENROUTER_API_KEY:-${OPENAI_API_KEY:-}}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ManifoldFuzz preflight (cloud / OpenAI-compatible)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ -z "$CLOUD_KEY" ]]; then
        echo "scripts/fuzz.sh: --backend openai needs an API key in the environment." >&2
        echo "  export OPENROUTER_API_KEY=sk-or-...   (preferred; or OPENAI_API_KEY)" >&2
        echo "  Do NOT pass keys on the command line — they leak into ps/shell history." >&2
        exit 2
    fi
    echo "  API key: present (env)"
    echo "  Caveats:"
    echo "    • Replay/shrink are unavailable — cloud generation is non-deterministic."
    echo "    • Free OpenRouter models are rate-limited (HTTP 429) and ':free' slugs"
    echo "      can 404 on data-policy gating. Transient HTTP errors are recorded as"
    echo "      failed runs, NOT fuzz findings, so a throttled campaign stays honest."
    echo "    • --base-url must omit the /v1 suffix (OpenRouter base = https://openrouter.ai/api)."
    echo "    • Per-request idle timeout defaults to 90s (--request-timeout N to override)."
    echo "      Slow/free models otherwise hang the full 300s session default per request;"
    echo "      detectors already flag >60s, so 90s captures the slow-but-real cases without"
    echo "      destroying throughput."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
else
    OLLAMA_HIT="miss"
    FOUNDATION_HIT="miss"

    if curl -s -m 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
        OLLAMA_HIT="hit"
    fi

    PRODUCT_VERSION="$(sw_vers -productVersion 2>/dev/null || echo 0)"
    PRODUCT_MAJOR="${PRODUCT_VERSION%%.*}"
    if [[ "$PRODUCT_MAJOR" =~ ^[0-9]+$ ]] && (( PRODUCT_MAJOR >= 26 )); then
        FOUNDATION_HIT="hit"
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ManifoldFuzz preflight"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  Discovered: Ollama=%s, Foundation=%s\n" \
        "$OLLAMA_HIT" "$FOUNDATION_HIT"
    echo "  (MLX / llama.cpp fuzzing moved to manifold-mlx / manifold-llama — #1749)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ "$OLLAMA_HIT" == "miss" && "$FOUNDATION_HIT" == "miss" && "$REQUESTED_BACKEND" != "mock" && "$REQUESTED_BACKEND" != "chaos" ]]; then
        echo "No usable backends detected. Install hints:" >&2
        echo "  Ollama:     brew install ollama && ollama serve   (then: ollama pull qwen3.5:4b)" >&2
        echo "  Foundation: requires macOS 26+" >&2
        echo "  OpenAI:     --backend openai --base-url https://openrouter.ai/api --model <slug>" >&2
        echo "              (set OPENROUTER_API_KEY; no local model needed)" >&2
        echo "  MLX/Llama:  fuzz from the manifold-mlx / manifold-llama companion repos (#1749)" >&2
        exit 2
    fi
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

# Cloud path: make the per-request idle bound explicit in the echoed command so
# the throughput protection is visible. fuzz-chat already defaults to 90s; we
# only inject when the caller didn't pass --request-timeout so an explicit value
# always wins. Slow/free OpenRouter models otherwise hang the 300s session
# default per request, and the detectors already flag anything over 60s.
if [[ $CLOUD_BACKEND -eq 1 ]]; then
    HAS_REQUEST_TIMEOUT=0
    for arg in "${FORWARDED_ARGS[@]+"${FORWARDED_ARGS[@]}"}"; do
        case "$arg" in
            --request-timeout|--request-timeout=*) HAS_REQUEST_TIMEOUT=1 ;;
        esac
    done
    if [[ $HAS_REQUEST_TIMEOUT -eq 0 ]]; then
        FORWARDED_ARGS=("--request-timeout" "90" "${FORWARDED_ARGS[@]+"${FORWARDED_ARGS[@]}"}")
    fi
fi

cd "$PACKAGE_DIR"

echo ""
echo "Running: swift run fuzz-chat ${FORWARDED_ARGS[*]+"${FORWARDED_ARGS[*]}"}"
echo ""

set +e
swift run fuzz-chat "${FORWARDED_ARGS[@]+"${FORWARDED_ARGS[@]}"}"
SWIFT_EXIT=$?
set -e

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  FUZZ SUMMARY"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "  fuzz-chat exit:             %d\n" "$SWIFT_EXIT"
printf "  Findings index:             tmp/fuzz/INDEX.md\n"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

if [[ $SWIFT_EXIT -eq 0 ]]; then
    echo "  RESULT: OK (no crashes; review tmp/fuzz/INDEX.md for findings)"
else
    echo "  RESULT: FAILED (exit $SWIFT_EXIT)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

exit $SWIFT_EXIT
