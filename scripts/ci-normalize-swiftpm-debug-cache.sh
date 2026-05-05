#!/usr/bin/env bash
# Normalize restored SwiftPM debug-cache mtimes after actions/cache extraction.
# GitHub checkout gives source files fresh mtimes; cached .o/.swiftmodule files
# can look older than identical sources and force a full rebuild. This script is
# intentionally limited to SwiftPM debug outputs and only runs on exact cache hits.

set -euo pipefail

BUILD_DIR="${1:-.build/debug}"

if [[ ! -d "$BUILD_DIR" ]]; then
    echo "SwiftPM debug cache directory not found: $BUILD_DIR"
    exit 0
fi

# Keep the list focused on files SwiftPM/Swift's incremental build consults or
# emits for debug builds. Do not touch source checkouts or repositories.
count=$(find "$BUILD_DIR" -type f \( \
    -name '*.o' -o \
    -name '*.swiftmodule' -o \
    -name '*.swiftdoc' -o \
    -name '*.swiftsourceinfo' -o \
    -name '*.swiftinterface' -o \
    -name '*.swiftdeps' -o \
    -name '*.swiftdeps~' -o \
    -name '*.abi.json' -o \
    -name '*.d' -o \
    -name '*.buildrecord' \
\) -print | wc -l | tr -d ' ')

if [[ "$count" == "0" ]]; then
    echo "No SwiftPM debug-cache outputs needed mtime normalization."
    exit 0
fi

find "$BUILD_DIR" -type f \( \
    -name '*.o' -o \
    -name '*.swiftmodule' -o \
    -name '*.swiftdoc' -o \
    -name '*.swiftsourceinfo' -o \
    -name '*.swiftinterface' -o \
    -name '*.swiftdeps' -o \
    -name '*.swiftdeps~' -o \
    -name '*.abi.json' -o \
    -name '*.d' -o \
    -name '*.buildrecord' \
\) -print0 | xargs -0 touch -c

echo "Normalized mtimes for $count SwiftPM debug-cache output files under $BUILD_DIR."
