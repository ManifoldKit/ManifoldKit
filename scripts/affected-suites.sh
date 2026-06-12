#!/usr/bin/env bash
#
# Tier 0 selective-testing resolver — maps a set of changed paths to the
# subset of per-PR `test`-job suites that could be affected, using the SwiftPM
# target dependency graph.
#
# WHY a committed graph snapshot instead of `swift package describe` in CI:
#   The `changes` job runs on ubuntu-latest (1× billing) specifically to AVOID a
#   10×-billed macOS runner. ubuntu-latest ships no Swift toolchain, and
#   resolving ManifoldKit's graph on Linux would fail anyway (MLX / llama.cpp are
#   Apple-only). The target dependency graph is derived *purely* from the
#   manifest (`swift package dump-package` reads Package.swift, no dependency
#   resolution, no network), and it can only change when Package.swift changes.
#   So we commit a normalized snapshot (`affected-suites-graph.json`), read it in
#   CI with nothing but `jq`, and keep it honest two ways:
#     1. Any Package.swift edit FORCES a full run (the manifest is in the
#        force-full set below), so a stale snapshot can never cause an
#        under-selection on the PR that changed the graph.
#     2. A CI guard step (gated on the deps-changed filter, mirroring the
#        Package.resolved freshness check) regenerates the snapshot and fails on
#        drift, so the committed copy is updated in the same PR.
#
# USAGE
#   Resolve (default): changed paths on stdin (one per line) → one line on stdout
#       printf '%s\n' Sources/ManifoldUI/Foo.swift | scripts/affected-suites.sh
#     stdout is exactly one of:
#       - a space-separated subset of the test-job suite names, or
#       - "FULL"  (run everything — manifest/CI/hub/gate change or unmapped path), or
#       - "NONE"  (no test-job suite is affected; sibling jobs cover the change)
#     Human-readable reasoning goes to stderr.
#
#   Regenerate the snapshot (needs Swift + jq, run on macOS / locally):
#       scripts/affected-suites.sh --generate > scripts/affected-suites-graph.json
#
# Robustness: the resolve path never exits non-zero for "I don't know" — it
# falls back to FULL. The CI step treats any hard failure as FULL too. Selective
# narrowing must never be able to SKIP a suite that should have run.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GRAPH_FILE="${MANIFOLD_GRAPH_FILE:-$SCRIPT_DIR/affected-suites-graph.json}"

# ---------------------------------------------------------------------------
# Suites the per-PR `test` job actually executes (the hard-coded --filter set in
# ci.yml). The resolver only ever emits names from THIS set: suites that run in
# sibling jobs (server / macros / cold-start / iOS file-protection) or not at all
# in per-PR CI have their own paths filters and are never this gate's concern.
# PinnedSessionDelegateTests is a class-level --filter inside ManifoldBackendsTests,
# so at suite granularity it is covered by ManifoldBackendsTests.
# ---------------------------------------------------------------------------
TEST_JOB_SUITES=(
  ManifoldCoreTests
  ManifoldRuntimeTests
  ManifoldPersistenceSwiftDataTests
  ManifoldUITests
  ManifoldUIModelManagementTests
  ManifoldMCPTests
  ManifoldTestSupportTests
  ManifoldAppIntentsTests
  ManifoldVoiceTests
  ManifoldSkillsTests
  ManifoldToolsTests
  ManifoldInferenceTests
  ManifoldNetworkingTests
  ManifoldTurnLoopCharacterizationTests
  ManifoldBackendsTests
  ManifoldInferenceSwiftTestingTests
)

