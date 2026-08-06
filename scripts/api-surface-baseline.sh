#!/usr/bin/env bash
# scripts/api-surface-baseline.sh — member-aware public-surface tripwire
#
# Originated as a 7-module prototype (docs/plans/api-review-2026-07.md item
# 0.2b). Made load-bearing in docs/plans/api-review-wave2-2026-07.md item
# 0.A: full coverage of every `.library()` product in Package.swift (27 as
# of 2026-07-10), wired into nightly-slow-tests.yml via `--check`. No
# longer a prototype — a red run here blocks the nightly job.
#
# ── Why this exists ─────────────────────────────────────────────────────
#
# `swift package diagnose-api-breaking-changes` (the existing per-PR gate,
# ci.yml:599-660) diagnoses BREAKING changes only. Tonight's digester
# rehearsal confirmed two blind spots:
#   1. Pure member ADDITIONS are invisible (the command exits 0) — so the
#      exact GenerationConfig-init accretion pattern that motivated this
#      plan item (RC1: "28-parameter init is the fossil record of one
#      cheap param per PR") would sail through unnoticed.
#   2. A defaulted-param addition to an existing initializer can show up as
#      a false-positive "constructor removed" breakage — noisy in the
#      wrong direction.
#
# So this script does NOT rely on the breakage diff. It dumps the
# swift-api-digester's member-granular ABIRoot JSON for a scoped module
# list, normalizes each dump into a flat, deterministic, checked-in-diffable
# text file (one line per type + one line per member; genuinely PUBLIC
# only — the normalizer filters out `package`-scoped and `@_spi` decls the
# digester also dumps, see scripts/_lib/api-surface-extract.py), and diffs
# that text against a checked-in baseline. ANY public member added or
# removed shows up as a plain-text diff line — additions included, and a
# public→package demotion reads as removed lines.
#
# ── Division of labor with the existing digester gate (residual blind
#    spot — read before extending this) ──────────────────────────────────
#
# The baseline lines are presence-keyed on `printedName`, which carries
# parameter LABELS but not TYPES. So member TYPE changes — a property's
# type changing, a parameter/return type changing under unchanged labels,
# an enum case's payload changing — produce ZERO drift here. That class of
# change is exactly what the existing per-PR breakage-diff gate
# (`swift package diagnose-api-breaking-changes`, ci.yml:599-660) already
# diagnoses. The two gates are complementary, not redundant:
#   - breakage-diff gate: catches REMOVALS and TYPE/SIGNATURE changes;
#     blind to pure additions.
#   - this baseline:      catches ADDITIONS, removals, and demotions;
#     blind to type changes under a stable name/labels.
# Neither subsumes the other. Do not retire one for the other.
#
# ── Usage ───────────────────────────────────────────────────────────────
#
#   scripts/api-surface-baseline.sh
#       Regenerate the checked-in baselines in place
#       (Tests/APIFreezeTests/api-surface-baseline/<Module>.txt). Run this
#       after a PR intentionally changes public surface, then review the
#       diff and justify additions in the PR body (see the message below).
#
#   scripts/api-surface-baseline.sh --check
#       Regenerate to a scratch directory and diff against the checked-in
#       baselines WITHOUT touching them. Exits non-zero and lists every
#       added/removed member if anything drifted.
#
#   scripts/api-surface-baseline.sh --modules "ModuleA ModuleB"
#       Override the scoped module list (space-separated, one --modules
#       flag). Defaults to every covered module below.
#
#   scripts/api-surface-baseline.sh --treeish <ref>
#       Advanced escape hatch: dump a specific git treeish instead of the
#       live working tree (see CAVEAT below). Rarely needed.
#
# ── Module scope (full coverage — no exclusions) ────────────────────────
#
# Every `.library(...)` product in Package.swift — the same product surface
# the nightly api-check step (nightly-slow-tests.yml, `swift package
# diagnose-api-breaking-changes`) covers, so the two gates track the same
# modules and neither silently drifts ahead of the other. Keep
# DEFAULT_MODULES in sync with Package.swift's `products:` array when a
# product is added, removed, or renamed — no longer a hand-checked invariant:
# `PublicSurfaceBaselineTests.testScriptDefaultModulesMatchManifest` derives
# the expected set from the manifest (minus the documented exclusions — see
# `ManifoldServerKit` below, held in that test's `baselineScopeExclusions`)
# and fails if this list disagrees, naming the offending module in either
# direction. (That test's former hand-kept `expectedModules` array is gone —
# it is derived now, so there is nothing to update on that side.)
# Executables (fuzz-chat, manifold-tools, the
# `ManifoldServer` CLI product → ManifoldServerCLI target, see Package.swift's
# product comments) and the ManifoldMacrosPlugin build plugin aren't
# `.library()` products and have no digestible module interface — out of
# scope by construction, not an exclusion.
#
# `ManifoldServerKit` (Package.swift:142, module name `ManifoldServer` — NOT
# the executable product of the same simple name above) IS a `.library()`
# product, and does NOT belong in the "out of scope by construction" bucket
# above — it shipped a real public seam (`ServerBackendProvider`,
# `ManifoldServer.serve(configuration:backendProvider:)`) in #2242. It is
# still deliberately absent from DEFAULT_MODULES, for a different reason: a
# confirmed swift-package-manager tool limitation, not a scoping choice —
# see #2245 item 4.
#
#   `swift package diagnose-api-breaking-changes --baseline-dir <dir>`
#   builds the target being dumped in an internal SCRATCH CHECKOUT
#   (`.build/arm64-apple-macosx/apidiff/<hash>-checkout/`) — a separate
#   `swift build` invocation from the one the outer `swift package` command
#   itself drives. That scratch-checkout build does NOT receive `--traits`,
#   no matter where the flag is placed (tried: before the subcommand — the
#   only grammatically valid position per `swift package --help`'s TRAIT
#   OPTIONS section — and stacked with `-Xswiftc -DServer` as a forcing
#   attempt). `ManifoldServerKit`'s entire module body is wrapped in
#   `#if Server` (`.define("Server", .when(traits: ["Server"]))`,
#   Package.swift:953), so an un-traited scratch-checkout compile emits a
#   module with zero declarations — just the four implicit stdlib imports.
#
#   Verified 2026-07-16, three ways, scoped to just `--targets ManifoldServer`:
#     1. `swift package --traits Server diagnose-api-breaking-changes HEAD
#        --targets ManifoldServer --baseline-dir /tmp/x` → dumped JSON has
#        0 declarations.
#     2. Same command WITHOUT `--traits Server` → byte-identical dump
#        (44315 bytes both times) — the flag had no measurable effect.
#     3. `-v` output, grepped for the actual `swiftc` invocation: the LIVE
#        tree build (`.build/arm64-apple-macosx/debug/...`, not the
#        `-checkout` path) correctly gets `-DServer` on its ManifoldServer
#        compile line; the CHECKOUT build's ManifoldServer compile line has
#        only `-DSWIFT_PACKAGE -DDEBUG
#        -DSWIFT_MODULE_RESOURCE_BUNDLE_UNAVAILABLE` — no `-DServer`. So
#        `--traits` reaches manifest/target resolution and the live build,
#        but never the scratch-checkout build the dump is actually taken
#        from.
#     4. Forcing the define directly (`-Xswiftc -DServer` stacked with
#        `--traits Server`) makes the checkout build fail outright —
#        `error: no such module 'ManifoldInference'` — because the
#        trait-conditioned product dependencies (`ManifoldInference`,
#        `Hummingbird`, `HTTPTypes`; Package.swift:940-949) are still
#        resolved WITHOUT the trait for that build, even though the source
#        define now says to reference them.
#
#   Net effect: for a target whose entire public surface sits behind a
#   trait-gated `#if`, this tool's `--baseline-dir` dump is *structurally*
#   always empty — not fixable by flag placement. If someone adds
#   `ManifoldServer` to DEFAULT_MODULES anyway, the resulting 0-line
#   baseline is correctly rejected by
#   `PublicSurfaceBaselineTests.testEachModuleBaselineIsWellFormed`
#   (`XCTAssertFalse(lines.isEmpty, ...)`) — a loud failure, not a silent
#   vacuous gate — but it still can't ship until either
#   swift-package-manager forwards `--traits` into its scratch-checkout
#   build, or ManifoldServerKit's trait-gated surface is redesigned so the
#   seam itself (`ServerBackendProvider`, `ServerConfiguration`,
#   `ManifoldServer.serve`) compiles unconditionally and only the
#   Hummingbird-touching internals stay behind the trait.
#
# ManifoldFoundation note (checked before including it, 2026-07-10): its
# main surface sits behind `#if canImport(FoundationModels)`, which is a
# compile-SDK check, not a runtime-OS check. The repo's toolchain floor is
# Xcode 26.x (see AGENTS.md "swift-tools-version ceiling"), whose SDK
# always ships FoundationModels — so the gated surface compiles, and dumps,
# identically on every supported dev machine and CI runner. Verified: the
# module dumps its full surface (FoundationBackend + registrar) on both
# sides of the digester's scratch-checkout build. If a future toolchain
# situation makes this flaky, exclude it HERE with a comment — never
# silently.
#
# ── How the dump is generated (the part worth reviewing carefully) ─────
#
# `swift package diagnose-api-breaking-changes <treeish> --targets X
# --baseline-dir <dir>` checks <treeish> out into a scratch build
# (.build/arm64-apple-macosx/apidiff/<hash>-checkout/, cached across runs)
# and writes ITS per-module JSON dump into <dir>/<hash>/<Module>.json — that
# baseline-dir dump is the artifact this script actually wants. The
# command's own breakage comparison (baseline <treeish> vs the live working
# directory) is a byproduct we don't use directly.
#
# To get a dump of the CURRENT working tree (including uncommitted edits,
# for the sabotage-verify workflow below) without requiring a commit, we
# resolve the default <treeish> via `git stash create`: a plumbing command
# that snapshots tracked changes (staged or not) into a dangling commit
# object with NO side effects on the working tree, index, or stash list.
# That makes <treeish> == the live tree, so the command's own breakage
# comparison is always a trivial no-op (identical trees, exit 0) and its
# only effect we care about is the baseline-dir JSON dump.
#
# CAVEAT: `git stash create` has no -u/--include-untracked equivalent — a
# brand-new (never `git add`ed) file is invisible to it. `git add` a new
# file (even unstaged is fine for everything ELSE) before running this
# against a change that adds a new file with new public members.
#
# NOTE: each `git stash create` invocation leaves a harmless dangling
# commit object behind (unreachable; reclaimed by normal `git gc`). It
# touches no refs, index, or stash list.
#
# ── Cost — the honest answer to "can this run per-PR?" ──────────────────
#
# Measured on a local Apple Silicon worktree, all modules in ONE
# invocation (--targets scoping does NOT reduce the build —
# diagnose-api-breaking-changes builds the whole package graph regardless,
# matching ci.yml's own documented "~12 min compile cost" comment):
#   - Cold (nothing cached): ~13 minutes wall clock (measured at the
#     original 7-module scope; the dominant cost is the two full package
#     builds — the scratch treeish checkout AND the live tree — each
#     ~1300+ compile actions, so scope barely moves it).
#   - Warm (both .build dirs already built from a prior run, e.g. right
#     after `scripts/test.sh`): ~97 seconds for all 27 modules together
#     (2026-07-10; was ~78s at 7-module scope — the per-module dump cost
#     is small next to the build).
# The gap between those numbers IS the finding: this is only "per-PR
# cheap" if a PR's normal `swift build`/`swift test` already warmed both
# caches AND the scratch-checkout side also stays warm across runs (true
# locally across repeated invocations; NOT true in CI today, where each PR
# commit is a different treeish needing a fresh scratch checkout — same
# cold-cache tax the existing digester gate already pays, per its own
# doc comment). Recommend nightly/pre-release cadence, not per-PR, until
# that's re-measured against a real CI runner.
#
# ── CI integration ───────────────────────────────────────────────────────
#
# Wired into .github/workflows/nightly-slow-tests.yml as its own job
# (`api-surface-baseline`) running `scripts/api-surface-baseline.sh --check`,
# given the cold-cache cost measured above. Not per-PR — revisit once the
# scratch-checkout cache behavior is measured warm on an actual GitHub
# Actions runner across consecutive nightly runs.
#
# ── Failure message contract ─────────────────────────────────────────────
#
# On drift, --check prints every added/removed line per module, then:
#   "public surface changed — regenerate the baseline in this PR
#   (scripts/api-surface-baseline.sh) and justify additions in the PR body"

