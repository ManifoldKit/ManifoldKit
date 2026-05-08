#!/usr/bin/env bash
# clean-build.sh — full .build directory wipe + resolve
#
# Use this when `swift build` fails with "XCFramework Info.plist not found" or
# other workspace-state.json desync errors. A partial cleanup (e.g. removing
# only .build/artifacts/) is insufficient: SwiftPM caches binary-target paths
# in .build/workspace-state.json and does not re-resolve stale entries without
# a full clean.
#
# Common trigger: changing the active trait set (--disable-default-traits,
# adding/removing Llama or MLX) after a prior build has cached the xcframework
# paths from the previous configuration.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "Removing .build directory…"
rm -rf "$REPO_ROOT/.build"

echo "Resolving packages…"
swift package resolve --package-path "$REPO_ROOT"

echo "Done. Run your build command now."
