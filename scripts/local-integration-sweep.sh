#!/usr/bin/env bash
#
# local-integration-sweep.sh — repeatable real-model integration + perf sweep
# across the ManifoldKit family on local Apple Silicon hardware.
#
# WHY THIS EXISTS
# ---------------
# CI is macOS-only and mocks every backend. An entire tier of behaviour is only
# ever exercised on a developer machine against real models:
#   - core   : real-Ollama E2E (DemoScenarioOllamaE2ETests, BackendBenchmarkE2ETests)
#   - llama  : 5-family GBNF grammar / tool-call conformance + regression fixtures
#   - mlx    : real text + vision-input E2E + TTFT/TPS benchmark
# All of these XCTSkip silently in CI (no models, hardware-gated). This script
# runs them deliberately, against the models on disk, and writes one report.
#
# It is INTENTIONALLY not scheduled — run it by hand on nights you want a sweep.
#
# USAGE
# -----
#   scripts/local-integration-sweep.sh                 # all lanes, auto-discover models
#   scripts/local-integration-sweep.sh --lanes core,llama
#   scripts/local-integration-sweep.sh --out /path/to/report-dir
#   COMPANIONS_DIR=~/src scripts/local-integration-sweep.sh   # where the companion repos live
#   MLX_DIR=/path/to/mlx-worktree LLAMA_DIR=/path/to/llama-worktree \
#     scripts/local-integration-sweep.sh --lanes collate     # pin exact worktrees, bypass the probe
#   DECOY_LEVELS=0,5,20 SWEEP_REPEATS=2 scripts/local-integration-sweep.sh --lanes core,collate
#   MANIFOLD_CORE_COMMIT=abc1234 scripts/local-integration-sweep.sh   # pin the value every leg stamps, instead of auto-resolving CORE_DIR's HEAD
#
# REQUIREMENTS
# ------------
#   - Apple Silicon + Metal (companion suites skip otherwise).
#   - GGUF / MLX models under ~/Documents/Models (see the inventory it prints).
#   - Ollama running at localhost:11434 for the core lane.
#   - Companion repos checked out at $COMPANIONS_DIR (default ~/Repos).
#
# DESIGN NOTES
# ------------
#   - Lanes run SEQUENTIALLY: MLX and llama.cpp both contend for the GPU and
#     unified memory; running them concurrently would distort perf and risk OOM.
#   - Every lane gets a unique TMPDIR (concurrent swift-test runs otherwise
#     collide on a shared test_output.txt -> spurious failures).
#   - NO --parallel: llama's process-global llama_backend_init is not parallel-
#     safe (matches both repos' own CI). BackendContractChecks' capability-claims
#     registry is now instance-scoped per test case (arch-plan item 4.2) and no
#     longer a --parallel hazard on its own.
#   - The script never fails the whole sweep on one lane; it records per-lane
#     status and always writes the report.

set -uo pipefail  # fail-open-ok: NOT -e — run every lane and report all failures in the summary

# ----- config ---------------------------------------------------------------
MODELS_DIR="${MODELS_DIR:-$HOME/Documents/Models}"
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# COMPANIONS_DIR is a HINT, not the answer — see resolve_repo() below. The old
# hardcoded `$HOME/Repos` default silently missed a checkout layout that nests
# the family one level deeper (`~/Repos/ManifoldKit/manifold-*`), reporting
# `skip (repo absent)` for llama+mlx+eval while the run still exited 0.
COMPANIONS_DIR="${COMPANIONS_DIR:-$HOME/Repos}"
# The core commit under measurement — resolved ONCE, here, from the tree
# actually checked out (tonight that is frequently an unmerged worktree
# branch, NOT origin/main), and exported so every leg that can accept a
# core-commit value receives the SAME one. Without this, `manifold-tools
# score`'s Ollama leg and `manifold-tools-mlx`'s MLX leg each independently
# fell back to their own "unknown" placeholder, and collate's cross-leg
# comparability guard — the entire reason to run collate over
# `cat *.json | matrix` — stayed structurally inert (manifold-mlx#178).
# A caller-set MANIFOLD_CORE_COMMIT always wins. Resolution failure is
# recorded LOUDLY (preflight FAIL + summary line), never a silent fall-through
# to the placeholder — a silent one would look identical to success.
MANIFOLD_CORE_COMMIT="${MANIFOLD_CORE_COMMIT:-}"
CORE_COMMIT_RESOLVED=1
if [ -z "$MANIFOLD_CORE_COMMIT" ]; then
  MANIFOLD_CORE_COMMIT="$(git -C "$CORE_DIR" rev-parse --short HEAD 2>/dev/null)"
fi
if [ -z "$MANIFOLD_CORE_COMMIT" ]; then
  CORE_COMMIT_RESOLVED=0
  MANIFOLD_CORE_COMMIT="unknown"
fi
export MANIFOLD_CORE_COMMIT
LANES="core,llama,mlx,eval,collate,evalmain"
# Preflight knobs. OLLAMA_START_TIMEOUT bounds the wait for a daemon we start
# ourselves; EVAL_TOOL_MAX_BYTES caps the model chosen for the BFCL role (the
# largest corpus) so the night stays bounded. The instruct role has its own
# ceiling for the same reason — see EVAL_INSTRUCT_MAX_BYTES and _resolve_roles().
OLLAMA_START_TIMEOUT="${OLLAMA_START_TIMEOUT:-60}"
EVAL_TOOL_MAX_BYTES="${EVAL_TOOL_MAX_BYTES:-12000000000}"
# Same ceiling for the instruct role. It previously took the LARGEST chat model
# on the "capability signal, not a tiny model's ceiling" argument — still right,
# but "capable" has to also mean "finishes inside the cap". On 2026-07-28 that
# selected qwen3.6:27b (17.4 GB), which blew the harness's 120s per-case timeout
# on essentially every case: 261 timeouts, 264/541 attempted, and 3 responses
# persisted before the outer cap killed the lane.
EVAL_INSTRUCT_MAX_BYTES="${EVAL_INSTRUCT_MAX_BYTES:-12000000000}"
# Refuse to print a capability score derived from near-zero coverage. IFEval and
# BFCL both score un-generated cases rather than treating them as holes
# (manifold-eval#59, #60), so a run that generated 3 of 541 cases still renders a
# readable "19.2%". Below this percentage the sweep reports coverage instead.
EVAL_MIN_COVERAGE_PCT="${EVAL_MIN_COVERAGE_PCT:-80}"
SKIP_NEGATIVE_CONTROL="${SKIP_NEGATIVE_CONTROL:-0}"
LANE_TIMEOUT="${LANE_TIMEOUT:-2400}"   # per-lane hard cap (s); a hung xctest must not eat the night
# Decoy x repeat sweep matrix for the tool-selection degradation curve (F1 vs
# advertised-tool count). `ConformanceRecord` has carried `decoyLevel` and
# `repeatIndex` as first-class cell coordinates since #2041, and
# `ScenarioCLIHarness` has parsed `--extra-tools N` since the decoy pool
# landed — but until this change nothing in scripts/ ever varied either axis,
# so every measurement ever taken was a single sample of the easiest cell
# (decoyLevel 0, one rep). Both overridable so the night can degrade under
# time pressure, e.g. `DECOY_LEVELS=0,5,20 SWEEP_REPEATS=2`.
DECOY_LEVELS="${DECOY_LEVELS:-0,3,5,10,20}"
SWEEP_REPEATS="${SWEEP_REPEATS:-3}"
# DEPENDENCY (not yet on origin/main as of this writing): the sweep below
# passes `--repeat-index` to the scenario CLIs. That flag is being added
# concurrently to `ScenarioCLIHarness`/`manifold-tools` by a parallel lane and
# does NOT exist on the core commit this script ships against. Until it lands,
# every matrix/collate cell run below fails fast with "unexpected argument
# '--repeat-index'" — a loud, visible failure (surfaced via lane_noop / the
# per-level run log), never a silent mis-measurement. Do not remove
# --repeat-index to work around that; land the CLI flag instead.
# The eval lane drives hundreds of live generations (not xctest), so it gets its
# OWN, larger per-command cap — the 40-min xctest cap would kill it mid-corpus.
# It is resumable (generate skips keys already on disk), so a kill loses nothing.
EVAL_CMD_TIMEOUT="${EVAL_CMD_TIMEOUT:-5400}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$CORE_DIR/.local-integration-runs/$STAMP"

while [ $# -gt 0 ]; do
  case "$1" in
    --lanes) LANES="$2"; shift 2 ;;
    --out)   OUT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

# Reject an unknown lane name outright. `--lanes none` (or a typo like `lama`,
# or a lane renamed out from under overnight-sweep.sh's LANES default) used to
# select nothing, bypass every lane_noop guard, and report "Every requested lane
# did work" with exit 0 — a perfect clean run that measured nothing at all.
# `matrix` is deliberately ABSENT: it is a sub-step of the core lane (its block
# is gated on `have_lane core`), so listing it as selectable would certify a lane
# name that runs nothing — the allowlist itself becoming a source of false
# confidence. It still reports under its own `matrix:` prefix.
KNOWN_LANES="core llama mlx eval collate evalmain"
if [ -z "$LANES" ]; then
  # An empty lane set iterates the validator zero times and selects nothing —
  # reproducing the exact "did no work, reported clean" outcome the validator
  # was added to prevent.
  echo "empty lane set — known lanes: $KNOWN_LANES" >&2; exit 2
fi
for _l in $(printf '%s' "$LANES" | tr ',' ' '); do
  case " $KNOWN_LANES " in
    *" $_l "*) ;;
    *) echo "unknown lane '$_l' — known lanes: $KNOWN_LANES" >&2; exit 2 ;;
  esac
done

# DECOY_LEVELS / SWEEP_REPEATS get the same allowlist-style validation as
# LANES above — unlike LANES, an invalid value here doesn't error visibly on
# its own: a non-numeric SWEEP_REPEATS silently resolves `$(( … ))` to 0,
# EXPECTED_CELLS becomes 0, and the coverage assertion MISMATCHes for a reason
# that has nothing to do with real coverage.
case "$SWEEP_REPEATS" in
  ''|*[!0-9]*) echo "SWEEP_REPEATS must be a positive integer, got '$SWEEP_REPEATS'" >&2; exit 2 ;;
esac
if [ "$SWEEP_REPEATS" -lt 1 ]; then
  echo "SWEEP_REPEATS must be >= 1, got '$SWEEP_REPEATS'" >&2; exit 2
fi
if [ -z "$DECOY_LEVELS" ]; then
  echo "DECOY_LEVELS must not be empty (e.g. '0,3,5,10,20')" >&2; exit 2
fi
for _dl in $(printf '%s' "$DECOY_LEVELS" | tr ',' ' '); do
  case "$_dl" in
    ''|*[!0-9]*) echo "DECOY_LEVELS entries must be non-negative integers, got '$_dl' in '$DECOY_LEVELS'" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT"
REPORT="$OUT/REPORT.md"
PREFLIGHT="$OUT/PREFLIGHT.md"
SUMMARY_LANES=""   # "name=status(skip/pass/fail) detail" lines, newline-joined
# Lanes that were REQUESTED but did no work (missing repo/model/corpus, a filter
# that matched nothing). Tracked separately from pass/fail because a silent skip
# used to render identically to a pass and the script exited 0 either way — the
# single most dangerous property this sweep had for an unattended overnight run.
NOOP_LANES=""
# Lanes that RAN and FAILED (non-zero rc, or a watchdog kill). Previously these
# fed only the human-readable summary: every lane could fail to BUILD and the
# script still exited 0, because the exit code looked at no-ops only.
FAILED_LANES=""
# Measurements taken against a source of unknown or known-stale provenance. Not
# a failure, but it must reach the verdict — a pass over stale input is not the
# pass it appears to be.
STALE_NOTES=""
PREFLIGHT_LINES=""
PREFLIGHT_FAILED=0

# Locate a companion repo by PROBING for its Package.swift rather than trusting a
# path convention. Order: caller's COMPANIONS_DIR, then the core checkout's own
# parent (the layout where the family is siblings under one dir), then the two
# historical defaults. Echoes the resolved path, or nothing.
resolve_repo() {
  local n="$1" c
  for c in "$COMPANIONS_DIR/$n" "$(dirname "$CORE_DIR")/$n" "$HOME/Repos/$n" "$HOME/Repos/ManifoldKit/$n"; do
    if [ -f "$c/Package.swift" ]; then (cd "$c" && pwd); return 0; fi
  done
  return 1
}
# An explicit caller override (LLAMA_DIR / MLX_DIR / EVAL_DIR set in env)
# ALWAYS wins over the Package.swift probe below and is never overwritten by
# it. This is load-bearing for a run against WORKTREES holding unmerged
# branches: resolve_repo() would otherwise happily find the shared checkout
# instead (e.g. manifold-mlx's shared checkout parked on an unrelated
# branch) and silently measure the wrong tree.
LLAMA_DIR="${LLAMA_DIR:-}"
[ -n "$LLAMA_DIR" ] || LLAMA_DIR="$(resolve_repo manifold-llama)" || LLAMA_DIR="$COMPANIONS_DIR/manifold-llama"
MLX_DIR="${MLX_DIR:-}"
[ -n "$MLX_DIR" ] || MLX_DIR="$(resolve_repo manifold-mlx)" || MLX_DIR="$COMPANIONS_DIR/manifold-mlx"
EVAL_DIR="${EVAL_DIR:-}"
[ -n "$EVAL_DIR" ] || EVAL_DIR="$(resolve_repo manifold-eval)" || EVAL_DIR="$COMPANIONS_DIR/manifold-eval"

# Record a requested lane that did NO work, with the cause. Keeps the existing
# "<name>: ..." lane-line shape so overnight-sweep.sh's grep still matches.
lane_noop() {
  NOOP_LANES="${NOOP_LANES}${1}: ${2}\n"
  SUMMARY_LANES="${SUMMARY_LANES}${1}: SKIP-NO-WORK (${2})\n"
}
# Installed-tag snapshot + membership test. Defined at TOP LEVEL (not inside the
# eval lane) so the negative control can exercise the predicate even when that
# lane didn't run — a control that calls an undefined function gets rc=127 and
# would score as "detection fired", which is the exact false-confidence this
# section exists to prevent.
_EVAL_INSTALLED_TAGS=""
eval_model_installed() {
  # An EMPTY model name means preflight resolved no model for that role. It is
  # never "installed" — without this guard `grep -qxF ""` matches every line and
  # an unresolved role reads as present, the silent-skip class this sweep now
  # refuses to have.
  [ -n "$1" ] || return 1
  # Empty tag list => a transient /api/tags failure; assume installed and let the
  # generator surface a real 404, rather than skipping every sub-lane on a blip.
  [ -z "$_EVAL_INSTALLED_TAGS" ] && return 0
  printf '%s\n' "$_EVAL_INSTALLED_TAGS" | grep -qxF "${1%:latest}"
}

# Record a preflight check outcome: pf PASS|WARN|FAIL <label> <detail>
pf() {
  PREFLIGHT_LINES="${PREFLIGHT_LINES}| $1 | $2 | $3 |\n"
  [ "$1" = "FAIL" ] && PREFLIGHT_FAILED=1
  return 0
}