set -euo pipefail

# The baselines are Python-`sorted()` (Unicode code-point order == UTF-8
# byte order). `comm` below requires ITS collation to match, and the
# default locale's collation does NOT (verified: locale `sort` interleaves
# `Agent.ID`/`Agent.chunk...` differently). Pin byte order globally.
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE_DIR="${REPO_ROOT}/Tests/APIFreezeTests/api-surface-baseline"
EXTRACT_PY="${REPO_ROOT}/scripts/_lib/api-surface-extract.py"
ALLOWLIST_PATH="${REPO_ROOT}/.github/api-breakage-allowlist.txt"

# Every `.library(...)` product in Package.swift (see the "Module scope"
# header section above). Order mirrors Package.swift's products: array.
DEFAULT_MODULES="ManifoldKit ManifoldInference ManifoldContract ManifoldNetworking ManifoldSecrets ManifoldHardware ManifoldModelCatalog ManifoldMCP ManifoldMCPHost ManifoldRuntime ManifoldPersistenceSwiftData ManifoldCloudCore ManifoldFoundation ManifoldOllama ManifoldCloudSaaS ManifoldAnyLanguageModel ManifoldUI ManifoldUIModelManagement ManifoldHuggingFace ManifoldVoice ManifoldFuzz ManifoldTestSupport ManifoldPersistenceTestSupport ManifoldBackendTestKit ManifoldTools ManifoldAppIntents ManifoldAgentInstructions ManifoldTelemetryOTLP ManifoldAppEval"

