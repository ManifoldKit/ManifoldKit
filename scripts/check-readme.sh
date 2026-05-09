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
# Every `from: "X.Y.Z"` line in README.md must reference the current release.
# We do NOT match `exact: "..."`, `branch: "..."`, or `revision: "..."` —
# those are intentional pins for specific scenarios. Only the open-ended
# `from:` declarations are required to match `version.txt`.
echo
echo "── Check: README install pins match version.txt ─────────────────────"

# Grep with -n for line numbers; awk to extract the version literal.
# `mapfile` is bash 4+; macOS ships bash 3.2, so use a portable read loop.
pin_lines=()
while IFS= read -r line; do
    pin_lines+=("$line")
done < <(grep -nE '^\s*from:\s*"[0-9]+\.[0-9]+\.[0-9]+' "${README_PATH}" || true)

if [[ ${#pin_lines[@]} -eq 0 ]]; then
    echo "::warning::README contains no \`from: \"X.Y.Z\"\` install pins. Did the install snippet move?"
fi

bad_pins=0
for entry in "${pin_lines[@]}"; do
    line_no="${entry%%:*}"
    line_text="${entry#*:}"
    pinned_version=$(printf '%s' "${line_text}" | sed -nE 's/.*from:\s*"([0-9]+\.[0-9]+\.[0-9]+)".*/\1/p')
    if [[ -z "${pinned_version}" ]]; then
        continue
    fi
    if [[ "${pinned_version}" != "${CURRENT_VERSION}" ]]; then
        echo "::error file=README.md,line=${line_no}::Install pin \`from: \"${pinned_version}\"\` does not match version.txt (${CURRENT_VERSION})."
        bad_pins=$((bad_pins + 1))
    fi
done

if [[ ${bad_pins} -gt 0 ]]; then
    failures=$((failures + 1))
    echo "Found ${bad_pins} stale install pin(s). Bump them to ${CURRENT_VERSION}."
else
    echo "✓ All \`from:\` install pins match version.txt (${CURRENT_VERSION})."
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

echo

if [[ ${failures} -gt 0 ]]; then
    echo "::error::check-readme.sh found ${failures} failing check(s)."
    exit 1
fi

echo "✓ check-readme.sh passed."