log() { printf '%s\n' "$*"; }
have_lane() { case ",$LANES," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# Run one command under the LANE_TIMEOUT watchdog as its own process group, with
# no summary side effect — the caller classifies. Same set -m / kill -TERM -pid
# shape as run_lane; used by lanes whose output is a rendered artifact rather
# than xctest verdict lines. (The eval lane has its own EVAL_CMD_TIMEOUT twin.)
run_capped_lane() {
  local logf="$1"; shift
  set -m
  ( "$@" ) >"$logf" 2>&1 &
  local p=$!
  set +m
  ( sleep "$LANE_TIMEOUT"; kill -TERM -"$p" 2>/dev/null; sleep 8; kill -KILL -"$p" 2>/dev/null ) &
  local w=$!
  wait "$p"; local r=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return $r
}

# Run a lane command, tee to a log, classify the result.
# args: lane-name  logfile  cmd...
run_lane() {
  local name="$1" logf="$2"; shift 2
  local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/mk-sweep-$name.XXXXXX")"
  log "=== [$name] $(date +%H:%M:%S) starting (cap ${LANE_TIMEOUT}s) ==="
  # Run the lane as its own process group (set -m) so the watchdog can kill the
  # WHOLE tree — a hung xctest grandchild (e.g. MLX xcodebuild) ignores a kill
  # aimed only at the subshell. Without this a single hang runs forever.
  set -m
  ( export TMPDIR="$tmp"; "$@" ) >"$logf" 2>&1 &
  local pid=$!
  set +m
  ( sleep "$LANE_TIMEOUT"; kill -TERM -"$pid" 2>/dev/null; sleep 8; kill -KILL -"$pid" 2>/dev/null ) &
  local wd=$!
  wait "$pid"; local rc=$?
  kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
  rm -rf "$tmp"
  local status detail
  if [ $rc -eq 143 ] || [ $rc -eq 137 ]; then
    SUMMARY_LANES="${SUMMARY_LANES}${name}: TIMEOUT/killed (rc=$rc, cap ${LANE_TIMEOUT}s) -> $(basename "$logf")\n"
    FAILED_LANES="${FAILED_LANES}${name}: TIMEOUT/killed after ${LANE_TIMEOUT}s\n"
    log "=== [$name] $(date +%H:%M:%S) KILLED after ${LANE_TIMEOUT}s cap ==="
    return
  fi
  # Count only real xctest verdict lines — NOT raw "error:" greps, which match
  # CoreData/XPC log noise and deprecation warnings and wildly inflate "failed".
  local skips passes fails
  passes=$(grep -c "Test Case '.*' passed" "$logf" 2>/dev/null)
  fails=$(grep -c "Test Case '.*' failed" "$logf" 2>/dev/null)
  skips=$(grep -c "Test Case '.*' skipped" "$logf" 2>/dev/null)
  detail="passed=$passes failed=$fails skipped=$skips"
  # Zero verdict lines with a clean rc is NOT a pass — it means the filter matched
  # no tests (the `ManifoldE2ETests\.` anchoring hazard) or every case XCTSkip'd
  # for a missing model. Both used to render as `pass (passed=0 failed=0)`.
  if [ "$rc" -eq 0 ] && [ "$passes" -eq 0 ] && [ "$fails" -eq 0 ]; then
    lane_noop "$name" "ran but produced no test verdicts (filter matched nothing, or all cases skipped) — $(basename "$logf")"
    log "=== [$name] $(date +%H:%M:%S) NO-OP: no test verdicts ($detail) ==="
    return
  fi
  if [ "$rc" -eq 0 ] && [ "$fails" -eq 0 ]; then
    status="pass"
  else
    status="fail(rc=$rc)"
    # A lane that fails to BUILD has rc!=0 and zero verdict lines, so it misses
    # the no-op branch above; without this it reached the report as a failure
    # nobody's exit code ever saw.
    FAILED_LANES="${FAILED_LANES}${name}: ${status} (${detail})\n"
  fi
  SUMMARY_LANES="${SUMMARY_LANES}${name}: ${status} (${detail}) -> $(basename "$logf")\n"
  log "=== [$name] $(date +%H:%M:%S) done: $status ($detail) ==="
}

# ----- 0a. PREFLIGHT ---------------------------------------------------------
# Assert the rig CAN do work before spending the night finding out it couldn't.
# Every check below corresponds to a real failure mode observed on 2026-07-28,
# where eight independent preconditions were unmet, every affected lane skipped
# silently, and the run would still have written a clean-looking report.

ollama_up() { curl -s --max-time 3 localhost:11434/api/tags >/dev/null 2>&1; }
OLLAMA_STARTED_BY_US=0
stop_ollama_if_ours() {
  [ "$OLLAMA_STARTED_BY_US" -eq 1 ] || return 0
  log "=== [preflight] stopping the ollama daemon this run started ==="
  kill "$OLLAMA_SERVE_PID" 2>/dev/null   # fail-open-ok: best-effort teardown of our own child; a stale daemon is not worth failing the completed run over
  return 0
}
trap stop_ollama_if_ours EXIT

ensure_ollama() {
  if ollama_up; then pf PASS "ollama" "already running at localhost:11434"; return 0; fi
  if ! command -v ollama >/dev/null 2>&1; then
    pf FAIL "ollama" "not reachable and \`ollama\` is not on PATH — core/matrix/eval lanes cannot run"
    return 1
  fi
  log "=== [preflight] ollama down — starting it ==="
  nohup ollama serve >"$OUT/ollama-serve.log" 2>&1 &
  OLLAMA_SERVE_PID=$!
  OLLAMA_STARTED_BY_US=1
  local i=0
  while [ "$i" -lt "$OLLAMA_START_TIMEOUT" ]; do
    if ollama_up; then pf PASS "ollama" "started by this run (ready in ${i}s, pid $OLLAMA_SERVE_PID)"; return 0; fi
    i=$((i + 1)); sleep 1
  done
  pf FAIL "ollama" "started but not ready after ${OLLAMA_START_TIMEOUT}s — see ollama-serve.log"
  return 1
}

# Resolve the eval role models from Ollama's OWN capability metadata (/api/show)
# instead of hardcoded tag names. WHY: the previous defaults were literal strings
# (`mistral-7b-tools`, `llama3.1-8b`, `nomic-embed-text`). On a machine whose tags
# are `mistral:7b-instruct-v0.3-q4_K_M` / `llama3.1:8b` / `embeddinggemma`, all
# three matched nothing, all three eval sub-lanes skipped, and the sweep reported
# a clean run having measured zero models. A capability query cannot drift that
# way: `tools` means tools whatever the tag is called.
# Emits shell assignments on stdout, plus `#`-prefixed inventory comments.
_resolve_roles() {
  python3 - "$EVAL_TOOL_MAX_BYTES" "$EVAL_INSTRUCT_MAX_BYTES" <<'PY'
import json, sys, urllib.request

MAX_TOOL_BYTES = int(sys.argv[1])
MAX_INSTRUCT_BYTES = int(sys.argv[2])

def api(path, payload=None):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request("http://localhost:11434" + path, data=data,
                                 headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.load(r)

try:
    tags = api("/api/tags").get("models", [])
except Exception as exc:
    import shlex as _s
    print("ROLE_ERROR=%s" % _s.quote(str(exc).replace("\n", " ")[:120]))
    sys.exit(0)

info = []
for m in tags:
    name = m.get("name", "")
    if not name:
        continue
    try:
        caps = api("/api/show", {"name": name}).get("capabilities") or []
    except Exception:
        caps = []
    info.append((name, int(m.get("size", 0)), caps))

def pick(pred, key=None):
    c = [x for x in info if pred(x)]
    c.sort(key=key or (lambda x: -x[1]))
    return c[0][0] if c else ""

is_embed = lambda x: "embedding" in x[2] or "embed" in x[0].lower()
# tool role drives the LARGEST corpus (BFCL), so it takes the biggest model that
# still fits under the size ceiling — capability with a bounded runtime.
tool = pick(lambda x: "tools" in x[2] and x[1] <= MAX_TOOL_BYTES)
tool_oversize = 0
if not tool:
    tool = pick(lambda x: "tools" in x[2])
    tool_oversize = 1 if tool else 0
# instruct role is a CAPABILITY signal (is MK's prompt assembly lossy?), so it
# takes the largest chat model that still FITS THE CEILING. It used to ignore the
# ceiling entirely; that selected a 17.4 GB model which timed out on essentially
# every case, so "capable" now also means "finishes inside the cap".
instruct = pick(lambda x: "completion" in x[2] and not is_embed(x) and x[1] <= MAX_INSTRUCT_BYTES)
instruct_oversize = 0
if not instruct:
    # Nothing fits. Falling back to the largest overall reintroduces exactly the
    # timeout this ceiling exists to prevent, so the fallback must be ANNOUNCED —
    # a silent one renders a green preflight row for the failing precondition.
    instruct = pick(lambda x: "completion" in x[2] and not is_embed(x))
    instruct_oversize = 1 if instruct else 0
embed = pick(is_embed)
vision = pick(lambda x: "vision" in x[2])

import shlex
# Inventory FIRST, assignments LAST. The shell reads the assignments with a sed
# range anchored on the first ROLE_ line running to EOF (a line filter would
# truncate the multi-line ROLE_TOOL_TAGS value mid-quote). Ordering the output
# this way keeps that range default-DENY by construction: nothing that is not a
# role assignment can follow it. Do not append anything after this block.
for n, sz, c in sorted(info):
    print("# %-42s %6.1f GB  caps=%s" % (n, sz / 1e9, ",".join(c) or "none"))
print("ROLE_TOOL=%s" % shlex.quote(tool))
print("ROLE_INSTRUCT=%s" % shlex.quote(instruct))
print("ROLE_EMBED=%s" % shlex.quote(embed))
print("ROLE_VISION=%s" % shlex.quote(vision))
print("ROLE_TOOL_OVERSIZE=%d" % tool_oversize)
print("ROLE_INSTRUCT_OVERSIZE=%d" % instruct_oversize)
# Every tools-capable tag, for the conformance matrix (newline-joined). MUST be
# last — it is the only multi-line value.
print("ROLE_TOOL_TAGS=%s" % shlex.quote("\n".join(n for n, _, c in info if "tools" in c)))
PY
}

log "=== [preflight] $(date +%H:%M:%S) starting ==="

# -- core commit ----------------------------------------------------------
# Resolved once, at the top of this script (see MANIFOLD_CORE_COMMIT above).
# Surfaced here so an operator reads the FAIL before trusting any downstream
# cross-leg comparison — a resolution failure that only showed up as a quiet
# "unknown" in a records.json field would be indistinguishable from success.
if [ "$CORE_COMMIT_RESOLVED" -eq 1 ]; then
  pf PASS "core-commit" "$MANIFOLD_CORE_COMMIT (resolved from $CORE_DIR HEAD)"
else
  pf FAIL "core-commit" "could not resolve HEAD at $CORE_DIR — every emitted record will carry the 'unknown' placeholder coreCommit, and collate's cross-leg comparability guard cannot verify anything this run"
fi

# -- repos --------------------------------------------------------------------
# A repo is needed if ITS OWN lane is requested, or if a lane that DEPENDS on it
# is: collate needs mlx (the second leg) + eval (the collator); evalmain needs
# eval. Without the dependency arms, `--lanes collate` reported "lane not
# requested" for the very repos it was about to fail on.
repo_needed() {
  case "$1" in
    llama) have_lane llama ;;
    mlx)   have_lane mlx || have_lane collate ;;
    eval)  have_lane eval || have_lane collate || have_lane evalmain ;;
    *)     return 1 ;;
  esac
}
for pair in "llama:$LLAMA_DIR" "mlx:$MLX_DIR" "eval:$EVAL_DIR"; do
  _n="${pair%%:*}"; _d="${pair#*:}"
  if repo_needed "$_n"; then
    if [ -f "$_d/Package.swift" ]; then pf PASS "repo:$_n" "$_d"
    else pf FAIL "repo:$_n" "no Package.swift at $_d (lane will be skipped)"; fi
  else
    pf "SKIP" "repo:$_n" "lane not requested"
  fi
done

# -- ollama + role models -----------------------------------------------------
OLLAMA_NEEDED=0
if have_lane core || have_lane eval; then OLLAMA_NEEDED=1; fi
ROLE_TOOL=""; ROLE_INSTRUCT=""; ROLE_EMBED=""; ROLE_VISION=""; ROLE_ERROR=""; ROLE_TOOL_TAGS=""
ROLE_TOOL_OVERSIZE=0; ROLE_INSTRUCT_OVERSIZE=0
if [ "$OLLAMA_NEEDED" -eq 1 ]; then
  if ensure_ollama; then
    ROLES_RAW="$(_resolve_roles 2>"$OUT/preflight-roles.err")"
    eval "$(printf '%s\n' "$ROLES_RAW" | sed -n '/^ROLE_[A-Z_]*=/,$p')"   # fail-open-ok: the sed range starts at the first ROLE_ assignment and the helper emits nothing but assignments after that point (inventory is printed BEFORE them); a miss leaves every role empty, which each guard below reports as a named FAIL
    printf '%s\n' "$ROLES_RAW" | grep '^#' > "$OUT/ollama-inventory.txt"   # fail-open-ok: inventory comments are diagnostics; an empty file is not a run-stopping condition
    # Caller-set env always wins over resolution.
    EVAL_TOOL_MODEL="${EVAL_TOOL_MODEL:-$ROLE_TOOL}"
    EVAL_INSTRUCT_MODEL="${EVAL_INSTRUCT_MODEL:-$ROLE_INSTRUCT}"
    EVAL_EMBED_MODEL="${EVAL_EMBED_MODEL:-$ROLE_EMBED}"
    # Role models matter ONLY to the eval lane. Failing preflight on a missing
    # embedding model during `--lanes core` reds the gate for a precondition the
    # run never touches, which teaches the operator to ignore the exit code.
    if [ -n "$ROLE_ERROR" ]; then
      # Escape `|`: PREFLIGHT.md renders these as a markdown table, and a pipe in
      # an upstream error string would silently split the row into bogus columns.
      pf WARN "role:resolution" "role query failed: $(printf '%s' "$ROLE_ERROR" | sed 's/|/\\|/g')"
    fi
    if have_lane eval; then
    # Delimit on '|', NOT ':' — Ollama tags contain colons (`qwen3.5:9b`), so
    # splitting on the first ':' reported role:tool as "qwen3.5" with "9b" folded
    # into the reason. Display-only, but a preflight table that misnames the model
    # it selected is the kind of small dishonesty this whole change exists to end.
    for rp in "tool|$EVAL_TOOL_MODEL|tools-capable, BFCL" "instruct|$EVAL_INSTRUCT_MODEL|largest chat that fits the ceiling, IFEval" "embed|$EVAL_EMBED_MODEL|embedding, MTEB"; do
      _role="${rp%%|*}"; _rest="${rp#*|}"; _m="${_rest%%|*}"; _why="${_rest#*|}"
      _oversize=0
      [ "$_role" = "tool" ] && _oversize="${ROLE_TOOL_OVERSIZE:-0}"
      [ "$_role" = "instruct" ] && _oversize="${ROLE_INSTRUCT_OVERSIZE:-0}"
      if [ -n "$_m" ] && [ "$_oversize" = "1" ]; then
        pf WARN "role:$_role" "$_m EXCEEDS the size ceiling — no smaller model satisfies this role; expect per-case timeouts"
      elif [ -n "$_m" ]; then pf PASS "role:$_role" "$_m ($_why)"
      else pf FAIL "role:$_role" "no installed model satisfies this role ($_why) — sub-lane will skip"; fi
    done
    else
      pf "SKIP" "role:*" "eval lane not requested — role models are irrelevant to this run"
    fi
  else
    pf FAIL "role:*" "ollama unavailable — role models unresolvable"
  fi
else
  pf "SKIP" "ollama" "no lane requested needs it"
fi

# -- eval corpora -------------------------------------------------------------
if have_lane eval && [ -f "$EVAL_DIR/Package.swift" ]; then
  _cache="${MANIFOLD_EVAL_CACHE:-$HOME/.cache/manifold-eval}"
  if [ ! -f "${EVAL_STSB:-$_cache/stsb_test.json}" ] && [ -x "$EVAL_DIR/scripts/fetch-corpora.sh" ]; then
    log "=== [preflight] fetching eval corpora (absent at $_cache) ==="
    ( cd "$EVAL_DIR" && MANIFOLD_EVAL_CACHE="$_cache" scripts/fetch-corpora.sh ) >"$OUT/preflight-corpora.log" 2>&1
    _fetch_rc=$?
    [ "$_fetch_rc" -eq 0 ] || pf WARN "corpora" "fetch-corpora.sh exited $_fetch_rc — see preflight-corpora.log"
  fi
  if [ -f "${EVAL_STSB:-$_cache/stsb_test.json}" ]; then pf PASS "corpus:stsb" "${EVAL_STSB:-$_cache/stsb_test.json}"
  else pf FAIL "corpus:stsb" "absent — mteb sub-lane will skip"; fi
  _ifc="${EVAL_IFEVAL_CORPUS:-$EVAL_DIR/Tests/ManifoldEvalTests/Fixtures/ifeval.jsonl}"
  if [ -f "$_ifc" ]; then pf PASS "corpus:ifeval" "$(grep -c . "$_ifc" 2>/dev/null) cases"
  else pf FAIL "corpus:ifeval" "absent at $_ifc — ifeval sub-lane will skip"; fi
