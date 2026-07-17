#!/usr/bin/env bash
#
# affected-suites-test.sh — regression coverage for scripts/affected-suites.sh's
# selection rules, run under bash 3.2 semantics (macOS ships bash 3.2 as
# /bin/bash; CI runners do too — #2099/#2248).
#
# Principle 4 ("every rule has a tripwire, and the tripwires are tested"):
# the runtime-filesystem-scan force rules added for issue #2290 are exactly
# the kind of rule that silently rots if nothing re-checks it on a future
# edit to the resolver. This script is that tripwire.
#
# Each case pipes a synthetic changed-path list into affected-suites.sh (via
# MANIFOLD_GRAPH_FILE pointed at the real committed snapshot, so target-path
# lookups resolve against the real graph) and asserts the exact stdout line.
#
# Exit codes: 0 all cases pass; 1 at least one case failed (full diff printed).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESOLVER="$SCRIPT_DIR/affected-suites.sh"
export MANIFOLD_GRAPH_FILE="$SCRIPT_DIR/affected-suites-graph.json"
export MANIFOLD_EVENT_NAME="pull_request"

failures=0
cases_run=0

# run_case NAME EXPECTED CHANGED_PATH...
run_case() {
  local name="$1" expected="$2"
  shift 2
  local actual
  actual="$(printf '%s\n' "$@" | bash "$RESOLVER" 2>/dev/null)"
  cases_run=$((cases_run + 1))
  if [[ "$actual" != "$expected" ]]; then
    failures=$((failures + 1))
    echo "FAIL: $name"
    echo "  changed paths: $*"
    echo "  expected:      $expected"
    echo "  actual:        $actual"
  else
    echo "PASS: $name"
  fi
}

# ---------------------------------------------------------------------------
# 1. The #2212 regression shape (issue #2290's proof case): a new *Audit*.swift
#    test file lands in a target ManifoldCoreTests does not depend on
#    (ManifoldPersistenceSwiftDataTests). Before the fix this resolved to
#    ManifoldPersistenceSwiftDataTests alone — the audit that enforces
#    sabotage coverage never ran. It must now also force ManifoldCoreTests
#    (and ManifoldInferenceTests, per the Tests/-tree generalisation).
# ---------------------------------------------------------------------------
run_case \
  "new audit file in an unrelated test target forces ManifoldCoreTests + ManifoldInferenceTests" \
  "ManifoldCoreTests ManifoldInferenceTests ManifoldPersistenceSwiftDataTests" \
  "Tests/ManifoldPersistenceSwiftDataTests/SomeNewAuditTest.swift"

# ---------------------------------------------------------------------------
# 2. A plain (non-audit) test file addition in an unrelated suite still hits
#    the same force rule: TestSuiteSilentSkipAuditTest / SwiftTestingAuditTest
#    / UserDefaultsStandardAuditTest scan the ENTIRE Tests/ tree, not just
#    *Audit*.swift files.
# ---------------------------------------------------------------------------
run_case \
  "plain (non-audit) test file change also forces the Tests/-tree audits" \
  "ManifoldCoreTests ManifoldInferenceTests ManifoldPersistenceSwiftDataTests" \
  "Tests/ManifoldPersistenceSwiftDataTests/SomeOrdinaryTest.swift"

# ---------------------------------------------------------------------------
# 3. A Sources/ change in a target well outside ManifoldInference's own
#    closure must still force ManifoldInferenceTests (SilentCatchAuditTest /
#    TrafficBoundaryAuditTest / UnlockedNonisolatedUnsafeTestSeamAuditTest
#    scan the ENTIRE Sources/ tree) and ManifoldBackendsTests
#    (DirectURLSessionConstructionAuditTest, same shape).
# ---------------------------------------------------------------------------
run_case \
  "Sources/ change outside Inference's closure forces the Sources/-tree audits" \
  "APIFreezeTests ManifoldBackendsTests ManifoldInferenceTests ManifoldUIModelManagementTests ManifoldUITests ManifoldVoiceTests" \
  "Sources/ManifoldUI/SomeView.swift"

# ---------------------------------------------------------------------------
# 4. Docs-only changes are untouched by the runtime-scan rules — they don't
#    match Sources/*|Tests/* and none of the audited trees include docs/.
# ---------------------------------------------------------------------------
run_case \
  "docs-only change stays NONE" \
  "NONE" \
  "docs/SOME-GUIDE.md"

# ---------------------------------------------------------------------------
# 5. The resolver's own force-full triggers still win outright (Package.swift
#    is FORCE_FULL_EXACT) — the runtime-scan rule must not narrow that.
# ---------------------------------------------------------------------------
run_case \
  "Package.swift change is still FULL, not narrowed by the runtime-scan rule" \
  "FULL" \
  "Package.swift"

echo
echo "affected-suites-test.sh: ${cases_run} case(s), ${failures} failure(s)"
[[ $failures -eq 0 ]]
