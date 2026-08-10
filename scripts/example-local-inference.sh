#!/usr/bin/env bash
#
# LocalInferenceExample M2 gate (#2453) — opt-in, HUMAN-run lane.
#
# scripts/demo-apps-build.sh proves LocalInferenceExample_MLX and
# LocalInferenceExample_Llama COMPILE (no model, no download, no
# generation) and runs on every release. This script goes further: it
# drives a REAL model download and a REAL generation against each
# companion backend, then hands off to a human for the one step nothing
# here can script — confirming a reply, and an image, actually appear in
# the chat UI. It is NOT part of any CI gate; run it by hand.
#
# Requires:
#   - A real Apple Silicon Mac — not CI. MLX and llama.cpp need Metal /
#     native process lifecycle the iOS Simulator (and any Linux/x86 CI
#     runner) can't provide. See docs/HARDWARE-TOOLCHAIN.md.
#   - Network access. `run llama` downloads a ~400 MB GGUF starter model.
#     `run mlx` downloads a ~1.8 GB MLX text model and a ~13.9 GB SDXL-Turbo
#     diffusion snapshot — expect this to take a while on first run. That
#     13.9 GB is real, not a mistake: `MLXDiffusionBackend`
#     (manifold-mlx, Sources/StableDiffusion/Configuration.swift
#     `presetSDXLTurbo`) hardcodes the plain (fp32) safetensors paths —
#     `unet/diffusion_pytorch_model.safetensors` (10.3 GB) and friends —
#     and upconverts to float16 in memory at load time; it never reads the
#     repo's `*.fp16.safetensors` files on disk. An earlier version of this
#     script downloaded the whole `stabilityai/sdxl-turbo` repo with no
#     `--include` filter — three redundant representations (fp32
#     safetensors, fp16 safetensors, ONNX) plus onnx_data shards — which
#     pulled 50 GB and never actually completed the one fp32 unet file the
#     loader opens, so image generation had zero real evidence behind it.
#     See docs/PRODUCTION-READINESS.md's demo-coverage manifest,
#     `media-generation` row.
#   - The `hf` CLI on PATH for `run mlx` (MLX has no in-app downloader in
#     this example — see Example/Examples/LocalInferenceExample/README.md):
#       pip install -U "huggingface_hub[cli]"
#     or
#       brew install huggingface-cli
#
# Usage:
#   scripts/example-local-inference.sh build          # compile both targets only
#   scripts/example-local-inference.sh run llama      # download + launch the Llama app
#   scripts/example-local-inference.sh run mlx        # download + launch the MLX app
#   scripts/example-local-inference.sh run all         # both, one after another
#
# Each `run` launches the built .app and waits for it to quit (`open -W`)
# so the manual verification step happens before the script returns.
# Verify, then quit the app to let the script (and, for `run all`, the next
# target) continue.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLES_DIR="$REPO_ROOT/Example/Examples"
PROJECT="ManifoldExamples.xcodeproj"
DERIVED_DATA_PATH="$REPO_ROOT/DerivedData/LocalInferenceExampleGate"
MODELS_DIR="$HOME/Documents/Models"
MLX_TEXT_MODEL_REPO="mlx-community/Llama-3.2-3B-Instruct-4bit"
IMAGE_MODEL_REPO="stabilityai/sdxl-turbo"
IMAGE_MODEL_DIR="$MODELS_DIR/ImageModels/stabilityai-sdxl-turbo"

usage() {
    cat <<'EOF'
Usage:
  scripts/example-local-inference.sh build
  scripts/example-local-inference.sh run <llama|mlx|all>

See the header of this script for what "run" downloads, and why this is a
human-run lane rather than a CI gate.
EOF
}

require_command() {
    local cmd="$1" hint="$2"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "error: '$cmd' not found on PATH. $hint" >&2
        exit 1
    fi
}

build_scheme() {
    local scheme="$1"
    echo "=================================================================="
    echo ">> Building $scheme (macOS)"
    echo "=================================================================="
    # -skipPackagePluginValidation: LocalInferenceExample_MLX links
    # manifold-mlx's MLXMetallibPlugin build-tool plugin, which Xcode gates
    # behind an interactive "Trust & Enable" prompt on first use — headless
    # `xcodebuild` has no prompt to answer, so this is the documented CI
    # bypass for first-party, already-trusted dependencies (`xcodebuild
    # -help`). No-op for the Llama scheme, which uses no build-tool plugin.
    ( cd "$EXAMPLES_DIR" && xcodebuild \
        -project "$PROJECT" \
        -scheme "$scheme" \
        -destination "platform=macOS" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -skipPackagePluginValidation \
        build )
}

