#!/usr/bin/env bash
# Verifies that a FoundationOnly build of BaseChatKit produces an App
# Store-lean BaseChatBackends artifact:
#
#   1. Symbol audit — `nm -gU` on `BaseChatBackends/*.o` asserts zero MLX
#      framework or llama.cpp C-API symbols leaked into the compiled
#      objects. Stub `MLXBackends` / `LlamaBackends` enum entries are
#      tolerated because they are no-op registrar namespaces (the bodies
#      compile out under `#if MLX` / `#if Llama`).
#   2. Bundle-size cap — `BaseChatBackends.build` ≤ 5 MB.
#
# Together these two checks are the load-bearing guarantee for App Store
# submitters: regardless of what SwiftPM resolves into `.build/checkouts`
# during package resolution, what the linker actually pulls into your IPA
# is bounded by what the compiled BaseChatBackends objects reference.
# `.build/checkouts` size is NOT what consumers ship; the linker drops
# unreferenced packages entirely.
#
# Why no dep-graph (`.build/checkouts`) assertion? SwiftPM's `traits`
# system gates which targets compile and which library-products a target
# depends on, but it does NOT gate dependency *resolution*. Once a
# `.package(url:)` is declared in Package.swift, SwiftPM fetches it into
# `.build/checkouts` regardless of the active trait set. The symbol audit
# below is what proves no MLX/Llama bytes reach the final binary.
#
# Used by `.github/workflows/ci.yml::foundation-only-build` and runnable
# locally to mirror the CI gate. See docs/AppStoreSubmission.md for the
# bundle-size rationale.
set -euo pipefail

cd "$(dirname "$0")/.."

# 5 MB ceiling for the BaseChatBackends per-target build directory. Bump
# only with documented justification — the FoundationOnly trait exists
# precisely to keep this lean.
BUDGET_KB=5120

echo "==> swift build --traits FoundationOnly"
swift build --traits FoundationOnly

BACKENDS_BUILD_DIR=".build/debug/BaseChatBackends.build"
if [[ ! -d "$BACKENDS_BUILD_DIR" ]]; then
    echo "::error::Expected $BACKENDS_BUILD_DIR after FoundationOnly build but it is missing."
    exit 1
fi

echo "==> Symbol audit: nm -gU on BaseChatBackends/*.o"
SYMBOL_COUNT=$(find "$BACKENDS_BUILD_DIR" -name '*.o' -exec nm -gU {} + 2>/dev/null \
    | grep -ciE 'MLXLLM|MLXLMCommon|LlamaSwift|llama_(?:backend|model|context|tokenize|decode|sample)' \
    || true)
if [[ "$SYMBOL_COUNT" -ne 0 ]]; then
    echo "::error::FoundationOnly build leaked $SYMBOL_COUNT MLX/Llama framework symbols into BaseChatBackends. The trait should compile those backends out via #if MLX / #if Llama."
    find "$BACKENDS_BUILD_DIR" -name '*.o' -exec nm -gU {} + 2>/dev/null \
        | grep -iE 'MLXLLM|MLXLMCommon|LlamaSwift|llama_(?:backend|model|context|tokenize|decode|sample)' \
        | head -20
    exit 1
fi
echo "    OK — zero MLX/Llama framework symbols leaked."

echo "==> Bundle size: BaseChatBackends.build directory"
SIZE_KB=$(du -sk "$BACKENDS_BUILD_DIR" | awk '{print $1}')
echo "    BaseChatBackends.build = ${SIZE_KB} KB (budget: ${BUDGET_KB} KB)"
if [[ "$SIZE_KB" -gt "$BUDGET_KB" ]]; then
    echo "::error::FoundationOnly BaseChatBackends.build size ${SIZE_KB} KB exceeds budget ${BUDGET_KB} KB."
    exit 1
fi

echo "==> FoundationOnly bundle audit passed."
