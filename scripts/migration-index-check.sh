#!/bin/bash
# migration-index-check.sh — two-mode gate over docs/MIGRATION-INDEX.md.
#
# WHY THIS EXISTS: docs/MIGRATION-INDEX.md is the page Principle 9 promises
# consumers as the starting point when a version bump breaks their build —
# "the complete list, newest first, with the release that shipped the note".
# A retired API's migration note ships with a row added to that table, with
# `next` in the Release column; at release time that row is supposed to be
# flipped to the version actually shipping. Nothing enforced either half:
# a note could ship with no index row at all, and a `next` row could sail
# through a release un-flipped, silently lying about which release broke
# what. Eight rows were sitting at `next` on main the day this script was
# written (see docs/MIGRATION-INDEX.md).
#
# This is NOT scripts/lint-doc-claims.sh's "index coverage" check — that
# check (mirroring DocClaimsAuditTest.auditIndexCoverage) only asserts every
# docs/*.md is *mentioned by some* Markdown file, which a migration note
# already satisfies just by being linked from MIGRATION-INDEX.md's own
# table. It says nothing about whether that link is a real table row with a
# correct Release column — that is this script's job.
#
# ── TWO MODES ───────────────────────────────────────────────────────────
#   (no flags)   Completeness only: every docs/MIGRATION-*.md (other than
#                MIGRATION-INDEX.md itself) has a row in the index table.
#                Safe to run on any PR — this is a per-PR-safe invariant.
#   --release    Completeness, PLUS: no row may still have `next` in its
#                Release column. Those must have been flipped to the
#                version being shipped. NOT safe to run per-PR today — see
#                Tests/ManifoldCoreTests/MigrationIndexAuditTest.swift's
#                header comment for why the release half is release-gated
#                only, not an in-suite tripwire.
#
# ── DRIFT GUARD ────────────────────────────────────────────────────────────
# The completeness half is deliberately duplicated against the AUTHORITATIVE
# tripwire in Tests/ManifoldCoreTests/MigrationIndexAuditTest.swift (same
# split as lint-docs-headers.sh / lint-doc-claims.sh vs. their Swift
# audits: this is a cheap table-shape parse for a release-time / ad hoc
# check, the Swift file is the one that must be trusted to detect a real
# regression). If the table's column order or row shape changes, update
# both in the same commit — the Swift audit is not this script's caller and
# a divergence between them will not surface as a build failure.
#
# Fail-closed: a missing/unreadable index file, a missing docs directory, or
# a table that parses to zero rows are all FATAL — never a silent pass. The
# zero-row case in particular is a known failure mode in this repo (a
# table-shape edit that breaks this script's regex would otherwise look
# identical to "nothing to check").
#
# Written for Bash 3.2 (CI runners ship it) — no `declare -A`, no
# `${var^}`. Tested under `/bin/bash` explicitly, not zsh.
#
# Usage:
#   scripts/migration-index-check.sh                  # completeness only
#   scripts/migration-index-check.sh --release         # completeness + no pending "next" rows
#   scripts/migration-index-check.sh --index FILE       # override the index path (fixtures/tests)
#   scripts/migration-index-check.sh --docs-dir DIR     # override the migration-notes dir (fixtures/tests)
#
# Exit codes: 0 pass, 1 violations found (or the index could not be parsed), 2 usage error.
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: scripts/migration-index-check.sh [--release] [--index FILE] [--docs-dir DIR]

  (no flags)      Completeness only: every docs/MIGRATION-*.md (except
                  MIGRATION-INDEX.md itself) has a row in the index table.
  --release       Completeness, plus: no index row may have "next" in its
                  Release column — those must be flipped to the shipped
                  version before a release ships.
  --index FILE    Override the index file path (fixtures/tests).
  --docs-dir DIR  Override the migration-notes directory (fixtures/tests).

