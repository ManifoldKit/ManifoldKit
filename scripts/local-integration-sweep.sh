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
EVAL_DIR="$COMPANIONS_DIR/manifold-eval"
LANES="core,llama,mlx,eval"
LANE_TIMEOUT="${LANE_TIMEOUT:-2400}"   # per-lane hard cap (s); a hung xctest must not eat the night
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
  # Count only real xctest verdict lines — NOT raw "error:" greps, which match
  # CoreData/XPC log noise and deprecation warnings and wildly inflate "failed".
  local skips passes fails
  passes=$(grep -c "Test Case '.*' passed" "$logf" 2>/dev/null)
  fails=$(grep -c "Test Case '.*' failed" "$logf" 2>/dev/null)
  skips=$(grep -c "Test Case '.*' skipped" "$logf" 2>/dev/null)
  detail="passed=$passes failed=$fails skipped=$skips"
  if [ "$rc" -eq 0 ] && [ "$fails" -eq 0 ]; then status="pass"; else status="fail(rc=$rc)"; fi
  SUMMARY_LANES="${SUMMARY_LANES}${name}: ${status} (${detail}) -> $(basename "$logf")\n"
  log "=== [$name] $(date +%H:%M:%S) done: $status ($detail) ==="
}

# ----- 0. model inventory ----------------------------------------------------
{
  echo "# Local integration + perf sweep — $STAMP"
  echo
  echo "- core repo: \`$CORE_DIR\` ($(git -C "$CORE_DIR" rev-parse --short HEAD 2>/dev/null) on $(git -C "$CORE_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null))"
  echo "- companions dir: \`$COMPANIONS_DIR\`  (llama: $([ -d "$LLAMA_DIR" ] && echo present || echo MISSING), mlx: $([ -d "$MLX_DIR" ] && echo present || echo MISSING), eval: $([ -d "$EVAL_DIR" ] && echo present || echo MISSING))"
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
    MATRIX_MODELS="$(printf '%s\n' "$OLLAMA_CHAT_TAGS" | sed 's/:latest$//' | paste -sd, -)"
    export MATRIX_MODELS
    echo "MATRIX_MODELS (matrix lane) <- installed: $MATRIX_MODELS" >> "$REPORT"
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
  # vision input path — reuses the cached build from the text lane. The VLM gate
  # test reads MLX_VLM_TEST_MODEL from the ENV (the script forwards it into the
  # xctestrun); a positional arg only sets MLX_TEST_MODEL, leaving the gate test
  # to skip. Override MLX_VLM_TEST_MODEL externally to point at a different VLM.
  run_lane mlx-vlm "$OUT/mlx-vlm.log" \
    bash -c "cd '$MLX_DIR' && MLX_VLM_TEST_MODEL='${MLX_VLM_TEST_MODEL:-Qwen2-VL}' scripts/test-mlx-integration.sh --only MLXVLMGateExperimentTests 2>&1"
