#!/usr/bin/env bash
# Cold-start conformance — tier 4: human path (README from line 1).
#
# Tier 1 (`cold-start-conformance.sh`), tier 2 (`cold-start-tier2-bootstrap.sh`),
# and tier 3 (`cold-start-tier3-chatview.sh`) all scaffold known-good consumers
# from hand-written code. They prove the *machine* path: a SwiftPM consumer can
# link ManifoldKit and call the public surface in shapes the maintainers
# control.
#
# Tier 4 follows the *human* path. It treats README.md as the documented
# onboarding contract and asks: would a person reading the README from line 1
# reach a working chat? Concretely:
#
#   1. The FIRST `##` heading under the H1 title must be `## Hello World`
#      (case-insensitive, tolerant of "Hello, World" / "Hello world"). If a
#      future PR slides Hello World below Features / Install / Architecture,
#      this gate fails immediately with a message naming what took its place.
#   2. The first fenced ```swift block following that heading must compile
#      against the current ManifoldKit on this branch, scaffolded into a fresh
#      SwiftPM consumer in a tmpdir. If the README's canonical snippet drifts
#      from the public API (deleted symbol, renamed type, missing import) the
#      gate fails.
#
# We deliberately stop at `swift build`. The canonical Hello World uses `@main
# struct MyChatApp: App` — actually running it on a macOS runner would either
# hang waiting for the SwiftUI runloop or produce no useful signal. The "it
# compiles end-to-end" bar is what catches the breakages this gate exists to
# catch (deleted public symbols, missing `@_exported`s in the umbrella, broken
# import shapes) and stays under ~30s.
#
# Companion W-D-C1 gate (`scripts/check-readme-snippets.sh` / parallel worker)
# compiles ALL Swift snippets across README + docs. C2 (this script) is
# narrower and stricter: it asserts the SPECIFIC structural constraint that
# the canonical Hello World leads the README and works.
#
# Portability: macOS BSD `awk` / `sed` / `grep` only; no `grep -P`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=_lib/consumer-scaffold.sh
source "${REPO_ROOT}/scripts/_lib/consumer-scaffold.sh"
README="${REPO_ROOT}/README.md"

if [[ ! -f "${README}" ]]; then
    echo "::error::README.md not found at ${README}"
    exit 1
fi

echo "==> Cold-start conformance (tier 4 — human path)"
echo "    ManifoldKit: ${REPO_ROOT}"
echo "    README:      ${README}"

# ── Check 1: Hello World must be the FIRST H2 ─────────────────────────────────
#
# Skip the H1 title (`# ManifoldKit`) and the intro prose under it. The first
# line beginning with exactly `## ` is the first H2. We capture both the line
# number and the heading text so the failure message can name what's there.

first_h2_line=""
first_h2_text=""
while IFS= read -r entry; do
    first_h2_line="${entry%%:*}"
    first_h2_text="${entry#*:}"
    break
done < <(grep -nE '^## ' "${README}" || true)

if [[ -z "${first_h2_line}" ]]; then
    echo "::error file=README.md::No \`## \` (H2) heading found in README.md."
    exit 1
fi

# Match `Hello World`, `Hello, World`, `Hello world`, any case. The check-readme.sh
# strict-mode regex is our reference for tolerated variants.
if ! printf '%s\n' "${first_h2_text}" | grep -qiE '^## hello[, ]+world[[:space:]]*$'; then
    echo "::error file=README.md,line=${first_h2_line}::First H2 must be \`## Hello World\` — found \`${first_h2_text}\` at line ${first_h2_line}."
    echo "    The DX overhaul requires Hello World to lead the README so a reader's"
    echo "    first interaction with ManifoldKit is a runnable snippet, not a feature"
    echo "    table or install matrix. Move the Hello World section back to the top."
    exit 1
fi

echo "✓ First H2 is Hello World (line ${first_h2_line})."

