#!/usr/bin/env bash
#
# Tier 0 selective-testing resolver — maps a set of changed paths to the
# subset of per-PR `test`-job suites that could be affected, using the SwiftPM
# target dependency graph.
#
# WHY a committed graph snapshot instead of `swift package describe` in CI:
#   The `changes` job runs on ubuntu-latest (1× billing) specifically to AVOID a
#   10×-billed macOS runner. ubuntu-latest ships no Swift toolchain, and
#   resolving ManifoldKit's graph on Linux would fail anyway (the package
#   depends on Apple-only frameworks throughout the UI layer). The target dependency graph is derived *purely* from the
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

set -uo pipefail  # fail-open-ok: NOT -e — the resolver must fail open to FULL, never die mid-decision

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
  ManifoldAgentInstructionsTests
  ManifoldToolsTests
  ManifoldFuzzTests
  ManifoldInferenceTests
  ManifoldNetworkingTests
  ManifoldTurnLoopCharacterizationTests
  ManifoldBackendsTests
  ManifoldInferenceSwiftTestingTests
  ManifoldAppEvalTests
  APIFreezeTests
  ManifoldSnapshotTests
  ManifoldTelemetryOTLPTests
  ManifoldKitTests
  ManifoldHuggingFaceTests
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

# Read changed paths from stdin. `mapfile` needs bash 4+; macOS ships bash 3.2
# as /bin/bash, so read line-by-line instead (#2099).
CHANGED=()
while IFS= read -r __line; do
  [[ -n "$__line" ]] && CHANGED+=("$__line")
done < <(grep -v '^[[:space:]]*$' || true)
unset __line
if [[ ${#CHANGED[@]} -eq 0 ]]; then
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

# ---- Load the committed graph into bash-3.2-compatible parallel arrays ------
# `declare -A` needs bash 4+; macOS ships bash 3.2 as /bin/bash, so the graph
# and every "set" below use indexed arrays + a linear-search lookup, or a
# space-delimited string with `case " $set " in *" $item "*)` membership tests
# (#2099). Target counts here are in the dozens, so the O(n) lookups this
# trades away from O(1) hashing are not perf-relevant for a script this size.
NODE_NAMES=()
NODE_TYPE=()
NODE_TPATH=()
NODE_DEPS=()   # comma-separated local target names, parallel to NODE_NAMES
while IFS=$'\t' read -r name type tpath deps; do
  NODE_NAMES+=("$name")
  NODE_TYPE+=("$type")
  NODE_TPATH+=("$tpath")
  NODE_DEPS+=("$deps")
done < <(jq -r '.targets | to_entries[] | "\(.key)\t\(.value.type)\t\(.value.path)\t\(.value.deps | join(","))"' "$GRAPH_FILE")

if [[ ${#NODE_NAMES[@]} -eq 0 ]]; then
  log "graph snapshot parsed to 0 targets → FULL (conservative)"
  emit FULL
fi

# node_find NAME sets NODE_IDX to the matching index into NODE_NAMES/NODE_TYPE/
# NODE_TPATH/NODE_DEPS, or -1 if NAME is not a known target.
node_find() {
  local name="$1" i
  NODE_IDX=-1
  for i in "${!NODE_NAMES[@]}"; do
    if [[ "${NODE_NAMES[$i]}" == "$name" ]]; then
      NODE_IDX=$i
      return
    fi
  done
}

# ---- "Set" helpers over space-delimited strings (bash-3.2-safe stand-in for
# associative-array keys) ------------------------------------------------------
CHANGED_TARGETS=""
changed_targets_add() {
  case " $CHANGED_TARGETS " in
    *" $1 "*) ;;
    *) CHANGED_TARGETS="$CHANGED_TARGETS $1" ;;
  esac
}

DIRECT_SUITES=""
direct_suites_add() {
  case " $DIRECT_SUITES " in
    *" $1 "*) ;;
    *) DIRECT_SUITES="$DIRECT_SUITES $1" ;;
  esac
}
direct_suites_has() {
  case " $DIRECT_SUITES " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

CHANGED_SOURCES=""
changed_sources_add() {
  case " $CHANGED_SOURCES " in
    *" $1 "*) ;;
    *) CHANGED_SOURCES="$CHANGED_SOURCES $1" ;;
  esac
}

AFFECTED=""
affected_add() {
  case " $AFFECTED " in
    *" $1 "*) ;;
    *) AFFECTED="$AFFECTED $1" ;;
  esac
}