MODE="generate"
TREEISH=""
MODULES_STR="${DEFAULT_MODULES}"

usage() {
    cat <<'EOF'
Usage:
  scripts/api-surface-baseline.sh                      regenerate checked-in baselines
  scripts/api-surface-baseline.sh --check              diff against checked-in baselines (CI-shaped)
  scripts/api-surface-baseline.sh --modules "A B C"    override the scoped module list
  scripts/api-surface-baseline.sh --treeish <ref>      dump a specific git treeish (advanced)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check)
            MODE="check"
            shift
            ;;
        --modules)
            MODULES_STR="${2:?--modules requires a value}"
            shift 2
            ;;
        --treeish)
            TREEISH="${2:?--treeish requires a value}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "::error::Unknown argument: $1" >&2
            usage
            exit 2
            ;;
    esac
done

if ! command -v python3 >/dev/null 2>&1; then
    echo "::error::python3 is required to normalize the digester dump." >&2
    exit 2
fi

if [[ ! -f "${EXTRACT_PY}" ]]; then
    echo "::error::Missing normalizer: ${EXTRACT_PY}" >&2
    exit 2
fi

resolve_treeish() {
    if [[ -n "${TREEISH}" ]]; then
        printf '%s' "${TREEISH}"
        return
    fi
    local snapshot
    snapshot="$(cd "${REPO_ROOT}" && git stash create 2>/dev/null || true)"  # fail-open-ok: nothing stash-able → empty → falls back to HEAD below
    if [[ -n "${snapshot}" ]]; then
        printf '%s' "${snapshot}"
    else
        printf '%s' "HEAD"
    fi
}

