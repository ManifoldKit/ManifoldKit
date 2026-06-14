#!/usr/bin/env bash
# extract-snippets-test.sh — Compile every kept Swift snippet from README.md
# and docs/QUICKSTART.md against the current ManifoldKit package.
#
# Companion to scripts/extract-snippets.sh. The extract script writes one
# .swift per kept snippet into a working directory; this script scaffolds a
# SINGLE SwiftPM consumer package with one executable target per snippet,
# drops each snippet into its own target, and runs `swift build` ONCE.
# Failures print the source location (file:line) the snippet was lifted from
# so the docs author can fix the original block.
#
# One package, one executable target per snippet:
#   - The whole package builds with a SINGLE `swift build`. SwiftPM compiles
#     the ManifoldKit umbrella (the long pole) ONCE and links it into every
#     target, parallelizing the cheap per-snippet target compiles. This
#     replaces the previous package-per-snippet loop that re-linked the heavy
#     umbrella N times serially and cost ~17 min in CI.
#   - Separate executable TARGETS (not one shared target) are still required:
#     snippets are independent SwiftUI apps — Hello World variants carry
#     `@main` on `App` types, and two snippets can declare the same type
#     names. Each target is its own module, so `@main` and type-name
#     collisions are impossible across snippets.
#   - The aggregate `swift build` also *links* each executable, and snippets
#     that are valid top-level/library code but carry no `@main` entry point
#     fail at link ("Undefined symbols … _main") despite compiling cleanly.
#     A non-zero aggregate exit is also triggered by transient parallel-build
#     module-ordering errors (e.g. `error: no such module 'ManifoldInference'`
#     when a snippet target compiles before that re-exported module is emitted);
#     pass 2's serial per-target build resolves these too. This gate validates
#     COMPILATION, not linking, so a non-zero aggregate exit is not trusted as
#     a snippet failure. Instead we re-build each target
#     compile-only (`swift build --target <name>` stops at emit-module, no
#     link step) to attribute PASS/FAIL per snippet. Already-compiled modules
#     are cache hits; a module that FAILED in the aggregate pass has no cached
#     object and is genuinely recompiled here — that recompile is the
#     authoritative per-snippet signal, so never shortcut pass-2 by trusting
#     the aggregate exit code. The report also stays complete (one PASS/FAIL
#     line per snippet) instead of stopping at the first error.
#
# The shared package:
#   - tools-version 6.2 (matches cold-start-conformance.sh)
#   - platforms macOS .v15 / iOS .v18 (ManifoldKit's floor)
#   - depends on the local ManifoldKit checkout via .package(name: ..., path: ...)
#   - each target links the ManifoldKit umbrella product (covers ManifoldUI /
#     Inference re-exports)
#   - no traits: parameter — since v0.48 PR C2 the core package has no
#     default traits and the MLX/Llama families live in companion packages,
#     so a bare dependency is already the lean full-core build.
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

# Scaffold ONE package with one executable target per snippet. Each target
# gets a sanitized, collision-proof name; we keep three index-parallel arrays
# (target name / snippet base / source location) so the report can map a
# target back to its origin. Index-parallel arrays — NOT `declare -A` — because
# the macOS CI runners ship Bash 3.2, which has no associative arrays.
target_names=()
target_bases=()
target_srcs=()
target_decls=""

mkdir -p "$WORK/Sources"

