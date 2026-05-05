#!/usr/bin/env bash
# scripts/test-mlx-integration.sh — Run BaseChatMLXIntegrationTests with the
# discovery env vars properly forwarded to the xctest runner.
#
# Why this exists
# ---------------
# `BaseChatMLXIntegrationTests` requires real MLX model files on disk (Apple
# Silicon + Metal + a HuggingFace-style snapshot dir with config.json,
# tokenizer.json, and *.safetensors weights). The discovery helper
# `HardwareRequirements.findMLXModelDirectory()` is opt-out — it returns nil
# unless `BASECHAT_DISCOVER_LOCAL_MODELS=1` (or `MLX_TEST_MODEL=<name>`) is
# set in the test runner's environment. Without it, every test silently
# `XCTSkip`s and the suite reports green with zero real-model coverage.
#
# `xcodebuild test ...` does NOT propagate shell env vars to the spawned
# xctest runner. Neither `export VAR=1; xcodebuild ...` nor the
# `TEST_RUNNER_*` prefix convention reaches the test process for a SwiftPM
# auto-generated scheme. The only working path is:
#
#   1. `xcodebuild build-for-testing` to produce the test bundle and an
#      `.xctestrun` plist.
#   2. PlistBuddy-edit the `.xctestrun` to add `EnvironmentVariables` to the
#      `BaseChatMLXIntegrationTests` target's dict.
#   3. `xcodebuild test-without-building -xctestrun <patched>` to execute
#      with the injected env.
#
# This script automates that. See #986.
#
# Usage
# -----
#   scripts/test-mlx-integration.sh                # discover any valid MLX dir
#   scripts/test-mlx-integration.sh <name>         # prefer dir whose name contains <name>
#   scripts/test-mlx-integration.sh <name> --rebuild  # force rebuild
#
# Models are searched in $HOME/Documents/Models/ (and one nested level) per
# `HardwareRequirements.modelSearchDirectories()`. A dir is valid if it has:
#   - config.json with non-empty model_type
#   - tokenizer.json or tokenizer.model
#   - at least one .safetensors weights file

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

MODEL_HINT="${1:-}"
REBUILD=0
for arg in "$@"; do
    [[ "$arg" == "--rebuild" ]] && REBUILD=1
done

DERIVED="$REPO_ROOT/.build/mlx-integration-test-derived"

if [[ "$REBUILD" -eq 1 || ! -d "$DERIVED" ]]; then
    echo "==> Building test bundle (xcodebuild build-for-testing)…"
    rm -rf "$DERIVED"
    xcodebuild build-for-testing \
        -scheme BaseChatKit-Package \
        -only-testing BaseChatMLXIntegrationTests \
        -destination 'platform=macOS' \
        -derivedDataPath "$DERIVED" \
        -quiet
fi

RUNFILE=$(find "$DERIVED" -name "*.xctestrun" 2>/dev/null | head -1)
if [[ -z "$RUNFILE" ]]; then
    echo "ERROR: No .xctestrun found under $DERIVED — try --rebuild" >&2
    exit 1
fi

# Find the BaseChatMLXIntegrationTests target index in the TestTargets array.
TARGET_INDEX=""
TOTAL=$(/usr/libexec/PlistBuddy -c "Print :TestConfigurations:0:TestTargets" "$RUNFILE" 2>/dev/null | grep -c "BlueprintName")
for ((i = 0; i < TOTAL; i++)); do
    name=$(/usr/libexec/PlistBuddy -c "Print :TestConfigurations:0:TestTargets:$i:BlueprintName" "$RUNFILE" 2>/dev/null || true)
    if [[ "$name" == "BaseChatMLXIntegrationTests" ]]; then
        TARGET_INDEX=$i
        break
    fi
done

if [[ -z "$TARGET_INDEX" ]]; then
    echo "ERROR: BaseChatMLXIntegrationTests target not found in $RUNFILE" >&2
    exit 1
fi

# Inject env vars. Use Set (which works whether the key existed before or was
# added by a prior run of this script).
ENV_PATH=":TestConfigurations:0:TestTargets:$TARGET_INDEX:EnvironmentVariables"
/usr/libexec/PlistBuddy -c "Add $ENV_PATH:BASECHAT_DISCOVER_LOCAL_MODELS string 1" "$RUNFILE" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set $ENV_PATH:BASECHAT_DISCOVER_LOCAL_MODELS 1" "$RUNFILE"

if [[ -n "$MODEL_HINT" ]]; then
    /usr/libexec/PlistBuddy -c "Add $ENV_PATH:MLX_TEST_MODEL string $MODEL_HINT" "$RUNFILE" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set $ENV_PATH:MLX_TEST_MODEL $MODEL_HINT" "$RUNFILE"
    echo "==> Selecting MLX model whose name contains: $MODEL_HINT"
else
    echo "==> Discovering MLX models from \$HOME/Documents/Models/ (first valid wins)"
fi

# Optional VLM-only selector for tests that need a vision model in addition to
# (or instead of) the text-only MLX_TEST_MODEL fixture. Forwarded only when set
# in the calling shell so default runs stay green without a downloaded VLM.
if [[ -n "${MLX_VLM_TEST_MODEL:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add $ENV_PATH:MLX_VLM_TEST_MODEL string $MLX_VLM_TEST_MODEL" "$RUNFILE" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set $ENV_PATH:MLX_VLM_TEST_MODEL $MLX_VLM_TEST_MODEL" "$RUNFILE"
    echo "==> Forwarding MLX_VLM_TEST_MODEL=$MLX_VLM_TEST_MODEL to the VLM gate experiment"
fi

echo "==> Running tests (xcodebuild test-without-building)…"
xcodebuild test-without-building \
    -xctestrun "$RUNFILE" \
    -only-testing BaseChatMLXIntegrationTests \
    -destination 'platform=macOS'