Exit codes: 0 pass, 1 violations found, 2 usage error.
EOF
}

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INDEX_FILE="${REPO_ROOT}/docs/MIGRATION-INDEX.md"
DOCS_DIR="${REPO_ROOT}/docs"
RELEASE_MODE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)
            RELEASE_MODE=1
            shift
            ;;
        --index)
            if [[ $# -lt 2 ]]; then
                echo "::error::--index requires a path argument" >&2
                usage
                exit 2
            fi
            INDEX_FILE="$2"
            shift 2
            ;;
        --docs-dir)
            if [[ $# -lt 2 ]]; then
                echo "::error::--docs-dir requires a path argument" >&2
                usage
                exit 2
            fi
            DOCS_DIR="$2"
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

# ── Fail-closed input validation ────────────────────────────────────────
if [[ ! -f "${INDEX_FILE}" ]]; then
    echo "::error::Migration index not found: ${INDEX_FILE}"
    exit 1
fi
if [[ ! -r "${INDEX_FILE}" ]]; then
    echo "::error::Migration index not readable: ${INDEX_FILE}"
    exit 1
fi
if [[ ! -d "${DOCS_DIR}" ]]; then
    echo "::error::Migration-notes directory not found: ${DOCS_DIR}"
    exit 1
fi

# ── Parse the index table ───────────────────────────────────────────────
# Row shape (docs/MIGRATION-INDEX.md § the table):
#   | next | [`MIGRATION-foo.md`](MIGRATION-foo.md) | What changed |
#   | v0.74.0 | [`MIGRATION-bar.md`](MIGRATION-bar.md) | What changed |
# Bash 3.2 has no associative arrays, so release and filename are kept in
# two parallel arrays, aligned by index.
row_releases=()
row_files=()

while IFS= read -r line; do
    # Only rows that name a MIGRATION-*.md file — this alone excludes the
    # header row and the `|---|---|---|` separator, neither of which
    # contains that token.
    if ! printf '%s' "$line" | grep -qE '^\|.*MIGRATION-[A-Za-z0-9._-]+\.md'; then
        continue
    fi

    # Release column: the first field after the leading "|".
    release_field="$(printf '%s\n' "$line" | awk -F'|' '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}')"
    # The migration-note filename. Matched natively rather than via
    # `grep -oE ... | head -n1`: `head` closing the pipe early can SIGPIPE
    # grep, which `pipefail` would then propagate, so that form needs a
    # `|| true` to be safe — and a discarded failure is exactly what this
    # repo's fail-open rules (and the estate lint) exist to stop. Bash's own
    # `=~` has no pipe, no subprocess and no failure mode to discard.
    # BASH_REMATCH is available in Bash 3.2, which is what CI runners ship.
    # The regex must stay unquoted; a quoted one matches literally in 3.2.
    if [[ "$line" =~ (MIGRATION-[A-Za-z0-9._-]+\.md) ]]; then
        filename="${BASH_REMATCH[1]}"
    else
        # Unreachable given the filter above, which already required this
        # token — kept so a future edit to that filter degrades to "skip the
        # row" rather than to an unset variable under `set -u`.
        continue
    fi

    row_releases+=("$release_field")
    row_files+=("$filename")
done < "${INDEX_FILE}"

# Bare `${#arr[@]}` is 0 for an empty array even under `set -u` (Bash 3.2) —
# see lint-docs-headers.sh's comment on the same idiom.
if [[ ${#row_files[@]} -eq 0 ]]; then
    echo "::error::Parsed zero rows from the migration index table at ${INDEX_FILE}."
    echo "::error::Either the table is genuinely empty (never a legitimate state — the"
    echo "::error::index promises to be the complete migration-note list) or this"
    echo "::error::script's row parser has drifted from the table's real shape. A"
    echo "::error::zero-match parse reading as success is a known failure mode in this"
    echo "::error::repo — treated as fatal, never a silent pass."
    exit 1
fi

echo "Parsed ${#row_files[@]} row(s) from $(basename "${INDEX_FILE}")."

# ── Completeness: every docs/MIGRATION-*.md has a row ─────────────────────
index_basename="$(basename "${INDEX_FILE}")"
missing_rows=()

while IFS= read -r f; do
    name="$(basename "$f")"
    [[ "$name" == "$index_basename" ]] && continue

    found=0
    for indexed in "${row_files[@]}"; do
        if [[ "$indexed" == "$name" ]]; then
            found=1
            break
        fi
    done
    if [[ $found -eq 0 ]]; then
        missing_rows+=("$name")
    fi
done < <(find "${DOCS_DIR}" -maxdepth 1 -type f -name 'MIGRATION-*.md' | LC_ALL=C sort)

if [[ ${#missing_rows[@]} -gt 0 ]]; then
    echo "::error::docs/MIGRATION-INDEX.md is missing a row for the following migration note(s):"
    echo
    for m in "${missing_rows[@]}"; do
        echo "  - docs/${m}"
    done
    echo
    echo "Add a row to the table with the release that ships the note (\`next\` if"
    echo "unreleased) and a one-line summary of what changed."
    echo
    echo "Authoritative tripwire: Tests/ManifoldCoreTests/MigrationIndexAuditTest.swift"
    exit 1
fi

# ── Release mode: no pending "next" rows ──────────────────────────────────
if [[ $RELEASE_MODE -eq 1 ]]; then
    pending=()
    idx=0
    while [[ $idx -lt ${#row_files[@]} ]]; do
        if [[ "${row_releases[$idx]}" == "next" ]]; then
            pending+=("${row_files[$idx]}")
        fi
        idx=$((idx + 1))
    done

    if [[ ${#pending[@]} -gt 0 ]]; then
        echo "::error::${#pending[@]} migration-index row(s) still say \"next\" in the Release column."
        echo "::error::Flip each to the version being shipped before this release merges:"
        echo
        for p in "${pending[@]}"; do
            echo "  - docs/${p}"
        done
        echo
        echo "Authoritative tripwire: Tests/ManifoldCoreTests/MigrationIndexAuditTest.swift"
        echo "(completeness half only — the \"next\"-row rule is release-gated, not an"
        echo "in-suite audit; see that file's header comment for why)."
        exit 1
    fi

    echo "✓ Completeness holds and no pending \"next\" rows remain (${#row_files[@]} row(s), release check)."
    exit 0
fi

echo "✓ All docs/MIGRATION-*.md file(s) have an index row (${#row_files[@]} row(s) checked)."