# ── Check 2: extract the first ```swift block under Hello World ───────────────
#
# Strategy: read from the Hello World heading line forward. The first line that
# is exactly ```swift opens the block; the next line that is exactly ``` closes
# it. Everything between is the snippet. We allow up to ~30 lines of prose
# between the heading and the opening fence (the current README has one or two
# paragraphs of intro), but we warn if the gap is large because that suggests
# the snippet is no longer the immediate companion to the heading.

snippet_file="$(mktemp -t manifoldkit-hello-snippet.XXXXXX)"
WORK=""
cleanup() { [[ -n "${WORK}" ]] && rm -rf "${WORK}"; rm -f "${snippet_file}"; }
trap cleanup EXIT

# Find the next H2 line number AFTER the Hello World H2 — the swift block
# must live in the Hello World section, not in a sibling section further down
# the README (Install / Architecture etc. also contain ```swift blocks).
next_h2_line=""
while IFS= read -r entry; do
    ln="${entry%%:*}"
    if [[ "${ln}" -gt "${first_h2_line}" ]]; then
        next_h2_line="${ln}"
        break
    fi
done < <(grep -nE '^## ' "${README}" || true)

# Find the first ```swift fence strictly inside the Hello World section.
fence_at=""
while IFS= read -r entry; do
    ln="${entry%%:*}"
    if [[ "${ln}" -le "${first_h2_line}" ]]; then continue; fi
    if [[ -n "${next_h2_line}" && "${ln}" -ge "${next_h2_line}" ]]; then break; fi
    fence_at="${ln}"
    break
done < <(grep -nE '^```swift[[:space:]]*$' "${README}" || true)