fi

# -- write PREFLIGHT.md -------------------------------------------------------
{
  echo "# Preflight — $STAMP"
  echo
  echo "| Status | Check | Detail |"
  echo "|---|---|---|"
  printf "%b" "$PREFLIGHT_LINES"
  echo
  _pf_ran=$(printf "%b" "$PREFLIGHT_LINES" | grep -cE '^\| (PASS|WARN|FAIL) ')
  if [ "$PREFLIGHT_FAILED" -eq 1 ]; then
    echo "**One or more checks FAILED — the affected lanes below will not produce signal.**"
  elif [ "$_pf_ran" -eq 0 ]; then
    # "All checks passed" over zero executed checks is the same lie this whole
    # change exists to remove — say so plainly instead.
    echo "**No preflight check actually ran** (every check was skipped for the requested lane set)."
  else
    echo "All $_pf_ran executed preflight checks passed."
  fi
} > "$PREFLIGHT"
log "=== [preflight] $(date +%H:%M:%S) done (failed=$PREFLIGHT_FAILED) -> $PREFLIGHT ==="

# ----- 0. model inventory ----------------------------------------------------
{
  echo "# Local integration + perf sweep — $STAMP"
  echo
  echo "- core repo: \`$CORE_DIR\` ($(git -C "$CORE_DIR" rev-parse --short HEAD 2>/dev/null) on $(git -C "$CORE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null))"
  # Print the RESOLVED paths, not the COMPANIONS_DIR hint — they differ whenever
  # the probe found the family somewhere other than the hint, and printing the
  # hint made a correct resolution look like it had searched the wrong place.
  echo "- companion repos (resolved by Package.swift probe, or LLAMA_DIR/MLX_DIR/EVAL_DIR override; hint was \`$COMPANIONS_DIR\`):"
  for _p in "llama:$LLAMA_DIR" "mlx:$MLX_DIR" "eval:$EVAL_DIR"; do
    _pd="${_p#*:}"
    if [ -f "$_pd/Package.swift" ]; then
      # -e, not -d: a git WORKTREE's `.git` is a FILE (gitdir pointer), not a
      # directory — `-d` would report a valid worktree as having no git state.
      # PREP must record the tree it actually measured, never switch branches
      # or stash to get there (2026-06-29 stashed edits and measured a
      # diverged HEAD, corrupting attribution) — this is read-only.
      if [ -e "$_pd/.git" ]; then
        _pbr="$(git -C "$_pd" rev-parse --abbrev-ref HEAD 2>/dev/null)"
        _psha="$(git -C "$_pd" rev-parse --short HEAD 2>/dev/null)"
        _pdirty="$(git -C "$_pd" status --porcelain 2>/dev/null | grep -c .)"
        echo "    - ${_p%%:*}: \`$_pd\` (present; branch=$_pbr head=$_psha dirty_paths=$_pdirty — MEASURING THIS TREE AS-IS)"
      else
        echo "    - ${_p%%:*}: \`$_pd\` (present; not a git checkout — no branch/HEAD attribution)"
      fi
    else
      echo "    - ${_p%%:*}: \`$_pd\` (MISSING)"
    fi
  done
  echo "- models dir: \`$MODELS_DIR\`"
  echo "- lanes: \`$LANES\`"
  echo
  echo "## Model inventory"
  echo '```'
  # RECURSIVE: GGUF live one directory deep, as `Models/gguf/<Family>/<file>.gguf`.
  # The old flat `ls "$MODELS_DIR"/*.gguf` matched nothing on that layout and
  # printed `MISSING` for every family while 14 GGUF sat on disk — an inventory
  # that lies in the safe direction is still an inventory that lies.
  echo "GGUF (llama family-fragment match):"
  _all_gguf="$(find "$MODELS_DIR" -type f -name '*.gguf' 2>/dev/null | grep -vi 'mmproj')"
  for f in llama qwen mistral phi gemma bonsai; do
    m=$(printf '%s\n' "$_all_gguf" | grep -i "$f" | head -1)
    echo "  $f: ${m:-MISSING}"
  done
  echo "  (total non-mmproj GGUF found: $(printf '%s\n' "$_all_gguf" | grep -c .))"
  echo "MLX dirs:"
  find "$MODELS_DIR" -maxdepth 3 -name config.json 2>/dev/null | sed 's#/config.json##' | sed 's#^#  #'
  echo "Ollama @ localhost:11434: $(curl -s --max-time 3 localhost:11434/api/tags >/dev/null 2>&1 && echo UP || echo DOWN)"
  echo '```'
  echo
} > "$REPORT"

# ----- 0b. Ollama model selection (default the sweep's model env to INSTALLED
# tags) ----------------------------------------------------------------------
# WHY: the matrix lane's scenario default model is `llama3.1:8b` (the canonical
# Ollama *registry* name). On a machine whose tags are custom-named (e.g. a
# Modelfile build tagged `llama3.1-8b`), every scenario 404s ("Model not found")
# and `matrix` renders a single garbage `renders-no-call` cell — silently
# destroying the before/after comparison the sweep exists to produce. Discover
# what is actually installed and pin the model env to it. Explicit caller values
# always win. NOTE: OLLAMA_TEST_MODEL is deliberately NOT pinned here — the tool
# E2E suite auto-discovers a tool-capable model, and a failure there (a model
# that advertises `tools` via /api/show but renders no call) is a real
# capability signal we must not mask.
_ollama_tags() {
  local json; json="$(curl -s --max-time 5 localhost:11434/api/tags 2>/dev/null)" || return 1
  [ -n "$json" ] || return 1
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$json" | python3 -c 'import sys,json; print("\n".join(m["name"] for m in json.load(sys.stdin).get("models",[])))' 2>/dev/null
  else
    printf '%s' "$json" | grep -oE '"name":"[^"]+"' | sed 's/"name":"//; s/"$//'
  fi
}

if curl -s --max-time 3 localhost:11434/api/tags >/dev/null 2>&1; then
  # chat tags only (embedding models can't tool-call), sorted for order-stable
  # selection regardless of /api/tags ordering.
  OLLAMA_CHAT_TAGS="$(_ollama_tags | grep -ivE 'embed|minilm|nomic|bge|gte' | grep . | sort)"
  { echo "## Model selection (auto)"; echo '```'; } >> "$REPORT"
  if [ -z "${MATRIX_MODELS:-}" ] && [ -n "$OLLAMA_CHAT_TAGS" ]; then
    # strip `:latest` so rows match the soak-baseline naming for clean diffs
    # Tools-capable tags only. The conformance scenarios ARE tool-calling
    # scenarios, so a tag whose /api/show capabilities omit `tools` renders a
    # 💥 load-fail row ("Tools passed to a backend that does not support tool
    # calling") that says nothing about the model and nothing about ManifoldKit.
    # Observed for gemma3:4b, which advertises only completion,vision.
    # `| sort` on both branches: /api/tags is ordered by modified_at, so it
    # changes whenever a model is pulled or run, and an unsorted list makes this
    # report line diff noisily between otherwise identical runs.
    _tool_tags="$(printf '%s\n' "${ROLE_TOOL_TAGS:-}" | grep . | sed 's/:latest$//' | sort | paste -sd, -)"
    if [ -n "$_tool_tags" ]; then
      MATRIX_MODELS="$_tool_tags"
      _matrix_rule="tools-capable tags (/api/show capabilities)"
    else
      MATRIX_MODELS="$(printf '%s\n' "$OLLAMA_CHAT_TAGS" | sed 's/:latest$//' | sort | paste -sd, -)"
      _matrix_rule="FALLBACK: ALL chat tags — the capability query returned none, so expect 💥 load-fail rows for models without tool support"
    fi
    export MATRIX_MODELS
    echo "MATRIX_MODELS (matrix lane) <- $_matrix_rule: $MATRIX_MODELS" >> "$REPORT"
  else
    echo "MATRIX_MODELS: caller-set or no installed tags ('${MATRIX_MODELS:-}')" >> "$REPORT"
  fi
  if [ -z "${MANIFOLD_BENCH_OLLAMA_MODEL:-}" ]; then
    # deterministic benchmark model: a mid-size chat tag, else the first installed
    bench="$(printf '%s\n' "$OLLAMA_CHAT_TAGS" | grep -iE '[0-9]b' | head -1)"
    [ -n "$bench" ] || bench="$(printf '%s\n' "$OLLAMA_CHAT_TAGS" | head -1)"
    bench="${bench%:latest}"   # match MATRIX_MODELS naming
    if [ -n "$bench" ]; then
      export MANIFOLD_BENCH_OLLAMA_MODEL="$bench"
      echo "MANIFOLD_BENCH_OLLAMA_MODEL (benchmark) <- $bench" >> "$REPORT"
    fi
  else
    echo "MANIFOLD_BENCH_OLLAMA_MODEL: caller-set ($MANIFOLD_BENCH_OLLAMA_MODEL)" >> "$REPORT"
  fi
  # Validate the resolved benchmark model against what Ollama ACTUALLY has. A
  # caller-set MANIFOLD_BENCH_OLLAMA_MODEL (e.g. from a shell profile) drifts
  # easily from the installed tag naming — registry-style `llama3.1:8b` vs a
  # custom Modelfile tag `llama3.1-8b` — and 404s the throughput benchmark,
  # failing the whole core lane on a naming mismatch (seen 2026-07-09). If the
  # requested tag isn't installed, fall back to an installed chat tag and log the
  # substitution instead. (The auto-selected value above is always installed, so
  # this only ever rewrites a stale caller value.)
  if [ -n "${MANIFOLD_BENCH_OLLAMA_MODEL:-}" ]; then
    _installed_norm="$(_ollama_tags | sed 's/:latest$//' | sort -u)"
    # Only validate if we actually got a tag list back — a transient /api/tags
    # failure here must not falsely rewrite a valid caller model to a fallback.
    if [ -n "$_installed_norm" ] && ! printf '%s\n' "$_installed_norm" | grep -qxF "${MANIFOLD_BENCH_OLLAMA_MODEL%:latest}"; then
      _bench_fallback="$(printf '%s\n' "$OLLAMA_CHAT_TAGS" | grep -iE '[0-9]b' | head -1)"
      [ -n "$_bench_fallback" ] || _bench_fallback="$(printf '%s\n' "$OLLAMA_CHAT_TAGS" | head -1)"
      _bench_fallback="${_bench_fallback%:latest}"
      if [ -n "$_bench_fallback" ]; then
        echo "MANIFOLD_BENCH_OLLAMA_MODEL '$MANIFOLD_BENCH_OLLAMA_MODEL' NOT installed -> falling back to installed '$_bench_fallback'" >> "$REPORT"
        export MANIFOLD_BENCH_OLLAMA_MODEL="$_bench_fallback"
      else
        echo "MANIFOLD_BENCH_OLLAMA_MODEL '$MANIFOLD_BENCH_OLLAMA_MODEL' NOT installed and no chat tag to fall back to — benchmark will 404" >> "$REPORT"
      fi
    fi
  fi
  { echo '```'; echo; } >> "$REPORT"
fi

# ----- 1. core lane: real-Ollama E2E ----------------------------------------
if have_lane core; then
  # Anchor to the Ollama real-inference suites only. The bare ManifoldE2ETests
  # filter also pulls Foundation (OS-gated), MCP-backed demo scenarios (need
  # local MCP servers), and GlassBox-live suites — which trap/crash without
  # that infra and drown the real signal. The `\.Ollama` anchor matches
  # OllamaE2ETests / OllamaThinkingE2ETests / OllamaToolCallingE2ETests /
  # OllamaBackendBenchmark (post-v2 swift-test needs the `\.` anchor).
  run_lane core "$OUT/core.log" \
    bash -c "cd '$CORE_DIR' && swift test --filter 'ManifoldE2ETests\.Ollama' 2>&1"
fi

# ----- 2. llama lane: grammar/tool conformance + regression fixtures ---------
if have_lane llama && [ -d "$LLAMA_DIR" ]; then
  # NOTE: RUN_SLOW_TESTS deliberately NOT set — the slow contract suites
  # (LlamaLocalBackendContractTests) need a wired fixture model, not on-disk
  # discovery, and fail "No model loaded" under bare discovery. Integration +
  # conformance suites run via MANIFOLD_DISCOVER_LOCAL_MODELS alone. Set
  # MANIFOLD_EMBEDDING_MODEL_PATH externally to also light up embedding live-fire.
  run_lane llama "$OUT/llama.log" \
    bash -c "cd '$LLAMA_DIR' && MANIFOLD_DISCOVER_LOCAL_MODELS=1 swift test --no-parallel 2>&1"
elif have_lane llama; then
  lane_noop "llama" "repo absent at $LLAMA_DIR"
fi

# ----- 3. mlx lane: text E2E + vision input + benchmark ----------------------
if have_lane mlx && [ -d "$MLX_DIR" ]; then
  # text + benchmark. --rebuild on the first MLX invocation forces
  # build-for-testing to (re)generate the .xctestrun; without it a missing/stale
  # derived bundle makes test-without-building fail instantly ("target not found
  # in xctestrun"). Pass the model NAME as a positional arg — the script injects
  # MLX_TEST_MODEL into the patched xctestrun (env-prefix does not propagate to
  # the xctest runner; that is the whole reason the script exists).
  run_lane mlx-text "$OUT/mlx-text.log" \
    bash -c "cd '$MLX_DIR' && scripts/test-mlx-integration.sh Qwen2.5-0.5B --rebuild 2>&1"
  # vision input path — reuses the cached build from the text lane. The VLM gate
  # test reads MLX_VLM_TEST_MODEL from the ENV (the script forwards it into the
  # xctestrun); a positional arg only sets MLX_TEST_MODEL, leaving the gate test
  # to skip. Override MLX_VLM_TEST_MODEL externally to point at a different VLM.
  run_lane mlx-vlm "$OUT/mlx-vlm.log" \
    bash -c "cd '$MLX_DIR' && MLX_VLM_TEST_MODEL='${MLX_VLM_TEST_MODEL:-Qwen2-VL}' scripts/test-mlx-integration.sh --only MLXVLMGateExperimentTests 2>&1"
elif have_lane mlx; then
  lane_noop "mlx" "repo absent at $MLX_DIR"
fi

# ----- 4. conformance matrix (rendered from ConformanceRecords) --------------
# Run the reference tool-calling scenarios through the manifold-tools harness,
# then SCORE -> emit [ConformanceRecord] JSON -> RENDER MATRIX.md. The matrix is
# a PURE rendered query over the records (MatrixRenderer): the same records
# always render byte-identical, and absence (model/GGUF/backend missing) reads as
# a 🚫/💥 hole row, never a measured 0.000. This covers the Ollama leg; the
# companion llama/mlx legs emit the same record shape from their own repos, so a
# cross-leg collation can later concatenate the JSON arrays before `matrix`.
# Bash 3.2 safe — no associative arrays.
# Merge every per-cell records-*.json array under DIR matching PREFIX* into one
# JSON array at OUT. Bash-3.2-safe (no associative arrays); python3 is already
# a hard dependency of this script (see _resolve_roles above).
# args: out-path  glob-dir  glob-prefix
merge_records_json() {
  python3 - "$1" "$2" "$3" <<'PY'
import glob, json, os, sys
out_path, dir_, prefix = sys.argv[1], sys.argv[2], sys.argv[3]
merged = []
for f in sorted(glob.glob(os.path.join(dir_, prefix + "*.json"))):
    try:
        with open(f) as fh:
            data = json.load(fh)
        if isinstance(data, list):
            merged.extend(data)
    except Exception:
        pass  # a cell that failed to score contributes no records, not a crash
with open(out_path, "w") as fh:
    json.dump(merged, fh)
print(len(merged))
PY
}