DUMP_DIR="$(mktemp -d)"
NORMALIZED_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "${DUMP_DIR}" "${NORMALIZED_DIR}"
}
trap cleanup EXIT

treeish="$(resolve_treeish)"
echo "── api-surface-baseline: snapshotting public surface at treeish ${treeish} ──"

# Split MODULES_STR on whitespace into --targets flags. Bash 3.2 safe: no
# arrays-of-arrays, no `readarray`/`mapfile`.
target_args=()
for m in ${MODULES_STR}; do
    target_args+=(--targets "${m}")
done

allowlist_args=()
if [[ -f "${ALLOWLIST_PATH}" ]]; then
    allowlist_args=(--breakage-allowlist-path "${ALLOWLIST_PATH}")
fi

# This also runs the digester's own breakage comparison (treeish vs the
# live working tree). By construction (see header) those two are
# content-identical in the default flow, so that comparison is always a
# no-op here — the only artifact we consume is the --baseline-dir JSON
# dump. See header CAVEAT for the one case (brand-new untracked file) where
# that invariant doesn't hold.
(
    cd "${REPO_ROOT}"
    swift package diagnose-api-breaking-changes "${treeish}" \
        "${target_args[@]}" \
        "${allowlist_args[@]}" \
        --baseline-dir "${DUMP_DIR}"
)

