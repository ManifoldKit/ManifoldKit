#!/bin/bash
# lint-plan-status.sh — required PR-time mirror of the live-plan lifecycle
# audit. Terminal plans must leave docs/plans; an empty directory is valid.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${MANIFOLD_PLAN_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

if [[ "${1:-}" == "--self-test" ]]; then
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/lint-plan-status.XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/docs/plans"
    printf '# closed\n\n**Status (2026-07-26): CLOSED as campaign.**\n' > "$tmp/docs/plans/closed.md"
    printf '# no marker\n' > "$tmp/docs/plans/missing.md"
    printf '# misleading\n\n**StatusReport:** Active\n' > "$tmp/docs/plans/status-report.md"
    printf '# unterminated\n\n**Status:** Executed' > "$tmp/docs/plans/unterminated.md"
    if MANIFOLD_PLAN_ROOT="$tmp" bash "$0" >"$tmp/output" 2>&1; then
        echo "self-test failed: terminal/missing statuses were accepted" >&2; exit 1
    fi
    /usr/bin/grep -q 'terminal lifecycle status' "$tmp/output"
    /usr/bin/grep -q 'missing Status:' "$tmp/output"
    /usr/bin/grep -q 'status-report.md' "$tmp/output"
    /usr/bin/grep -q 'unterminated.md' "$tmp/output"
    printf '# active\n\n**Status:** Active — Phase 1 completed, Phase 2 open.\n' > "$tmp/docs/plans/closed.md"
    printf '# active\n\n**Status:** Active\n' > "$tmp/docs/plans/missing.md"
    printf '# active\n\n**Status:** Active\n' > "$tmp/docs/plans/status-report.md"
    printf '# active\n\n**Status:** Active' > "$tmp/docs/plans/unterminated.md"
    MANIFOLD_PLAN_ROOT="$tmp" bash "$0" >/dev/null
    # Empty plans is a valid steady state; an absent directory is not.
    rm "$tmp/docs/plans/closed.md" "$tmp/docs/plans/missing.md" "$tmp/docs/plans/status-report.md" "$tmp/docs/plans/unterminated.md"
    MANIFOLD_PLAN_ROOT="$tmp" bash "$0" >/dev/null
    rm -rf "$tmp/docs/plans"
    if MANIFOLD_PLAN_ROOT="$tmp" bash "$0" >/dev/null 2>&1; then
        echo "self-test failed: absent plans directory was accepted" >&2; exit 1
    fi
    echo "✓ lint-plan-status self-test: red fixture and healthy control passed"
    exit 0
fi

plans="$REPO_ROOT/docs/plans"
if [[ ! -d "$plans" || ! -r "$plans" || ! -x "$plans" ]]; then
    echo "::error::docs/plans is absent or unreadable at $plans; lifecycle audit would be inert" >&2
    exit 1
fi

failures=0
if ! plan_list="$(find "$plans" -maxdepth 1 -type f -name '*.md' -print)"; then
    echo "::error::could not enumerate $plans; lifecycle audit would be inert" >&2
    exit 1
fi
while IFS= read -r plan; do
    [[ -n "$plan" ]] || continue # an empty plans directory is valid
    [[ "$(basename "$plan")" == "README.md" ]] && continue
    status=""
    line_no=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))
        [[ "$line_no" -gt 20 ]] && break
        if [[ "$line" =~ ^[[:space:]]*(\>[[:space:]]*)*(\*\*)?Status([^[:alnum:]_]|$) ]] && [[ "$line" == *:* ]]; then
            status="$line"; break
        fi
    done < "$plan"
    if [[ -z "$status" ]]; then
        echo "::error file=${plan#$REPO_ROOT/}::missing Status: line in first 20 lines" >&2
        failures=$((failures + 1)); continue
    fi
    value="${status#*:}"
    value="${value#\*\*}"
    normalized="$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//')"
    if printf '%s' "$normalized" | /usr/bin/grep -Eq '^(closed|complete|completed|superseded|rejected|executed|done)([^[:alpha:]]|$)'; then
        echo "::error file=${plan#$REPO_ROOT/}::terminal lifecycle status remains in live plans directory: $value" >&2
        failures=$((failures + 1))
    fi
    if ! shallow="$(git -C "$REPO_ROOT" rev-parse --is-shallow-repository 2>/dev/null)"; then
        shallow="unknown"
    fi
    if ! timestamp="$(git -C "$REPO_ROOT" log -1 --format=%ct -- "$plan" 2>/dev/null)"; then
        timestamp=""
    fi
    if [[ "$shallow" != "false" || -z "$timestamp" || ! "$timestamp" =~ ^[0-9]+$ ]]; then
        echo "::warning file=${plan#$REPO_ROOT/}::plan age unknown; stale-age check intentionally not evaluated" >&2
    fi
done <<< "$plan_list"

if [[ "$failures" -gt 0 ]]; then exit 1; fi
echo "✓ live plan lifecycle statuses are valid (empty docs/plans is allowed)."
