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
# Both CI and local runs inspect the active Xcode simulator inventory. The
# resolver selects an available iPhone whose runtime is between Package.swift's
# iOS deployment floor and the active iOS Simulator SDK, preferring a booted
# device and then the newest compatible runtime. Pass --destination to override.
#
# Usage
# -----
#   scripts/test-ios-simulator.sh                    # auto-pick simulator
#   scripts/test-ios-simulator.sh --destination 'platform=iOS Simulator,id=<UDID>'
#   scripts/test-ios-simulator.sh --ci               # CI inventory selection

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
      Resolve an eligible installed iPhone from the GitHub Actions simulator
      inventory. The explicit --destination override still wins.
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

# The deployment floor is the lower bound for a runnable simulator. Keep this
# derived from the manifest so the gate fails loudly when a future floor bump
# has no matching installed runtime instead of silently testing an older OS.
ios_deployment_floor() {
    local floor
    floor="$(sed -nE 's/^[[:space:]]*\.iOS\("([0-9]+(\.[0-9]+)*)"\),?[[:space:]]*$/\1/p' Package.swift | head -n 1)"
    if [[ -z "$floor" ]]; then
        echo "Could not read the iOS deployment floor from Package.swift." >&2
        return 1
    fi
    printf '%s\n' "$floor"
}

# `xcodebuild -showsdks` reflects the selected Xcode, rather than a runtime
# that another Xcode installation may have left visible to CoreSimulator.
ios_simulator_sdk_version() {
    local sdks version
    if ! sdks="$(xcodebuild -showsdks)"; then
        echo "Could not read the active iOS Simulator SDK from xcodebuild -showsdks." >&2
        return 1
    fi
    version="$(printf '%s\n' "$sdks" | sed -nE 's/.*-sdk[[:space:]]+iphonesimulator([0-9]+(\.[0-9]+)*).*/\1/p' | head -n 1)"
    if [[ -z "$version" ]]; then
        echo "Could not read the active iOS Simulator SDK from xcodebuild -showsdks." >&2
        return 1
    fi
    printf '%s\n' "$version"
}

resolve_inventory_destination() {
    local minimum_os maximum_os simctl_json selection
    if ! minimum_os="$(ios_deployment_floor)"; then
        return 1
    fi
    if ! maximum_os="$(ios_simulator_sdk_version)"; then
        return 1
    fi
    if ! simctl_json="$(xcrun simctl list devices available -j)"; then
        echo "Could not read the available iOS Simulator inventory from simctl." >&2
        return 1
    fi

    if ! selection="$(printf '%s' "$simctl_json" | python3 -c '
import json
import re
import sys

minimum = tuple(int(part) for part in sys.argv[1].split("."))
maximum = tuple(int(part) for part in sys.argv[2].split("."))

def comparable(version):
    return version + (0,) * (3 - len(version))

def runtime_version(runtime):
    match = re.search(r"\.iOS-([0-9]+(?:-[0-9]+)*)$", runtime)
    if match is None:
        return None
    return tuple(int(part) for part in match.group(1).split("-"))

try:
    inventory = json.load(sys.stdin)
    runtimes = inventory["devices"]
except (KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
    raise SystemExit(f"Malformed simctl device inventory: {error}")

candidates = []
seen_iPhones = []
for runtime, devices in runtimes.items():
    version = runtime_version(runtime)
    if version is None:
        continue
    for device in devices:
        name = device.get("name", "")
        if not name.startswith("iPhone "):
            continue
        seen_iPhones.append("{} (iOS {})".format(name, ".".join(map(str, version))))
        if device.get("isAvailable", True) is False or device.get("availabilityError"):
            continue
        state = device.get("state", "Shutdown")
        if state not in {"Booted", "Shutdown", "Creating", "Booting"}:
            continue
        if not (comparable(minimum) <= comparable(version) <= comparable(maximum)):
            continue
        udid = device.get("udid")
        if not isinstance(udid, str) or not udid:
            continue
        candidates.append((state != "Booted", tuple(-part for part in comparable(version)), name.lower(), udid, name, version, state))

if not candidates:
    installed = ", ".join(sorted(set(seen_iPhones))) or "none"
    raise SystemExit(
        "No available iPhone simulator satisfies iOS "
        f"{sys.argv[1]} through {sys.argv[2]}. Installed iPhones: {installed}"
    )

_, _, _, udid, name, version, state = sorted(candidates)[0]
print("{}\t{}\t{}\t{}".format(udid, name, ".".join(map(str, version)), state))
' "$minimum_os" "$maximum_os")"; then
        return 1
    fi

    local sim_id sim_name sim_runtime sim_state
    IFS=$'\t' read -r sim_id sim_name sim_runtime sim_state <<< "$selection"
    if [[ -z "$sim_id" || -z "$sim_name" || -z "$sim_runtime" || -z "$sim_state" ]]; then
        echo "Simulator selector returned malformed destination data." >&2
        return 1
    fi
    DESTINATION="platform=iOS Simulator,id=$sim_id"
    echo "Using iOS simulator: $sim_name ($sim_id), iOS $sim_runtime ($sim_state)" >&2
}

if [[ -n "$DESTINATION" ]]; then
    echo "Using destination: $DESTINATION" >&2
elif [[ "$CI_MODE" -eq 1 ]]; then
    echo "CI mode — resolving an eligible installed iPhone." >&2
    resolve_inventory_destination
else
    resolve_inventory_destination
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
