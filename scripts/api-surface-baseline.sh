#!/usr/bin/env bash
# scripts/api-surface-baseline.sh — member-aware public-surface tripwire (prototype)
#
# PROTOTYPE / mechanism design — see docs/plans/api-review-2026-07.md item
# 0.2b. This is scoped narrowly on purpose (7 modules, no CI wiring) so the
# mechanism can be reviewed before it's made load-bearing.
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
# text file (one line per type + one line per member), and diffs that text
# against a checked-in baseline. ANY member added or removed shows up as a
# plain-text diff line — additions included.
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
#       flag). Defaults to the 7 modules below.
#
#   scripts/api-surface-baseline.sh --treeish <ref>
#       Advanced escape hatch: dump a specific git treeish instead of the
#       live working tree (see CAVEAT below). Rarely needed.
#
# ── Module scope (prototype — deliberately narrow) ─────────────────────
#
# The 5 modules the existing per-PR digester gate already covers
# (ci.yml:226-238) plus the two the arch-review plan's item 0.0 flags as
# gate-scope holes that matter most for THIS tripwire's motivating example
# (ModelType/ToolTypes/BackendCapabilities physically live in
# ManifoldHardware; GenerationConfig's home, ManifoldContract, is the
# accretion example itself):
#   ManifoldInference, ManifoldRuntime, ManifoldCloudCore,
#   ManifoldPersistenceSwiftData, ManifoldUI, ManifoldContract,
#   ManifoldHardware
# Closing the REST of the 0.0 gate-scope hole (ManifoldTestSupport,
# ManifoldBackendTestKit, and wiring this into CI) is out of scope here —
# this script only prototypes the member-aware MECHANISM.
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
# ── Cost — the honest answer to "can this run per-PR?" ──────────────────
#
# Measured tonight on this worktree, 7 modules in ONE invocation (--targets
# scoping does NOT reduce the build — diagnose-api-breaking-changes builds
# the whole package graph regardless, matching ci.yml's own documented
# "~12 min compile cost" comment):
#   - Cold (nothing cached): ~13 minutes wall clock (two full package
#     builds — the scratch treeish checkout AND the live tree — each
#     ~1300+ compile actions).
#   - Warm (both .build dirs already built from a prior run, e.g. right
#     after `scripts/test.sh`): ~78 seconds for all 7 modules together.
# The gap between those numbers IS the finding: this is only "per-PR
# cheap" if a PR's normal `swift build`/`swift test` already warmed both
# caches AND the scratch-checkout side also stays warm across runs (true
# locally across repeated invocations; NOT true in CI today, where each PR
# commit is a different treeish needing a fresh scratch checkout — same
# cold-cache tax the existing digester gate already pays, per its own
# doc comment). Recommend nightly/pre-release cadence, not per-PR, until
# that's re-measured against a real CI runner.
#
# ── CI integration (NOT wired here — see PR body) ───────────────────────
#
# PR #2145 owns workflow files tonight, so this script does not touch
# .github/workflows/*. The suggested integration step (for whoever picks
# this up) mirrors the existing "Public API source-compatibility check" in
# ci.yml:599: run `scripts/api-surface-baseline.sh --check` as a nightly
# step (nightly-slow-tests.yml) given the cold-cache cost measured above;
# revisit per-PR once the scratch-checkout cache behavior is measured on an
# actual GitHub Actions runner.
#
# ── Failure message contract ─────────────────────────────────────────────
#
# On drift, --check prints every added/removed line per module, then:
#   "public surface changed — regenerate the baseline in this PR
#   (scripts/api-surface-baseline.sh) and justify additions in the PR body"

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASELINE_DIR="${REPO_ROOT}/Tests/APIFreezeTests/api-surface-baseline"
EXTRACT_PY="${REPO_ROOT}/scripts/_lib/api-surface-extract.py"
ALLOWLIST_PATH="${REPO_ROOT}/.github/api-breakage-allowlist.txt"

DEFAULT_MODULES="ManifoldInference ManifoldRuntime ManifoldCloudCore ManifoldPersistenceSwiftData ManifoldUI ManifoldContract ManifoldHardware"

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
    snapshot="$(cd "${REPO_ROOT}" && git stash create 2>/dev/null || true)"
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
