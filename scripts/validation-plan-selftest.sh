#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLAN="$ROOT/scripts/validation-plan.sh"
CONSUMER="$ROOT/scripts/ci-selective-test.sh"
failures=0

fail() { echo "FAIL $1" >&2; failures=$((failures + 1)); }
contains() { [[ "$1" == *"$2"* ]] || fail "$3: expected '$2', got '$1'"; }

safe="$(printf '%s\n' Tests/ManifoldUIModelManagementTests/APIEndpointPresentationTests.swift | "$PLAN" 2>/dev/null)"
contains "$safe" 'ManifoldCoreTests@anchor' safe-core-anchor
contains "$safe" 'ManifoldInferenceTests@anchor' safe-inference-anchor
contains "$safe" 'ManifoldUIModelManagementTests@direct' safe-direct-suite
[[ "$safe" != *'@skip='* ]] || fail 'safe plan must retain every test'

mixed="$(printf '%s\n' Tests/ManifoldUIModelManagementTests/APIEndpointPresentationTests.swift .agents/known-issues.md | "$PLAN" 2>/dev/null)"
[[ "$mixed" == "$safe" ]] || fail "known ignored path changed resolver routing: safe='$safe' mixed='$mixed'"

empty="$(printf '\n' | "$PLAN" 2>/dev/null)"
[[ "$empty" == NONE ]] || fail "blank input must select NONE, got '$empty'"

direct="$(printf '%s\n' Tests/ManifoldCoreTests/ValidationPlanScriptTests.swift | "$PLAN" 2>/dev/null)"
contains "$direct" 'ManifoldCoreTests@direct' direct-core-role

# Eight directly selected suites cross the shared threshold and choose FULL.
broad="$(printf '%s\n' \
  Tests/ManifoldRuntimeTests/A.swift \
  Tests/ManifoldPersistenceSwiftDataTests/A.swift \
  Tests/ManifoldUITests/A.swift \
  Tests/ManifoldUIModelManagementTests/A.swift \
  Tests/ManifoldMCPTests/A.swift \
  Tests/ManifoldNetworkingTests/A.swift \
  Tests/ManifoldTestSupportTests/A.swift \
  Tests/ManifoldTurnLoopCharacterizationTests/A.swift | "$PLAN" 2>/dev/null)"
[[ "$broad" == FULL ]] || fail "eight-suite threshold: got '$broad'"

unknown="$(printf '%s\n' Sources/Unknown/Foo.swift | "$PLAN" 2>/dev/null)"
[[ "$unknown" == FULL ]] || fail "unknown path: got '$unknown'"

set +e
unreadable="$(MANIFOLD_CHANGED_PATHS_FILE="$ROOT/scripts" "$PLAN" 2>/dev/null)"
unreadable_rc=$?
set -e
[[ "$unreadable" == FULL && $unreadable_rc -ne 0 ]] || fail "unreadable input must emit FULL and fail loudly (rc=$unreadable_rc output=$unreadable)"

# Exercise the real selective consumer with a hermetic xcodebuild and assert
# the exact whole-target invocation before checking failure propagation.
fixture="$(mktemp -d "${TMPDIR:-/tmp}/mk-plan-consumer.XXXXXX")"
trap 'rm -r "$fixture"' EXIT
printf '%s\n' '#!/bin/sh' 'echo malformed-plan' > "$fixture/bad-resolver"
printf '%s\n' '#!/bin/sh' 'exit 23' > "$fixture/failing-resolver"
chmod +x "$fixture/bad-resolver" "$fixture/failing-resolver"
for resolver in bad-resolver failing-resolver; do
  set +e
  resolver_output="$(printf '%s\n' Tests/ManifoldUITests/A.swift \
    | MANIFOLD_AFFECTED_SUITES_SCRIPT="$fixture/$resolver" "$PLAN" 2>/dev/null)"
  resolver_rc=$?
  set -e
  [[ "$resolver_output" == FULL && $resolver_rc -ne 0 ]] \
    || fail "$resolver must emit FULL and fail loudly (rc=$resolver_rc output=$resolver_output)"
done

printf '%s\n' '#!/bin/sh' 'printf '\''%s\n'\'' "$*" > "$FAKE_XCODEBUILD_LOG"' 'exit "${FAKE_XCODEBUILD_EXIT:-0}"' > "$fixture/xcodebuild"
chmod +x "$fixture/xcodebuild"
set +e
FAKE_XCODEBUILD_LOG="$fixture/argv" PATH="$fixture:$PATH" \
  "$CONSUMER" 'ManifoldCoreTests@anchor' > "$fixture/success-output" 2>&1
success_rc=$?
set -e
[[ $success_rc -eq 0 ]] || fail "selective consumer rejected valid role (rc=$success_rc)"
expected_argv='test -scheme ManifoldCoreTests -destination platform=macOS,arch=arm64'
actual_argv=''
if [[ -f "$fixture/argv" ]]; then
  actual_argv="$(cat "$fixture/argv")"
fi
[[ "$actual_argv" == "$expected_argv" ]] || fail "consumer argv: expected '$expected_argv', got '$actual_argv'"

set +e
FAKE_XCODEBUILD_LOG="$fixture/failure-argv" \
FAKE_XCODEBUILD_EXIT="${MANIFOLD_SELFTEST_FAKE_XCODEBUILD_EXIT:-17}" \
PATH="$fixture:$PATH" "$CONSUMER" 'ManifoldCoreTests@anchor' > "$fixture/output" 2>&1
consumer_rc=$?
set -e
[[ $consumer_rc -ne 0 ]] || fail 'selective consumer swallowed failing xcodebuild'
failure_argv=''
if [[ -f "$fixture/failure-argv" ]]; then
  failure_argv="$(cat "$fixture/failure-argv")"
fi
[[ "$failure_argv" == "$expected_argv" ]] || fail "failing consumer did not execute expected command: '$failure_argv'"

set +e
"$CONSUMER" 'ManifoldCoreTests@unknown-role' > /dev/null 2>&1
role_rc=$?
set -e
[[ $role_rc -ne 0 ]] || fail 'selective consumer accepted an unknown role'

if [[ $failures -ne 0 ]]; then
  echo "validation-plan self-test: FAIL ($failures)" >&2
  exit 1
fi
echo "validation-plan self-test: PASS"
