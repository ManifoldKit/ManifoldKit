#!/usr/bin/env bash
# audit-availability.sh — Flags @available / #available annotations that exceed
# the Package.swift platform floors (macOS 15 / iOS 18) in targets that are not
# explicitly elevated to a higher OS floor.
#
# ManifoldKit targets n-1 (macOS 15 / iOS 18). Any usage of
#   @available(macOS 16+, *)   or   #available(iOS 19+, *)
# in general source files indicates either:
#   (a) a real violation — we're gating on an API that doesn't exist at the floor, or
#   (b) a legitimate Foundation Models guard — confined to ManifoldFoundation /
#       ManifoldFoundationUmbrella (iOS 26 / macOS 26+ targets), which are exempted.
#
# Allowed exceptions beyond (b):
#   - @available(*, deprecated/unavailable/renamed/message ...) — these are
#     deprecation markers, not OS-version gates; they carry no availability floor.
#   - @available(iOS 18, macOS 15, *) at exactly the floor — always fine.
#   - Comments (lines beginning with // or containing #available inside a comment)
#     are skipped because they carry no runtime meaning.
#
# The script intentionally accepts iOS 26 / macOS 26 annotations in files outside
# ManifoldFoundation because several modules check for Foundation Models
# availability via `if #available(iOS 26, macOS 26, *)` before calling into the
# ManifoldFoundation target. These are runtime guards, not compile-time policy
# violations — the package still compiles on iOS 18 / macOS 15, and the
# `#available` check is the correct pattern for conditional code paths.
#
# Usage:
#   bash scripts/audit-availability.sh        # pass/fail, no output on success
#   AVAILABILITY_AUDIT_VERBOSE=1 \
#     bash scripts/audit-availability.sh      # show all scanned lines
#
# Exit 0 when no violations are found, exit 1 otherwise.
#
# ── Floor versions ─────────────────────────────────────────────────────────
# Keep in sync with Package.swift `platforms:` block.
#
#   .iOS(.v18)    → floor = 18
#   .macOS(.v15)  → floor = 15
#
# When Apple ships a new major OS and ManifoldKit bumps the floor, increment
# FLOOR_IOS and FLOOR_MACOS here as well.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCES_DIR="${REPO_ROOT}/Sources"

FLOOR_IOS=18
FLOOR_MACOS=15

# ── Excluded paths ─────────────────────────────────────────────────────────
# ManifoldFoundation and its umbrella re-export are explicitly gated to
# iOS 26 / macOS 26 — all availability annotations inside them are intentional.
EXCLUDE_DIRS=(
    "${SOURCES_DIR}/ManifoldFoundation"
    "${SOURCES_DIR}/ManifoldFoundationUmbrella"
)

verbose="${AVAILABILITY_AUDIT_VERBOSE:-0}"

violations=0
files_scanned=0

# Build the find(1) exclude expression.
# Each excluded dir becomes: -path "<dir>/*" -prune -o
find_excludes=()
for excl in "${EXCLUDE_DIRS[@]}"; do
    find_excludes+=( -path "${excl}/*" -prune -o )
done

