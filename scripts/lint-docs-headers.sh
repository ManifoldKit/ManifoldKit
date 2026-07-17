#!/bin/bash
# lint-docs-headers.sh — cheap PR-time mirror of
# Tests/ManifoldInferenceTests/DocsAudienceStatusAuditTest.swift.
#
# WHY THIS EXISTS (not just what it checks): ci.yml's macOS `test` job (which
# runs the Swift audit above) is paths-filtered and does NOT include
# `docs/**`, so a docs-only PR skips it entirely — the "CI Required Test
# Shim" reports green in its place. The merge queue's `merge_group` trigger
# has no paths filter and forces a full run, so a docs-only PR that is
# missing headers only discovers the failure for the first time in the
# queue — where it also burns through the batch of up to 5 PRs the queue
# validates together, failing innocent bystanders alongside it (see PR #2306
# poisoning PR #2212, 2026-07). Lint (this script's caller,
# .github/workflows/lint.yml) is ubuntu-latest, has no paths filter, and
# already runs on docs-only PRs — so it is where this check needs to live to
# catch the problem on the PR run, before the queue.
#
# ── DRIFT GUARD ────────────────────────────────────────────────────────────
# This script is a deliberately duplicated, cheap mirror of the AUTHORITATIVE
# tripwire in Tests/ManifoldInferenceTests/DocsAudienceStatusAuditTest.swift.
# The duplication is intentional (fast ubuntu-latest PR gate vs. the
# authoritative macOS Swift suite that already runs it for non-docs PRs too)
# but it means the two WILL drift apart silently if only one side is edited.
# If you change the accepted Audience:/Status: values, the lookback window,
# the doc set/exclusions, or the header regex shape in that Swift file,
# update this script to match (and vice versa).
#
# Mirrors, from the Swift audit:
#   - Doc set: docs/*.md top-level files only (NOT docs/plans/**, which has
#     its own Status:-only convention/audit — AgentsMdPlansStatusAuditTest).
#   - Accepted Audience values: consumer | contributor (case-insensitive).
#   - Accepted Status values: living | historical (case-insensitive).
#   - Header must appear within the first 15 lines of the file.
#   - Accepts both bare (`Audience: consumer`) and bold (`**Audience:**
#     consumer`) Markdown forms, with an optional stray `**` right after the
#     label (`Audience**:`).
#
# Written for Bash 3.2 (CI runners ship it) — no `declare -A`, no
# `mapfile`/`readarray`. Tested locally under `/bin/bash`. Empty-array reads
# are guarded for `set -u` per commit 978d03c2 (bash 3.2 treats `${arr[@]}`
# on an empty array as unbound).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCS_DIR="${REPO_ROOT}/docs"

if [[ ! -d "${DOCS_DIR}" ]]; then
    echo "::error::docs/ not found at ${DOCS_DIR}"
    exit 1
fi

# Top-level *.md only — same scope as the Swift audit. `find -maxdepth 1`
# keeps docs/plans/** and any other subdirectory out of scope.
doc_files=()
while IFS= read -r f; do
    doc_files+=("$f")
done < <(find "${DOCS_DIR}" -maxdepth 1 -type f -name '*.md' | LC_ALL=C sort)

if [[ ${#doc_files[@]:-0} -eq 0 ]]; then
    echo "::error::Expected at least one doc file directly under docs/ — path or filter probably wrong"
    exit 1
fi

# Accepted values (lowercase; comparison is case-insensitive).
is_valid_audience() {
    case "$1" in
        consumer|contributor) return 0 ;;
        *) return 1 ;;
    esac
}
is_valid_status() {
    case "$1" in
        living|historical) return 0 ;;
        *) return 1 ;;
    esac
}

# Extract the value word for a given label ("Audience" or "Status") from a
# single line, tolerating the bold-Markdown forms the Swift regex accepts:
#   Audience: word
#   **Audience:** word
#   Audience**: word   (stray ** right after the label)
# Prints nothing if the line does not match.
extract_header_value() {
    local label="$1" line="$2"
    printf '%s\n' "$line" | sed -nE "s/^[[:space:]]*(\*\*)?${label}(\*\*)?[[:space:]]*:[[:space:]]*(\*\*)?[[:space:]]*([A-Za-z0-9_]+).*/\4/p" | head -n1
}

missing=()

for f in "${doc_files[@]}"; do
    name="$(basename "$f")"

    has_audience=0
    audience_valid=0
    has_status=0
    status_valid=0

    # First ~15 lines only, matching the Swift audit's windowLines default.
    window="$(head -n 15 "$f")"

    while IFS= read -r line; do
        av="$(extract_header_value "Audience" "$line")"
        if [[ -n "$av" ]]; then
            has_audience=1
            av_lc="$(printf '%s' "$av" | tr '[:upper:]' '[:lower:]')"
            if is_valid_audience "$av_lc"; then
                audience_valid=1
            fi
        fi
        sv="$(extract_header_value "Status" "$line")"
        if [[ -n "$sv" ]]; then
            has_status=1
            sv_lc="$(printf '%s' "$sv" | tr '[:upper:]' '[:lower:]')"
            if is_valid_status "$sv_lc"; then
                status_valid=1
            fi
        fi
    done <<< "$window"

    if [[ $has_audience -eq 0 || $audience_valid -eq 0 || $has_status -eq 0 || $status_valid -eq 0 ]]; then
        reasons=""
        if [[ $has_audience -eq 0 ]]; then
            reasons="missing Audience:"
        elif [[ $audience_valid -eq 0 ]]; then
            reasons="invalid Audience value (want consumer|contributor)"
        fi
        if [[ $has_status -eq 0 ]]; then
            reasons="${reasons:+${reasons}, }missing Status:"
        elif [[ $status_valid -eq 0 ]]; then
            reasons="${reasons:+${reasons}, }invalid Status value (want living|historical)"
        fi
        missing+=("${name} — ${reasons}")
    fi
done

if [[ ${#missing[@]:-0} -gt 0 ]]; then
    echo "::error::The following docs/*.md files are missing (or have an invalid value for) an Audience:/Status: header in their first ~15 lines (see Tests/README.md § \"Documentation freshness headers\"):"
    echo
    for entry in "${missing[@]}"; do
        echo "  - ${entry}"
    done
    echo
    echo "Add two lines near the top, right after the H1 title:"
    echo "  **Audience:** consumer|contributor"
    echo "  **Status:** living|historical"
    echo
    echo "This mirrors Tests/ManifoldInferenceTests/DocsAudienceStatusAuditTest.swift, which is"
    echo "the authoritative tripwire and will also fail the macOS test suite."
    exit 1
fi

echo "OK: all ${#doc_files[@]} docs/*.md file(s) carry valid Audience:/Status: headers."
