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
#   - NO --parallel: BackendContractChecks + llama's process-global init are not
#     parallel-safe (matches both repos' own CI).
#   - The script never fails the whole sweep on one lane; it records per-lane
#     status and always writes the report.

set -uo pipefail

# ----- config ---------------------------------------------------------------
COMPANIONS_DIR="${COMPANIONS_DIR:-$HOME/Repos}"
MODELS_DIR="${MODELS_DIR:-$HOME/Documents/Models}"
CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LLAMA_DIR="$COMPANIONS_DIR/manifold-llama"
MLX_DIR="$COMPANIONS_DIR/manifold-mlx"
LANES="core,llama,mlx"
LANE_TIMEOUT="${LANE_TIMEOUT:-2400}"   # per-lane hard cap (s); a hung xctest must not eat the night
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$CORE_DIR/.local-integration-runs/$STAMP"

while [ $# -gt 0 ]; do
  case "$1" in
    --lanes) LANES="$2"; shift 2 ;;
    --out)   OUT="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$OUT"
REPORT="$OUT/REPORT.md"
SUMMARY_LANES=""   # "name=status(skip/pass/fail) detail" lines, newline-joined

log() { printf '%s\n' "$*"; }
have_lane() { case ",$LANES," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

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
    log "=== [$name] $(date +%H:%M:%S) KILLED after ${LANE_TIMEOUT}s cap ==="
    return
  fi
  if [ $rc -eq 0 ]; then status="pass"; else status="fail(rc=$rc)"; fi
  # A swift-test run that only XCTSkips still exits 0; surface skip counts.
  local skips passes fails
  skips=$(grep -c "Test Case.*skipped\|XCTSkip\| skipped" "$logf" 2>/dev/null | head -1)
  passes=$(grep -c "Test Case.*passed" "$logf" 2>/dev/null | head -1)
  fails=$(grep -c "Test Case.*failed\|error:" "$logf" 2>/dev/null | head -1)
  detail="passed=$passes failed=$fails skipped=$skips"
  SUMMARY_LANES="${SUMMARY_LANES}${name}: ${status} (${detail}) -> $(basename "$logf")\n"
  log "=== [$name] $(date +%H:%M:%S) done: $status ($detail) ==="
}

# ----- 0. model inventory ----------------------------------------------------
{
  echo "# Local integration + perf sweep — $STAMP"
  echo
  echo "- core repo: \`$CORE_DIR\` ($(git -C "$CORE_DIR" rev-parse --short HEAD 2>/dev/null) on $(git -C "$CORE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null))"
  echo "- companions dir: \`$COMPANIONS_DIR\`  (llama: $([ -d "$LLAMA_DIR" ] && echo present || echo MISSING), mlx: $([ -d "$MLX_DIR" ] && echo present || echo MISSING))"
  echo "- models dir: \`$MODELS_DIR\`"
  echo "- lanes: \`$LANES\`"
  echo
  echo "## Model inventory"
  echo '```'
  echo "GGUF (llama family-fragment match):"
  for f in llama qwen mistral phi gemma; do
    m=$(ls "$MODELS_DIR"/*.gguf 2>/dev/null | grep -i "$f" | head -1)
    echo "  $f: ${m:-MISSING}"
  done
  echo "MLX dirs:"
  find "$MODELS_DIR" -maxdepth 3 -name config.json 2>/dev/null | sed 's#/config.json##' | sed 's#^#  #'
  echo "Ollama @ localhost:11434: $(curl -s --max-time 3 localhost:11434/api/tags >/dev/null 2>&1 && echo UP || echo DOWN)"
  echo '```'
  echo
} > "$REPORT"

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
  SUMMARY_LANES="${SUMMARY_LANES}llama: skip (repo absent at $LLAMA_DIR)\n"
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
  # vision input path — reuses the cached build from the text lane.
  run_lane mlx-vlm "$OUT/mlx-vlm.log" \
    bash -c "cd '$MLX_DIR' && scripts/test-mlx-integration.sh Qwen2-VL --only MLXVLMGateExperimentTests 2>&1"
elif have_lane mlx; then
  SUMMARY_LANES="${SUMMARY_LANES}mlx: skip (repo absent at $MLX_DIR)\n"
fi

# ----- 4. perf extraction ----------------------------------------------------
{
  echo "## Performance signals"
  echo '```'
  echo "MLX benchmark (TTFT/TPS sentinels):"
  grep -h "MLX summary\|\[MLX run" "$OUT"/mlx-*.log 2>/dev/null | sed 's/^/  /' || echo "  (none)"
  echo "llama prefill footprint (bytes/token):"
  grep -hi "bytesPerToken\|lastMeasured\|prefill" "$OUT"/llama.log 2>/dev/null | head -10 | sed 's/^/  /' || echo "  (none)"
  echo "core backend benchmark:"
  grep -hi "tokensPerSecond\|TTFT\|benchmark" "$OUT"/core.log 2>/dev/null | head -10 | sed 's/^/  /' || echo "  (none)"
  echo '```'
  echo
  echo "## Lane summary"
  echo '```'
  printf "%b" "$SUMMARY_LANES"
  echo '```'
  echo
  echo "_Full per-lane logs: \`$OUT/\`_"
} >> "$REPORT"

log ""
log "Sweep complete. Report: $REPORT"
printf "%b" "$SUMMARY_LANES"
