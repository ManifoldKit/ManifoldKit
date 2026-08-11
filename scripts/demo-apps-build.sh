#!/usr/bin/env bash
#
# Pre-release demo-app build gate.
#
# Builds every example app across the platforms it ships for and prints an
# honest pass/fail summary. Exits non-zero if any configuration fails.
#
#   - Advanced  (iOS Simulator)  — full reference app
#   - Minimal   (iOS Simulator)  — umbrella-import smoke (catches `import
#                                   ManifoldKit` breakage on iOS)
#   - Minimal   (macOS)          — umbrella-import smoke on macOS
#   - LocalInferenceExample_MLX/_Llama (macOS) — companion-package
#     compile proof (#2453 M2): catches drift in the `manifold-mlx` /
#     `manifold-llama` pins and the `quickStart`/`ManifoldBootstrap.build`
#     surface those apps call. Build only — never downloads a model or runs
#     generation; see scripts/example-local-inference.sh for that.
#
# WHY THIS EXISTS, AND WHY IT IS NOT PER-PR:
# The demos consume ManifoldKit by local path, so package-level drift (retired
# traits, renamed modules, changed `quickStart` signatures, iOS-unavailable
# symbols pulled in via the umbrella) breaks them while plain `swift test` —
# which builds for macOS only — stays green. iOS-only API unavailability is
# invisible to the core gate; only an actual iOS build surfaces it. Demo
# breakage is rare and these builds are slow, so this runs at RELEASE TIME,
# not on every PR. Run it before bumping the version (see CLAUDE.md § Release
# workflow); it must be green.
#
# Usage:
#   scripts/demo-apps-build.sh
#   scripts/demo-apps-build.sh --destination 'platform=iOS Simulator,id=<ID>'

set -uo pipefail   # fail-open-ok: NOT -e — we want to run all configs and report every failure

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ADVANCED_DIR="$REPO_ROOT/Example"
MINIMAL_DIR="$REPO_ROOT/Example/Examples"
# DerivedData (incl. SourcePackages) must live OUTSIDE the repo root because
# the repo root is a local SwiftPM package in the example projects' graphs —
# in-repo DerivedData retriggers package resolution in an infinite loop (bit
# 2026-08-10/11, ~5h wedges).
DERIVED_DATA_PATH="${MANIFOLD_DD_ROOT:-$HOME/Library/Caches/ManifoldKit}/DemoAppsGate-$(basename "$REPO_ROOT")"

IOS_DESTINATION="${1:-}"
if [[ "$IOS_DESTINATION" == "--destination" ]]; then
    IOS_DESTINATION="${2:-}"
fi

pick_simulator_line() {
    xcrun simctl list devices available | grep -E "$1" | head -n 1 || true
}

resolve_ios_destination() {
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
    local sim_id sim_name
    sim_id="$(printf '%s\n' "$line" | sed -E 's/.*\(([0-9A-F-]{36})\) \((Booted|Shutdown|Creating|Booting)\)[[:space:]]*$/\1/')"
    sim_name="$(printf '%s\n' "$line" | sed -E 's/^[[:space:]]+(.+) \([0-9A-F-]{36}\) \((Booted|Shutdown|Creating|Booting)\)[[:space:]]*$/\1/')"
    IOS_DESTINATION="platform=iOS Simulator,id=$sim_id"
    echo "Using iOS simulator: $sim_name ($sim_id)" >&2
}

if [[ -z "$IOS_DESTINATION" ]]; then
    resolve_ios_destination
fi

# Bash 3.2 on macOS has no associative arrays — track results in parallel arrays.
NAMES=()
STATUSES=()

# xcodebuild intermittently crashes during the package-graph resolution phase
# with an NSInvalidArgumentException ("insertObjects:atIndexes: count of array
# ... differs from count of index set ...") — a tooling bug that aborts before
# a single file compiles, unrelated to the demo's own code. Retry once on that
# signature so the release gate doesn't emit a false "DO NOT RELEASE". A real
# compile error (no signature match) fails immediately without a retry.
XCODEBUILD_FLAKE_SIGNATURE="NSInvalidArgumentException"