app_path() {
    local scheme="$1"
    echo "$DERIVED_DATA_PATH/Build/Products/Debug/${scheme}.app"
}

download_mlx_text_model() {
    require_command hf "Install with: pip install -U \"huggingface_hub[cli]\" (or: brew install huggingface-cli)."
    local dest="$MODELS_DIR/$MLX_TEXT_MODEL_REPO"
    if [[ -f "$dest/config.json" ]]; then
        echo "MLX text model already present at $dest — skipping download."
        return
    fi
    echo "Downloading $MLX_TEXT_MODEL_REPO to $dest (real network — several GB)…"
    mkdir -p "$dest"
    hf download "$MLX_TEXT_MODEL_REPO" --local-dir "$dest"
}

# Exactly the files `StableDiffusionConfiguration.presetSDXLTurbo` opens
# (manifold-mlx Sources/StableDiffusion/Configuration.swift) plus
# `model_index.json`, which the loader itself never reads but this app's
# own `discoverSDXLTurbo()` (LocalInferenceExampleMLXApp.swift) uses as the
# on-disk "is the snapshot present" marker. Listed as exact filenames, not
# a glob, so this can never silently widen to catch a stray large sibling
# file (e.g. the repo's onnx/fp16 duplicates) if the upstream repo layout
# changes.
readonly -a SDXL_TURBO_FILES=(
    model_index.json
    unet/config.json
    unet/diffusion_pytorch_model.safetensors
    text_encoder/config.json
    text_encoder/model.safetensors
    text_encoder_2/config.json
    text_encoder_2/model.safetensors
    vae/config.json
    vae/diffusion_pytorch_model.safetensors
    scheduler/scheduler_config.json
    tokenizer/vocab.json
    tokenizer/merges.txt
    tokenizer_2/vocab.json
    tokenizer_2/merges.txt
)

download_sdxl_turbo() {
    require_command hf "Install with: pip install -U \"huggingface_hub[cli]\" (or: brew install huggingface-cli)."
    if [[ -f "$IMAGE_MODEL_DIR/unet/diffusion_pytorch_model.safetensors" ]]; then
        echo "SDXL-Turbo already present at $IMAGE_MODEL_DIR — skipping download."
        return
    fi
    echo "Downloading $IMAGE_MODEL_REPO to $IMAGE_MODEL_DIR (real network — ~13.9 GB, the exact files the MLX diffusion loader opens)…"
    mkdir -p "$IMAGE_MODEL_DIR"
    hf download "$IMAGE_MODEL_REPO" "${SDXL_TURBO_FILES[@]}" --local-dir "$IMAGE_MODEL_DIR"
}

cmd_build() {
    build_scheme "LocalInferenceExample_Llama"
    build_scheme "LocalInferenceExample_MLX"
    echo
    echo "Both LocalInferenceExample targets compiled."
}

run_llama() {
    build_scheme "LocalInferenceExample_Llama"
    local app
    app="$(app_path "LocalInferenceExample_Llama")"
    echo "=================================================================="
    echo ">> Launching LocalInferenceExample_Llama"
    echo "   The app downloads its own GGUF starter model on first launch"
    echo "   (ManifoldKit.quickStart(seed: .recommendedSmallModel(...)),"
    echo "   ~400 MB, real network)."
    echo
    echo "   MANUAL STEP: once the composer is enabled, send one chat"
    echo "   message and confirm a reply streams back. Quit the app when done."
    echo "=================================================================="
    open -W "$app"
}

run_mlx() {
    build_scheme "LocalInferenceExample_MLX"
    download_mlx_text_model
    download_sdxl_turbo
    local app
    app="$(app_path "LocalInferenceExample_MLX")"
    echo "=================================================================="
    echo ">> Launching LocalInferenceExample_MLX"
    echo
    echo "   MANUAL STEPS:"
    echo "     1. Once the composer is enabled, send one chat message and"
    echo "        confirm a reply streams back (MLX text generation)."
    echo "     2. Ask the model to generate an image — it can call the"
    echo "        generate_image tool itself — and confirm a picture appears"
    echo "        inline in the conversation (MLX image generation)."
    echo "   Quit the app when done."
    echo "=================================================================="
    open -W "$app"
}

main() {
    local verb="${1:-}"
    case "$verb" in
        build)
            cmd_build
            ;;
        run)
            local target="${2:-}"
            case "$target" in
                llama) run_llama ;;
                mlx) run_mlx ;;
                all) run_llama; run_mlx ;;
                *)
                    usage
                    exit 1
                    ;;
            esac
            ;;
        *)
            usage
            exit 1
            ;;
    esac
}

main "$@"