# Build a tool-name -> approximate-schema-byte-size lookup table, ONCE per
# run (tool definitions are static within a run), from the REAL source
# specification of every decoy tool in DecoyTools.swift. For each `def(name,
# description, [(param, paramDescription), ...], required: [...])` call, the
# byte length of the ENTIRE Swift literal span (name + description + every
# param name/description) is used as a size proxy — not a byte-perfect
# reconstruction of the JSON schema `--extra-tools` actually sends (that would
# require touching Sources/ or wire-capturing live Ollama traffic mid-sweep,
# both out of scope for a shell-only lane), but a real, per-tool, monotonic-
# with-complexity number derived from the SHIPPED spec, not a guess. This is
# what makes the estimate actually VARY across decoy levels — see the
# comment on `append_cell_stats` below for why a flat guess wouldn't. The six
# built-in reference tools (now/calc/read_file/list_dir/sample_repo_search/
# http_get_fixture) get a flat documented constant: they are the scenario's
# REQUIRED set, constant per scenario regardless of decoy level, so their
# precision doesn't affect whether the curve varies with level — only its
# constant offset, which doesn't need per-tool fidelity.
# args: core-dir  out-tsv-path
build_tool_schema_size_table() {
  python3 - "$1" "$2" <<'PY'
import re, sys
core_dir, out_path = sys.argv[1], sys.argv[2]
decoy_path = core_dir + "/Sources/ManifoldTools/ReferenceTools/DecoyTools.swift"
sizes = {}
try:
    with open(decoy_path) as fh:
        text = fh.read()
except FileNotFoundError:
    text = ""
i, n = 0, len(text)
while True:
    idx = text.find('def("', i)
    if idx == -1:
        break
    open_paren = text.find("(", idx)
    depth, in_str, j = 0, False, open_paren
    while j < n:
        c = text[j]
        if c == '"' and text[j - 1] != "\\":
            in_str = not in_str
        elif not in_str:
            if c == "(":
                depth += 1
            elif c == ")":
                depth -= 1
                if depth == 0:
                    break
        j += 1
    span = text[idx:j + 1]
    m = re.match(r'def\("([^"]+)"', span)
    if m:
        sizes[m.group(1)] = len(span)
    i = j + 1 if j < n else n
for ref_tool in ("now", "calc", "read_file", "list_dir", "sample_repo_search", "http_get_fixture"):
    sizes.setdefault(ref_tool, 220)
with open(out_path, "w") as fh:
    for name, size in sorted(sizes.items()):
        fh.write("%s\t%d\n" % (name, size))
print(len(sizes))
PY
}

# Append one row per (scenario, model, backend) cell to CELL_STATS: the
# prompt-text size, the advertised-tool count, AND the tool-SCHEMA size
# estimate — all the transcript's own `prompt` record carried for that cell.
# THIS IS NOT OPTIONAL BOOKKEEPING: `promptTextTokenEstimate` alone is
# INVARIANT with decoy level (scenario.systemPrompt/userPrompt never change —
# only the tool array does), so a column that never moves across levels
# cannot distinguish "context overflow" from "tool-selection capability",
# which was the whole point (found in review of an earlier revision of this
# file). `toolSchemaTokenEstimate` (built from `build_tool_schema_size_table`
# above) is what actually grows with decoy level, so `promptTokenEstimateTotal`
# — the sum of both — is the number a reader should actually watch move.
# `model`/`backend` are read straight off the SAME transcript record
# (TranscriptLogger stamps both on every event) so multi-model /
# multi-backend runs stay attributable per row instead of collapsing N
# models' worth of cells into unattributable duplicates (both legs append
# into the same CELL_STATS file — see the matrix/collate call sites).
# Caveat, stated plainly: `advertisedTools`/prompt text are read from what
# ManifoldKit's own ToolRegistry/PromptAssembler HANDED TO the backend, not a
# wire capture of what the backend actually parsed off the socket — the
# closest signal observable without instrumenting the wire from a
# shell-only lane. `*TokenEstimate` columns are chars/4 heuristics over real
# source content, NOT a real tokenizer count — directional, not authoritative.
# args: transcript-jsonl  decoyLevel  repeatIndex  cell-stats-tsv  schema-size-tsv
append_cell_stats() {
  python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import json, sys
transcript, level, rep, out_path, sizes_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
sizes = {}
try:
    with open(sizes_path) as fh:
        for line in fh:
            parts = line.rstrip("\n").split("\t")
            if len(parts) == 2:
                sizes[parts[0]] = int(parts[1])
except FileNotFoundError:
    pass
DEFAULT_TOOL_SIZE = 150  # fallback for a name absent from the table — should not normally hit
rows = []
try:
    with open(transcript) as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
            except Exception:
                continue
            if obj.get("kind") != "prompt":
                continue
            system = obj.get("system", "") or ""
            user = obj.get("user", "") or ""
            advertised = obj.get("advertisedTools", []) or []
            text_chars = len(system) + len(user)
            schema_bytes = sum(sizes.get(name, DEFAULT_TOOL_SIZE) for name in advertised)
            text_tok = text_chars // 4
            schema_tok = schema_bytes // 4
            rows.append((
                obj.get("scenario", "?"), obj.get("backend", "?"), obj.get("model", "?"),
                level, rep, text_chars, text_tok, len(advertised), schema_bytes, schema_tok,
                text_tok + schema_tok,
            ))
except FileNotFoundError:
    pass
with open(out_path, "a") as fh:
    for r in rows:
        fh.write("\t".join(str(x) for x in r) + "\n")
PY
}

# Assert no emitted record still carries the "unknown" coreCommit placeholder.
# The whole point of resolving MANIFOLD_CORE_COMMIT once at the top of this
# script is to give collate's cross-leg comparability guard a real, shared
# value; a leg that silently fell back to the placeholder recreates the exact
# inert-guard state manifold-mlx#178 exists to close — and because the run
# still exits clean otherwise, it would look identical to success. Only
# asserted when resolution itself succeeded; when it did NOT (see the loud
# preflight FAIL above), "unknown" is the honest, already-announced value,
# not a silent wiring defect.
# args: label  records-json-path
assert_no_placeholder_core_commit() {
  local label="$1" path="$2"
  [ "$CORE_COMMIT_RESOLVED" -eq 1 ] || return 0
  [ -s "$path" ] || return 0
  local bad
  bad="$(python3 - "$path" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    records = json.load(fh)
print(sum(1 for r in records if r.get("coreCommit") == "unknown"))
PY
)"
  if [ "${bad:-0}" -gt 0 ]; then
    SUMMARY_LANES="${SUMMARY_LANES}${label}: CORE-COMMIT WIRING DEAD — $bad record(s) carry the placeholder 'unknown' coreCommit despite MANIFOLD_CORE_COMMIT=$MANIFOLD_CORE_COMMIT resolving cleanly; collate's comparability guard is inert for this leg (manifold-mlx#178) -> $path\n"
    FAILED_LANES="${FAILED_LANES}${label}: core-commit wiring dead ($bad placeholder record(s))\n"
  else
    SUMMARY_LANES="${SUMMARY_LANES}${label}: core-commit wiring OK — no record carries the placeholder (coreCommit=$MANIFOLD_CORE_COMMIT)\n"
  fi
}

# LOAD-BEARING INVARIANT, invisible from the scorer side: `decoyLevel` is NOT
# part of ConformanceScorer's grouping key (backend x model x quant x
# scenario) — it's derived post-hoc from `advertisedTools` on the transcript's
# `prompt` record. The per-level loops below are safe ONLY because they write
# exactly ONE transcript per (decoyLevel, repeatIndex) cell. If anything ever
# appends two decoy levels into the SAME transcript file, the scorer silently
# merges them into a single accumulator keyed on the LAST prompt record's
# advertised set — one plausible-looking row that is actually two levels
# averaged together, with no error and no warning. Never change either loop to
# append multiple levels into one `--output` path. `assert_transcript_count`
# below is the only thing that would catch a regression here.
# args: label  dir  glob-pattern  expected-count
assert_transcript_count() {
  local label="$1" dir="$2" pattern="$3" expected="$4"
  local actual
  actual="$(find "$dir" -maxdepth 1 -type f -name "$pattern" 2>/dev/null | grep -c .)"
  if [ "${actual:-0}" -eq "$expected" ]; then
    SUMMARY_LANES="${SUMMARY_LANES}${label}: transcript count OK — $actual/$expected distinct (decoyLevel x repeatIndex) transcripts\n"
  else
    SUMMARY_LANES="${SUMMARY_LANES}${label}: TRANSCRIPT COUNT MISMATCH — $actual/$expected distinct transcripts; a missing/merged file means decoyLevel attribution for that leg may be silently wrong (see the invariant comment above the sweep loop) -> $dir\n"
    FAILED_LANES="${FAILED_LANES}${label}: transcript count mismatch ($actual/$expected)\n"
  fi
}

# Prints two labeled, EXPLICITLY SEPARATE series from a merged records.json:
#   1. F1 vs decoyLevel, over TOOL-BEARING scenarios only (toolSelection != null).
#   2. Decoy-grab rate vs decoyLevel, over ABSTENTION-CLASS scenarios only
#      (toolSelection == null, i.e. requiredTools was empty) — the fraction of
#      those runs where the model called a tool anyway (failureClass ==
#      "lowPrecision", which fires exactly when confusion.fp > 0 on a
#      non-tool-bearing row).
# These MUST stay separate: a non-tool-bearing row's toolSelection is nil
# because precision/recall/F1 are mathematically undefined with zero expected
# positives — averaging a naive 0-for-nil into the F1 series would read as a
# dramatic precision collapse that is entirely an artifact of the averaging,
# not a real degradation.
# args: label  records-json-path
report_degradation_curves() {
  local label="$1" path="$2"
  [ -s "$path" ] || return 0
  python3 - "$label" "$path" <<'PY'
import json, sys
from collections import defaultdict
label, path = sys.argv[1], sys.argv[2]
with open(path) as fh:
    records = json.load(fh)
by_level = defaultdict(lambda: {"f1_sum": 0.0, "f1_n": 0, "abst_n": 0, "abst_grab": 0})
for r in records:
    if (r.get("status") or {}).get("kind") != "measured":
        continue  # holes carry no toolSelection/failureClass signal
    level = r.get("decoyLevel")
    ts = r.get("toolSelection")
    d = by_level[level]
    if ts is not None:
        d["f1_sum"] += ts["f1"]
        d["f1_n"] += 1
    else:
        # Non-tool-bearing (abstention-class): toolSelection is nil BY DESIGN,
        # never averaged as a 0. failureClass == "lowPrecision" is the only
        # signal that survives for these rows (confusion.fp > 0).
        d["abst_n"] += 1
        if r.get("failureClass") == "lowPrecision":
            d["abst_grab"] += 1
print("-- %s: F1-vs-decoyLevel (tool-bearing scenarios only) --" % label)
print("decoyLevel\tmeanF1\tn_tool_bearing_measurements")
for level in sorted(k for k in by_level if by_level[k]["f1_n"] > 0):
    d = by_level[level]
    print("%s\t%.3f\t%d" % (level, d["f1_sum"] / d["f1_n"], d["f1_n"]))
print("-- %s: decoy-grab-rate-vs-decoyLevel (abstention scenarios only, NOT part of the F1 curve above) --" % label)
print("decoyLevel\tdecoyGrabRate\tn_abstention_measurements")
for level in sorted(k for k in by_level if by_level[k]["abst_n"] > 0):
    d = by_level[level]
    print("%s\t%.3f\t%d" % (level, d["abst_grab"] / d["abst_n"], d["abst_n"]))

# Repeat spread: `MatrixRenderer` keys on (backend, model, quant, renderer)
# and reports count + MEAN F1 across repeats — but the documented reason
# repeats exist at all is to see the run-to-run F1 SWING (a 0.10-0.12 F1
# range observed historically), which a mean alone hides. Group by the full
# cell coordinate MINUS repeatIndex and report min/max/spread over the
# repeats actually gathered for that cell.
per_cell = defaultdict(list)
for r in records:
    if (r.get("status") or {}).get("kind") != "measured":
        continue
    ts = r.get("toolSelection")
    if ts is None:
        continue  # spread is only meaningful on the F1 series (tool-bearing)
    key = (r.get("backend"), r.get("model"), r.get("quant"), r.get("scenario"), r.get("decoyLevel"))
    per_cell[key].append(ts["f1"])
print("-- %s: repeat spread (min/max F1 across repeatIndex, per cell; NOT the same as MatrixRenderer's mean) --" % label)
print("backend\tmodel\tquant\tscenario\tdecoyLevel\tn_repeats\tminF1\tmaxF1\tspread\tmeanF1")
for key in sorted(per_cell, key=lambda k: (str(k[0]), str(k[1]), str(k[2]), str(k[3]), k[4] if k[4] is not None else -1)):
    vals = per_cell[key]
    if len(vals) < 2:
        continue  # a spread over one sample is not a spread
    lo, hi, mean = min(vals), max(vals), sum(vals) / len(vals)
    print("%s\t%s\t%s\t%s\t%s\t%d\t%.3f\t%.3f\t%.3f\t%.3f" % (
        key[0], key[1], key[2], key[3], key[4], len(vals), lo, hi, hi - lo, mean))
PY
}

