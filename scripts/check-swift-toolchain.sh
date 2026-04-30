#!/usr/bin/env bash

set -euo pipefail

tools_line=$(head -n 1 Package.swift)
tools_version=$(printf '%s\n' "$tools_line" | sed -E 's|^//[[:space:]]*swift-tools-version:[[:space:]]*([0-9]+\.[0-9]+).*|\1|')
if ! [[ "$tools_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
  echo "Could not parse swift-tools-version from first line of Package.swift: $tools_line"
  exit 1
fi

swift_version_full=$(swift -version | head -n 1)
if command -v xcrun >/dev/null 2>&1; then
  xcrun_swift_version=$(xcrun swift -version 2>/dev/null | head -n 1 || true)
  if [[ -n "$xcrun_swift_version" ]]; then
    swift_version_full="$xcrun_swift_version"
  fi
fi

swift_version=$(printf '%s\n' "$swift_version_full" | sed -E 's|.*Swift version ([0-9]+\.[0-9]+).*|\1|')
if ! [[ "$swift_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
  echo "Could not parse Swift major.minor from: $swift_version_full"
  exit 1
fi

tools_major=${tools_version%.*}; tools_minor=${tools_version#*.}
swift_major=${swift_version%.*}; swift_minor=${swift_version#*.}
if (( tools_major > swift_major )) || { (( tools_major == swift_major )) && (( tools_minor > swift_minor )); }; then
  echo "::error::Package.swift requires swift-tools-version $tools_version but runner has Swift $swift_version. Lower swift-tools-version or upgrade the pinned toolchain."
  exit 1
fi

echo "swift-tools-version=$tools_version OK against runner Swift $swift_version"