attempt_build() {
    local project_dir="$1" project="$2" scheme="$3" destination="$4" out_log="$5"
    local skip_plugin_validation="${6:-}"
    local extra_args=()
    if [[ -n "$skip_plugin_validation" ]]; then
        # -skipPackagePluginValidation: manifold-mlx's MLXMetallibPlugin is a
        # SwiftPM build-tool plugin. Xcode gates first use of ANY build-tool
        # plugin behind an interactive "Trust & Enable" prompt; headless
        # `xcodebuild` has no prompt to answer, so an unapproved plugin fails
        # as "Validate plug-in ... " with no further diagnostic. This flag is
        # the documented headless/CI bypass for first-party, already-trusted
        # dependencies (`xcodebuild -help`) — NOT a blanket "skip validation
        # for uniformity" choice, so it is passed only for the one scheme
        # that actually links a build-tool plugin (LocalInferenceExample_MLX),
        # never for Advanced/Minimal, which use none.
        extra_args+=("-skipPackagePluginValidation")
    fi
    ( cd "$project_dir" && xcodebuild \
            -project "$project" \
            -scheme "$scheme" \
            -destination "$destination" \
            -derivedDataPath "$DERIVED_DATA_PATH" \
            "${extra_args[@]}" \
            build ) 2>&1 | tee "$out_log"
    return "${PIPESTATUS[0]}"
}

run_build() {
    local name="$1" project_dir="$2" project="$3" scheme="$4" destination="$5"
    local skip_plugin_validation="${6:-}"
    echo
    echo "=================================================================="
    echo ">> $name"
    echo "   project:     $project"
    echo "   scheme:      $scheme"
    echo "   destination: $destination"
    echo "=================================================================="
    local out_log
    out_log="$(mktemp -t demo-apps-build)"

    if attempt_build "$project_dir" "$project" "$scheme" "$destination" "$out_log" "$skip_plugin_validation"; then
        NAMES+=("$name"); STATUSES+=("PASS"); rm -f "$out_log"; return
    fi

    if grep -q "$XCODEBUILD_FLAKE_SIGNATURE" "$out_log"; then
        echo ">> $name: xcodebuild crashed during package resolution (flaky) — retrying once..." >&2
        if attempt_build "$project_dir" "$project" "$scheme" "$destination" "$out_log" "$skip_plugin_validation"; then
            NAMES+=("$name"); STATUSES+=("PASS (retry)"); rm -f "$out_log"; return
        fi
    fi

    NAMES+=("$name"); STATUSES+=("FAIL"); rm -f "$out_log"
}

run_build "Advanced (iOS)"   "$ADVANCED_DIR" "Advanced.xcodeproj"        "Advanced"            "$IOS_DESTINATION"
run_build "Minimal  (iOS)"   "$MINIMAL_DIR"  "ManifoldExamples.xcodeproj" "MinimalExample_iOS"   "$IOS_DESTINATION"
run_build "Minimal  (macOS)" "$MINIMAL_DIR"  "ManifoldExamples.xcodeproj" "MinimalExample_macOS" "platform=macOS"
# LocalInferenceExample (#2453 M2) — macOS-only (MLX/llama.cpp need Metal /
# native process lifecycle the iOS Simulator doesn't provide). This is the
# compile-proof gate only: it never downloads a model or runs generation —
# see scripts/example-local-inference.sh for the opt-in human "real
# download + one chat turn" lane. Only the MLX scheme passes
# skip_plugin_validation=1 — see attempt_build's comment for why.
run_build "Local MLX   (macOS)" "$MINIMAL_DIR" "ManifoldExamples.xcodeproj" "LocalInferenceExample_MLX"   "platform=macOS" "1"
run_build "Local Llama (macOS)" "$MINIMAL_DIR" "ManifoldExamples.xcodeproj" "LocalInferenceExample_Llama" "platform=macOS"

echo
echo "=================================================================="
echo "Demo apps build summary"
echo "=================================================================="
exit_code=0
for i in "${!NAMES[@]}"; do
    printf '  %-18s %s\n' "${NAMES[$i]}" "${STATUSES[$i]}"
    if [[ "${STATUSES[$i]}" == "FAIL" ]]; then
        exit_code=1
    fi
done
echo "=================================================================="
if [[ "$exit_code" -eq 0 ]]; then
    echo "All demo apps built. Safe to bump the release."
else
    echo "One or more demo apps FAILED to build. Do NOT bump the release."
fi
exit "$exit_code"
