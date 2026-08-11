#!/usr/bin/env bash

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXAMPLE_DIR="$REPO_ROOT/Example"
PROJECT="Advanced.xcodeproj"
SCHEME="Advanced"
# DerivedData (incl. SourcePackages) must live OUTSIDE the repo root because
# the repo root is a local SwiftPM package in the example projects' graphs —
# in-repo DerivedData retriggers package resolution in an infinite loop (bit
# 2026-08-10/11, ~5h wedges). Override with --derived-data-path below.
DERIVED_DATA_PATH="${MANIFOLD_DD_ROOT:-$HOME/Library/Caches/ManifoldKit}/AdvancedUITests-$(basename "$REPO_ROOT")"

usage() {
    cat <<'EOF'
Usage:
  scripts/example-ui-tests.sh build-for-testing [xcodebuild args...]
  scripts/example-ui-tests.sh test-without-building [xcodebuild args...]
  scripts/example-ui-tests.sh test [xcodebuild args...]
  scripts/example-ui-tests.sh show-destination

Options:
  --destination 'platform=iOS Simulator,id=<SIMULATOR_ID>'
  --destination 'platform=macOS'
  --macos                          Shorthand for --destination 'platform=macOS'
  --derived-data-path <path>

Examples:
  scripts/example-ui-tests.sh build-for-testing
  scripts/example-ui-tests.sh test-without-building -only-testing:AdvancedUITests/ChatFlowUITests/testEmptyStateShowsWelcome
  scripts/example-ui-tests.sh test-without-building --destination 'platform=iOS Simulator,id=<SIMULATOR_ID>' -only-testing:AdvancedUITests/SettingsUITests
  scripts/example-ui-tests.sh build-for-testing --macos
  scripts/example-ui-tests.sh test-without-building --macos -only-testing:AdvancedUITests/ChatFlowUITests/testEmptyStateShowsWelcome

The default destination is the first booted iPhone simulator. If none are booted,
the script falls back to the first available iPhone simulator, then the first
available iPad simulator. Pass --macos to target macOS instead.
EOF
}

extract_simulator_id() {
    printf '%s\n' "$1" | sed -E 's/.*\(([0-9A-F-]{36})\) \((Booted|Shutdown|Creating|Booting)\)[[:space:]]*$/\1/'
}

extract_simulator_name() {
    printf '%s\n' "$1" | sed -E 's/^[[:space:]]+(.+) \([0-9A-F-]{36}\) \((Booted|Shutdown|Creating|Booting)\)[[:space:]]*$/\1/'
}

pick_simulator_line() {
    xcrun simctl list devices available | grep -E "$1" | head -n 1 || true
}

resolve_destination() {
    local line=""

    line="$(pick_simulator_line '^[[:space:]]+iPhone .*\([0-9A-F-]{36}\) \(Booted\)[[:space:]]*$')"
    if [[ -z "$line" ]]; then
        line="$(pick_simulator_line '^[[:space:]]+iPhone .*\([0-9A-F-]{36}\) \((Shutdown|Creating|Booting)\)[[:space:]]*$')"
    fi
    if [[ -z "$line" ]]; then
        line="$(pick_simulator_line '^[[:space:]]+iPad .*\([0-9A-F-]{36}\) \((Booted|Shutdown|Creating|Booting)\)[[:space:]]*$')"
    fi
    if [[ -z "$line" ]]; then
        echo "No available iOS Simulator destination found." >&2
        echo "Run 'xcrun simctl list devices available' and pass --destination manually." >&2
        exit 1
    fi

    local simulator_id simulator_name
    simulator_id="$(extract_simulator_id "$line")"
    simulator_name="$(extract_simulator_name "$line")"
    DESTINATION="platform=iOS Simulator,id=$simulator_id"

    echo "Using simulator: $simulator_name ($simulator_id)" >&2
}

if [[ $# -eq 0 ]]; then
    usage
    exit 1
fi

COMMAND="$1"
shift

DESTINATION=""
EXTRA_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --destination)
            [[ $# -ge 2 ]] || { echo "--destination requires a value" >&2; exit 1; }
            DESTINATION="$2"
            shift 2
            ;;
        --macos)
            DESTINATION="platform=macOS"
            shift
            ;;
        --derived-data-path)
            [[ $# -ge 2 ]] || { echo "--derived-data-path requires a value" >&2; exit 1; }
            DERIVED_DATA_PATH="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            EXTRA_ARGS+=("$1")
            shift
            ;;
    esac
done

case "$COMMAND" in
    build-for-testing|test-without-building|test)
        ;;
    show-destination)
        if [[ -z "$DESTINATION" ]]; then
            resolve_destination
        fi
        printf '%s\n' "$DESTINATION"
        exit 0
        ;;
    *)
        usage
        exit 1
        ;;
esac

if [[ -z "$DESTINATION" ]]; then
    resolve_destination
fi

mkdir -p "$DERIVED_DATA_PATH"

cd "$EXAMPLE_DIR"

echo "Derived data: $DERIVED_DATA_PATH"
echo "Destination:  $DESTINATION"
echo "Command:      xcodebuild -project $PROJECT -scheme $SCHEME -derivedDataPath $DERIVED_DATA_PATH $COMMAND ${EXTRA_ARGS[*]+"${EXTRA_ARGS[*]}"}"

# Xcode's SPM workspace integration intermittently aborts during package
# resolution with an uncaught NSInvalidArgumentException ("count of array (15)
# differs from count of index set (14)", inside IDESPMWorkspaceDelegate) — the
# process dies with Abort trap: 6 before a single file compiles, so it says
# nothing about the Example app's own code. It hit every weekly smoke run from
# 2026-05-18 through 2026-07-20 (#2341), turning a permanently-red lane into
# pure noise. scripts/demo-apps-build.sh already retries once on this exact
# signature; mirror it here. A real build or test failure does NOT match the
# signature and still fails on the first attempt, without a retry.
XCODEBUILD_FLAKE_SIGNATURE="NSInvalidArgumentException"
RUN_LOG="$(mktemp -t example-ui-tests)"
trap 'rm -f "$RUN_LOG"' EXIT

attempt_xcodebuild() {
    xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -derivedDataPath "$DERIVED_DATA_PATH" \
        -destination "$DESTINATION" \
        "$COMMAND" \
        "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" 2>&1 | tee "$RUN_LOG"
    return "${PIPESTATUS[0]}"
}

if attempt_xcodebuild; then
    exit 0
fi

if grep -q "$XCODEBUILD_FLAKE_SIGNATURE" "$RUN_LOG"; then
    echo ">> xcodebuild crashed during package resolution (flaky) — retrying once..." >&2
    if attempt_xcodebuild; then
        exit 0
    fi
fi

exit 1
