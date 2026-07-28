#!/usr/bin/env bash
#
# overnight-sweep.sh — Claude-orchestrated overnight local-inference SIGNAL run.
#
# WHY THIS EXISTS
# ---------------
# CI is macOS-only and mocks every backend. The local GPU sits idle overnight.
# This wraps scripts/local-integration-sweep.sh (real Ollama E2E + llama GBNF
# conformance + real MLX text/vision/benchmark) with the orchestration the raw
# sweep doesn't do:
#   - caffeinate so the Mac doesn't sleep mid-run
#   - honest PREP: record each repo's branch/HEAD/dirtiness (measure what's
#     checked out; NEVER silently switch branches or stash — 2026-06-29 stashed
#     edits and measured a diverged HEAD, corrupting attribution)
#   - baseline diff vs the previous overnight run
#   - failure triage into a concise morning SUMMARY.md
#   - a completion sentinel line the morning session greps for
#
# The 40-min per-lane cap is KEPT deliberately: every real-model test completes
# in seconds once the MLX metallib is staged (fresh --rebuild does this); the cap
# is only a hang-backstop. See the 2026-07-08 investigation — the historical MLX
# "timeout" was a missing-metallib hang, fixed by manifold-mlx #108, not slowness.
#
# USAGE
#   scripts/overnight-sweep.sh                 # all lanes, current checkouts
#   LANES=core,llama scripts/overnight-sweep.sh
set -uo pipefail  # fail-open-ok: NOT -e — the sweep must reach its summary even when lanes fail

CORE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# COMPANIONS_DIR is a HINT, not the answer — see resolve_repo() below, mirrored
# from local-integration-sweep.sh. The old hardcoded `$HOME/Repos` default
# silently missed a checkout layout that nests the family one level deeper
# (`~/Repos/ManifoldKit/manifold-*`), reporting every companion MISSING in PREP
# while the sweep it wraps was still able to find them.
COMPANIONS_DIR="${COMPANIONS_DIR:-$HOME/Repos}"
LANES="${LANES:-core,llama,mlx,eval,collate,evalmain}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$CORE_DIR/.local-integration-runs/overnight-$STAMP"
mkdir -p "$OUT"
WRAP_LOG="$OUT/overnight-wrapper.log"
SUMMARY="$OUT/SUMMARY.md"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S %Z')" "$*" | tee -a "$WRAP_LOG"; }

# Locate a companion repo by PROBING for its Package.swift rather than trusting
# a path convention. Order: caller's COMPANIONS_DIR, then the core checkout's
# own parent (siblings-under-one-dir layout), then the two historical
# defaults. Echoes the resolved path, or nothing. (Mirrors
# local-integration-sweep.sh's resolve_repo() — these scripts are standalone,
# so the helper is duplicated rather than sourced.)
resolve_repo() {
  local n="$1" c
  for c in "$COMPANIONS_DIR/$n" "$(dirname "$CORE_DIR")/$n" "$HOME/Repos/$n" "$HOME/Repos/ManifoldKit/$n"; do
    if [ -f "$c/Package.swift" ]; then (cd "$c" && pwd); return 0; fi
  done
  return 1
}
LLAMA_DIR="$(resolve_repo manifold-llama)" || LLAMA_DIR="$COMPANIONS_DIR/manifold-llama"
MLX_DIR="$(resolve_repo manifold-mlx)"     || MLX_DIR="$COMPANIONS_DIR/manifold-mlx"
EVAL_DIR="$(resolve_repo manifold-eval)"   || EVAL_DIR="$COMPANIONS_DIR/manifold-eval"

log "=== overnight signal run START (lanes=$LANES, out=$OUT) ==="

# ----- PREP: honest per-repo state (no stashing, no branch switching) --------
{
  echo "# PREP $(date '+%Y-%m-%d %H:%M:%S %Z')"
  for name in "core:$CORE_DIR" "llama:$LLAMA_DIR" "mlx:$MLX_DIR" "eval:$EVAL_DIR"; do
    d="${name#*:}"; n="${name%%:*}"
    if [ -d "$d/.git" ]; then
      br="$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)"
      sha="$(git -C "$d" rev-parse --short HEAD 2>/dev/null)"
      dirty="$(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
      echo "$n: branch=$br head=$sha dirty_paths=$dirty  (MEASURING THIS TREE AS-IS)"
    else
      echo "$n: MISSING at $d"
    fi
  done
  echo
  echo "## ollama"
  if curl -sf http://localhost:11434/api/tags >/dev/null 2>&1; then
    echo "ollama: UP"
    curl -s http://localhost:11434/api/tags | python3 -c 'import sys,json;[print("  -",m["name"]) for m in json.load(sys.stdin).get("models",[])]' 2>/dev/null
  else
    echo "ollama: DOWN — core lane will have no real backend"
  fi
} | tee "$OUT/PREP.txt" >>"$WRAP_LOG"

