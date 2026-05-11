#!/usr/bin/env bash
# scripts/test-ios-simulator.sh — Run ModelContainerFileProtectionTests on an
# iOS simulator via xcodebuild.
#
# Why this exists
# ---------------
# NSFileProtectionComplete / NSFileProtectionCompleteUntilFirstUserAuthentication
# are iOS kernel features.  The four tests in ModelContainerFileProtectionTests
# are guarded by a compile-time `#if os(iOS)` (and skip on macOS/Catalyst), so
# the normal `swift test` CI lane — which targets macOS — never exercises them.
# xcodebuild against an iOS Simulator destination compiles the bundle as iOS,
# making the guard false and the tests actually run.
#
# Simulator selection
# -------------------
# CI uses `name=iPhone 16` (available on every Xcode 26.x macOS-15 runner).
# Locally the script picks the first booted iPhone simulator, falling back to
# any available iPhone simulator.  Pass --destination to override both.
#
# Usage
# -----
#   scripts/test-ios-simulator.sh                    # auto-pick simulator
#   scripts/test-ios-simulator.sh --destination 'platform=iOS Simulator,name=iPhone 16'
#   scripts/test-ios-simulator.sh --ci               # force CI name= form

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SCHEME="ManifoldPersistenceSwiftDataTests"
TEST_TARGET="ManifoldPersistenceSwiftDataTests"
TEST_SUITE="ModelContainerFileProtectionTests"
DERIVED_DATA="$REPO_ROOT/.build/ios-simulator-file-protection-derived"

usage() {
    cat <<'EOF'
Usage:
  scripts/test-ios-simulator.sh [options]

Options:
  --destination '<xcodebuild destination string>'
      Override the simulator destination. Default: auto-pick from simctl.
  --ci
      Use a name= destination suitable for GitHub Actions runners
      (platform=iOS Simulator,name=iPhone 16).
  -h, --help
      Show this help.
EOF
}

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
DESTINATION=""
CI_MODE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --destination)
            [[ $# -ge 2 ]] || { echo "--destination requires a value" >&2; exit 1; }
            DESTINATION="$2"
            shift 2
            ;;
        --ci)
            CI_MODE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Resolve destination
# ---------------------------------------------------------------------------

# Helpers — intentionally mirror example-ui-tests.sh's approach.
extract_simulator_id() {
    printf '%s\n' "$1" \
        | sed -E 's/.*\(([0-9A-F-]{36})\) \((Booted|Shutdown|Creating|Booting)\)[[:space:]]*$/\1/'
}

extract_simulator_name() {
    printf '%s\n' "$1" \
        | sed -E 's/^[[:space:]]+(.+) \([0-9A-F-]{36}\) \((Booted|Shutdown|Creating|Booting)\)[[:space:]]*$/\1/'
}

pick_simulator_line() {
    xcrun simctl list devices available | grep -E "$1" | head -n 1 || true
}

resolve_local_destination() {
    local line=""

    # 1. Prefer a currently-booted iPhone (saves the boot wait).
    line="$(pick_simulator_line '^[[:space:]]+iPhone .*\([0-9A-F-]{36}\) \(Booted\)[[:space:]]*$')"

    # 2. Any available iPhone simulator.
    if [[ -z "$line" ]]; then
        line="$(pick_simulator_line '^[[:space:]]+iPhone .*\([0-9A-F-]{36}\) \((Shutdown|Creating|Booting)\)[[:space:]]*$')"
    fi

    if [[ -z "$line" ]]; then
        echo "No available iPhone simulator found." >&2
        echo "Run 'xcrun simctl list devices available' and pass --destination manually." >&2
        exit 1
    fi

    local sim_id sim_name
    sim_id="$(extract_simulator_id "$line")"
    sim_name="$(extract_simulator_name "$line")"
    DESTINATION="platform=iOS Simulator,id=$sim_id"
    echo "Using simulator: $sim_name ($sim_id)" >&2
}

if [[ -n "$DESTINATION" ]]; then
    echo "Using destination: $DESTINATION" >&2
elif [[ "$CI_MODE" -eq 1 ]]; then
    # GitHub Actions macos-15 runners with Xcode 26.x ship iPhone 16 simulators.
    DESTINATION="platform=iOS Simulator,name=iPhone 16"
    echo "CI mode — destination: $DESTINATION" >&2
else
    resolve_local_destination
fi

# ---------------------------------------------------------------------------
# Build and test
# ---------------------------------------------------------------------------

mkdir -p "$DERIVED_DATA"

echo ""
echo "Scheme:       $SCHEME"
echo "Test suite:   $TEST_TARGET/$TEST_SUITE"
echo "Destination:  $DESTINATION"
echo "Derived data: $DERIVED_DATA"
echo ""

xcodebuild test \
    -scheme "$SCHEME" \
    -destination "$DESTINATION" \
    -derivedDataPath "$DERIVED_DATA" \
    -only-testing:"$TEST_TARGET/$TEST_SUITE" \
    -disableAutomaticPackageResolution