# ---------------------------------------------------------------------------
# --generate: rebuild the committed snapshot from the live manifest.
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--generate" ]]; then
  if ! command -v swift >/dev/null 2>&1; then
    echo "error: --generate needs the Swift toolchain on PATH" >&2
    exit 2
  fi
  # dump-package reads only Package.swift (no resolution / no network). We
  # normalize it to { targets: { name: { type, path, deps:[local targets] } } }.
  # path defaults: Sources/<name> for non-test targets, Tests/<name> for tests
  # (SwiftPM's own default layout) when the manifest leaves .path null.
  swift package --package-path "$SCRIPT_DIR/.." dump-package \
    | jq '
        [.targets[].name] as $local
        | {
            generatedBy: "scripts/affected-suites.sh --generate (swift package dump-package)",
            note: "Committed snapshot of the SwiftPM target graph. Regenerate when Package.swift changes; CI guards freshness.",
            targets: (reduce .targets[] as $t ({}; .[$t.name] = {
                type: $t.type,
                path: ($t.path // (if $t.type == "test" then "Tests/\($t.name)" else "Sources/\($t.name)" end)),
                deps: ([$t.dependencies[]? | (.byName[0] // .target[0]) | select(. != null)]
                       | map(select(. as $d | $local | index($d))) | unique)
            }))
          }'
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolve mode.
# ---------------------------------------------------------------------------
log() { printf '%s\n' "$*" >&2; }

emit() { # print result to stdout and stop
  printf '%s\n' "$1"
  exit 0
}

# Selective testing applies to pull_request only. Pushes to main and the nightly
# workflow always run the full suite (safety net per #1588).
EVENT_NAME="${MANIFOLD_EVENT_NAME:-pull_request}"
if [[ "$EVENT_NAME" != "pull_request" ]]; then
  log "event=$EVENT_NAME → full suite (selective applies to pull_request only)"
  emit FULL
fi

if [[ ! -f "$GRAPH_FILE" ]]; then
  log "graph snapshot not found at $GRAPH_FILE → FULL (conservative)"
  emit FULL
fi
if ! command -v jq >/dev/null 2>&1; then
  log "jq not available → FULL (conservative)"
  emit FULL
fi

# Read changed paths from stdin.
mapfile -t CHANGED < <(grep -v '^[[:space:]]*$' || true)
# `${arr[*]:-}` is the set -u-safe emptiness test: an empty (hence "unset") array
# would make a bare `${#arr[@]}` trip nounset, so guard with the `:-` form.
if [[ -z "${CHANGED[*]:-}" ]]; then
  log "no changed paths on stdin → NONE"
  emit NONE
fi

# ---- Force-full surface -----------------------------------------------------
# Hub modules fan out to nearly every suite; the manifest / lockfile / CI config
# can change build or trait semantics globally; the gate's own script + snapshot
# and the shared test harness scripts change how everything runs. Any of these
# → full run. (Hubs are also force-full so we never rely on closure completeness
# for the highest-fan-out modules.)
HUB_PREFIXES=(
  "Sources/ManifoldInference/"
  "Sources/ManifoldRuntime/"
  "Sources/ManifoldPersistenceSwiftData/"
)
FORCE_FULL_EXACT=(
  "Package.swift"
  "Package.resolved"
  "scripts/affected-suites.sh"
  "scripts/affected-suites-graph.json"
  "scripts/test.sh"
  "scripts/ci-test-with-watchdog.sh"
  "scripts/ci-selective-test.sh"
)
for p in "${CHANGED[@]}"; do
  case "$p" in
    .github/*) log "force-full: $p (CI config)"; emit FULL ;;
  esac
  for ex in "${FORCE_FULL_EXACT[@]}"; do
    [[ "$p" == "$ex" ]] && { log "force-full: $p (manifest/gate/harness)"; emit FULL; }
  done
  for hub in "${HUB_PREFIXES[@]}"; do
    [[ "$p" == "$hub"* ]] && { log "force-full: $p (hub module)"; emit FULL; }
  done
done

# ---- Load the committed graph into bash maps --------------------------------
declare -A TYPE TPATH DEPS
while IFS=$'\t' read -r name type tpath deps; do
  TYPE["$name"]="$type"
  TPATH["$name"]="$tpath"
  DEPS["$name"]="$deps"   # comma-separated local target names
done < <(jq -r '.targets | to_entries[] | "\(.key)\t\(.value.type)\t\(.value.path)\t\(.value.deps | join(","))"' "$GRAPH_FILE")

if [[ ${#TYPE[@]} -eq 0 ]]; then
  log "graph snapshot parsed to 0 targets → FULL (conservative)"
  emit FULL
fi

# ---- Map each changed path to its owning target (longest path-prefix match) --
declare -A CHANGED_TARGETS
for p in "${CHANGED[@]}"; do
  # Only Sources/ and Tests/ paths can map to a target. Anything else (docs,
  # READMEs, …) cannot affect compiled test outcomes and is ignored.
  case "$p" in
    Sources/*|Tests/*) ;;
    *) continue ;;
  esac
  best=""; best_len=-1
  for name in "${!TPATH[@]}"; do
    tp="${TPATH[$name]}"
    if [[ "$p" == "$tp/"* || "$p" == "$tp" ]]; then
      len=${#tp}
      if (( len > best_len )); then best="$name"; best_len=$len; fi
    fi
  done
  if [[ -z "$best" ]]; then
    log "force-full: $p maps to no known target (conservative)"
    emit FULL
  fi
  CHANGED_TARGETS["$best"]=1
  log "changed: $p → target $best"
done

if [[ -z "${CHANGED_TARGETS[*]:-}" ]]; then
  log "no changed path maps to a target → NONE"
  emit NONE
fi

# Partition changed targets into directly-changed test suites vs source targets.
declare -A CHANGED_SOURCES
declare -A DIRECT_SUITES
for t in "${!CHANGED_TARGETS[@]}"; do
  if [[ "${TYPE[$t]}" == "test" ]]; then
    DIRECT_SUITES["$t"]=1
  else
    CHANGED_SOURCES["$t"]=1
  fi
done

# ---- Forward closure of a test target over local deps (BFS) -----------------
# Returns (via global CLOSURE assoc array) every local target reachable from the
# given test target, including itself.
declare -A CLOSURE
closure_of() {
  local start="$1"
  CLOSURE=()
  local -a queue=("$start")
  CLOSURE["$start"]=1
  while (( ${#queue[@]} > 0 )); do
    local cur="${queue[0]}"
    queue=("${queue[@]:1}")
    local deps="${DEPS[$cur]:-}"
    [[ -z "$deps" ]] && continue
    local IFS=','
    local d
    for d in $deps; do
      [[ -z "$d" ]] && continue
      if [[ -z "${CLOSURE[$d]:-}" ]]; then
        CLOSURE["$d"]=1
        queue+=("$d")
      fi
    done
  done
}

# ---- Reverse mapping: which test-job suites are affected --------------------
declare -A AFFECTED
for suite in "${TEST_JOB_SUITES[@]}"; do
  # A directly-changed test suite always runs.
  if [[ -n "${DIRECT_SUITES[$suite]:-}" ]]; then
    AFFECTED["$suite"]=1
    continue
  fi
  # Otherwise the suite is affected if its dependency closure includes any
  # changed source target.
  [[ -z "${TYPE[$suite]:-}" ]] && continue   # suite not in graph; skip defensively
  closure_of "$suite"
  for src in "${!CHANGED_SOURCES[@]}"; do
    if [[ -n "${CLOSURE[$src]:-}" ]]; then
      AFFECTED["$suite"]=1
      break
    fi
  done
done

if [[ -z "${AFFECTED[*]:-}" ]]; then
  log "no test-job suite affected (change covered by sibling jobs or no test) → NONE"
  emit NONE
fi

# Stable, deterministic ordering for the output line. Safe to expand AFFECTED
# unguarded here: the emptiness check above already returned for the empty case.
result="$(printf '%s\n' "${!AFFECTED[@]}" | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
log "affected ${#AFFECTED[@]}/${#TEST_JOB_SUITES[@]} test-job suites: $result"
emit "$result"
