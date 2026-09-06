#!/usr/bin/env bash
# Produce the selective test execution plan used by local preflight and CI.
# Unknown state prints FULL and exits non-zero so callers cannot confuse an
# operational failure with a valid empty diff.

set -uo pipefail # fail-open-ok: planner uncertainty deliberately becomes FULL

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOLVER="${MANIFOLD_AFFECTED_SUITES_SCRIPT:-$ROOT/scripts/affected-suites.sh}"
CHANGED_PATHS_INPUT="${MANIFOLD_CHANGED_PATHS_FILE:-/dev/stdin}"

report_toolchain() {
  local expected="${1:-}" xcode="unavailable" swift="unavailable" sdk="unavailable" os="unavailable"
  command -v xcodebuild >/dev/null 2>&1 && xcode="$(xcodebuild -version | tr '\n' ' ')"
  command -v xcrun >/dev/null 2>&1 && {
    swift="$(xcrun swift -version 2>/dev/null | head -n 1)"
    sdk="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo unavailable)"
  }
  command -v sw_vers >/dev/null 2>&1 && os="$(sw_vers -productVersion 2>/dev/null || echo unavailable)"
  printf 'validation toolchain: xcode="%s" swift="%s" macos-sdk="%s" host-os="%s"\n' "$xcode" "$swift" "$sdk" "$os"
  if [[ -n "$expected" ]]; then
    case "$xcode" in
      "Xcode $expected "*) echo "validation toolchain parity: MATCH expected-xcode=$expected" ;;
      *) echo "validation toolchain parity: MISMATCH expected-xcode=$expected" ;;
    esac
  fi
}

if [[ "${1:-}" == "--report-toolchain" ]]; then
  [[ "${2:-}" == "--expected-xcode" || -z "${2:-}" ]] || { echo "error: expected --expected-xcode <version>" >&2; exit 64; }
  [[ -z "${2:-}" || -n "${3:-}" ]] || { echo "error: --expected-xcode needs a version" >&2; exit 64; }
  report_toolchain "${3:-}"
  exit 0
fi

changed_file="$(mktemp "${TMPDIR:-/tmp}/mk-plan-input.XXXXXX")" || { echo "error: could not allocate changed-path input; selecting FULL" >&2; echo FULL; exit 74; }
trap 'rm -f "$changed_file"' EXIT
grep -v '^[[:space:]]*$' "$CHANGED_PATHS_INPUT" > "$changed_file"
read_rc=$?
if [[ $read_rc -ge 2 ]]; then
  echo "error: could not read changed paths; selecting FULL" >&2
  echo FULL
  exit 74
fi
[[ -s "$changed_file" ]] || { echo NONE; exit 0; }

roles="$(MANIFOLD_EVENT_NAME="${MANIFOLD_EVENT_NAME:-pull_request}" \
  "$RESOLVER" --roles < "$changed_file")" || { echo "error: affected-suite resolver failed; selecting FULL" >&2; echo FULL; exit 74; }
[[ -n "$roles" ]] || { echo "error: affected-suite resolver returned no plan; selecting FULL" >&2; echo FULL; exit 74; }
[[ "$roles" == FULL || "$roles" == NONE ]] && { echo "$roles"; exit 0; }

output=""
non_anchor_count=0
for record in $roles; do
  case "$record" in
    *@direct|*@anchor) ;;
    *) echo "error: malformed suite role '$record'; selecting FULL" >&2; echo FULL; exit 74 ;;
  esac
  suite="${record%@*}"; role="${record#*@}"
  [[ "$role" == "direct" ]] && non_anchor_count=$((non_anchor_count + 1))
  output="${output}${output:+ }${record}"
done
if [[ $non_anchor_count -ge 8 ]]; then
  echo "FULL"
  exit 0
fi
printf '%s\n' "$output"