# Extract block between fence_at+1 and the next ``` line.
if [[ -n "${fence_at}" ]]; then
    awk -v start="${fence_at}" '
        NR <= start { next }
        $0 ~ /^```[[:space:]]*$/ { exit }
        { print }
    ' "${README}" > "${snippet_file}"
fi

if [[ ! -s "${snippet_file}" ]]; then
    echo "::error file=README.md,line=${first_h2_line}::No \`\`\`swift fenced code block found after \`## Hello World\` heading."
    echo "    Hello World is the contract for a reader's first runnable example."
    echo "    The section must include a swift block that compiles standalone."
    exit 1
fi

if [[ -n "${fence_at}" ]]; then
    gap=$((fence_at - first_h2_line))
    echo "✓ Found \`\`\`swift block at line ${fence_at} (gap from heading: ${gap} lines)."
    if [[ ${gap} -gt 30 ]]; then
        echo "::warning file=README.md,line=${fence_at}::Hello World snippet sits ${gap} lines below its heading. Consider moving it closer so the snippet is the immediate companion to the heading."
    fi
fi

snippet_lines=$(wc -l < "${snippet_file}" | tr -d '[:space:]')
echo "    Snippet captured: ${snippet_lines} lines."

# ── Check 3: build the snippet in a fresh SwiftPM consumer ────────────────────
#
# We pin tools-version 6.2 and macOS .v15 (ManifoldKit's n-1 floor) to match
# tiers 1-3. Name the package by absolute path so worktree directory names
# don't break `.product(... package: "ManifoldKit")` resolution
# (see `feedback_swiftpm_local_consumer_name` in CLAUDE.md).
#
# The Hello World snippet uses `@main struct ...: App`. SwiftPM allows `@main`
# in either library or executable targets; we use a library target to dodge
# the synthetic main collision a SwiftUI App entry has with the
# executableTarget's implicit `_main`. iOS-only or platform-specific SwiftUI
# constructs still compile on macOS as long as `import SwiftUI` is available.

WORK="$(mktemp -d -t manifoldkit-cold-start-human.XXXXXX)"

echo "==> Scaffolding consumer at ${WORK}"

cat > "${WORK}/Package.swift" <<EOF
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ColdStartHumanConsumer",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HelloWorldApp", targets: ["HelloWorldApp"]),
    ],
    dependencies: [
        // Pin name explicitly so worktree directory names do not change the
        // dependency identity seen by .product(package:). The Hello World
        // snippet imports the umbrella module ManifoldKit + ManifoldUI; both
        // come from ManifoldKit's product list.
        .package(name: "ManifoldKit", path: "${REPO_ROOT}"),
    ],
    targets: [
        // Library target (not executable): the snippet supplies its own
        // @main App entry point. An executableTarget would conflict with
        // SwiftPM's synthetic _main symbol on macOS.
        .target(
            name: "HelloWorldApp",
            dependencies: [
                .product(name: "ManifoldKit", package: "ManifoldKit"),
                .product(name: "ManifoldUI", package: "ManifoldKit"),
            ],
            path: "Sources/HelloWorldApp"
        ),
    ]
)
EOF

mkdir -p "${WORK}/Sources/HelloWorldApp"
cp "${snippet_file}" "${WORK}/Sources/HelloWorldApp/HelloWorld.swift"

# Optional persistent build cache. When MANIFOLDKIT_COLD_START_BUILD_CACHE_DIR is
# set we redirect SwiftPM's build path to that directory so a CI cache step can
# warm-restore it across runs. The tmpdir-based consumer's *Package.swift* and
# the snippet itself live in ${WORK} and are recreated each run, but the
# resolved dep checkouts + compiled object files keyed under .build/arm64-apple-
# macosx survive the next invocation. We accept that SwiftPM path-fingerprints
# make the consumer-target object cache invalid (snippet path changes each run
# under mktemp), but the dependency graph's checkouts still warm-restore — see
# PR body for the measurement of where the win lands. (Pre-v0.48-C2 the big
# win was the llama.cpp xcframework artifact; that dependency now lives in the
# manifold-llama companion package.)
#
# The build itself (bare-repository git env override + tail-60 of the captured
# output) is shared with tiers 1-3 / the specialised-module gates via
# cs_swift_build (scripts/_lib/consumer-scaffold.sh) — this used to be its own
# copy of the same ~15 lines with a Bash-3.2 empty-array footgun
# (`${arr[@]+"${arr[@]}"}`) that the shared helper's `if [[ "${1:-}" ==
# --build-path ]]` branch sidesteps entirely.
echo "==> swift build (Hello World snippet from README)"
if [[ -n "${MANIFOLDKIT_COLD_START_BUILD_CACHE_DIR:-}" ]]; then
    mkdir -p "${MANIFOLDKIT_COLD_START_BUILD_CACHE_DIR}"
    echo "    Using persistent build cache: ${MANIFOLDKIT_COLD_START_BUILD_CACHE_DIR}"
    build_ok=1
    cs_swift_build "${WORK}" --build-path "${MANIFOLDKIT_COLD_START_BUILD_CACHE_DIR}" || build_ok=0
else
    build_ok=1
    cs_swift_build "${WORK}" || build_ok=0
fi

if [[ "${build_ok}" -ne 1 ]]; then
    echo "::error file=README.md,line=${first_h2_line}::The Hello World snippet does not compile against the current ManifoldKit public API."
    echo "    Either the snippet drifted (e.g. deleted symbol, renamed type) or"
    echo "    a public symbol it relies on was removed without updating the README."
    echo "    See the build output above for the exact compile error."
    exit 1
fi

# Sanity: confirm SwiftPM actually built the target's object file.
# Empty/skipped builds can exit 0 if no sources matched. Search the configured
# build root: either the in-${WORK} default or the persistent cache dir.
BUILD_SEARCH_ROOT="${WORK}/.build"
if [[ -n "${MANIFOLDKIT_COLD_START_BUILD_CACHE_DIR:-}" ]]; then
    BUILD_SEARCH_ROOT="${MANIFOLDKIT_COLD_START_BUILD_CACHE_DIR}"
fi
if ! find "${BUILD_SEARCH_ROOT}" -name 'HelloWorld.swift.o' -print -quit 2>/dev/null | grep -q .; then
    echo "::error::swift build exited 0 but did not produce HelloWorld.swift.o — check target wiring."
    exit 1
fi

echo "==> Cold-start conformance (tier 4 — human path): OK"