for snippet in "${snippets[@]}"; do
    base="$(basename "$snippet" .swift)"
    # Read source-location header for failure reports.
    src_header=$(head -n 1 "$snippet")
    src_location="${src_header#// Source: }"

    # Sanitize the snippet base into a valid Swift target identifier: any char
    # outside [A-Za-z0-9_] becomes `_`. The `Snippet_` prefix guarantees the
    # identifier never starts with a digit. Separate targets = separate
    # modules, so `@main` / type-name collisions across snippets are impossible.
    sanitized="${base//[^A-Za-z0-9_]/_}"
    target="Snippet_${sanitized}"

    # Two distinct snippet bases can sanitize to the same identifier (e.g.
    # `hello-world` and `hello.world`). Without this guard the second would
    # silently overwrite the first's source dir and drop it from the gate with
    # no error. The target's source dir is the collision artifact, so its prior
    # existence is the cleanest Bash-3.2-safe detector.
    target_dir="$WORK/Sources/$target"
    if [[ -d "$target_dir" ]]; then
        echo "::error::snippet target-name collision: '$target' (sanitized from '$base') already exists." >&2
        exit 1
    fi

    target_names+=("$target")
    target_bases+=("$base")
    target_srcs+=("$src_location")

    mkdir -p "$target_dir"
    # Copy the snippet verbatim (including its `// Source:` header). We
    # deliberately do NOT inject imports — the test is "does the published
    # snippet compile as-published?".
    cp "$snippet" "$target_dir/Snippet.swift"

    target_decls+="        .executableTarget(
            name: \"$target\",
            dependencies: [
                .product(name: \"ManifoldKit\", package: \"ManifoldKit\"),
                // ManifoldUI is re-exported by the umbrella, but the README
                // Hello World imports it explicitly. Link it as a direct
                // product too so the import resolves under both umbrella
                // and direct-import patterns.
                .product(name: \"ManifoldUI\", package: \"ManifoldKit\"),
                // ManifoldUIModelManagement is NOT re-exported by the umbrella
                // (it stays an explicit import — see CLAUDE.md). Link it as a
                // third direct product so doc snippets for the public
                // \`ModelPicker\` sample view (and other model-management UI)
                // compile in the snippet gate. (Decision 6 / Correction G.)
                .product(name: \"ManifoldUIModelManagement\", package: \"ManifoldKit\"),
            ],
            path: \"Sources/$target\"
        ),
"
done

# Write the single shared manifest. `products:` is omitted — `swift build`
# builds all targets in the root package regardless. SwiftPM derives package
# identity from the last path component of .package(path:); explicit name:
# keeps this worktree-portable.
cat > "$WORK/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ManifoldKitSnippets",
    platforms: [.macOS(.v15), .iOS(.v18)],
    dependencies: [
        .package(name: "ManifoldKit", path: "$REPO_ROOT"),
    ],
    targets: [
$target_decls    ]
)
EOF

echo
echo "── Building ${#target_names[@]} snippet target(s) in one package (single umbrella compile)…"

# Pass 1: one aggregate `swift build`. SwiftPM compiles the ManifoldKit
# umbrella (the long pole) ONCE and the per-snippet target compiles run in
# parallel against it. We do NOT trust a non-zero exit here as a snippet
# failure: `swift build` also *links* each executable target, and a doc
# snippet that is valid library/top-level code but has no `@main` entry point
# will fail at link ("Undefined symbols … _main") even though it compiled
# cleanly. Compilation — not linking — is what this gate validates, so the
# aggregate run exists to warm the umbrella + emit every snippet module; pass 2
# reads off the authoritative per-snippet result.
if (cd "$WORK" && swift build) > "$WORK/build.log" 2>&1; then
    # Linked cleanly too → every snippet compiled; nothing more to check.
    echo "   PASS — all ${#target_names[@]} snippet(s) compiled."
    passed=${#target_names[@]}
    failed=0
else
    # Pass 2: attribute PASS/FAIL per snippet with a compile-only per-target
    # build (`swift build --target` stops at emit-module — no link step, so
    # no-`@main` snippets are not penalized). Modules that already compiled in
    # pass 1 are cache hits; a module that FAILED in the aggregate has no
    # cached object and is genuinely recompiled here — that recompile is the
    # authoritative per-snippet signal. Never shortcut this pass by trusting
    # the aggregate exit code.
    echo "   linking the aggregate build did not complete — verifying each snippet compiles…"
    for i in "${!target_names[@]}"; do
        target="${target_names[$i]}"
        base="${target_bases[$i]}"
        src_location="${target_srcs[$i]}"
        echo
        echo "── ${base}  (from ${src_location})"

        log="$WORK/$target.build.log"
        if (cd "$WORK" && swift build --target "$target") > "$log" 2>&1; then
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
fi

# 3. Validate Package.swift manifest fragments.
#
# extract-snippets.sh writes package-manifest fragments (anything starting
# `.package(`/`.target(`/`import PackageDescription`) to `.skip` files because
# they cannot compile as executable sources. But "can't compile" is not "can't
# rot": a fragment can still name a product that no longer exists or declare a
# swift-tools-version too old for the platform it targets — exactly the two
# defects the v0.50.0 DX walkthrough hit in docs/QUICKSTART-CLI.md (a retired
# `ManifoldBackends` product + `swift-tools-version: 6.1` with `.macOS(.v26)`).
# Both are pure-text checks, so validate them here instead of skipping blind.
echo
echo "==> Package.swift fragment validation"

# Authoritative product list (what a consumer may name in .product(name:)).
valid_products=$(grep -oE '\.(library|executable)\(name: "[^"]+"' "$REPO_ROOT/Package.swift" \
    | sed -E 's/.*name: "([^"]+)".*/\1/' | LC_ALL=C sort -u)

# version_lt A B → exit 0 if major.minor A < B.
version_lt() {
    local a_major="${1%%.*}" a_minor="${1#*.}"
    local b_major="${2%%.*}" b_minor="${2#*.}"
    [[ "$a_major" -lt "$b_major" ]] && return 0
    [[ "$a_major" -eq "$b_major" && "$a_minor" -lt "$b_minor" ]] && return 0
    return 1
}

shopt -s nullglob
fragments=("$SNIPPETS_DIR"/*.skip)
shopt -u nullglob

frag_checked=0
for frag in "${fragments[@]}"; do
    body=$(sed '1,/^---$/d' "$frag")
    # Validate any fragment that names a ManifoldKit product or declares a
    # tools-version — covers both the `.package`/`.target` auto-skips AND
    # `swift,no-build`-tagged manifests (e.g. the companion-package CLI
    # examples), which carry the same product/tools-version rot risk.
    printf '%s\n' "$body" \
        | grep -qE '\.product\(name: "[^"]+", package: "ManifoldKit"\)|swift-tools-version' \
        || continue
    src_location=$(sed -n 's/^# Source: //p' "$frag" | head -n 1)
    frag_checked=$((frag_checked + 1))

    # 3a. Every .product(name: "X", package: "ManifoldKit") must be a real product.
    while IFS= read -r prod; do
        [[ -z "$prod" ]] && continue
        if ! printf '%s\n' "$valid_products" | grep -qxF "$prod"; then
            echo "   FAIL — ${src_location}: references product \"$prod\" which is not vended by Package.swift."
            failed=$((failed + 1))
            fail_reports+=("manifest product \"$prod\"  from  $src_location")
        fi
    done < <(printf '%s\n' "$body" \
        | grep -oE '\.product\(name: "[^"]+", package: "ManifoldKit"\)' \
        | sed -E 's/.*name: "([^"]+)".*/\1/')

    # 3b. .macOS(.v26)/.iOS(.v26) require swift-tools-version >= 6.2.
    if printf '%s\n' "$body" | grep -qE '\.(macOS|iOS)\(\.v26\)'; then
        tools_ver=$(printf '%s\n' "$body" \
            | grep -oE 'swift-tools-version:?[[:space:]]*[0-9]+\.[0-9]+' \
            | grep -oE '[0-9]+\.[0-9]+' | head -n 1)
        if [[ -n "$tools_ver" ]] && version_lt "$tools_ver" "6.2"; then
            echo "   FAIL — ${src_location}: swift-tools-version $tools_ver but uses .v26 (needs >= 6.2)."
            failed=$((failed + 1))
            fail_reports+=("manifest tools-version $tools_ver with .v26  from  $src_location")
        fi
    fi
done
echo "   Validated ${frag_checked} manifest fragment(s) against Package.swift products + platform/tools-version."

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