# Locate the dumped JSON files. diagnose-api-breaking-changes names the
# subdirectory after the RESOLVED commit hash, not the treeish string we
# passed in (e.g. "HEAD" resolves to a hash-named directory) — so glob
# rather than assume the directory name.
found_any=0
while IFS= read -r -d '' jsonfile; do
    found_any=1
    module_name="$(basename "${jsonfile}" .json)"
    python3 "${EXTRACT_PY}" "${jsonfile}" > "${NORMALIZED_DIR}/${module_name}.txt"
done < <(find "${DUMP_DIR}" -mindepth 2 -maxdepth 2 -name '*.json' -print0)

if [[ "${found_any}" -eq 0 ]]; then
    echo "::error::No digester dumps produced under ${DUMP_DIR} — check the module list (${MODULES_STR})." >&2
    exit 2
fi

if [[ "${MODE}" == "generate" ]]; then
    mkdir -p "${BASELINE_DIR}"
    for m in ${MODULES_STR}; do
        src="${NORMALIZED_DIR}/${m}.txt"
        if [[ ! -f "${src}" ]]; then
            echo "::error::Expected a dump for module ${m} but none was produced." >&2
            exit 2
        fi
        cp "${src}" "${BASELINE_DIR}/${m}.txt"
        echo "✓ Wrote $(wc -l < "${src}" | tr -d ' ') lines to Tests/APIFreezeTests/api-surface-baseline/${m}.txt"
    done
    echo
    echo "Baselines regenerated. Review the diff (git diff -- Tests/APIFreezeTests/api-surface-baseline)"
    echo "and justify any additions in the PR body."
    exit 0
fi

# ── --check mode ─────────────────────────────────────────────────────────
drift_found=0
for m in ${MODULES_STR}; do
    new_file="${NORMALIZED_DIR}/${m}.txt"
    baseline_file="${BASELINE_DIR}/${m}.txt"

    if [[ ! -f "${new_file}" ]]; then
        echo "::error::Expected a dump for module ${m} but none was produced." >&2
        exit 2
    fi

    if [[ ! -f "${baseline_file}" ]]; then
        echo "── ${m}: no checked-in baseline (new module) ──"
        echo "All $(wc -l < "${new_file}" | tr -d ' ') members would be additions."
        drift_found=1
        continue
    fi

    # Both files are already sorted + de-duplicated by the extractor.
    # comm -13: lines only in the new dump (additions).
    # comm -23: lines only in the checked-in baseline (removals).
    added="$(comm -13 "${baseline_file}" "${new_file}" || true)"
    removed="$(comm -23 "${baseline_file}" "${new_file}" || true)"

    if [[ -z "${added}" && -z "${removed}" ]]; then
        continue
    fi

    drift_found=1
    echo "── ${m}: public surface drift ──"
    if [[ -n "${added}" ]]; then
        while IFS= read -r line; do
            [[ -n "${line}" ]] && echo "  + ${line}"
        done <<< "${added}"
    fi
    if [[ -n "${removed}" ]]; then
        while IFS= read -r line; do
            [[ -n "${line}" ]] && echo "  - ${line}"
        done <<< "${removed}"
    fi
done

if [[ "${drift_found}" -ne 0 ]]; then
    echo
    echo "::error::public surface changed — regenerate the baseline in this PR (scripts/api-surface-baseline.sh) and justify additions in the PR body"
    exit 1
fi

echo "✓ No public-surface drift across: ${MODULES_STR}"