elif have_lane mlx; then
  SUMMARY_LANES="${SUMMARY_LANES}mlx: skip (repo absent at $MLX_DIR)\n"
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
if have_lane core; then
  MATRIX_DIR="$OUT/matrix"
  mkdir -p "$MATRIX_DIR"
  TRANSCRIPT="$MATRIX_DIR/transcript.jsonl"
  RECORDS="$MATRIX_DIR/records.json"
  MATRIX_MD="$OUT/MATRIX.md"
  CORE_COMMIT="$(git -C "$CORE_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  log "=== [matrix] $(date +%H:%M:%S) building manifold-tools ==="
  if ( cd "$CORE_DIR" && swift build --product manifold-tools ) >"$MATRIX_DIR/build.log" 2>&1; then
    TOOL_BIN="$(cd "$CORE_DIR" && swift build --product manifold-tools --show-bin-path 2>/dev/null)/manifold-tools"
    if curl -s --max-time 3 localhost:11434/api/tags >/dev/null 2>&1; then
      # Optional model override: MATRIX_MODELS="m1,m2". Unset -> scenario defaults.
      MATRIX_MODEL_ARGS=""
      if [ -n "${MATRIX_MODELS:-}" ]; then MATRIX_MODEL_ARGS="--model ${MATRIX_MODELS}"; fi
      # A non-zero exit means some scenarios failed — that is data, not a script
      # error; score the transcript regardless (word-split MODEL_ARGS on purpose).
      ( cd "$CORE_DIR" && "$TOOL_BIN" --backend ollama --scenario all --output "$TRANSCRIPT" ${MATRIX_MODEL_ARGS} ) \
        >"$MATRIX_DIR/run.log" 2>&1 || true
      if [ -s "$TRANSCRIPT" ]; then
        "$TOOL_BIN" score "$TRANSCRIPT" --emit-records "$RECORDS" \
          --renderer ollama-server --core-commit "$CORE_COMMIT" \
          >/dev/null 2>"$MATRIX_DIR/score.log" || true
        if [ -s "$RECORDS" ]; then
          if "$TOOL_BIN" matrix "$RECORDS" --out "$MATRIX_MD" 2>>"$MATRIX_DIR/score.log"; then
            SUMMARY_LANES="${SUMMARY_LANES}matrix: rendered -> $(basename "$MATRIX_MD")\n"
            log "=== [matrix] $(date +%H:%M:%S) rendered $MATRIX_MD ==="
          else
            SUMMARY_LANES="${SUMMARY_LANES}matrix: render failed -> matrix/score.log\n"
          fi
        else
          SUMMARY_LANES="${SUMMARY_LANES}matrix: skip (no records emitted -> matrix/score.log)\n"
        fi
      else
        SUMMARY_LANES="${SUMMARY_LANES}matrix: skip (empty transcript — Ollama models absent?)\n"
      fi
    else
      SUMMARY_LANES="${SUMMARY_LANES}matrix: skip (Ollama down at localhost:11434)\n"
    fi
  else
    SUMMARY_LANES="${SUMMARY_LANES}matrix: skip (manifold-tools build failed -> matrix/build.log)\n"
  fi
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
  # Model roster (override any via env). Tool model must advertise `tools`; the
  # instruct model matches the corpus the fixture was verified against.
  EVAL_TOOL_MODEL="${EVAL_TOOL_MODEL:-mistral-7b-tools}"
  EVAL_INSTRUCT_MODEL="${EVAL_INSTRUCT_MODEL:-qwen2.5:0.5b-instruct-q4_K_M}"
  EVAL_EMBED_MODEL="${EVAL_EMBED_MODEL:-nomic-embed-text}"
  # BFCL defaults to `simple` (400 cases) to stay bounded overnight; set to `all`
  # (1240) for the full leaderboard, or any comma-list of categories.
  EVAL_BFCL_CATEGORY="${EVAL_BFCL_CATEGORY:-simple}"
  EVAL_IFEVAL_CORPUS="${EVAL_IFEVAL_CORPUS:-$EVAL_DIR/Tests/ManifoldEvalTests/Fixtures/ifeval.jsonl}"
  EVAL_STSB="${EVAL_STSB:-$EVAL_CACHE/stsb_test.json}"

  # Run one eval subcommand as its own process group under an EVAL_CMD_TIMEOUT
  # watchdog (same set -m / kill -TERM -pid pattern as run_lane). Appends a
  # one-line status to SUMMARY_LANES. args: sub-label logfile cmd...
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
      log "=== [eval:$lbl] $(date +%H:%M:%S) KILLED after ${EVAL_CMD_TIMEOUT}s cap ==="
      return 1
    fi
    # Scorer reports print a one-line metric summary to stdout (BFCL/IFEval
    # accuracy, MTEB Spearman). Surface it verbatim; fall back to the exit code.
    local metric; metric="$(grep -hiE 'accuracy|spearman|pearson|F1|pass%|strict' "$logf" 2>/dev/null | tail -1 | sed 's/[[:space:]]\{2,\}/ /g')"
    if [ "$rc" -eq 0 ]; then
      SUMMARY_LANES="${SUMMARY_LANES}eval:${lbl}: ok ${metric:+— $metric} -> $(basename "$logf")\n"
    else
      SUMMARY_LANES="${SUMMARY_LANES}eval:${lbl}: fail(rc=$rc) ${metric:+— $metric} -> $(basename "$logf")\n"
    fi
    log "=== [eval:$lbl] $(date +%H:%M:%S) done rc=$rc ==="
    return $rc
  }

  if ! curl -s --max-time 3 localhost:11434/api/tags >/dev/null 2>&1; then
    SUMMARY_LANES="${SUMMARY_LANES}eval: skip (Ollama down at localhost:11434)\n"
  elif ! ( cd "$EVAL_DIR" && swift build ) >"$EVAL_OUT/build.log" 2>&1; then
    SUMMARY_LANES="${SUMMARY_LANES}eval: skip (manifold-eval build failed -> eval/build.log)\n"
  else
    EVAL_BIN="$(cd "$EVAL_DIR" && swift build --show-bin-path 2>/dev/null)/manifold-eval"
    log "=== [eval] built manifold-eval -> $EVAL_BIN ==="

    # --- tool-calling: BFCL generate -> score (Gorilla v4 cache layout) -------
    run_eval_cmd "bfcl-generate" "$EVAL_OUT/bfcl-generate.log" \
      "$EVAL_BIN" bfcl-generate --ollama-model "$EVAL_TOOL_MODEL" \
        --category "$EVAL_BFCL_CATEGORY" --cache-dir "$EVAL_CACHE/bfcl" \
        --out "$EVAL_OUT/bfcl-responses.jsonl"
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
      elif [ $bfcl_rc -ne 0 ]; then
        SUMMARY_LANES="${SUMMARY_LANES}eval:bfcl: fail(rc=$bfcl_rc) -> bfcl.log\n"
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
          SUMMARY_LANES="${SUMMARY_LANES}eval:bfcl: ok — $bfcl_metric [generated categories only; BFCL.md Overall spans full corpus] -> BFCL.md\n"
        else
          SUMMARY_LANES="${SUMMARY_LANES}eval:bfcl: ok (scoped metric unparsed — see BFCL.md) -> BFCL.md\n"
        fi
      fi
      log "=== [eval:bfcl] $(date +%H:%M:%S) done rc=$bfcl_rc ==="
    else
      SUMMARY_LANES="${SUMMARY_LANES}eval:bfcl: skip (no responses generated -> eval/bfcl-generate.log)\n"
    fi

    # --- instruction-following: IFEval generate -> score ----------------------
    if [ -f "$EVAL_IFEVAL_CORPUS" ]; then
      run_eval_cmd "ifeval-generate" "$EVAL_OUT/ifeval-generate.log" \
        "$EVAL_BIN" ifeval-generate --ollama-model "$EVAL_INSTRUCT_MODEL" \
          --corpus "$EVAL_IFEVAL_CORPUS" --out "$EVAL_OUT/ifeval-responses.jsonl"
      if [ -s "$EVAL_OUT/ifeval-responses.jsonl" ]; then
        run_eval_cmd "ifeval" "$EVAL_OUT/ifeval.log" \
          "$EVAL_BIN" ifeval --corpus "$EVAL_IFEVAL_CORPUS" \
            --responses "$EVAL_OUT/ifeval-responses.jsonl" --out "$EVAL_OUT/IFEVAL.md"
      else
        SUMMARY_LANES="${SUMMARY_LANES}eval:ifeval: skip (no responses generated -> eval/ifeval-generate.log)\n"
      fi
    else
      SUMMARY_LANES="${SUMMARY_LANES}eval:ifeval: skip (corpus absent at $EVAL_IFEVAL_CORPUS)\n"
    fi

    # --- embedding quality: MTEB STS-B ----------------------------------------
    if [ -f "$EVAL_STSB" ]; then
      run_eval_cmd "mteb" "$EVAL_OUT/mteb.log" \
        "$EVAL_BIN" mteb --dataset "$EVAL_STSB" --ollama-model "$EVAL_EMBED_MODEL" \
          --out "$EVAL_OUT/MTEB.md"
    else
      SUMMARY_LANES="${SUMMARY_LANES}eval:mteb: skip (STS-B dataset absent at $EVAL_STSB — run scripts/fetch-corpora.sh)\n"
    fi
  fi
elif have_lane eval; then
  SUMMARY_LANES="${SUMMARY_LANES}eval: skip (repo absent at $EVAL_DIR)\n"
fi

# ----- 5. perf extraction ----------------------------------------------------
{
  echo "## Conformance matrix"
  if [ -s "$OUT/MATRIX.md" ]; then
    echo "- rendered from \`ConformanceRecord\`s: \`$OUT/MATRIX.md\` (records: \`matrix/records.json\`)"
  else
    echo "- not rendered this run (see Lane summary for why)"
  fi
  echo
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
  echo "## Capability scores (manifold-eval)"
  if [ -d "$OUT/eval" ]; then
    echo '```'
    for r in BFCL IFEVAL MTEB; do
      f="$OUT/eval/$r.md"
      if [ -s "$f" ]; then
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

log ""
log "Sweep complete. Report: $REPORT"
printf "%b" "$SUMMARY_LANES"
