#!/usr/bin/env bash
# check-readme.sh — Lint the README's API references against the current package.
#
# This is the load-bearing tripwire for initiative I8 (Docs from source). The
# goal is that future PRs cannot reintroduce stale snippets without flipping
# this check red.
#
# Two checks today:
#
#   1. Every `from: "X.Y.Z"` install pin in README.md must match the current
#      release recorded in version.txt. Stale pins point readers at versions
#      that may no longer exist.
#   2. README must not reference deleted public API names. The current
#      blacklist:
#        - `loadModel(from:contextSize:)`     (replaced by `loadModel(from:plan:)`)
#        - `vm.send(_:)` / `viewModel.send(_:)` (replaced by `sendMessage(_:)`)
#        (`import ManifoldKit` was forbidden pre-0.19; the umbrella now exists.)
#
# Why not full Swift snippet typecheck:
#   The README's Package.swift fragments and `.target(dependencies:)` snippets
#   are not standalone Swift programs. A full `swift -typecheck` pass against
#   the package would need a synthetic per-snippet harness with imports,
#   surrounding types, and trait gating. That work belongs to a follow-up
#   if README drift continues to slip past lint. For now this catches the
#   high-frequency mistakes (version pin, deleted method names) that I8 was
#   chartered to prevent.
#
# Exit 0 on success, non-zero on any check failure.
#
# ── Strict mode (opt-in) ──────────────────────────────────────────────────
#
# Set `MANIFOLDKIT_README_STRICT=1` to additionally enforce the README
# structure anchors below. These checks are gated because they describe a
# README layout that is being introduced by a later DX-overhaul worker
# (W-C-B1a); flipping them on before the new README ships would fail `main`.
# The follow-up worker that lands the README rewrite will export the var in
# the relevant CI job. Until then, this lane is opt-in only.
#
# Strict-mode checks:
#   3. README contains a `## Hello World` heading (case-insensitive, also
#      tolerates `## Hello, World` / `## Hello world`) within the first 250
#      lines — guards against the quickstart sliding below Architecture.
#   4. README contains a `## Feature Matrix` heading (case-insensitive)
#      anywhere, AND within 20 lines of that heading links to
#      `docs/FeatureMatrix.md` so the section actually routes readers to
#      the rendered matrix instead of stubbing it inline.
#
# Usage:
#   bash scripts/check-readme.sh                          # default (loose) — baseline checks only
#   MANIFOLDKIT_README_STRICT=1 bash scripts/check-readme.sh   # also enforce structure anchors
#
# ── Snippet pre-flight (always on, cheap) ─────────────────────────────────
#
# In addition to the API-name lint above, we sanity-check that README.md
# still contains at least one ```swift fenced block. A future PR that
# accidentally strips the Hello World (e.g. a bad merge resolution) would
# satisfy every other check; this is the cheapest possible tripwire for
# "the canonical snippet vanished". The full compile gate lives in the
# `.github/workflows/readme-snippets.yml` workflow and invokes
# `scripts/extract-snippets-test.sh`.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
README_PATH="${REPO_ROOT}/README.md"
VERSION_PATH="${REPO_ROOT}/version.txt"

if [[ ! -f "${README_PATH}" ]]; then
    echo "::error::README.md not found at ${README_PATH}"
    exit 1
fi

if [[ ! -f "${VERSION_PATH}" ]]; then
    echo "::error::version.txt not found at ${VERSION_PATH}"
    exit 1
fi

CURRENT_VERSION="$(tr -d '[:space:]' < "${VERSION_PATH}")"
if [[ -z "${CURRENT_VERSION}" ]]; then
    echo "::error::version.txt is empty"
    exit 1
fi

echo "Current package version: ${CURRENT_VERSION}"

failures=0

# ── Check 1: install-pin freshness ────────────────────────────────────────
#
# Every core `ManifoldKit.git` `from: "X.Y.Z"` pin in the scanned consumer-facing
# docs must reference the current release in version.txt. Companion package pins
# (`manifold-llama.git` / `manifold-mlx.git`) are ignored — they track those
# packages' own versions.
#
# We do NOT match `exact: "..."`, `branch: "..."`, or `revision: "..."` —
# those are intentional pins for specific scenarios. Historical migration docs
# (docs/MIGRATION-*.md, docs/plans/**) are intentionally excluded.
echo
echo "── Check: core ManifoldKit install pins match version.txt ───────────"

