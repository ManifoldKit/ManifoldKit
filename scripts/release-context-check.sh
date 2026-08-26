#!/bin/bash
# release-context-check.sh — strict SemVer comparison used by lint.yml's
# release-only gates.
#
# `version.txt` must be strictly newer than the latest published tag before a
# run is allowed to dispatch companion canaries or require migration-note rows
# to be flipped. String inequality is not that predicate: it treats an older
# version as a release and cannot reject malformed values. Keep the comparison
# here, rather than in the workflow's inline shell, so XCTest can execute the
# exact fail-closed implementation against regression fixtures.
#
# Usage:
#   scripts/release-context-check.sh --is-strictly-greater CURRENT LATEST
#
# Output: `true` or `false` on stdout. Invalid SemVer input exits 2 with a
# named diagnostic; callers must treat that as fatal, never as `false`.
set -euo pipefail

usage() {
    echo "Usage: scripts/release-context-check.sh --is-strictly-greater CURRENT LATEST" >&2
}

if [[ $# -ne 3 || "$1" != "--is-strictly-greater" ]]; then
    usage
    exit 2
fi

# Python 3 is present on GitHub's Ubuntu runner and keeps SemVer 2.0.0's
# prerelease ordering legible. Bash 3.2 has no reliable native list handling
# for the numeric-versus-identifier precedence rule.
python3 - "$2" "$3" <<'PYEOF'
import re
import sys

NUMERIC_IDENTIFIER = r"(?:0|[1-9][0-9]*)"
# A non-numeric identifier may contain digits, but must contain at least one
# letter or hyphen. That prevents `01` from taking this alternate route around
# SemVer's no-leading-zero rule for numeric prerelease identifiers.
NON_NUMERIC_IDENTIFIER = r"(?:[0-9A-Za-z-]*[A-Za-z-][0-9A-Za-z-]*)"
PRERELEASE_IDENTIFIER = rf"(?:{NUMERIC_IDENTIFIER}|{NON_NUMERIC_IDENTIFIER})"
SEMVER = re.compile(
    rf"^(?P<major>{NUMERIC_IDENTIFIER})\.(?P<minor>{NUMERIC_IDENTIFIER})\.(?P<patch>{NUMERIC_IDENTIFIER})"
    rf"(?:-(?P<prerelease>{PRERELEASE_IDENTIFIER}(?:\.{PRERELEASE_IDENTIFIER})*))?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)


def parse(value: str):
    match = SEMVER.fullmatch(value)
    if not match:
        raise ValueError(value)
    return (
        tuple(int(match.group(name)) for name in ("major", "minor", "patch")),
        match.group("prerelease"),
    )


def compare_prerelease(left, right):
    # A normal release has higher precedence than its prereleases.
    if left is None:
        return 0 if right is None else 1
    if right is None:
        return -1

    left_parts = left.split(".")
    right_parts = right.split(".")
    for left_part, right_part in zip(left_parts, right_parts):
        if left_part == right_part:
            continue
        left_numeric = left_part.isdigit()
        right_numeric = right_part.isdigit()
        if left_numeric and right_numeric:
            return 1 if int(left_part) > int(right_part) else -1
        if left_numeric != right_numeric:
            return -1 if left_numeric else 1
        return 1 if left_part > right_part else -1
    return (len(left_parts) > len(right_parts)) - (len(left_parts) < len(right_parts))


def compare(left, right):
    left_core, left_prerelease = parse(left)
    right_core, right_prerelease = parse(right)
    if left_core != right_core:
        return 1 if left_core > right_core else -1
    return compare_prerelease(left_prerelease, right_prerelease)


try:
    result = compare(sys.argv[1], sys.argv[2])
except ValueError as error:
    print(f"::error::Invalid strict SemVer value: {error.args[0]!r}.", file=sys.stderr)
    sys.exit(2)

print("true" if result > 0 else "false")
PYEOF