# ---- Map each changed path to its owning target (longest path-prefix match) --
for p in "${CHANGED[@]}"; do
  # Special-case: the public-surface baseline tooling lives under scripts/,
  # but APIFreezeTests (PublicSurfaceBaselineTests) asserts its presence,
  # executability, and output contract — an edit to either script must run
  # that suite. (The baseline .txt files themselves live under
  # Tests/APIFreezeTests/ and map via the normal prefix rule below.)
  case "$p" in
    scripts/api-surface-baseline.sh|scripts/_lib/api-surface-extract.py)
      changed_targets_add "APIFreezeTests"
      log "changed: $p → target APIFreezeTests (surface-baseline tooling)"
      continue
      ;;
    # Same shape, same reason: these suites EXECUTE the script named, so an edit
    # to it must run them rather than discovering the break in the merge queue.
    # (The blanket scripts/*.sh rule further down selects ManifoldCoreTests for
    # ScriptFailOpenAuditTest, which scans every script; these two are about
    # suites that run one specific script end to end.)
    # NOTE on cost: ManifoldFuzzTests has no xcscheme, so ci-selective-test.sh
    # routes it to a full swift-test bundle compile — the shape the force-include
    # block below explicitly forbids for blanket use (#2290). Accepted here only
    # because it is bounded to edits of this one script, which are rare, and the
    # alternative is FuzzCIGateScriptTests first failing inside the merge queue.
    scripts/fuzz-ci-gate.sh)
      changed_targets_add "ManifoldFuzzTests"
      log "changed: $p → target ManifoldFuzzTests (FuzzCIGateScriptTests runs it)"
      continue
      ;;
    scripts/check-readme.sh)
      changed_targets_add "ManifoldInferenceTests"
      log "changed: $p → target ManifoldInferenceTests (AgentsMdAuditTest runs it)"
      continue
      ;;
    # scripts/demo-coverage.sh itself is a `.sh` file, so it's already caught
    # by the blanket scripts/*.sh force-include below. These two `.tsv` data
    # files are NOT `.sh`, so without this case they'd fall through to the
    # "only Sources/ and Tests/ paths map to a target" filter just below and
    # resolve to NONE — the same shape as the package.json / package-lock.json
    # hole documented at the force-include block (#2446): DemoCoverageGateAuditTest
    # reads and executes both files (via scripts/demo-coverage.sh --check), so
    # an edit to either must select the suite that runs that check.
    # UNLIKE the still-open #2446 package.json case, this mapping is NOT inert:
    # ci.yml's push/pull_request `paths:` (and the ci-required-test-shim.yml
    # `paths-ignore` mirror, kept in lockstep by lint.yml's shim-drift check)
    # both explicitly list these two files, so a manifest/baseline-only diff
    # actually triggers ci.yml's `changes` job to consult this resolver.
    scripts/demo-coverage-manifest.tsv|scripts/demo-coverage-baseline.tsv)
      changed_targets_add "ManifoldCoreTests"
      log "changed: $p → target ManifoldCoreTests (DemoCoverageGateAuditTest runs scripts/demo-coverage.sh --check against these)"
      continue
      ;;
    # ReleaseReadinessWorkflowAuditTest reads this file at runtime. Without
    # this case a lint.yml-only diff is ignored by the Sources/Tests filter
    # below and resolves to NONE — the audit first reds in the merge queue.
    # NOT inert: ci.yml's paths: and the shim paths-ignore both list it.
    .github/workflows/lint.yml)
      changed_targets_add "ManifoldCoreTests"
      log "changed: $p → target ManifoldCoreTests (ReleaseReadinessWorkflowAuditTest reads lint.yml)"
      continue
      ;;
  esac
  # Only Sources/ and Tests/ paths can map to a target. Anything else (docs,
  # READMEs, …) cannot affect compiled test outcomes and is ignored.
  case "$p" in
    Sources/*|Tests/*) ;;
    *) continue ;;
  esac
  best=""; best_len=-1
  for i in "${!NODE_NAMES[@]}"; do
    tp="${NODE_TPATH[$i]}"
    if [[ "$p" == "$tp/"* || "$p" == "$tp" ]]; then
      len=${#tp}
      if (( len > best_len )); then best="${NODE_NAMES[$i]}"; best_len=$len; fi
    fi
  done
  if [[ -z "$best" ]]; then
    log "force-full: $p maps to no known target (conservative)"
    emit FULL
  fi
  changed_targets_add "$best"
  log "changed: $p → target $best"
done

# A shell-script change must still run ManifoldCoreTests, because
# ScriptFailOpenAuditTest lives there and scans ALL of scripts/ — so a
# scripts-only diff was editing the very files an audit guards while selecting
# nothing to run it. Checked BEFORE the NONE early-exit below, which is what
# a scripts-only diff hits (no script path maps to a build target).
#
# Not theoretical: PR #2385 changed two shell scripts, ci.yml never triggered
# (its paths are an allowlist of ~12 named scripts, not scripts/**), the CI
# Required Test Shim reported `test` green in 4s, and the audit's first real
# execution was the merge queue's full run — where a failure would have poisoned
# the batch of up to 5 PRs (the #2306 / #2212 shape).
#
# KNOWN HOLE, deliberately left open (#2446). This rule matches `.sh` only, so a
# NON-shell file under scripts/ that a suite executes still maps to NONE —
# concretely scripts/changelog-parser-check/{package.json,package-lock.json},
# which ChangelogParserCheckScriptTests runs `npm ci` against. Adding a case
# entry for it HERE ALONE WOULD BE INERT: this resolver runs only inside ci.yml's
# `changes` job, and ci.yml's pull_request paths don't list those files either,
# so the job never triggers to consult it. The fix is both together — and editing
# ci.yml's paths compels a lockstep edit to ci-required-test-shim.yml's
# paths-ignore, which lint.yml's `shim-drift` step enforces as exact set
# equality. Do that as its own change; don't add a mapping here and call it
# fixed. Mitigation today: `lint` is required, has no paths filter, and runs
# scripts/changelog-parser-check.sh directly.
if printf '%s\n' "${CHANGED[@]}" | grep -qE '^scripts/.*\.sh$'; then
  affected_add "ManifoldCoreTests"
  log "force-include ManifoldCoreTests: scripts/*.sh changed (ScriptFailOpenAuditTest scans scripts/)"
fi

if [[ -z "$CHANGED_TARGETS" && -z "$AFFECTED" ]]; then
  log "no changed path maps to a target → NONE"
  emit NONE
fi

# Partition changed targets into directly-changed test suites vs source targets.
for t in $CHANGED_TARGETS; do
  node_find "$t"
  if [[ $NODE_IDX -ge 0 && "${NODE_TYPE[$NODE_IDX]}" == "test" ]]; then
    direct_suites_add "$t"
  else
    changed_sources_add "$t"
  fi
done

# ---- Forward closure of a test target over local deps (BFS) -----------------
# Returns (via the global CLOSURE set string) every local target reachable
# from the given test target, including itself.
CLOSURE=""
closure_has() {
  case " $CLOSURE " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}
closure_of() {
  local start="$1"
  CLOSURE=" $start "
  local -a queue=("$start")
  while (( ${#queue[@]} > 0 )); do
    local cur="${queue[0]}"
    queue=("${queue[@]:1}")
    node_find "$cur"
    local deps=""
    if [[ $NODE_IDX -ge 0 ]]; then
      deps="${NODE_DEPS[$NODE_IDX]}"
    fi
    [[ -z "$deps" ]] && continue
    # Split the comma-separated deps list without touching $IFS: a bash-3.2
    # bug turns `"${!array[@]}"` (used by node_find, below) into a single
    # unsplit token whenever a caller up the dynamic scope chain has a
    # non-default IFS in effect (observed here — `local IFS=','` in this
    # function silently corrupted the *next* iteration's `node_find` call
    # under bash 3.2 only; bash 4/5 were unaffected). Substituting commas for
    # spaces sidesteps IFS entirely (#2099).
    local deps_spaced="${deps//,/ }"
    local d
    for d in $deps_spaced; do
      [[ -z "$d" ]] && continue
      if ! closure_has "$d"; then
        CLOSURE="$CLOSURE$d "
        queue+=("$d")
      fi
    done
  done
}

# ---- Reverse mapping: which test-job suites are affected --------------------
for suite in "${TEST_JOB_SUITES[@]}"; do
  # A directly-changed test suite always runs.
  if direct_suites_has "$suite"; then
    affected_add "$suite"
    continue
  fi
  # Otherwise the suite is affected if its dependency closure includes any
  # changed source target.
  node_find "$suite"
  [[ $NODE_IDX -lt 0 ]] && continue   # suite not in graph; skip defensively
  closure_of "$suite"
  for src in $CHANGED_SOURCES; do
    if closure_has "$src"; then
      affected_add "$suite"
      break
    fi
  done
done

if [[ -z "$AFFECTED" ]]; then
  log "no test-job suite affected (change covered by sibling jobs or no test) → NONE"
  emit NONE
fi

# ---- Fail-earlier audit anchors (#2290 / #2326 item 6) -----------------------
# Cross-cutting audits walk the filesystem (AuditSabotageCoverageAuditTest,
# SilentCatchAuditTest, TestSuiteSilentSkipAuditTest, ContractTestSupportSplit,
# …). The import-graph resolver cannot see those reads, so a PR that only
# touches e.g. ManifoldPersistenceSwiftDataTests used to leave ManifoldCoreTests
# out of the selective set — green on the PR head, red at merge_group.
#
# Force-include the two xcscheme-backed anchors that host the bulk of those
# audits. Both compile as a subgraph via xcodebuild (ci-selective-test.sh), so
# the cost is bounded — unlike ManifoldBackendsTests, which routes to a full
# swift-test bundle compile and must NEVER be force-included here (that trade
# was rejected in #2290: it can make a narrow PR slower than mode=full).
#
# Only when we already selected something (code/test change). NONE stays NONE
# for docs-only diffs.
if [[ -n "$CHANGED_SOURCES" || -n "$DIRECT_SUITES" ]]; then
  affected_add "ManifoldCoreTests"
  affected_add "ManifoldInferenceTests"
  log "force-include audit anchors: ManifoldCoreTests ManifoldInferenceTests (#2290)"
fi

# Stable, deterministic ordering for the output line. Safe to expand AFFECTED
# unguarded here: the emptiness check above already returned for the empty case.
result="$(printf '%s\n' $AFFECTED | sort -u | tr '\n' ' ' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
affected_count=$(printf '%s\n' $AFFECTED | sort -u | grep -c '.')
log "affected ${affected_count}/${#TEST_JOB_SUITES[@]} test-job suites: $result"
emit "$result"