if have_lane core; then
  MATRIX_DIR="$OUT/matrix"
  mkdir -p "$MATRIX_DIR"
  RECORDS="$MATRIX_DIR/records.json"
  MATRIX_MD="$OUT/MATRIX.md"
  CELL_STATS="$MATRIX_DIR/cell-stats.tsv"
  printf 'scenario\tbackend\tmodel\tdecoyLevel\trepeatIndex\tpromptTextChars\tpromptTextTokenEstimate\tadvertisedToolCount\ttoolSchemaBytesEstimate\ttoolSchemaTokenEstimate\tpromptTokenEstimateTotal\n' > "$CELL_STATS"
  TOOL_SCHEMA_SIZES="$MATRIX_DIR/tool-schema-sizes.tsv"
  build_tool_schema_size_table "$CORE_DIR" "$TOOL_SCHEMA_SIZES" >/dev/null
  # MANIFOLD_CORE_COMMIT is resolved ONCE, at the top of this script, and
  # exported — every leg passes the SAME value rather than each computing its
  # own (see the preflight "core-commit" check for loud failure reporting).
  log "=== [matrix] $(date +%H:%M:%S) building manifold-tools ==="
  if ( cd "$CORE_DIR" && swift build --product manifold-tools ) >"$MATRIX_DIR/build.log" 2>&1; then
    TOOL_BIN="$(cd "$CORE_DIR" && swift build --product manifold-tools --show-bin-path 2>/dev/null)/manifold-tools"
    if curl -s --max-time 3 localhost:11434/api/tags >/dev/null 2>&1; then
      # Optional model override: MATRIX_MODELS="m1,m2". Unset -> scenario defaults
      # (in which case MODEL_COUNT below is a lower-bound placeholder of 1 — the
      # coverage denominator cannot know a per-scenario default model count
      # without running the harness, so an unset MATRIX_MODELS makes the
      # coverage assertion advisory rather than exact; the auto-selection above
      # normally sets MATRIX_MODELS from installed tags, so this is the rare path).
      MATRIX_MODEL_ARGS=""
      if [ -n "${MATRIX_MODELS:-}" ]; then MATRIX_MODEL_ARGS="--model ${MATRIX_MODELS}"; fi
      # `--list` prints a "Available scenarios:" HEADER line before the
      # per-scenario lines (each indented "  <id> — <description>") — a bare
      # `grep -c .` over-counts by exactly 1, which made the coverage
      # assertion below FAIL EVERY RUN regardless of actual coverage (a
      # permanent false alarm indistinguishable from a real shortfall).
      # Anchor on the two-space indent every scenario line actually has.
      SCENARIO_COUNT="$("$TOOL_BIN" --list 2>/dev/null | grep -c '^  ')"
      MODEL_COUNT=1
      [ -n "${MATRIX_MODELS:-}" ] && MODEL_COUNT="$(printf '%s' "$MATRIX_MODELS" | tr ',' '\n' | grep -c .)"
      LEVEL_COUNT="$(printf '%s' "$DECOY_LEVELS" | tr ',' '\n' | grep -c .)"
      MATRIX_LEVEL_TIMEOUT=0
      for LEVEL in $(printf '%s' "$DECOY_LEVELS" | tr ',' ' '); do
        log "=== [matrix] $(date +%H:%M:%S) decoyLevel=$LEVEL x ${SWEEP_REPEATS} repeat(s) ==="
        # ONE run_capped_lane invocation per (leg=ollama x decoyLevel) — this is
        # load-bearing: run_capped_lane kills at LANE_TIMEOUT (2400s) and reports
        # "records partial or absent"; a single invocation covering every level
        # AND every repeat would blow the cap and lose the ENTIRE leg. Scoped per
        # level (repeats run inside), a hang costs one cell-group, not the night.
        run_capped_lane "$MATRIX_DIR/run-L${LEVEL}.log" bash -c "
          set -uo pipefail
          for REP in \$(seq 1 '$SWEEP_REPEATS'); do
            T=\"$MATRIX_DIR/transcript-L${LEVEL}-R\${REP}.jsonl\"
            R=\"$MATRIX_DIR/records-L${LEVEL}-R\${REP}.json\"
            cd '$CORE_DIR' && '$TOOL_BIN' --backend ollama --scenario all \
              --extra-tools '$LEVEL' --repeat-index \"\$REP\" \
              --output \"\$T\" $MATRIX_MODEL_ARGS
            # A non-zero exit means some scenarios failed — that is DATA (a
            # decoy-pressure regression is exactly what this sweep hunts), so
            # score the transcript regardless of the run's own exit code.
            if [ -s \"\$T\" ]; then
              '$TOOL_BIN' score \"\$T\" --emit-records \"\$R\" \
                --renderer ollama-server --core-commit '$MANIFOLD_CORE_COMMIT' \
                >/dev/null 2>>\"$MATRIX_DIR/score-L${LEVEL}.log\"
            fi
          done
        "
        LEVEL_RC=$?
        if [ "$LEVEL_RC" -eq 143 ] || [ "$LEVEL_RC" -eq 137 ]; then
          MATRIX_LEVEL_TIMEOUT=1
          SUMMARY_LANES="${SUMMARY_LANES}matrix: decoyLevel=$LEVEL TIMEOUT/killed (rc=$LEVEL_RC, cap ${LANE_TIMEOUT}s) — records for this level are partial or absent\n"
          FAILED_LANES="${FAILED_LANES}matrix: decoyLevel=$LEVEL TIMEOUT/killed after ${LANE_TIMEOUT}s\n"
        fi
        for REP in $(seq 1 "$SWEEP_REPEATS"); do
          append_cell_stats "$MATRIX_DIR/transcript-L${LEVEL}-R${REP}.jsonl" "$LEVEL" "$REP" "$CELL_STATS" "$TOOL_SCHEMA_SIZES"
        done
      done
      assert_transcript_count "matrix" "$MATRIX_DIR" "transcript-L*-R*.jsonl" $(( LEVEL_COUNT * SWEEP_REPEATS ))
      RECORD_COUNT="$(merge_records_json "$RECORDS" "$MATRIX_DIR" "records-L")"
      if [ -s "$RECORDS" ] && [ "${RECORD_COUNT:-0}" -gt 0 ]; then
        assert_no_placeholder_core_commit "matrix" "$RECORDS"
        # ---- coverage-denominator assertion -------------------------------
        # measured + notMeasured + loadFail + renderFail MUST equal
        # scenarios x levels x repeats x models. A short matrix that renders
        # cleanly is the "empty CSV reads as measured" defect — count every
        # cell, not just the ones that happened to render a row.
        EXPECTED_CELLS=$(( SCENARIO_COUNT * LEVEL_COUNT * SWEEP_REPEATS * MODEL_COUNT ))
        COVERAGE_REPORT="$MATRIX_DIR/coverage.txt"
        python3 - "$RECORDS" "$EXPECTED_CELLS" > "$COVERAGE_REPORT" <<'PY'
import json, sys
records_path, expected = sys.argv[1], int(sys.argv[2])
with open(records_path) as fh:
    records = json.load(fh)
counts = {}
for r in records:
    kind = (r.get("status") or {}).get("kind", "unknown")
    counts[kind] = counts.get(kind, 0) + 1
total = sum(counts.values())
for k in ("measured", "notMeasured", "loadFail", "renderFail"):
    counts.setdefault(k, 0)
print("expected_cells=%d actual_records=%d" % (expected, total))
for k, v in sorted(counts.items()):
    print("  %s=%d" % (k, v))
print("MATCH" if total == expected else "MISMATCH")
PY
        if grep -q '^MATCH$' "$COVERAGE_REPORT"; then
          SUMMARY_LANES="${SUMMARY_LANES}matrix: coverage OK — $(grep '^expected_cells' "$COVERAGE_REPORT") -> $(basename "$COVERAGE_REPORT")\n"
        else
          SUMMARY_LANES="${SUMMARY_LANES}matrix: COVERAGE MISMATCH — $(grep '^expected_cells' "$COVERAGE_REPORT")$([ "$MATRIX_LEVEL_TIMEOUT" -eq 1 ] && echo ' (expected: a level TIMEOUT above already explains a shortfall)') -> $(basename "$COVERAGE_REPORT")\n"
          FAILED_LANES="${FAILED_LANES}matrix: coverage mismatch — see $(basename "$COVERAGE_REPORT")\n"
        fi
        if "$TOOL_BIN" matrix "$RECORDS" --out "$MATRIX_MD" 2>"$MATRIX_DIR/matrix-render.log"; then
          SUMMARY_LANES="${SUMMARY_LANES}matrix: rendered $RECORD_COUNT record(s) across decoyLevels={$DECOY_LEVELS} x ${SWEEP_REPEATS} repeat(s) -> $(basename "$MATRIX_MD")\n"
          log "=== [matrix] $(date +%H:%M:%S) rendered $MATRIX_MD ==="
        else
          SUMMARY_LANES="${SUMMARY_LANES}matrix: render failed -> matrix/matrix-render.log\n"
          FAILED_LANES="${FAILED_LANES}matrix: render failed\n"
        fi
      else
        lane_noop "matrix" "no records emitted across any decoyLevel — Ollama models absent, or every cell errored (see matrix/run-L*.log, matrix/score-L*.log)"
      fi
    else
      lane_noop "matrix" "Ollama down at localhost:11434"
    fi
  else
    lane_noop "matrix" "manifold-tools build failed -> matrix/build.log"
  fi
fi

# ----- 4c. cross-runtime collate ---------------------------------------------
# The matrix lane above renders the OLLAMA leg alone. This lane adds the MLX leg
# from the same core commit and folds both through manifold-eval's `collate`,
# whose comparability guard (records are only comparable across the same core
# binary) is the entire reason to use it over `cat *.json | matrix`.
#
# WHY THIS MATTERS: a cross-backend soak once found the SAME Mistral-v0.3 weights
# producing DIFFERENT tool-call verdicts across Ollama, llama.cpp and MLX. That
# incident is why manifold-eval exists as a separate repo — but until now nothing
# actually ran the comparison, and this script's own comment said cross-runtime
# collation was "deferred".
#
# ONE KNOWN LIMITATION, surfaced in the output rather than hidden:
#   There is NO llama leg. `manifold-tools-llama` parses only --model/--bench/
#   --flash/--describe — it has no --emit-records path, unlike its MLX sibling.
#   Nothing emits a placeholder record for it, so the matrix simply has no
#   llama row; the absence is carried in this lane's summary line instead. A
#   missing row is NOT a measured zero — do not read it as one.
#
# `manifold-tools-mlx` previously hardcoded `coreCommit: "unknown"` (manifold-mlx#178),
# which made collate's comparability guard structurally inert for the MLX leg.
# Fixed there (flag -> $MANIFOLD_CORE_COMMIT env var -> placeholder) and wired
# here via the explicit `--core-commit` passed to manifold-tools-mlx below,
# plus assert_no_placeholder_core_commit's post-merge check. UNTESTED
# end-to-end from this worktree: manifold-mlx's fix is on an unmerged branch
# (manifold-mlx#182) not reachable from origin/main.
if have_lane collate; then
  COLLATE_DIR="$OUT/collate"; mkdir -p "$COLLATE_DIR"
  XRUNTIME_MD="$OUT/XRUNTIME_MATRIX.md"
  # Family to compare. Must exist as an MLX snapshot dir AND as an Ollama tag; the
  # default is the family from the founding divergence incident.
  COLLATE_FAMILY="${COLLATE_FAMILY:-Mistral-7B-Instruct-v0.3}"
  COLLATE_MLX_MODEL="${COLLATE_MLX_MODEL:-}"
  if [ -z "$COLLATE_MLX_MODEL" ]; then
    # Require config.json: a plain -name match also hits the GGUF family dir,
    # and `gguf` sorts before `mlx`, so head -1 selected a directory with no MLX
    # snapshot in it and the lane no-op'd with a reason that was simply false.
    COLLATE_MLX_MODEL="$(find "$MODELS_DIR" -maxdepth 3 -type d -name "*${COLLATE_FAMILY}*" 2>/dev/null \
      | while read -r _d; do [ -f "$_d/config.json" ] && printf '%s\n' "$_d"; done | head -1)"
  fi
  OLLAMA_RECORDS="$OUT/matrix/records.json"

  if [ ! -s "$OLLAMA_RECORDS" ]; then
    lane_noop "collate" "no Ollama records at matrix/records.json — the matrix lane must succeed first"
  elif [ ! -d "$EVAL_DIR" ]; then
    lane_noop "collate" "manifold-eval absent at $EVAL_DIR — nothing can fold the legs"
  elif [ ! -d "$MLX_DIR" ]; then
    lane_noop "collate" "manifold-mlx absent at $MLX_DIR — only one leg available, a 1-leg collate is not a comparison"
  elif [ -z "$COLLATE_MLX_MODEL" ] || [ ! -f "$COLLATE_MLX_MODEL/config.json" ]; then
    lane_noop "collate" "no MLX snapshot dir matching '$COLLATE_FAMILY' under $MODELS_DIR"
  else
    log "=== [collate] $(date +%H:%M:%S) building manifold-tools-mlx ==="
    if ( cd "$MLX_DIR" && swift build --product manifold-tools-mlx ) >"$COLLATE_DIR/mlx-build.log" 2>&1; then
      MLX_TOOL_BIN="$(cd "$MLX_DIR" && swift build --product manifold-tools-mlx --show-bin-path 2>/dev/null)/manifold-tools-mlx"
      MLX_RECORDS="$COLLATE_DIR/mlx-records.json"
      MLX_LEVEL_TIMEOUT=0
      # DEPENDENCY: `--extra-tools`/`--repeat-index` are `ScenarioCLIHarness`
      # common flags — manifold-tools-mlx gets them for free once manifold-mlx
      # pins a core commit that carries both (--extra-tools already does;
      # --repeat-index does not exist on core as of this writing, see the
      # DECOY_LEVELS/SWEEP_REPEATS comment near the top of this script). Until
      # that pin bump lands, every cell below fails fast with a CLI parse
      # error rather than silently measuring the wrong thing.
      # `--core-commit` is manifold-mlx#178's fix (flag -> $MANIFOLD_CORE_COMMIT
      # env var, exported at the top of this script -> a documented "unknown"
      # placeholder) — passed explicitly here rather than relying on the env
      # fallback so the value this leg stamps is unambiguous.
      for LEVEL in $(printf '%s' "$DECOY_LEVELS" | tr ',' ' '); do
        log "=== [collate] $(date +%H:%M:%S) MLX leg decoyLevel=$LEVEL x ${SWEEP_REPEATS} repeat(s) on $COLLATE_MLX_MODEL ==="
        # ONE run_capped_lane invocation per (leg=mlx x decoyLevel) — same
        # reasoning as the matrix lane above: scoping the watchdog per level
        # means a hang costs one cell-group, not the whole collate leg.
        run_capped_lane "$COLLATE_DIR/mlx-run-L${LEVEL}.log" bash -c "
          set -uo pipefail
          for REP in \$(seq 1 '$SWEEP_REPEATS'); do
            T=\"$COLLATE_DIR/mlx-transcript-L${LEVEL}-R\${REP}.jsonl\"
            R=\"$COLLATE_DIR/mlx-records-L${LEVEL}-R\${REP}.json\"
            # A non-zero exit means some scenarios failed — that is DATA (it is
            # exactly the divergence this lane hunts), so keep going.
            '$MLX_TOOL_BIN' --model '$COLLATE_MLX_MODEL' --scenario all \
              --extra-tools '$LEVEL' --repeat-index \"\$REP\" \
              --core-commit '$MANIFOLD_CORE_COMMIT' \
              --output \"\$T\" --emit-records \"\$R\"
          done
        "
        MLX_LEVEL_RC=$?
        # A watchdog kill (143/137) must be visible; run_capped_lane returns it
        # for exactly this reason and every other caller classifies it.
        if [ "$MLX_LEVEL_RC" -eq 143 ] || [ "$MLX_LEVEL_RC" -eq 137 ]; then
          MLX_LEVEL_TIMEOUT=1
          SUMMARY_LANES="${SUMMARY_LANES}collate: MLX leg decoyLevel=$LEVEL TIMEOUT/killed (rc=$MLX_LEVEL_RC, cap ${LANE_TIMEOUT}s) — records for this level are partial or absent\n"
          FAILED_LANES="${FAILED_LANES}collate: MLX leg decoyLevel=$LEVEL TIMEOUT/killed after ${LANE_TIMEOUT}s\n"
        fi
        for REP in $(seq 1 "$SWEEP_REPEATS"); do
          append_cell_stats "$COLLATE_DIR/mlx-transcript-L${LEVEL}-R${REP}.jsonl" "$LEVEL" "$REP" "$CELL_STATS" "$TOOL_SCHEMA_SIZES"
        done
      done
      # LEVEL_COUNT is normally already set by the matrix block above (this
      # lane only reaches here once OLLAMA_RECORDS exists, which requires
      # `have_lane core` to have run) — recomputed defensively so this
      # assertion never reads an unset/stale value if that assumption ever
      # changes.
      COLLATE_LEVEL_COUNT="$(printf '%s' "$DECOY_LEVELS" | tr ',' '\n' | grep -c .)"
      assert_transcript_count "collate:mlx" "$COLLATE_DIR" "mlx-transcript-L*-R*.jsonl" $(( COLLATE_LEVEL_COUNT * SWEEP_REPEATS ))
      MLX_RECORD_COUNT="$(merge_records_json "$MLX_RECORDS" "$COLLATE_DIR" "mlx-records-L")"
      if [ -s "$MLX_RECORDS" ] && [ "${MLX_RECORD_COUNT:-0}" -gt 0 ]; then
        assert_no_placeholder_core_commit "collate:mlx" "$MLX_RECORDS"
        if ( cd "$EVAL_DIR" && swift build ) >"$COLLATE_DIR/eval-build.log" 2>&1; then
          EVAL_BIN_C="$(cd "$EVAL_DIR" && swift build --show-bin-path 2>/dev/null)/manifold-eval"
          if "$EVAL_BIN_C" collate "$OLLAMA_RECORDS" "$MLX_RECORDS" \
               --out "$XRUNTIME_MD" --title "Runtime comparison — $COLLATE_FAMILY" \
               >"$COLLATE_DIR/collate.log" 2>&1; then
            # CAVEAT (not this lane's own defect — flagged pending a companion
            # fix): core's DecoyTools pool has 46 entries; the manifold-mlx /
            # manifold-llama companions still carry their own stale ~24-entry
            # local copies with only partial overlap (confirmed on the llama
            # side: `--extra-tools 10` there actually advertises decoyLevel=7,
            # because 4 of core's first 10 decoy names aren't in its local
            # pool). Until the companions migrate to consuming core's shared
            # DecoyTools, this ladder's "same nominal decoyLevel" label does
            # NOT mean "same advertised tool set" across legs — remove this
            # note once that migration lands.
            {
              echo
              echo "> **Caveat:** the Ollama and MLX legs above may advertise DIFFERENT"
              echo "> decoy tool sets at the same nominal \`decoyLevel\` — core's shared"
              echo "> \`DecoyTools\` pool and the companion repos' local copies have not yet"
              echo "> converged. Level-for-level comparison across legs is NOT yet honest;"
              echo "> treat each leg's own within-leg curve as the reliable signal until"
              echo "> the companions migrate."
            } >> "$XRUNTIME_MD"
            # Rendering is NOT the same as comparing. The renderer only emits a
            # cross-runtime section when >=2 legs share a normalized model key,
            # and the two legs name the same weights differently — Ollama by tag
            # (`mistral:7b-instruct-v0.3-q4_K_M`) and MLX by snapshot dir
            # (`Mistral-7B-Instruct-v0.3-4bit`). Those normalize to DIFFERENT
            # keys, so the file renders happily as two unrelated rows with no
            # comparison in it. Claiming "rendered 2 legs" off a zero exit was
            # this script's own green-but-inert failure, reintroduced.
            # Anchor on MatrixRenderer's real section header ("## Cross-runtime
            # view (same logical model, side by side)"), emitted ONLY when >=2
            # legs share a normalized model key. Matching the looser phrase
            # matched this lane's own --title, so the assertion could never fail
            # — the same inert-guard bug, one layer up.
            # Two conditions, both required. The section header is emitted only
            # when >=2 legs share a normalized model key — but `crossRuntimeSection`
            # groups by key WITHOUT requiring distinct backends, so two Ollama tags
            # that normalize alike (e.g. `qwen3.5:9b` and `qwen3.5:9b-instruct`,
            # since `instruct` is dropped) would render a "cross-runtime" section
            # containing no MLX row at all. The sweep auto-selects every installed
            # chat tag, so that collision is one `ollama pull` away. Requiring the
            # section to actually NAME the mlx leg makes the claim match reality.
            if grep -qE '^## Cross-runtime view' "$XRUNTIME_MD" 2>/dev/null \
               && sed -n '/^## Cross-runtime view/,$p' "$XRUNTIME_MD" 2>/dev/null | grep -q '| mlx |'; then
              SUMMARY_LANES="${SUMMARY_LANES}collate: rendered a cross-runtime comparison (ollama+mlx; NO llama leg — manifold-tools-llama lacks --emit-records) -> $(basename "$XRUNTIME_MD")\n"
            else
              lane_noop "collate" "EXPECTED until ManifoldKit#2411 — collate exited 0 but rendered NO cross-runtime section: the legs' model keys did not match, so nothing was actually compared (ollama='$(grep -o '\"model\"[^,]*' "$OLLAMA_RECORDS" 2>/dev/null | head -1)' vs mlx='$(grep -o '\"model\"[^,]*' "$MLX_RECORDS" 2>/dev/null | head -1)') -> $(basename "$XRUNTIME_MD")"
            fi
          else
            SUMMARY_LANES="${SUMMARY_LANES}collate: fail(rc=$?) -> collate/collate.log\n"
            FAILED_LANES="${FAILED_LANES}collate: collate command failed\n"
          fi
          # Surface the guard's own verdict rather than assuming it passed.
          # Match the diagnostic the collator ACTUALLY emits — "records span N
          # ManifoldKit core commits (...)". The previous pattern (coreCommit/
          # mixed/drift) matched none of those words, so the NOTE this lane
          # promises "every run" could never fire once.
          #
          # Both legs now receive the SAME resolved MANIFOLD_CORE_COMMIT (see
          # the top of this script + assert_no_placeholder_core_commit above),
          # so this diagnostic firing is NO LONGER an accepted, expected
          # every-run state — it means the two legs genuinely disagree on
          # coreCommit (a real drift) or one leg is still on old wiring
          # (manifold-mlx#178 not yet merged). Report it as a live signal, not
          # a shrug.
          if grep -qiE '\[warning\]|core commits?' "$COLLATE_DIR/collate.log" 2>/dev/null; then
            SUMMARY_LANES="${SUMMARY_LANES}collate: NOTE comparability diagnostic emitted — legs disagree on coreCommit (real drift, or manifold-mlx#178's fix isn't on the pinned commit this run built) -> collate/collate.log\n"
          fi
        else
          lane_noop "collate" "manifold-eval build failed -> collate/eval-build.log"
        fi
      else
        lane_noop "collate" "MLX leg emitted no records across any decoyLevel -> collate/mlx-run-L*.log"
      fi
    else
      lane_noop "collate" "manifold-tools-mlx build failed -> collate/mlx-build.log"
    fi
  fi
fi

# ----- 4d. eval-vs-core-main -------------------------------------------------
# manifold-eval pins ManifoldKit `exact:` and has no `Canary (core main)`
# workflow, unlike manifold-mlx and manifold-llama. So the one consumer that
# GRADES the family is the only one never built against the core it grades.
# Principle 9 requires known consumers to be built against a change before it
# ships; this lane supplies that signal locally until the canary exists.
if have_lane evalmain && [ -d "$EVAL_DIR/.git" ]; then
  EVALMAIN_DIR="$OUT/evalmain"; mkdir -p "$EVALMAIN_DIR"
  EVALMAIN_CLONE="$EVALMAIN_DIR/manifold-eval"
  # Work on an ISOLATED CLONE, never the operator's checkout. `swift package
  # edit` mutates Package.resolved and plants an Editable entry; if this run is
  # killed mid-lane (the watchdog does exactly that on a hang) an un-undone edit
  # would leave the real repo silently resolving to core `main` instead of its
  # pin — every later eval run would then measure something other than what it
  # reported. Same discipline overnight-sweep.sh's PREP block already applies to
  # branches: measure the tree as-is, never mutate it behind the operator.
  # The clone captures the operator's checkout AS COMMITTED — which may lag its
  # own origin, and does not include uncommitted work. Silently testing a stale
  # eval and reporting a clean pass is the same lie this whole change removes, so
  # measure the lag and say so. `git fetch` only moves remote-tracking refs; it
  # touches no branch and no working tree, so it respects the "measure the tree
  # as-is" rule. Found the hard way: this machine's checkout was 8 commits behind
  # origin/main, which made a stale pin look like a live one.
  # Capture the fetch rc. A FAILED fetch leaves a stale-but-present origin/main
  # ref, so rev-list still succeeds and can report 0 — reading as "fresh" when
  # the truth is "unmeasured". That silent-fresh path is the very incident this
  # block exists to catch, so the failure must be announced, not swallowed.
  git -C "$EVAL_DIR" fetch --quiet origin 2>/dev/null   # fail-open-ok: offline must not abort the lane; the rc is captured on the next line and reported below
  EVAL_FETCH_RC=$?
  EVAL_BEHIND="$(git -C "$EVAL_DIR" rev-list --count HEAD..origin/main 2>/dev/null)"
  EVAL_HEAD="$(git -C "$EVAL_DIR" rev-parse --short HEAD 2>/dev/null)"
  EVAL_DIRTY="$(git -C "$EVAL_DIR" status --porcelain 2>/dev/null | grep -c .)"
  if [ "$EVAL_FETCH_RC" -ne 0 ]; then
    # UNMEASURED, not fresh. Say so regardless of what rev-list computed.
    SUMMARY_LANES="${SUMMARY_LANES}evalmain: FRESHNESS UNMEASURED — git fetch failed (rc=$EVAL_FETCH_RC, offline?); origin/main ref may be stale, so \"behind=${EVAL_BEHIND:-?}\" is not trustworthy\n"
    STALE_NOTES="${STALE_NOTES}evalmain freshness unmeasured (fetch rc=$EVAL_FETCH_RC)\n"
  elif [ -z "$EVAL_BEHIND" ]; then
    SUMMARY_LANES="${SUMMARY_LANES}evalmain: NOTE could not measure clone freshness (no origin/main ref) — result is about local HEAD $EVAL_HEAD\n"
    STALE_NOTES="${STALE_NOTES}evalmain freshness unmeasurable (no origin/main ref)\n"
  elif [ "$EVAL_BEHIND" -gt 0 ]; then
    SUMMARY_LANES="${SUMMARY_LANES}evalmain: STALE SOURCE — cloned HEAD $EVAL_HEAD is $EVAL_BEHIND commit(s) behind origin/main; this lane tested OLD manifold-eval against core\n"
    STALE_NOTES="${STALE_NOTES}evalmain tested manifold-eval $EVAL_BEHIND commit(s) behind origin/main (HEAD $EVAL_HEAD)\n"
  fi
  [ "${EVAL_DIRTY:-0}" -gt 0 ] && SUMMARY_LANES="${SUMMARY_LANES}evalmain: NOTE $EVAL_DIRTY uncommitted path(s) in $EVAL_DIR are NOT in the clone\n"
  log "=== [evalmain] $(date +%H:%M:%S) cloning manifold-eval ($EVAL_HEAD, behind=${EVAL_BEHIND:-?}) -> $EVALMAIN_CLONE ==="
  if git clone --shared --quiet "$EVAL_DIR" "$EVALMAIN_CLONE" 2>"$EVALMAIN_DIR/clone.log"; then
    run_lane evalmain "$EVALMAIN_DIR/evalmain.log" \
      bash -c "cd '$EVALMAIN_CLONE' && \
        echo '--- pinned dependency before override:' && \
        grep -n 'ManifoldKit.git' Package.swift && \
        swift package edit manifoldkit --path '$CORE_DIR' 2>&1 && \
        echo '--- building manifold-eval against core at $CORE_DIR' && \
        swift build 2>&1 && \
        swift test 2>&1"
  else
    lane_noop "evalmain" "git clone of $EVAL_DIR failed -> evalmain/clone.log"
  fi
elif have_lane evalmain; then
  lane_noop "evalmain" "manifold-eval absent (or not a git repo) at $EVAL_DIR"
fi

# ----- 4b. eval lane: local-LLM CAPABILITY scoring via manifold-eval ---------
# Where core/llama/mlx answer "do the backends still integrate", this answers
# "how CAPABLE are the local models" — tool-calling (BFCL), instruction-following
# (IFEval), and embedding quality (MTEB-STS). It drives live Ollama generations
# (not xctest) and scores them with the independent assurance harness, so it is a
# custom block (run_lane's xctest-verdict counting does not apply) with its own
# EVAL_CMD_TIMEOUT watchdog. All corpora are cached locally; models are env-
# overridable. Cross-runtime `diff`/`collate` is deferred — the matrix lane above
# already covers the Ollama conformance leg.
if have_lane eval && [ -d "$EVAL_DIR" ]; then
  EVAL_OUT="$OUT/eval"; mkdir -p "$EVAL_OUT"
  EVAL_CACHE="${MANIFOLD_EVAL_CACHE:-$HOME/.cache/manifold-eval}"
  # Model roster: RESOLVED IN PREFLIGHT from Ollama's own /api/show capabilities,
  # not defaulted to tag-name literals here. The literals this replaced
  # (`mistral-7b-tools`, `llama3.1-8b`, `nomic-embed-text`) matched nothing on a
  # machine tagged `mistral:7b-instruct-v0.3-q4_K_M` / `llama3.1:8b` /
  # `embeddinggemma`, so all three sub-lanes skipped and the sweep still read
  # clean. An empty value here means preflight found nothing for that role; the
  # per-sub-lane guards below report it as a named skip.
  # Rationale preserved from the old defaults: the instruct role takes the
  # largest chat model THAT FITS EVAL_INSTRUCT_MAX_BYTES, so IFEval reflects
  # ManifoldKit's prompt-assembly quality rather than a tiny model's ceiling — a
  # 0.5B scores ~21% and can't separate "model is small" from "MK plumbing is
  # lossy" — while still completing inside the per-case timeout. Override
  # EVAL_INSTRUCT_MODEL=qwen2.5:0.5b-instruct-q4_K_M for the provenance-anchored
  # 22.9% baseline.
  EVAL_TOOL_MODEL="${EVAL_TOOL_MODEL:-}"
  EVAL_INSTRUCT_MODEL="${EVAL_INSTRUCT_MODEL:-}"
  EVAL_EMBED_MODEL="${EVAL_EMBED_MODEL:-}"
  # BFCL categories: default to the tool-calling trio (simple + the two HARD
  # modes local models actually fail — multiple-tool selection and parallel
  # calls) so the lane isn't blind to the failure surface. `simple` alone (400)
  # for a fast run; `all` (1240) for the full leaderboard incl. irrelevance.
  EVAL_BFCL_CATEGORY="${EVAL_BFCL_CATEGORY:-simple,multiple,parallel}"
  EVAL_IFEVAL_CORPUS="${EVAL_IFEVAL_CORPUS:-$EVAL_DIR/Tests/ManifoldEvalTests/Fixtures/ifeval.jsonl}"
  EVAL_STSB="${EVAL_STSB:-$EVAL_CACHE/stsb_test.json}"

  # Run one command as its own process group under the EVAL_CMD_TIMEOUT watchdog
  # (same set -m / kill -TERM -pid pattern as run_lane). Returns the command's rc;
  # 143/137 signal a timeout kill. No summary side effect — the caller classifies.
  run_capped() {
    local logf="$1"; shift
    set -m
    ( "$@" ) >"$logf" 2>&1 &
    local pid=$!
    set +m
    ( sleep "$EVAL_CMD_TIMEOUT"; kill -TERM -"$pid" 2>/dev/null; sleep 8; kill -KILL -"$pid" 2>/dev/null ) &
    local wd=$!
    wait "$pid"; local rc=$?
    kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null
    return $rc
  }

  # run_capped + a one-line status appended to SUMMARY_LANES, with the metric
  # auto-grepped from the log. args: sub-label logfile cmd...
  run_eval_cmd() {
    local lbl="$1" logf="$2"; shift 2
    log "=== [eval:$lbl] $(date +%H:%M:%S) starting (cap ${EVAL_CMD_TIMEOUT}s) ==="
    run_capped "$logf" "$@"; local rc=$?
    if [ $rc -eq 143 ] || [ $rc -eq 137 ]; then
      SUMMARY_LANES="${SUMMARY_LANES}eval:${lbl}: TIMEOUT/killed (rc=$rc, cap ${EVAL_CMD_TIMEOUT}s; resumable) -> $(basename "$logf")\n"
      FAILED_LANES="${FAILED_LANES}eval:${lbl}: TIMEOUT/killed after ${EVAL_CMD_TIMEOUT}s\n"
      log "=== [eval:$lbl] $(date +%H:%M:%S) KILLED after ${EVAL_CMD_TIMEOUT}s cap ==="
      return 1
    fi
    # Scorer reports print a one-line metric summary to stdout (BFCL/IFEval
    # accuracy, MTEB Spearman). Surface it verbatim; fall back to the exit code.
    local metric; metric="$(grep -hiE 'accuracy|spearman|pearson|F1|pass%|strict' "$logf" 2>/dev/null | tail -1 | sed 's/[[:space:]]\{2,\}/ /g')"
    # A metric computed over near-zero coverage is an artifact, not a result, and
    # this line is what overnight-sweep.sh prints at the TOP of the morning
    # summary. Withholding it in the capability-scores block while emitting it
    # here would gate the render site nobody reads first.
    # Suppression is scoped to the sub-lane it was computed for, by LABEL — never
    # by "whichever call happens next". The reason is carried alongside so this
    # line cannot assert a coverage percentage on the path where coverage was
    # UNMEASURABLE (no responses file, or no corpus to divide by).
    if [ "$lbl" = "ifeval" ] && [ "${EVAL_SUPPRESS_METRIC:-0}" = "1" ]; then
      metric="metric withheld — ${EVAL_SUPPRESS_REASON:-coverage below ${EVAL_MIN_COVERAGE_PCT}%}; see Capability scores"
    fi
    if [ "$rc" -eq 0 ]; then
      SUMMARY_LANES="${SUMMARY_LANES}eval:${lbl}: ok ${metric:+— $metric} -> $(basename "$logf")\n"
    else
      SUMMARY_LANES="${SUMMARY_LANES}eval:${lbl}: fail(rc=$rc) ${metric:+— $metric} -> $(basename "$logf")\n"
      FAILED_LANES="${FAILED_LANES}eval:${lbl}: fail(rc=$rc)\n"
    fi
    log "=== [eval:$lbl] $(date +%H:%M:%S) done rc=$rc ==="
    return $rc
  }

  # True if <model> (":latest"-insensitive) is an installed Ollama tag. Reads a
  # tag list captured ONCE into _EVAL_INSTALLED_TAGS (set below) rather than
  # re-curling per call — a transient /api/tags blip mid-run must not falsely
  # skip a sub-lane. On an empty list (fetch failed) we ASSUME installed and let
  # the sub-lane run; the same "never act on an empty tag list" rule the
  # bench-model guard uses. The generator itself will surface a real 404.
  # (eval_model_installed + _EVAL_INSTALLED_TAGS are defined at top level.)
  # Append a generation-completeness line: how many cases actually landed on
  # disk. A count below the corpus size means cases errored/timed out (the
  # generators are resumable, so a re-run retries them) — surfacing it keeps a
  # 25%-error run from reading as a clean pass.
  eval_gen_count() {  # label logf responsesfile
    local n=0; [ -f "$3" ] && n="$(grep -c . "$3" 2>/dev/null)"
    SUMMARY_LANES="${SUMMARY_LANES}eval:${1}: generated=${n} cases (resumable; below corpus ⇒ some errored/timed out) -> $(basename "$2")\n"
  }

  if ! curl -s --max-time 3 localhost:11434/api/tags >/dev/null 2>&1; then
    lane_noop "eval" "Ollama down at localhost:11434"
  elif ! ( cd "$EVAL_DIR" && swift build ) >"$EVAL_OUT/build.log" 2>&1; then
    lane_noop "eval" "manifold-eval build failed -> eval/build.log"
  else
    EVAL_BIN="$(cd "$EVAL_DIR" && swift build --show-bin-path 2>/dev/null)/manifold-eval"
    log "=== [eval] built manifold-eval -> $EVAL_BIN ==="

    # Snapshot installed tags ONCE for the preflight + per-lane guards (see
    # eval_model_installed). Empty => a transient fetch failure; guards then
    # assume-installed rather than skip everything.
    _EVAL_INSTALLED_TAGS="$(_ollama_tags 2>/dev/null | sed 's/:latest$//' | sort -u)"

    # Model-resolution preflight: a requested eval model that isn't installed
    # 404s mid-run. Check up front, record it in the report, and skip the
    # affected sub-lane instead of burning the timeout on a guaranteed failure.
    # (Same class as the bench-model mismatch — registry name vs Modelfile tag.)
    { echo "## Eval model preflight"; echo '```'
      for pair in "tool=$EVAL_TOOL_MODEL" "instruct=$EVAL_INSTRUCT_MODEL" "embed=$EVAL_EMBED_MODEL"; do
        _role="${pair%%=*}"; _m="${pair#*=}"
        if eval_model_installed "$_m"; then
          echo "$_role: $_m  (installed)"
        else
          echo "$_role: $_m  NOT INSTALLED — sub-lane will skip"
        fi
      done
      echo '```'; echo; } >> "$REPORT"

    # --- tool-calling: BFCL generate -> score (Gorilla v4 cache layout) -------
    if ! eval_model_installed "$EVAL_TOOL_MODEL"; then
      lane_noop "eval:bfcl" "tool model '$EVAL_TOOL_MODEL' not installed"
    else
    run_eval_cmd "bfcl-generate" "$EVAL_OUT/bfcl-generate.log" \
      "$EVAL_BIN" bfcl-generate --ollama-model "$EVAL_TOOL_MODEL" \
        --category "$EVAL_BFCL_CATEGORY" --cache-dir "$EVAL_CACHE/bfcl" \
        --out "$EVAL_OUT/bfcl-responses.jsonl"
    eval_gen_count "bfcl-generate" "$EVAL_OUT/bfcl-generate.log" "$EVAL_OUT/bfcl-responses.jsonl"
    if [ -s "$EVAL_OUT/bfcl-responses.jsonl" ]; then
      # NB: `bfcl` scores the FULL Gorilla corpus present in the cache, counting
      # every un-generated case as a miss (irrelevance excepted). So when we
      # generate only a subset (EVAL_BFCL_CATEGORY != all), BFCL.md's "Overall"
      # conflates "not generated" with "failed" and understates capability. We
      # therefore report the accuracy of the GENERATED categories only, computed
      # from BFCL.md's per-category table — the honest signal for what ran. The
      # full report (with the diluted overall) is still written for inspection.
      log "=== [eval:bfcl] $(date +%H:%M:%S) starting (cap ${EVAL_CMD_TIMEOUT}s) ==="
      run_capped "$EVAL_OUT/bfcl.log" \
        "$EVAL_BIN" bfcl --gorilla-cache-dir "$EVAL_CACHE/bfcl" \
          --responses "$EVAL_OUT/bfcl-responses.jsonl" --out "$EVAL_OUT/BFCL.md"
      bfcl_rc=$?
      if [ $bfcl_rc -eq 143 ] || [ $bfcl_rc -eq 137 ]; then
        SUMMARY_LANES="${SUMMARY_LANES}eval:bfcl: TIMEOUT/killed (rc=$bfcl_rc, cap ${EVAL_CMD_TIMEOUT}s) -> bfcl.log\n"
        FAILED_LANES="${FAILED_LANES}eval:bfcl: TIMEOUT/killed after ${EVAL_CMD_TIMEOUT}s\n"
      elif [ $bfcl_rc -ne 0 ]; then
        SUMMARY_LANES="${SUMMARY_LANES}eval:bfcl: fail(rc=$bfcl_rc) -> bfcl.log\n"
        FAILED_LANES="${FAILED_LANES}eval:bfcl: fail(rc=$bfcl_rc)\n"
      elif [ "$EVAL_BFCL_CATEGORY" = "all" ]; then
        # Full corpus generated — the overall IS the honest number.
        bfcl_metric="$(grep -hiE 'overall|accuracy' "$EVAL_OUT/BFCL.md" 2>/dev/null | tail -1 | sed 's/[*|]//g; s/^ *//; s/[[:space:]]\{2,\}/ /g')"
        SUMMARY_LANES="${SUMMARY_LANES}eval:bfcl: ok ${bfcl_metric:+— $bfcl_metric} -> BFCL.md\n"
      else
        # Sum passed/total across ONLY the generated categories in BFCL.md's table.
        bfcl_metric="$(awk -F'|' -v cats="$EVAL_BFCL_CATEGORY" '
          BEGIN { n = split(cats, a, ","); for (i = 1; i <= n; i++) { gsub(/[[:space:]]/, "", a[i]); want[a[i]] = 1 } }
          /^\| *[a-z_]+ *\| *[0-9]+ *\| *[0-9]+ *\|/ {
            c = $2; gsub(/[[:space:]]/, "", c)
            if (c in want) { tot += $3 + 0; pas += $4 + 0 }
          }
          END { if (tot > 0) printf "%s %d/%d (%.1f%%)", cats, pas, tot, 100 * pas / tot }
        ' "$EVAL_OUT/BFCL.md" 2>/dev/null)"
        if [ -n "$bfcl_metric" ]; then
          SUMMARY_LANES="${SUMMARY_LANES}eval:bfcl: ok — $bfcl_metric [generated categories only; BFCL.md Overall spans full corpus; if the bfcl-generate 'generated=' count is below the category totals the number is understated] -> BFCL.md\n"
        else
          SUMMARY_LANES="${SUMMARY_LANES}eval:bfcl: ok (scoped metric unparsed — see BFCL.md) -> BFCL.md\n"
        fi
      fi
      log "=== [eval:bfcl] $(date +%H:%M:%S) done rc=$bfcl_rc ==="
    else
      lane_noop "eval:bfcl" "no responses generated -> eval/bfcl-generate.log"
    fi
    fi  # tool-model preflight guard

    # --- instruction-following: IFEval generate -> score ----------------------
    if ! eval_model_installed "$EVAL_INSTRUCT_MODEL"; then
      lane_noop "eval:ifeval" "instruct model '$EVAL_INSTRUCT_MODEL' not installed"
    elif [ ! -f "$EVAL_IFEVAL_CORPUS" ]; then
      lane_noop "eval:ifeval" "corpus absent at $EVAL_IFEVAL_CORPUS"
    else
      run_eval_cmd "ifeval-generate" "$EVAL_OUT/ifeval-generate.log" \
        "$EVAL_BIN" ifeval-generate --ollama-model "$EVAL_INSTRUCT_MODEL" \
          --corpus "$EVAL_IFEVAL_CORPUS" --out "$EVAL_OUT/ifeval-responses.jsonl"
      eval_gen_count "ifeval-generate" "$EVAL_OUT/ifeval-generate.log" "$EVAL_OUT/ifeval-responses.jsonl"
      # Coverage decides whether the scorer's number is reportable at all. IFEval
      # counts a MISSING response as a vacuous pass for any instruction an empty
      # string satisfies, so a near-empty run still yields a readable accuracy
      # (3/541 responses rendered "19.2%", 104 "passed"). manifold-eval#60.
      _ifc_total="$(grep -c . "$EVAL_IFEVAL_CORPUS" 2>/dev/null)"
      _ifc_have="$(grep -c . "$EVAL_OUT/ifeval-responses.jsonl" 2>/dev/null)"
      EVAL_SUPPRESS_METRIC=0; EVAL_SUPPRESS_REASON=""
      if [ -n "$_ifc_total" ] && [ "${_ifc_total:-0}" -gt 0 ] 2>/dev/null; then
        if [ $(( ${_ifc_have:-0} * 100 / _ifc_total )) -lt "$EVAL_MIN_COVERAGE_PCT" ]; then
          EVAL_SUPPRESS_METRIC=1
          EVAL_SUPPRESS_REASON="only ${_ifc_have:-0}/${_ifc_total} responses generated (below ${EVAL_MIN_COVERAGE_PCT}% coverage)"
        fi
      else
        # Denominator unknown => coverage unmeasurable => not reportable.
        EVAL_SUPPRESS_METRIC=1
        EVAL_SUPPRESS_REASON="coverage UNMEASURABLE (corpus absent, so generated cases cannot be checked against it)"
      fi
      if [ -s "$EVAL_OUT/ifeval-responses.jsonl" ]; then
        run_eval_cmd "ifeval" "$EVAL_OUT/ifeval.log" \
          "$EVAL_BIN" ifeval --corpus "$EVAL_IFEVAL_CORPUS" \
            --responses "$EVAL_OUT/ifeval-responses.jsonl" --out "$EVAL_OUT/IFEVAL.md"
      else
        lane_noop "eval:ifeval" "no responses generated -> eval/ifeval-generate.log"
      fi
    fi

    # --- embedding quality: MTEB STS-B ----------------------------------------
    if ! eval_model_installed "$EVAL_EMBED_MODEL"; then
      lane_noop "eval:mteb" "embed model '$EVAL_EMBED_MODEL' not installed"
    elif [ ! -f "$EVAL_STSB" ]; then
      lane_noop "eval:mteb" "STS-B dataset absent at $EVAL_STSB — run scripts/fetch-corpora.sh"
    else
      run_eval_cmd "mteb" "$EVAL_OUT/mteb.log" \
        "$EVAL_BIN" mteb --dataset "$EVAL_STSB" --ollama-model "$EVAL_EMBED_MODEL" \
          --out "$EVAL_OUT/MTEB.md"
    fi
  fi
elif have_lane eval; then
  lane_noop "eval" "repo absent at $EVAL_DIR"
fi

# ----- 5. perf extraction ----------------------------------------------------
{
  echo "## Conformance matrix"
  if [ -s "$OUT/MATRIX.md" ]; then
    echo "- rendered from \`ConformanceRecord\`s: \`$OUT/MATRIX.md\` (records: \`matrix/records.json\`)"
    echo "- decoyLevels swept: \`{$DECOY_LEVELS}\`, repeats: \`$SWEEP_REPEATS\` (override via DECOY_LEVELS / SWEEP_REPEATS)"
    if [ -s "$OUT/matrix/coverage.txt" ]; then
      echo "- coverage (measured+notMeasured+loadFail+renderFail vs scenarios x levels x repeats x models):"
      echo '```'
      sed 's/^/  /' "$OUT/matrix/coverage.txt"
      echo '```'
    fi
  else
    echo "- not rendered this run (see Lane summary for why)"
  fi
  echo
  echo "## Per-cell prompt size / advertised-tool count"
  echo "Interprets the F1-vs-decoy-count curve honestly: if the advertised-tool"
  echo "count a cell actually saw was truncated below the requested decoyLevel,"
  echo "or the prompt is close to the model's context ceiling, a degradation"
  echo "there measures context overflow, not tool-selection capability."
  echo "\`promptTextTokenEstimate\` alone does NOT vary with decoyLevel (the"
  echo "scenario's system/user text is fixed — only the tool array grows), so"
  echo "watch \`promptTokenEstimateTotal\` = text + \`toolSchemaTokenEstimate\`,"
  echo "the latter built from each tool's real shipped spec in DecoyTools.swift."
  echo "All \`*TokenEstimate\` columns are chars/4 heuristics over real source"
  echo "content (script-side, not a real tokenizer count, not a wire capture)"
  echo "— directional, not authoritative. \`backend\`/\`model\` are read straight"
  echo "off the transcript so every row stays attributable across legs and"
  echo "across a multi-model MATRIX_MODELS run."
  # Ollama (matrix) and MLX (collate) legs both append into the same TSV
  # (CELL_STATS is set once, in the matrix block) so the two legs' per-cell
  # numbers sit side by side for comparison — now genuinely distinguishable
  # by the backend/model columns rather than colliding on (scenario,
  # decoyLevel, repeatIndex) alone.
  if [ -s "$OUT/matrix/cell-stats.tsv" ] && [ "$(grep -c . "$OUT/matrix/cell-stats.tsv")" -gt 1 ]; then
    echo '```'
    cat "$OUT/matrix/cell-stats.tsv"
    echo '```'
  else
    echo "- no cell stats recorded this run (matrix lane did not run, or no cells produced a prompt record)"
  fi
  echo
  echo "## Tool-selection degradation curves"
  echo "Two DELIBERATELY SEPARATE series — do not fold one into the other (a"
  echo "non-tool-bearing / abstention row's toolSelection is nil BECAUSE"
  echo "precision/recall/F1 are mathematically undefined with zero expected"
  echo "positives; averaging a naive 0-for-nil into the F1 series reads as a"
  echo "dramatic collapse that is entirely an averaging artifact, not signal)."
  echo "Also includes per-cell repeat spread — a MEAN over repeats hides the"
  echo "run-to-run F1 swing repeats exist to surface."
  if [ -s "$OUT/matrix/records.json" ]; then
    echo '```'
    report_degradation_curves "matrix(ollama)" "$OUT/matrix/records.json"
    echo '```'
  fi
  if [ -s "$OUT/collate/mlx-records.json" ]; then
    echo '```'
    report_degradation_curves "collate(mlx)" "$OUT/collate/mlx-records.json"
    echo '```'
  fi
  if [ ! -s "$OUT/matrix/records.json" ] && [ ! -s "$OUT/collate/mlx-records.json" ]; then
    echo "- no records available this run (see Lane summary)"
  fi
  echo
  echo "## Performance signals"
  echo '```'
  echo "MLX benchmark (TTFT/TPS sentinels):"
  grep -h "MLX summary\|\[MLX run" "$OUT"/mlx-*.log 2>/dev/null | sed 's/^/  /' || echo "  (none)"
  echo "llama.cpp benchmark (per-run):"
  grep -h '\[.* run [0-9]*\] TTFT=' "$OUT"/llama.log 2>/dev/null | head -10 | sed 's/^/  /' || echo "  (none)"
  echo "llama.cpp benchmark (median summary, BENCH_RESULT sentinel):"
  grep -h "BENCH_RESULT" "$OUT"/llama.log 2>/dev/null | head -10 | sed 's/^/  /' || echo "  (none)"
  echo "llama prefill footprint (bytes/token):"
  grep -hi "bytesPerToken\|lastMeasured\|prefill" "$OUT"/llama.log 2>/dev/null | head -10 | sed 's/^/  /' || echo "  (none)"
  echo "core backend benchmark (per-run):"
  grep -h '\[.* run [0-9]*\] TTFT=' "$OUT"/core.log 2>/dev/null | head -10 | sed 's/^/  /' || echo "  (none)"
  echo "core backend benchmark (median summary, BENCH_RESULT sentinel):"
  grep -h "BENCH_RESULT" "$OUT"/core.log 2>/dev/null | head -10 | sed 's/^/  /' || echo "  (none)"
  echo '```'
  echo
  echo "## Capability scores (manifold-eval)"
  if [ -d "$OUT/eval" ]; then
    echo '```'
    # Coverage gate. IFEval and BFCL both score cases that were never generated
    # rather than treating them as holes (manifold-eval#60, #59) — and for IFEval
    # a MISSING response vacuously satisfies whole instruction classes
    # ("respond in all lowercase" is trivially true of an empty string), so a run
    # that persisted 3 of 541 responses still renders "Strict Accuracy 19.2%",
    # with 104 of those "passes" being absent responses. A readable percentage
    # with no coverage next to it is indistinguishable from a real measurement,
    # which is the entire failure mode this sweep exists to prevent. So: below
    # EVAL_MIN_COVERAGE_PCT, print the coverage and REFUSE to print the score.
    _cov_pct() {  # responses-file corpus-count -> integer percent, or empty
      [ -f "$1" ] || return 0
      [ -n "$2" ] && [ "$2" -gt 0 ] 2>/dev/null || return 0
      local n; n="$(grep -c . "$1" 2>/dev/null)"
      echo $(( n * 100 / $2 ))
    }
    _ifeval_total="$(grep -c . "${EVAL_IFEVAL_CORPUS:-/nonexistent}" 2>/dev/null)"
    _ifeval_cov="$(_cov_pct "$OUT/eval/ifeval-responses.jsonl" "${_ifeval_total:-0}")"
    for r in BFCL IFEVAL MTEB; do
      f="$OUT/eval/$r.md"
      # Gate on [ -s "$f" ] FIRST so "not produced" keeps its own honest branch
      # below; then withhold for BOTH low coverage and UNMEASURABLE coverage. An
      # empty _ifeval_cov means the responses file or the corpus was absent —
      # that is the worst case, and it previously took the permissive branch.
      if [ "$r" = "IFEVAL" ] && [ -s "$f" ] && \
         { [ -z "$_ifeval_cov" ] || [ "$_ifeval_cov" -lt "$EVAL_MIN_COVERAGE_PCT" ]; }; then
        if [ -z "$_ifeval_cov" ]; then
          echo "$r: SCORE WITHHELD — coverage UNMEASURABLE (responses file or corpus absent); a score here could not be checked against what was generated."
        else
          echo "$r: SCORE WITHHELD — only ${_ifeval_cov}% coverage ($(grep -c . "$OUT/eval/ifeval-responses.jsonl" 2>/dev/null)/${_ifeval_total} responses). IFEval scores missing responses as vacuous passes (manifold-eval#60), so any accuracy printed here would be an artifact, not a measurement. See eval/$r.md for the raw table."
        fi
      elif [ -s "$f" ]; then
        # Match the summary line, not the table HEADER row (which also contains
        # "Accuracy"): BFCL -> "Overall", IFEval -> "Strict Accuracy", MTEB ->
        # "Spearman". For a category-scoped BFCL run the Overall is diluted — the
        # honest per-category figure is in the Lane summary; BFCL.md has the table.
        echo "$r: $(grep -hiE 'overall|spearman|pearson|strict accuracy|^\| *F1' "$f" 2>/dev/null | head -1 | sed 's/[#*`]//g; s/^[[:space:]]*//')  (eval/$r.md)"
      else
        echo "$r: (not produced — see Lane summary)"
      fi
    done
    echo '```'
  else
    echo "- eval lane not run this sweep (see Lane summary)"
  fi
  echo
  echo "## Lane summary"
  echo '```'
  printf "%b" "$SUMMARY_LANES"
  echo '```'
  echo
  echo "_Full per-lane logs: \`$OUT/\`_"
} >> "$REPORT"

# ----- 6. negative control ---------------------------------------------------
# A green sweep is only meaningful if a broken sweep would have gone red. Every
# check below is DELIBERATELY fed a defect and must fail; a control that passes
# means the corresponding detection path is inert. This exists because this repo
# has repeatedly shipped machinery that reported success while doing nothing —
# a fuzzer logging 9,626 runs and 0 findings while executing no work, four
# green-but-inert tests in one night, and this very script's silent-skip class.
NEG_RESULTS=""
NEG_FAILED=0
neg_check() {  # label  expectation  <cmd...>   (expects NON-ZERO rc)
  local lbl="$1" expect="$2"; shift 2
  local out; out="$("$@" 2>&1)"; local rc=$?
  if [ "$rc" -ne 0 ]; then
    NEG_RESULTS="${NEG_RESULTS}  OK   $lbl — $expect (rc=$rc)\n"
  else
    NEG_RESULTS="${NEG_RESULTS}  DEAD $lbl — expected failure ($expect) but rc=0; this detection path is INERT\n"
    NEG_FAILED=1
  fi
}

if [ "$SKIP_NEGATIVE_CONTROL" != "1" ]; then
  log "=== [negative-control] $(date +%H:%M:%S) verifying the rig can report failure ==="
  NEG_DIR="$OUT/negative-control"; mkdir -p "$NEG_DIR"

  # 1/2 exercise the installed-model predicate against a FIXTURE tag list, so the
  #     result does not depend on whether the eval lane happened to populate the
  #     real one — an empty list means "assume installed", which would make these
  #     controls report DEAD for a reason unrelated to the predicate.
  _NEG_TAGS_SAVED="$_EVAL_INSTALLED_TAGS"
  _EVAL_INSTALLED_TAGS="llama3.1:8b"
  # 1. A model tag that does not exist must be rejected by the installed-model
  #    guard — the guard that silently passed empty strings before this change.
  neg_check "unresolvable-model" "eval_model_installed rejects a bogus tag" \
    eval_model_installed "definitely-not-a-real-model:0b"
  # 2. ...and an EMPTY role must be rejected too (the `grep -qxF ""` hazard).
  neg_check "empty-role-model" "eval_model_installed rejects an empty role" \
    eval_model_installed ""
  # 2b. POSITIVE control. A predicate hardwired to `return 1` would score a
  #     perfect negative-control sheet while rejecting every real model, so the
  #     sheet must also prove it says yes to something.
  if eval_model_installed "llama3.1:8b"; then
    NEG_RESULTS="${NEG_RESULTS}  OK   installed-model-accepted — predicate accepts a present tag\n"
  else
    NEG_RESULTS="${NEG_RESULTS}  DEAD installed-model-accepted — predicate rejected a PRESENT tag; it is stuck closed\n"
    NEG_FAILED=1
  fi
  _EVAL_INSTALLED_TAGS="$_NEG_TAGS_SAVED"
  # 3. A nonexistent repo path must not resolve.
  neg_check "repo-probe" "resolve_repo rejects a package that does not exist" \
    resolve_repo "manifold-does-not-exist"
  # Positive control: a resolve_repo stuck at `return 1` is precisely the failure
  # that started all of this, and it would pass the negative check perfectly.
  if resolve_repo "manifold-mlx" >/dev/null 2>&1 || resolve_repo "manifold-eval" >/dev/null 2>&1; then
    NEG_RESULTS="${NEG_RESULTS}  OK   repo-probe-accepts — resolve_repo finds a companion that IS present\n"
  else
    NEG_RESULTS="${NEG_RESULTS}  DEAD repo-probe-accepts — resolve_repo found NO companion repo; it may be stuck closed, which would silently skip every companion lane\n"
    NEG_FAILED=1
  fi
  # 4. Ollama must actually reject a bogus model rather than 200-ing — proves the
  #    live endpoint the eval/matrix lanes depend on is discriminating, not a stub.
  if ollama_up; then
    # Assert the STATUS CODE, not merely a non-zero curl exit: a timeout (28), a
    # refused connection (7) or a missing curl (127) are all non-zero for reasons
    # that prove nothing about whether Ollama discriminates.
    _bogus_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
      localhost:11434/api/show -d '{"name":"definitely-not-a-real-model:0b"}' 2>/dev/null)"
    if [ "$_bogus_code" = "404" ]; then
      NEG_RESULTS="${NEG_RESULTS}  OK   ollama-rejects-bogus — /api/show returned 404 for an uninstalled tag\n"
    else
      NEG_RESULTS="${NEG_RESULTS}  DEAD ollama-rejects-bogus — expected HTTP 404, got '${_bogus_code:-<no response>}'; this probe proves nothing\n"
      NEG_FAILED=1
    fi
    # Positive control: an Ollama that 404'd EVERYTHING would ace the check above.
    if [ -z "${ROLE_INSTRUCT:-}" ]; then
      # Absence of a check must be visible: an unrun control is not a passed one.
      NEG_RESULTS="${NEG_RESULTS}  n/a  ollama-accepts-real — SKIPPED (no role model resolved; the bogus-tag check above is therefore unpaired)\n"
    fi
    if [ -n "${ROLE_INSTRUCT:-}" ]; then
      _real_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
        localhost:11434/api/show -d "{\"name\":\"$ROLE_INSTRUCT\"}" 2>/dev/null)"
      if [ "$_real_code" = "200" ]; then
        NEG_RESULTS="${NEG_RESULTS}  OK   ollama-accepts-real — /api/show returned 200 for $ROLE_INSTRUCT\n"
      else
        NEG_RESULTS="${NEG_RESULTS}  DEAD ollama-accepts-real — expected HTTP 200 for installed '$ROLE_INSTRUCT', got '${_real_code:-<no response>}'; the bogus-tag check above is therefore meaningless\n"
        NEG_FAILED=1
      fi
    fi
  fi
  # 5. collate must refuse an empty corpus (its documented error-severity exit).
  if [ -n "${EVAL_BIN_C:-}" ] && [ -x "${EVAL_BIN_C:-}" ]; then
    echo '[]' > "$NEG_DIR/empty-records.json"
    neg_check "collate-empty-corpus" "collate exits non-zero on an empty corpus" \
      "$EVAL_BIN_C" collate "$NEG_DIR/empty-records.json" --out "$NEG_DIR/empty.md"
  fi
  # 6. A cell wired to a NONEXISTENT tool must land a `fail` verdict, not
  #    `pass` — the decoy-sweep's own positive control. A hand-crafted
  #    transcript (no live model needed) exercises the scorer directly: the
  #    scenario calls only a tool that was never its required tool, so a
  #    scorer stuck reporting `pass` regardless of tool identity would be
  #    exactly the false-confidence class this whole change exists to end.
  if [ -n "${TOOL_BIN:-}" ] && [ -x "${TOOL_BIN:-}" ]; then
    NEG_TRANSCRIPT="$NEG_DIR/wrong-tool-transcript.jsonl"
    NEG_RECORDS="$NEG_DIR/wrong-tool-records.json"
    cat > "$NEG_TRANSCRIPT" <<'JSONL'
{"ts":"2026-01-01T00:00:00Z","kind":"prompt","scenario":"neg-control-wrong-tool","backend":"mock","model":"neg-control-model","system":"s","user":"u","requiredTools":["real_tool"],"advertisedTools":["real_tool","ghost_tool_does_not_exist"]}
{"ts":"2026-01-01T00:00:01Z","kind":"tool_call","scenario":"neg-control-wrong-tool","backend":"mock","model":"neg-control-model","name":"ghost_tool_does_not_exist","arguments":"{}"}
{"ts":"2026-01-01T00:00:02Z","kind":"assertion","scenario":"neg-control-wrong-tool","backend":"mock","model":"neg-control-model","passed":false,"message":"Scenario requires `real_tool` to be dispatched — never dispatched"}
JSONL
    # fail-open-ok: the scorer's own exit code is not the assertion here — the emitted verdict (checked below) is
    "$TOOL_BIN" score "$NEG_TRANSCRIPT" --emit-records "$NEG_RECORDS" \
      --renderer neg-control --core-commit test >/dev/null 2>"$NEG_DIR/wrong-tool-score.log" || true
    if [ -s "$NEG_RECORDS" ]; then
      NEG_VERDICT="$(python3 - "$NEG_RECORDS" <<'PY'