# Same file set as Check 6 (marker presence) plus SECURITY / APP-EVAL / DocC.
pin_scan_files=("${README_PATH}")
for f in \
    "${REPO_ROOT}"/docs/QUICKSTART*.md \
    "${REPO_ROOT}/docs/SWIFTUI-MULTI-SESSION.md" \
    "${REPO_ROOT}/docs/APP-EVAL.md" \
    "${REPO_ROOT}/SECURITY.md" \
    "${REPO_ROOT}/Sources/ManifoldMCP/ManifoldMCP.docc/Articles/MCPGettingStarted.md"
do
    [[ -f "$f" ]] && pin_scan_files+=("$f")
done

bad_pins=0
for f in "${pin_scan_files[@]}"; do
    rel="${f#"${REPO_ROOT}/"}"
    # Shape-agnostic: same-line url+from, or ManifoldKit.git url followed within
    # 4 lines by a from: pin. Companion urls are ignored.
    while IFS= read -r hit; do
        [[ -z "$hit" ]] && continue
        line_no="${hit%%:*}"
        pinned_version="${hit#*:}"
        if [[ "${pinned_version}" != "${CURRENT_VERSION}" ]]; then
            echo "::error file=${rel},line=${line_no}::Core \`ManifoldKit.git\` install pin \`from: \"${pinned_version}\"\` does not match version.txt (${CURRENT_VERSION})."
            bad_pins=$((bad_pins + 1))
        fi
    done < <(awk '
        function isCoreUrl(s) { return (s ~ /ManifoldKit\.git/) }
        function isCompanionUrl(s) { return (s ~ /manifold-(llama|mlx)\.git/) }
        # BSD awk (macOS) has no match(..., array) — extract via RSTART/RLENGTH.
        function extractFrom(s,   t) {
            if (match(s, /from:[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"/)) {
                t = substr(s, RSTART, RLENGTH)
                sub(/from:[[:space:]]*"/, "", t)
                sub(/"/, "", t)
                return t
            }
            return ""
        }
        {
            if (isCompanionUrl($0)) { waiting = 0; next }
            if (isCoreUrl($0)) {
                v = extractFrom($0)
                if (v != "") { print FNR ":" v; waiting = 0; next }
                waiting = 1; window = 4; next
            }
            if (waiting) {
                v = extractFrom($0)
                if (v != "") { print FNR ":" v; waiting = 0; next }
                if ($0 ~ /\.package\(/ || isCompanionUrl($0)) { waiting = 0; next }
                window--; if (window <= 0) waiting = 0
            }
        }
    ' "$f")
done

if [[ ${bad_pins} -gt 0 ]]; then
    failures=$((failures + 1))
    echo "Found ${bad_pins} stale core install pin(s). Bump them to ${CURRENT_VERSION}."
else
    echo "✓ All core \`ManifoldKit.git\` \`from:\` install pins match version.txt (${CURRENT_VERSION})."
fi

# ── Check 2: deleted API references ───────────────────────────────────────
#
# README must not reference public API that no longer exists. The blacklist
# below is keyed on the exact textual shape the deleted name took in past
# READMEs — keep entries narrow so we don't false-positive on prose.
echo
echo "── Check: README does not reference deleted public API ──────────────"

declare -a forbidden=(
    'loadModel(from:contextSize:)|deleted in 0.18; use \`loadModel(from:plan:)\` taking a \`ModelLoadPlan\`'
)

# Looking up `vm.send(` is too noisy because `vm.send` could legitimately
# appear in prose like "vm.sendMessage". Match the exact two-arg call shape
# that was the deleted method, anchored by parens that do NOT start with
# "Message".
declare -a method_renames=(
    '\bvm\.send\(|use \`vm.sendMessage(_:)\` (the old \`vm.send\` was removed)'
    '\bviewModel\.send\(|use \`viewModel.sendMessage(_:)\`'
    '\bChatViewModel\.send\(|use \`ChatViewModel.sendMessage(_:)\`'
)

bad_apis=0

for entry in "${forbidden[@]}"; do
    pattern="${entry%%|*}"
    reason="${entry#*|}"
    # -F makes the pattern fixed-string for the literal API names; -E for
    # regex. Use -F if the pattern doesn't contain regex meta. The first two
    # entries are simple literals.
    if grep -nF -- "${pattern}" "${README_PATH}" > /tmp/check-readme-hits 2>/dev/null && [[ -s /tmp/check-readme-hits ]]; then
        while IFS= read -r hit; do
            line_no="${hit%%:*}"
            echo "::error file=README.md,line=${line_no}::References deleted API \`${pattern}\` — ${reason}."
            bad_apis=$((bad_apis + 1))
        done < /tmp/check-readme-hits
    fi
done

for entry in "${method_renames[@]}"; do
    pattern="${entry%%|*}"
    reason="${entry#*|}"
    if grep -nE -- "${pattern}" "${README_PATH}" > /tmp/check-readme-hits 2>/dev/null && [[ -s /tmp/check-readme-hits ]]; then
        while IFS= read -r hit; do
            line_no="${hit%%:*}"
            echo "::error file=README.md,line=${line_no}::References deleted API matching \`${pattern}\` — ${reason}."
            bad_apis=$((bad_apis + 1))
        done < /tmp/check-readme-hits
    fi
done

rm -f /tmp/check-readme-hits

if [[ ${bad_apis} -gt 0 ]]; then
    failures=$((failures + 1))
    echo "Found ${bad_apis} reference(s) to deleted public API."
else
    echo "✓ README contains no references to known-deleted public API."
fi

# ── Check 3: README contains at least one Swift snippet ──────────────────
#
# Cheap structural tripwire — the full compile gate runs in CI via
# scripts/extract-snippets-test.sh. We just need to fail loudly if the
# Hello World fence ever disappears.
echo
echo "── Check: README contains at least one \`\`\`swift block ──────────────"

# Match opening fence ```swift (case-insensitive), tolerate trailing tags.
if grep -niE '^```swift([,[:space:]]|$)' "${README_PATH}" > /dev/null 2>&1; then
    echo "✓ README has at least one Swift fenced block."
else
    echo "::error file=README.md::No \`\`\`swift fenced block found. The Hello World snippet must remain in README.md."
    failures=$((failures + 1))
fi

# ── Check 4: no-build under copy-paste-contract headings ─────────────────
#
# `swift,no-build` fenced blocks are skipped by the snippet compile gate
# (see scripts/extract-snippets.sh:174-180). That's appropriate for
# genuinely partial illustrations (a method signature, a fragment that
# references an undefined identifier), but it has been over-applied to
# copy-paste hello-world snippets — the very snippets readers paste into
# their own projects. A no-build-tagged copy-paste target can drift
# indefinitely without CI noticing.
#
# This check fails when a `swift,no-build` (or any `swift*no-build*`)
# fenced block appears under a heading whose text matches one of the
# "contract" patterns below. These headings advertise "the next code block
# is copy-pasteable" — they MUST be compilable or moved.
#
# See scripts/dx-walkthrough/runs/2026-05-23_v0.33.0/01-chat-cli/ROOT_CAUSES.md
# for the root-cause analysis that motivated this lint.
echo
echo "── Check: no-build blocks under copy-paste-contract headings ────────"

# Case-insensitive heading patterns. Each entry is a POSIX ERE that matches
# the trimmed heading text (no leading `#`). Keep this list narrow — it
# describes "contracts" the docs make with readers ("here is a thing to
# paste").
contract_heading_patterns=(
    'quick ?start'
    'getting started'
    'hello world'
    'hello[, ] world'
    'bring your own'
    'cli'
    'headless'
    'terminal'
)

# Build a single OR-joined pattern for grep.
joined_pattern=""
for p in "${contract_heading_patterns[@]}"; do
    if [[ -z "${joined_pattern}" ]]; then
        joined_pattern="${p}"
    else
        joined_pattern="${joined_pattern}|${p}"
    fi
done

bad_no_build=0

# Walk README.md and docs/QUICKSTART.md. For each file, track the current
# heading (any `#`-prefixed line). When we encounter a ```swift fence
# carrying `no-build`, compare the current heading against the contract
# patterns and emit an error if it matches.
check_no_build_in() {
    local file_rel="$1"
    local file_abs="${REPO_ROOT}/${file_rel}"
    if [[ ! -f "${file_abs}" ]]; then
        echo "::warning::${file_rel} not found, skipping no-build heading check."
        return 0
    fi

    local current_heading=""
    local current_heading_line=0
    local line_no=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))
        # Match Markdown ATX headings (# .. ######). Strip leading # and spaces.
        if [[ "$line" =~ ^#{1,6}[[:space:]]+(.+)$ ]]; then
            current_heading="${BASH_REMATCH[1]}"
            current_heading_line=$line_no
            continue
        fi
        # Match opening fences like ```swift,no-build or ```swift no-build ...
        # We're conservative: require the line to start with ```swift and
        # contain the literal token "no-build" somewhere on the same line.
        if [[ "$line" =~ ^\`\`\`[Ss]wift ]] && [[ "$line" == *no-build* ]]; then
            # Check if current heading matches a contract pattern (case-insensitive).
            if [[ -n "$current_heading" ]]; then
                heading_lc=$(printf '%s' "$current_heading" | tr '[:upper:]' '[:lower:]')
                if printf '%s' "$heading_lc" | grep -qE "${joined_pattern}"; then
                    echo "::error file=${file_rel},line=${line_no}::\`swift,no-build\` block under heading \"${current_heading}\" (line ${current_heading_line}). no-build is for partial illustrations; this section promises copy-pasteable code. Either make the snippet compilable or move it out of this section."
                    bad_no_build=$((bad_no_build + 1))
                fi
            fi
        fi
    done < "${file_abs}"
}

check_no_build_in "README.md"
check_no_build_in "docs/QUICKSTART.md"
check_no_build_in "docs/QUICKSTART-CLI.md"

# DocC catalogs (added 2026-05-23, see A2-F8): DocC articles are documentation
# and are subject to the same copy-paste-contract lint. Many articles use
# headings like "## Quick Start" / "## Getting Started" that promise readers
# a runnable snippet immediately below — a `swift,no-build` fence under one
# of those headings hides drift indefinitely.
while IFS= read -r docc_rel; do
    [[ -n "$docc_rel" ]] && check_no_build_in "$docc_rel"
done < <(cd "$REPO_ROOT" && find Sources -type f -name '*.md' -path '*/*.docc/*' 2>/dev/null | LC_ALL=C sort)

if [[ ${bad_no_build} -gt 0 ]]; then
    failures=$((failures + 1))
    echo "Found ${bad_no_build} \`no-build\` block(s) under copy-paste-contract heading(s)."
else
    echo "✓ No \`no-build\` blocks under copy-paste-contract headings."
fi

# ── Check 5: README Swift floor agrees with Package.swift ─────────────────
#
# README's "Requirements" section restates the Swift tools-version that
# consumers must use. There is no test that those agree with the actual
# `// swift-tools-version:` line in Package.swift, so the two drift
# (PR #1392 fixed a 6.1 vs `.macOS(.v26)` mismatch). This check extracts
# both values and fails if the README's stated floor is lower than what
# Package.swift declares.
#
# The check is intentionally lenient on README phrasing: it grabs the first
# "Swift X.Y" mention inside the Requirements/Installation section (the
# first 15 lines after the matching heading) and compares it to the
# Package.swift tools-version. A README that legitimately advertises a
# higher floor than Package.swift's tools-version (e.g. because consumers
# need 6.2 for `.macOS(.v26)` even though MK itself ships with 6.1) is
# still considered consistent.
echo
echo "── Check: README Swift floor agrees with Package.swift ──────────────"

PACKAGE_PATH="${REPO_ROOT}/Package.swift"
if [[ ! -f "${PACKAGE_PATH}" ]]; then
    echo "::error::Package.swift not found at ${PACKAGE_PATH}"
    failures=$((failures + 1))
else
    pkg_tools_version=$(grep -m1 -E '^//[[:space:]]*swift-tools-version:' "${PACKAGE_PATH}" \
        | sed -nE 's@^//[[:space:]]*swift-tools-version:[[:space:]]*([0-9]+\.[0-9]+).*@\1@p')
    if [[ -z "${pkg_tools_version}" ]]; then
        echo "::error::Could not extract \`// swift-tools-version:\` from Package.swift"
        failures=$((failures + 1))
    else
        # Locate the Requirements heading line. Prefer Requirements; fall back to
        # Installation/Install. `set -e` + pipefail makes empty grep pipelines
        # exit nonzero, so each lookup is wrapped in `|| true`.
        req_line_no=$(grep -niE '^##[[:space:]]+requirements[[:space:]]*$' "${README_PATH}" | head -n 1 | cut -d: -f1 || true)
        if [[ -z "${req_line_no}" ]]; then
            req_line_no=$(grep -niE '^##[[:space:]]+(installation|install)[[:space:]]*$' "${README_PATH}" | head -n 1 | cut -d: -f1 || true)
        fi
        if [[ -z "${req_line_no}" ]]; then
            echo "::warning::README has no \`## Requirements\` / \`## Install\` heading; skipping Swift floor agreement check."
        else
            window_end=$((req_line_no + 15))
            # Grab the first "Swift X.Y" mention in the window (case-insensitive,
            # tolerates trailing `+`). Strips bullet/markup noise via sed.
            readme_swift=$(sed -n "${req_line_no},${window_end}p" "${README_PATH}" \
                | grep -iE 'swift[[:space:]]+[0-9]+\.[0-9]+' \
                | head -n 1 \
                | sed -nE 's/.*[Ss]wift[[:space:]]+([0-9]+\.[0-9]+).*/\1/p' || true)
            if [[ -z "${readme_swift}" ]]; then
                echo "::warning::README \`## Requirements\` section has no \`Swift X.Y\` mention; skipping Swift floor agreement check."
            else
                # Compare as floats via awk for portability (no bc dependency).
                cmp=$(awk -v a="${readme_swift}" -v b="${pkg_tools_version}" 'BEGIN { if (a+0 < b+0) print "lt"; else print "ge" }')
                if [[ "${cmp}" == "lt" ]]; then
                    echo "::error file=README.md,line=${req_line_no}::README \`Requirements\` states Swift ${readme_swift} but Package.swift declares swift-tools-version ${pkg_tools_version}. README's stated floor must be >= Package.swift's tools-version."
                    failures=$((failures + 1))
                else
                    echo "✓ README Swift floor (${readme_swift}) >= Package.swift tools-version (${pkg_tools_version})."
                fi
            fi
        fi
    fi
fi

# ── Check 6: ManifoldKit install pins carry the release-please marker ─────
#
# Root cause of the 0.48-vs-0.61 drift (the pin this check was added for):
# release-please's `generic` updater (configured via `extra-files` in
# release-please-config.json) only rewrites a version on a line annotated
# with `x-release-please-version` (Swift: `// x-release-please-version`;
# Markdown: `<!-- x-release-please-version -->`). A `from: "X.Y.Z"` core pin
# WITHOUT that marker is never bumped, so it silently rots while the marked
# pins move forward each release.
#
# Check 1 above only matched `from:` at line-start (the multi-line `.package`
# form), so a SINGLE-LINE `.package(url: "…ManifoldKit.git", from: "X.Y.Z")`
# pin slipped past it entirely. This check is shape-agnostic: it locates
# every core `ManifoldKit.git` pin (single- or multi-line) and fails if the
# version-bearing line lacks the marker.
#
# Scope is deliberately narrow — the user-facing install docs listed in
# release-please-config.json's `extra-files` (README + docs/QUICKSTART* +
# docs/SWIFTUI-MULTI-SESSION.md). It does NOT scan docs/MIGRATION-*.md or
# docs/plans/**: those pin historical versions (e.g. 0.47.0/0.48.0 to
# document THAT migration) on purpose and must never be auto-bumped.
# Companion pins (`manifold-llama.git` / `manifold-mlx.git`) are ignored —
# they track the companions' own versions, not core's.
echo
echo "── Check: ManifoldKit install pins carry x-release-please-version ────"

# Build the file list: README + every existing docs/QUICKSTART*.md + the
# multi-session guide + APP-EVAL + SECURITY + MCP getting-started DocC.
# A glob that matches nothing expands to itself, so we test -f before scanning.
marker_scan_files=("${README_PATH}")
for f in \
    "${REPO_ROOT}"/docs/QUICKSTART*.md \
    "${REPO_ROOT}/docs/SWIFTUI-MULTI-SESSION.md" \
    "${REPO_ROOT}/docs/APP-EVAL.md" \
    "${REPO_ROOT}/SECURITY.md" \
    "${REPO_ROOT}/Sources/ManifoldMCP/ManifoldMCP.docc/Articles/MCPGettingStarted.md"
do
    [[ -f "$f" ]] && marker_scan_files+=("$f")
done

bad_markers=0
for f in "${marker_scan_files[@]}"; do
    # awk emits "relpath:lineno" for each core pin whose version line lacks the
    # marker. Shape-agnostic: same-line `from:`/`.exact(`/`.upToNextMinor(`,
    # or a `ManifoldKit.git` url line followed (within 4 lines) by the version.
    while IFS= read -r hit; do
        [[ -z "$hit" ]] && continue
        rel="${hit%%:*}"
        ln="${hit#*:}"
        echo "::error file=${rel},line=${ln}::Core \`ManifoldKit.git\` install pin lacks an \`x-release-please-version\` marker — release-please will never bump it (this is the 0.48→0.61 drift). Add \`// x-release-please-version\` (Swift fence) or \`<!-- x-release-please-version -->\` (Markdown) to the version-bearing line, and set it to the current release."
        bad_markers=$((bad_markers + 1))
    done < <(awk -v root="${REPO_ROOT}/" '
        function isCoreUrl(s) { return (s ~ /ManifoldKit\.git/) }
        function hasVersion(s) {
            return (s ~ /(from:|upToNextMinor\(from:|\.exact\()[[:space:]]*"[0-9]+\.[0-9]+\.[0-9]+"/)
        }
        function hasMarker(s) { return (s ~ /x-release-please-version/) }
        function relname(p) { sub("^" root, "", p); return p }
        {
            if (isCoreUrl($0)) {
                if (hasVersion($0)) {
                    if (!hasMarker($0)) print relname(FILENAME) ":" FNR
                    waiting = 0
                } else {
                    waiting = 1; window = 4
                }
                next
            }
            if (waiting) {
                if (hasVersion($0)) {
                    if (!hasMarker($0)) print relname(FILENAME) ":" FNR
                    waiting = 0; next
                }
                # A new package block or a companion url means the core block
                # closed without a version pin — stop looking.
                if ($0 ~ /\.package\(/ || $0 ~ /manifold-(llama|mlx)\.git/) { waiting = 0; next }
                window--; if (window <= 0) waiting = 0
            }
        }
    ' "$f")
done

if [[ ${bad_markers} -gt 0 ]]; then
    failures=$((failures + 1))
    echo "Found ${bad_markers} core install pin(s) missing the x-release-please-version marker."
else
    echo "✓ All core \`ManifoldKit.git\` install pins carry the x-release-please-version marker."
fi

# ── Strict-mode checks (opt-in) ────────────────────────────────────────────
#
# These checks describe the post-restructure README layout. They are gated
# behind MANIFOLDKIT_README_STRICT=1 so the baseline lane stays green on the
# pre-restructure README. The W-C-B1a worker (or its CI follow-up W-D-C1)
# will flip the env var on in the relevant workflow once the new sections
# exist. See top-of-file comment for the strict-mode contract.
if [[ "${MANIFOLDKIT_README_STRICT:-0}" == "1" ]]; then
    echo
    echo "── Strict: README structure anchors (MANIFOLDKIT_README_STRICT=1) ───"

    # Check 3: `## Hello World` heading within first 250 lines.
    # Case-insensitive; tolerate "Hello, World" / "Hello world" variants.
    hello_line=$(head -n 250 "${README_PATH}" | grep -niE '^## hello[, ]+world\s*$' | head -n 1 || true)
    if [[ -z "${hello_line}" ]]; then
        echo "::error file=README.md::Strict mode: missing \`## Hello World\` heading in first 250 lines (tolerant of \`## Hello, World\` / case)."
        failures=$((failures + 1))
    else
        echo "✓ Found Hello World anchor: ${hello_line}"
    fi

    # Check 4: `## Feature Matrix` heading anywhere, followed within 20 lines
    # by a link to docs/FeatureMatrix.md. The two-part shape stops a future
    # PR from satisfying the lint with an empty stub heading.
    fm_line_no=$(grep -niE '^## feature matrix\s*$' "${README_PATH}" | head -n 1 | cut -d: -f1 || true)
    if [[ -z "${fm_line_no}" ]]; then
        echo "::error file=README.md::Strict mode: missing \`## Feature Matrix\` heading."
        failures=$((failures + 1))
    else
        # Window: heading line through heading+20. `sed -n 'A,Bp'` extracts inclusive range.
        window_end=$((fm_line_no + 20))
        window=$(sed -n "${fm_line_no},${window_end}p" "${README_PATH}")
        if printf '%s\n' "${window}" | grep -qF 'docs/FeatureMatrix.md'; then
            echo "✓ Found Feature Matrix anchor at line ${fm_line_no} with link to docs/FeatureMatrix.md."
        else
            echo "::error file=README.md,line=${fm_line_no}::Strict mode: \`## Feature Matrix\` heading must link to \`docs/FeatureMatrix.md\` within 20 lines."
            failures=$((failures + 1))
        fi
    fi
fi

echo

if [[ ${failures} -gt 0 ]]; then
    echo "::error::check-readme.sh found ${failures} failing check(s)."
    exit 1
fi

echo "✓ check-readme.sh passed."