# baseline = most recent prior overnight run (for the morning diff)
BASELINE="$(ls -1dt "$CORE_DIR"/.local-integration-runs/overnight-* 2>/dev/null | grep -v "$STAMP" | head -1)"
log "baseline for diff: ${BASELINE:-<none>}"

# ----- RUN: caffeinate around the real sweep ---------------------------------
log "=== launching local-integration-sweep (caffeinated) ==="
caffeinate -i -s bash "$CORE_DIR/scripts/local-integration-sweep.sh" --lanes "$LANES" --out "$OUT/sweep" >>"$WRAP_LOG" 2>&1
SWEEP_RC=$?
log "=== sweep exited rc=$SWEEP_RC ==="

# ----- TRIAGE: build the morning SUMMARY.md ----------------------------------
{
  echo "# Overnight local-inference signal run — $STAMP"
  echo
  echo "_Sweep exit rc=$SWEEP_RC. Full report: \`$OUT/sweep/REPORT.md\`; wrapper log: \`$WRAP_LOG\`._"
  echo
  echo "## Preflight"
  if [ -f "$OUT/sweep/PREFLIGHT.md" ]; then
    grep -E '^\| |^\*\*|^All [0-9]' "$OUT/sweep/PREFLIGHT.md" 2>/dev/null
  else
    echo "(no PREFLIGHT.md — sweep may have died before preflight wrote it)"
  fi
  if grep -qE ': SKIP-NO-WORK' "$OUT/sweep/REPORT.md" 2>/dev/null; then
    echo
    echo "**⚠️ one or more requested lanes did NO WORK this run (SKIP-NO-WORK below) — read this before trusting the results as signal.**"
  fi
  echo
  echo "## Per-lane result"
  echo '```'
  grep -hE '^(core|llama|mlx[-a-z]*|matrix|collate|eval[:a-z-]*): ' "$OUT/sweep/REPORT.md" 2>/dev/null || echo "(no lane lines — sweep may have died in prep)"
  echo '```'
  echo
  echo "## MLX throughput"
  echo '```'
  grep -h "MLX summary" "$OUT"/sweep/mlx-*.log 2>/dev/null || echo "(none — MLX lane skipped or produced no summary)"
  echo '```'
  echo
  echo "## Local-LLM capability scores (manifold-eval)"
  echo '```'
  grep -hiE '^(BFCL|IFEVAL|MTEB): ' "$OUT/sweep/REPORT.md" 2>/dev/null || echo "(eval lane produced no scores — see Lane summary in REPORT.md)"
  echo '```'
  echo
  echo "## Core lane failures (triage these first)"
  if grep -qE '^core: (fail|TIMEOUT)' "$OUT/sweep/REPORT.md" 2>/dev/null; then
    echo '```'
    grep -hE "failed \(|error:|XCTAssert|Test Case '.*' failed" "$OUT/sweep/core.log" 2>/dev/null | grep -vE 'ACMonitoredAccountStore|CoreData:|accounts-service' | head -30
    echo '```'
  else
    echo "core lane clean ✅"
  fi
  echo
  echo "## Baseline diff"
  if [ -n "$BASELINE" ] && [ -f "$BASELINE/sweep/REPORT.md" ]; then
    echo "Comparing lane lines vs \`$(basename "$BASELINE")\`:"
    echo '```diff'
    diff <(grep -hE '^(core|llama|mlx[-a-z]*|eval[:a-z-]*): ' "$BASELINE/sweep/REPORT.md" 2>/dev/null) \
         <(grep -hE '^(core|llama|mlx[-a-z]*|eval[:a-z-]*): ' "$OUT/sweep/REPORT.md" 2>/dev/null) || true
    echo '```'
  else
    echo "No prior overnight baseline — this run becomes the baseline."
  fi
} > "$SUMMARY"

log "=== DONE. summary -> $SUMMARY ==="
echo "OVERNIGHT_SWEEP_COMPLETE out=$OUT rc=$SWEEP_RC summary=$SUMMARY" | tee -a "$WRAP_LOG"
