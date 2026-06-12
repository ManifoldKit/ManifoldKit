#!/usr/bin/env bash
# clean-build.sh — full .build directory wipe + resolve
#
# Use this when `swift build` fails with "XCFramework Info.plist not found" or
# other workspace-state.json desync errors. A partial cleanup (e.g. removing
# only .build/artifacts/) is insufficient: SwiftPM caches binary-target paths
# in .build/workspace-state.json and does not re-resolve stale entries without
# a full clean.
#
# Common trigger: changing the active trait set (e.g. toggling Server/Macros)
# or a binary-target dependency after a prior build has cached artifact paths
# from the previous configuration. (Pre-v0.48-C2 the usual culprit was the
# llama.cpp xcframework; that dependency now lives in the manifold-llama
# companion package, but the desync mode is generic to workspace-state.json.)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "Removing .build directory…"
rm -rf "$REPO_ROOT/.build"

echo "Resolving packages…"
swift package resolve --package-path "$REPO_ROOT"

echo "Done. Run your build command now."
