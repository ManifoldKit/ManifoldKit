# Plan: Consolidate cross-backend model evaluation (in-place, no new repo)

**Status:** Revised after adversarial review (2026-06-26) — **a dedicated `manifold-eval` repo was proposed and REJECTED.** This doc now tracks the in-place path.
**Related:** `docs/plans/tested-models-cross-repo.md`, `docs/plans/tool-calling-architecture.md`, `scripts/local-integration-sweep.sh`, `ToolCallConformance` port (#2030), SwiftData adapter (#2034)

## 1. Problem

Behavioral model evaluation — "does *this model × quant × backend × renderer* actually tool-call" — is smeared across three repos with real correctness defects in the eval itself:

- **Scorer attribution bug.** The llama.cpp Mistral cell dispatched the correct tool on every scenario (`passed:true` on both assertions) yet scored `toolTP=0, toolFP=1, f1=0`. The matrix verdict was **hand-corrected by a human reading JSONL** — the automated path was wrong.
- **Scorer "divergence" is a CLI `print`, not an engine fork.** MLX's `manifold-tools-mlx` hand-rolls a `SUMMARY` line on top of the *shared* `ScenarioRunner`; its `passed`/`clean` gate reads 0/9 for every model and never fires. `ConformanceScorer.swift` already documents it was built "to be promotable to a shared `.library` product."
- **Absence is not a state.** A missing GGUF → empty CSV → reads as measured.
- **No normalized result record.** Matrices are hand-assembled markdown.
- **`ScenarioLoader.loadBuiltIn()` is CWD-relative** → companions vendor copies of the corpus → drift.

## 2. Adversarial review verdict (why the repo was rejected)

Three independent reviewers (architecture / methodology / pragmatism) converged: **the consolidation is worth doing; a 4th repo is the wrong unit and the headline justifications are false.**

**Factual code corrections (architecture reviewer, verified against `Package.swift`):**
1. Both companions **already** depend on the published `ManifoldTools` library product (`manifold-llama/Package.swift:94`, `manifold-mlx/Package.swift:138`). The corpus + scorer are already shared. "Lifting them into `manifold-eval`" would invert that edge → **package cycle**.
2. `ConformanceScorer` is already meant to be promoted to a `.library`; unifying scoring is a **one-line product change**, not a repo.
3. **"One process" is unbuildable:** `llama_backend_init` is once-per-process, MLX needs serialized in-process Metal, #982 is the dual-engine hazard. Collation must be over records from *separate processes* — which the existing sweep script already does.

**Methodology reviewer (do not trust verdicts until these are fixed):**
- **Twin-divergence is confounded** — Ollama tag vs Q4_K_M GGUF vs 4bit MLX differ in quant **and** checkpoint **and** renderer at once; a divergence can't be attributed to the renderer without a **same-bytes control**.
- **Auto-rendering the matrix removes the human transcript-read that caught the last scorer bug**; golden tests only protect already-seen transcript shapes, not the novel cells the eval exists to run.
- **No determinism pinning.** Two *identical-code* runs show 0.10–0.12 F1 swings; a verdict-class regression detector would cry wolf.
- Macro-F1 over 9 scenarios (one a no-tool scenario scored as F1=0) is a toolset canary, not a capability measure. The cloud "anchor" is noisy and is **not** a ground-truth oracle.

**Pragmatism reviewer:** the value is all code that lives in existing repos; a repo with no owner rots (the documented fuzz cadence collapse — per-PR → nightly → weekly → hand-run — is the precedent); P0–P4 is the banned phased-multi-PR anti-pattern.

## 3. Revised approach — five in-place PRs, no new repo

| PR | Title | Repo / area | Wave | Depends on |
|----|-------|-------------|------|------------|
| **A** | `fix(tools): correct tool-call TP attribution in ConformanceScorer + golden-transcript test` | core / `ManifoldTools` | 1 | — |
| **B** | `fix(tools): load built-in scenarios from Bundle.module, not CWD` | core / `ManifoldTools` | 1 | — |
| **C** | `feat(tools): add ConformanceRecord + CellStatus normalized result schema` | core / `ManifoldTools` | 1 | — |
| **D** | `feat(tools): promote ConformanceScorer to a shared library surface; retire MLX self-scoring` | core product decl (+ companion follow-ups) | 2 | A |
| **E** | `feat(eval): local-integration-sweep emits ConformanceRecords + renders MATRIX from a query` | core / `scripts/` | 2 | C, (A) |

**Wave 1 (A, B, C)** — independent, core-only, additive/low-risk; run in parallel worktrees. **Wave 2 (D, E)** — held until Wave 1 merges (D promotes the *fixed* scorer; E emits the *new* record schema). The companion-side wiring for D (pointing `manifold-tools-mlx`/`-llama` at the shared scorer) is a separate follow-up PR per companion repo, not part of D's core change.

**Execution loop per wave:** implement in isolated worktrees → draft PRs (compile-then-commit-then-push to protect work) → **review-and-fix worker pass on each diff** → mark ready → CI → auto-merge on green. Orchestrator owns CI-watch, merge ordering, and rebases.

## 4. Measurement caveats to fix before any verdict is load-bearing

(These are *not* code PRs above — they gate trusting the output, tracked here so they aren't lost.)
- Pin sampling temperature + seed; report variance / repeats, not means-only.
- Type divergence by *what changed*; require a **same-bytes control** before calling a divergence a renderer bug.
- Drop or separately-score the no-tool scenario (`structured-json-extraction`) out of macro-F1.
- Keep a human transcript spot-check in the loop; demote the cloud anchor from "oracle" to "scenario-design sanity check."
- Guard regression-vs-last-run against environment drift (artifact-hash + same-cell-set baseline) so a missing GGUF doesn't read as a regression.

## 5. When to revisit a dedicated repo

Only if the script-based eval is **actually run on a cadence by an owner for 2–3 months** (clears the fuzz-rot bar) *and* in-process all-three collation proves necessary (it currently isn't — separate-process records suffice). Until both hold, a repo is speculative infrastructure.

## 6. Shipped (2026-06-26)

All six PRs landed on `main` (each reviewed by an adversarial worker before merge):

| PR | Change |
|----|--------|
| #2041 | `ConformanceRecord` + `CellStatus` normalized schema (`notMeasured` first-class) |
| #2042 | `ScenarioLoader` loads the corpus from `Bundle.module`, not CWD (kills vendoring drift) |
| #2043 | Scorer tool-call TP-attribution fix (bare-vs-backtick assertion recovery) + golden test |
| #2045 | `ConformanceScorer.records(...)` public API + `score --emit-records` (absence → `notMeasured`/`loadFail`) |
| #2046 | `MatrixRenderer` (records → `MATRIX.md`) + `matrix` CLI + `local-integration-sweep.sh` wiring |
| #2047 | Matrix cell verdict derived from F1, not dominant failure subtype |

**Validation (`docs/plans/archive/runs/soak-20260626-100115/`):**
- **Smoke + soak** through the full chain (run → `score --emit-records` → `matrix`): 21 cells, 189 normalized Ollama records, one queried `MATRIX.md`. Within-run repeats were bit-identical (greedy sampling) — the overnight 0.10–0.12 F1 swings were cross-environment drift, not per-call noise.
- **#2043 proven on real companion data:** the new scorer re-scored the exact llama.cpp Mistral transcript the overnight run wrongly reported as **F1=0.000** → **F1=0.810**. The cell that previously needed a human reading JSONL to override now scores correctly through the pipeline.
- **Cross-runtime matrix** (`XRUNTIME_MATRIX.md`, Ollama + llama.cpp from existing transcripts) surfaces the gap the hand-written matrices hid: gemma4-e4b ✅ on Ollama vs 💥 load-fail on llama.cpp; gemma3-4b 0.000 on both (model fact); mistral-7b ~0.81–0.88 on both — with the honest "not evidence of a backend bug without a same-bytes control" caveat.

**Still open (tracked in §4, not yet built):** determinism pinning (temp/seed) for cross-run comparison; companion CLIs (`manifold-tools-mlx`/`-llama`) scoring via the shared core scorer rather than self-`SUMMARY` (the consolidation enables it — demonstrated here by scoring their transcripts centrally); MLX leg (no transcripts emitted locally yet).