import json, sys
with open(sys.argv[1]) as fh:
    records = json.load(fh)
match = [r for r in records if r.get("scenario") == "neg-control-wrong-tool"]
print(match[0].get("verdict", "<missing>") if match else "<no-record>")
PY
)"
      if [ "$NEG_VERDICT" != "pass" ] && [ "$NEG_VERDICT" != "<missing>" ] && [ "$NEG_VERDICT" != "<no-record>" ]; then
        NEG_RESULTS="${NEG_RESULTS}  OK   wrong-tool-scored-fail — a cell that called only a wrong tool scored verdict='$NEG_VERDICT', not pass\n"
      else
        NEG_RESULTS="${NEG_RESULTS}  DEAD wrong-tool-scored-fail — a cell that called ONLY a wrong tool scored verdict='$NEG_VERDICT'; a matrix built on this is not discriminating wrong-tool calls\n"
        NEG_FAILED=1
      fi
    else
      NEG_RESULTS="${NEG_RESULTS}  DEAD wrong-tool-scored-fail — scorer emitted no record for the synthetic transcript -> wrong-tool-score.log\n"
      NEG_FAILED=1
    fi
  else
    NEG_RESULTS="${NEG_RESULTS}  n/a  wrong-tool-scored-fail — SKIPPED (manifold-tools was not built this run; matrix lane did not run)\n"
  fi

  {
    echo "## Negative control"
    echo '```'
    printf "%b" "$NEG_RESULTS"
    if [ "$NEG_FAILED" -eq 1 ]; then
      echo "VERDICT: FAILED — at least one detection path did not fire. Treat every"
      echo "         'pass' in this report as unverified until that is fixed."
    else
      echo "VERDICT: ok — every checked detection path fired on a planted defect."
    fi
    echo '```'
    echo
  } >> "$REPORT"
  log "=== [negative-control] $(date +%H:%M:%S) done (failed=$NEG_FAILED) ==="
