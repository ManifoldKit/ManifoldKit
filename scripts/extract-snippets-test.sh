#!/usr/bin/env bash
# extract-snippets-test.sh — Compile every kept Swift snippet from README.md
# and docs/QUICKSTART.md against the current ManifoldKit package.
#
# Companion to scripts/extract-snippets.sh. The extract script writes one
# .swift per kept snippet into a working directory; this script scaffolds a
# throwaway SwiftPM consumer per snippet, drops the snippet in, and runs
# `swift build`. Failures print the source location (file:line) the snippet
# was lifted from so the docs author can fix the original block.
#
# Why one package per snippet:
#   - Snippets are independent SwiftUI apps (Hello World variants have `@main`
#     on `App` types) and cannot coexist in one executable target.
#   - Per-snippet isolation also lets the next snippet still build when an
#     earlier one fails, so the report is complete instead of stopping at
#     the first error.
#
# Each per-snippet package:
#   - tools-version 6.2 (matches cold-start-conformance.sh)
#   - platforms macOS .v15 (ManifoldKit's floor)
#   - depends on the local ManifoldKit checkout via .package(name: ..., path: ...)
#   - links the ManifoldKit umbrella product (covers ManifoldUI / Inference re-exports)
#   - built with --disable-default-traits so MLX/Llama XCFrameworks are not
#     compiled (they require hardware and slow each build by ~3 min). Snippets
#     that import ManifoldBackends still compile — the umbrella is trait-safe.
#
# Exit codes:
#   0 — every snippet compiled.
#   1 — at least one snippet failed; full per-snippet log dumped at the end.
#   2 — extract step reported zero snippets (propagated from extract-snippets.sh).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$(mktemp -d -t manifoldkit-snippet-build.XXXXXX)"
SNIPPETS_DIR="$WORK/snippets"
mkdir -p "$SNIPPETS_DIR"

# Keep work dir for inspection on CI failure if SNIPPET_KEEP_WORK=1 is set.
if [[ "${SNIPPET_KEEP_WORK:-0}" != "1" ]]; then
    trap 'rm -rf "$WORK"' EXIT
else
    echo "SNIPPET_KEEP_WORK=1: work dir preserved at $WORK"
fi

echo "==> README/QUICKSTART snippet compile gate"
echo "    ManifoldKit: $REPO_ROOT"
echo "    work:        $WORK"

# 1. Extract.
bash "$SCRIPT_DIR/extract-snippets.sh" --out "$SNIPPETS_DIR"

# 2. Build each.
shopt -s nullglob
snippets=("$SNIPPETS_DIR"/*.swift)
shopt -u nullglob

if [[ ${#snippets[@]} -eq 0 ]]; then
    echo "::error::extract-snippets.sh wrote zero .swift files (only .skip)." >&2
    exit 2
fi

passed=0
failed=0
fail_reports=()

for snippet in "${snippets[@]}"; do
    base="$(basename "$snippet" .swift)"
    # Read source-location header for failure reports.
    src_header=$(head -n 1 "$snippet")
    src_location="${src_header#// Source: }"

    pkg_dir="$WORK/$base"
    mkdir -p "$pkg_dir/Sources/SnippetApp"

    # SwiftPM derives package identity from the last path component of
    # .package(path:); explicit name: keeps this worktree-portable.
    cat > "$pkg_dir/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Snippet_${base//-/_}",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .executable(name: "SnippetApp", targets: ["SnippetApp"]),
    ],
    dependencies: [
        .package(name: "ManifoldKit", path: "$REPO_ROOT"),
    ],
    targets: [
        .executableTarget(
            name: "SnippetApp",
            dependencies: [
                .product(name: "ManifoldKit", package: "ManifoldKit"),
                // ManifoldUI is re-exported by the umbrella, but the README
                // Hello World imports it explicitly. Link it as a direct
                // product too so the import resolves under both umbrella
                // and direct-import patterns.
                .product(name: "ManifoldUI", package: "ManifoldKit"),
            ],
            path: "Sources/SnippetApp"
        ),
    ]
)
EOF

    # Drop the snippet in. If it lacks `import Foundation` but uses Foundation
    # types, the build will catch it — we deliberately do NOT inject imports
    # because the test is "does the published snippet compile as-published?".
    cp "$snippet" "$pkg_dir/Sources/SnippetApp/Snippet.swift"

    echo
    echo "── ${base}  (from ${src_location})"

    log="$pkg_dir/build.log"
    if (cd "$pkg_dir" && swift build --disable-default-traits) > "$log" 2>&1; then
        echo "   PASS"
        passed=$((passed + 1))
    else
        echo "   FAIL — log:"
        sed -n '1,80p' "$log" | sed 's/^/     /'
        echo "   (full log: $log)"
        failed=$((failed + 1))
        fail_reports+=("$base  from  $src_location")
    fi
done

echo
echo "==================================================================="
echo "Snippet compile summary: ${passed} passed, ${failed} failed."
echo "==================================================================="

if [[ $failed -gt 0 ]]; then
    echo
    echo "Failing snippets:"
    for report in "${fail_reports[@]}"; do
        echo "  - $report"
    done
    echo
    echo "To investigate: rerun with SNIPPET_KEEP_WORK=1 to preserve $WORK."
    exit 1
fi

exit 0