# Collect all Swift files (respecting excludes).
while IFS= read -r swift_file; do
    files_scanned=$((files_scanned + 1))

    line_no=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line_no=$((line_no + 1))

        # Skip pure comment lines — availability in comments carries no meaning.
        trimmed="${line#"${line%%[![:space:]]*}"}"   # ltrim
        if [[ "${trimmed}" == //* ]]; then
            continue
        fi

        # ── @available(OS X, *) pattern ────────────────────────────────────
        # Matches: @available(iOS NN, *) or @available(macOS NN, *)
        # Does NOT match: @available(*, deprecated...) — those lack an OS name first.
        #
        # We extract the (platform, version) pairs.  A single @available clause
        # can combine multiple platforms, e.g. @available(iOS 26, macOS 26, *).
        # We check every (platform, version) pair in the clause independently.
        if printf '%s' "$line" | grep -qE '@available\([[:space:]]*(macOS|iOS)[[:space:]]+[0-9]+'; then
            # Extract "macOS NN" / "iOS NN" tokens from the @available(...) clause.
            while IFS= read -r token; do
                [[ -z "$token" ]] && continue
                plat="${token%% *}"
                ver="${token#* }"
                ver="${ver%%[^0-9]*}"   # strip trailing non-digit noise

                if [[ -z "$ver" ]] || [[ -z "$plat" ]]; then
                    continue
                fi

                # Determine the floor for this platform.
                floor=""
                case "$plat" in
                    iOS)   floor=$FLOOR_IOS  ;;
                    macOS) floor=$FLOOR_MACOS ;;
                    *)     continue ;;
                esac

                if (( ver > floor )); then
                    # iOS 26 / macOS 26 annotations outside ManifoldFoundation
                    # are legitimate runtime guards for Foundation Models feature
                    # detection — skip them.
                    if [[ "$plat" == "iOS"   && "$ver" -eq 26 ]] || \
                       [[ "$plat" == "macOS" && "$ver" -eq 26 ]]; then
                        [[ "$verbose" == "1" ]] && echo "  skipped (Foundation guard): ${swift_file}:${line_no}: ${line}"
                        continue
                    fi

                    rel_file="${swift_file#"${REPO_ROOT}/"}"
                    echo "::error file=${rel_file},line=${line_no}::@available(${plat} ${ver}, *) exceeds floor ${plat} ${floor} — ${rel_file}:${line_no}:"
                    printf '  %s\n' "$line"
                    violations=$((violations + 1))
                fi
            done < <(printf '%s' "$line" | grep -oE '(macOS|iOS)[[:space:]]+[0-9]+')
        fi

        # ── #available(OS X, *) pattern ─────────────────────────────────────
        # Same logic for runtime checks — flags them if the checked version
        # exceeds the floor and is not a legitimate iOS/macOS 26 Foundation guard.
        if printf '%s' "$line" | grep -qE '#available\([[:space:]]*(macOS|iOS)[[:space:]]+[0-9]+'; then
            while IFS= read -r token; do
                [[ -z "$token" ]] && continue
                plat="${token%% *}"
                ver="${token#* }"
                ver="${ver%%[^0-9]*}"

                if [[ -z "$ver" ]] || [[ -z "$plat" ]]; then
                    continue
                fi

                floor=""
                case "$plat" in
                    iOS)   floor=$FLOOR_IOS  ;;
                    macOS) floor=$FLOOR_MACOS ;;
                    *)     continue ;;
                esac

                if (( ver > floor )); then
                    # iOS 26 / macOS 26 #available checks are the standard pattern
                    # for opt-in Foundation Models paths — skip them.
                    if [[ "$plat" == "iOS"   && "$ver" -eq 26 ]] || \
                       [[ "$plat" == "macOS" && "$ver" -eq 26 ]]; then
                        [[ "$verbose" == "1" ]] && echo "  skipped (Foundation guard): ${swift_file}:${line_no}: ${line}"
                        continue
                    fi

                    rel_file="${swift_file#"${REPO_ROOT}/"}"
                    echo "::error file=${rel_file},line=${line_no}::#available(${plat} ${ver}, *) exceeds floor ${plat} ${floor} — ${rel_file}:${line_no}:"
                    printf '  %s\n' "$line"
                    violations=$((violations + 1))
                fi
            done < <(printf '%s' "$line" | grep -oE '(macOS|iOS)[[:space:]]+[0-9]+')
        fi

    done < "$swift_file"
done < <(find "${SOURCES_DIR}" "${find_excludes[@]}" -name "*.swift" -print)

echo ""
echo "Scanned ${files_scanned} Swift file(s) under Sources/ (excluding ManifoldFoundation*)."

if [[ $violations -gt 0 ]]; then
    echo ""
    echo "::error::audit-availability.sh found ${violations} availability annotation(s) that exceed the platform floor (macOS ${FLOOR_MACOS} / iOS ${FLOOR_IOS})."
    echo ""
    echo "Remediation options:"
    echo "  1. Lower the version to the floor if the annotation is wrong."
    echo "  2. If the annotation gates a Foundation Models feature, move the source"
    echo "     file into Sources/ManifoldFoundation (or wrap in #if canImport(...))."
    echo "  3. If the annotation guards a different OS-version API above the floor,"
    echo "     add a comment explaining why and extend the EXEMPT list in this script."
    exit 1
fi

echo "✓ No availability annotations exceed the platform floor."