fi

# ----- 7. verdict + exit code ------------------------------------------------
# The sweep still runs every lane to completion regardless of failures (see
# DESIGN NOTES) — but it no longer EXITS 0 regardless. An unattended overnight
# run whose lanes all skipped used to be indistinguishable from a clean pass.
NOOP_COUNT=$(printf "%b" "$NOOP_LANES" | grep -c . )
VERDICT_MD="$OUT/verdict-fragment.md"
{
  echo "## Verdict"
  echo '```'
  if [ "$NOOP_COUNT" -gt 0 ]; then
    echo "$NOOP_COUNT REQUESTED LANE(S) DID NO WORK:"
    printf "%b" "$NOOP_LANES" | sed 's/^/  - /'
    echo
    echo "These are NOT passes. Fix the cause and re-run before reading any"
    echo "number in this report as signal."
  else
    echo "Every requested lane did work."
  fi
  if [ -n "$FAILED_LANES" ]; then
    echo
    echo "LANE(S) THAT RAN AND FAILED:"
    printf "%b" "$FAILED_LANES" | sed 's/^/  - /'
  fi
  if [ -n "$STALE_NOTES" ]; then
    echo
    echo "MEASUREMENTS OF UNCERTAIN PROVENANCE (a pass here is not the pass it looks like):"
    printf "%b" "$STALE_NOTES" | sed 's/^/  - /'
  fi
  echo
  # "0" must not be printable when the control never ran — the same ambiguity the
  # preflight block explicitly refuses.
  if [ "$SKIP_NEGATIVE_CONTROL" = "1" ]; then _neg_state="SKIPPED (SKIP_NEGATIVE_CONTROL=1 — nothing verified the rig can report failure)"; else _neg_state="$NEG_FAILED"; fi
  echo "preflight_failed=$PREFLIGHT_FAILED  noop_lanes=$NOOP_COUNT  failed_lanes=$(printf "%b" "$FAILED_LANES" | grep -c .)  negative_control_failed=$_neg_state"
  echo '```'
  echo
} > "$VERDICT_MD"

# Prepend the verdict so it is the FIRST thing a morning reader sees. Written to
# its own fragment and concatenated — a sed-based in-place reorder would break
# the moment any lane log echoed a line starting with "## Verdict".
if [ -s "$VERDICT_MD" ] && [ -s "$REPORT" ]; then
  cat "$VERDICT_MD" "$REPORT" > "$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT" && rm -f "$VERDICT_MD"
fi

log ""
log "Sweep complete. Report: $REPORT"
printf "%b" "$SUMMARY_LANES"

EXIT_RC=0
[ "$NOOP_COUNT" -gt 0 ] && EXIT_RC=1
[ "$PREFLIGHT_FAILED" -eq 1 ] && EXIT_RC=1
[ -n "$FAILED_LANES" ] && EXIT_RC=1
[ "$NEG_FAILED" -eq 1 ] && EXIT_RC=2
log "exit rc=$EXIT_RC (0=clean, 1=preflight/no-op/failed lanes, 2=negative control inert)"
exit "$EXIT_RC"
