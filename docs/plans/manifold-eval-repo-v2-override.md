# Plan: `manifold-eval` — dedicated cross-backend eval repo (v2, OVERRIDE)

**Status:** OVERRIDE of the 2026-06-26 rejection recorded in
[`manifold-eval-repo.md`](manifold-eval-repo.md), proceeding per maintainer direction
(2026-06-29). The in-place consolidation (#2041–#2047) **stays shipped and is the foundation
this builds on** — this plan does **not** unwind it. Read the rejection doc first: this plan is
only credible insofar as it answers every objection it raised. §2 does that explicitly.

**Related:** [`manifold-eval-repo.md`](manifold-eval-repo.md) (the rejection + the 6 shipped PRs),
[`1997-on-device-eval.md`](1997-on-device-eval.md) (the scorer surface + deferred replay moat),
[`tested-models-cross-repo.md`](tested-models-cross-repo.md), `scripts/local-integration-sweep.sh`,
`XRUNTIME_MATRIX.md`, the `ConformanceRecord`/`MatrixRenderer` surface in `ManifoldTools`.

---

## 1. Override rationale — CONFIRMED (maintainer, 2026-06-29)

The 2026-06-26 review rejected a repo for consolidating **tool-call conformance scoring** — a
narrow thing that was, correctly, better done in-place (and was, #2041–#2047). It did **not** weigh
the governance rationale the maintainer has since stated, which is the real basis for the override:

**Primary: separation of implementation from assurance.** ManifoldKit is optimized for *developer
utility* — fast iteration, ergonomic capability surface. The eval repo is optimized for
*assurance* — reproducible, deterministic, adversarial verdicts on model × quant × backend ×
renderer behavior. These are different optimization targets, and the maintainer is deliberately
making the repo boundary the **governance boundary** between them. "Inline is technically simpler"
is true and beside the point: the choice is made on assurance-independence grounds, not convenience.

Why this is the right *kind* of reason (not just preference):
- **Independence reduces self-grading bias.** The rejection's sharpest worry was rubber-stamping
  (auto-verdicts removing the human who caught the scorer bug). An assurance authority with its own
  owner and an adversarial mandate is structurally less prone to bless its own code than evals
  living beside it. Separation improves verdict credibility, it isn't only tidiness.
- **Precedented.** Independent conformance suites are how trusted ecosystems do it — `test262`,
  `web-platform-tests`, Khronos Vulkan CTS, SQLite's separate TH3. All sit outside the
  implementation repo on purpose. What's distinctive here is applying it to a Swift **on-device**
  LLM kit + companion engines, not the pattern itself.

**Supporting:**
1. **Scope is now a multi-benchmark assurance product** (BFCL-full + IFEval + MTEB + vision + the
   #1997 replay-regression moat the plan said "cannot be honestly demonstrated in this repo"), none
   of which fits in `ManifoldTools` without bloating core.
2. **Pure top-of-graph consumer** that owns nothing the companions consume (§2.1) — dissolves the v1 cycle objection.

> ⚠️ The separation rationale *depends on* §11, it does not escape it. The conformance-suite
> precedents all work because they have a committed owner and cadence; an assurance repo that lags
> the implementation is worse than none, because stale assurance reads as a passing grade. Confirm
> the owner + cadence (§11) before P1.

---

## 2. The three rejection reasons, each confronted

A repo plan that does not answer these is the rejected plan. Each is a hard design constraint here.

### 2.1 "Lifting `ManifoldTools` into `manifold-eval` inverts the edge → package cycle"

**Dissolved by an ownership rule, not a workaround.** `manifold-eval` **owns nothing that any
companion or core target consumes.** It is strictly top-of-graph and depends *downward*:

```
manifold-eval ──┬─→ ManifoldKit (ManifoldTools, ManifoldInference scorers, ManifoldBackendTestKit)
                ├─→ manifold-llama ─→ ManifoldKit
                ├─→ manifold-mlx   ─→ ManifoldKit
                └─→ AnyLanguageModel (external)
```

This is a DAG (a diamond), not a cycle. The corpus, `ConformanceScorer`, `ConformanceRecord`,
`MatrixRenderer`, and `ASTMatcher` **stay in `ManifoldTools`** (already a published `.library`,
already consumed by both companions — confirmed by audit 2026-06-29). `manifold-eval` *imports*
them. The cycle only ever arose from *moving* the shared corpus up; we do not move it. New eval
code (IFEval/MTEB lanes, differential comparator, replay driver) that companions do **not** need
lives in `manifold-eval`; anything a companion *would* need stays in or moves *down* into
`ManifoldTools`.

### 2.2 "One process importing all backends is unbuildable"

**Accepted in full; the repo never does this.** `llama_backend_init` is once-per-process, MLX
needs serialized in-process Metal, #982 is the dual-engine hazard. `manifold-eval` is therefore a
**separate-process orchestrator + collator**, exactly like `local-integration-sweep.sh` today: it
shells per-backend runs (a `swift test`/`xcodebuild` invocation per repo, or a small per-backend
runner executable), each emits `ConformanceRecord` JSON, and `manifold-eval` collates the records.
The shipped `XRUNTIME_MATRIX.md` already proves cross-backend collation works this way. The repo's
value over the bash script is **typed, tested orchestration + scoring + differential analysis**,
not in-process unification.

### 2.3 "A repo with no owner rots (the fuzz precedent)"

**Answered by §11.** Named owner, a fixed local-Apple-Silicon cadence, and a **CI rot-guard** that
fails if the manifest of evaluated (model × backend × lane) cells regresses or the last successful
run is older than the cadence window. No cadence commitment → do not create the repo; extend
in-place instead.

### 2.4 Methodology caveats (still binding, repo or not)

From the rejection doc §4 — these gate *trusting a verdict*, and are designed into §8:
same-bytes control before calling a divergence a bug; determinism pinning (temp/seed) with
reported variance; the no-tool scenario scored separately; cloud demoted from "oracle" to
"sanity check"; environment-drift guard so a missing model reads as `notMeasured`, not a regression.

---

## 3. Scope

**In:**
- A top-of-graph SwiftPM package + CLI that runs eval lanes uniformly across **Ollama, Foundation,
  MLX, llama.cpp, and AnyLanguageModel (cloud)** via separate-process runs, collating `ConformanceRecord`s.
- New standard-benchmark lanes: **BFCL-full** (expand from 5 fixtures), **IFEval**, **MTEB subset**.
- The **differential comparator** with same-bytes controls (§8).
- The **#1997 replay-regression moat** (§9), now demonstrable here against a real GGUF backend.
- Consumes the **#1997 scorer surface** (built in-core first — §5).

**Out (stays where it is — the audit confirmed it can't cleanly move):**
- All unit/contract/CI tests in core + companions.
- Backend-intimate live suites: llama's GBNF 5-family conformance + `llama_backend_init` latch;
  MLX's KV-cache / diffusion / VLM suites + metallib-under-`xcodebuild` gate.
- The shared harness (`ManifoldBackendTestKit`, `ManifoldTestSupport`, `ManifoldTools`) — consumed, never relocated.

---

## 4. Architecture & repo layout

Repo: **`ManifoldKit/manifold-eval`** (org per the 2026-06 move). SwiftPM, `swift-tools-version`
matching the CI toolchain ceiling (≤ Xcode 26.x / Swift 6.2.x). Local-package consumers use explicit
`name:` per the SwiftPM identity rule.

```
manifold-eval/
  Package.swift                 # deps: ManifoldKit, manifold-mlx, manifold-llama, AnyLanguageModel
  Sources/
    ManifoldEval/               # library: lane protocol, collator, differential comparator, report
      Lane.swift                #   protocol EvalLane { run(backend) -> [ConformanceRecord] }
      Collator.swift            #   merge per-process records → one normalized result set
      Differential/
        Cohort.swift            #   same-weights / same-family / cloud cohorts (§8)
        DivergenceTriage.swift  #   classify divergence: quant|template|sampler|nondeterminism|bug
        PromptByteControl.swift #   capture + diff rendered prompt bytes across backends
      Lanes/
        ConformanceLane.swift   #   wraps existing ManifoldTools ScenarioRunner + ConformanceScorer
        BFCLLane.swift          #   full BFCL corpus via existing ASTMatcher/BFCLRunner
        IFEvalLane.swift        #   programmatic constraint checks (new scorer)
        MTEBLane.swift          #   embeddings: cosine/nDCG via #1997 SemanticSimilarity
      Replay/
        RecordReDriver.swift    #   #1997 §3 primitive (extracted from Replayer.runOnce)
        RegressionGate.swift    #   byte-deterministic re-drive + score-movement detection
    manifold-eval-cli/          # executable: lane selection, model discovery, report emit
  Tests/                        # CI-safe only: collator/triage/scorer unit tests on FIXTURES
                                # (real-model lanes are hardware-gated, run via the CLI, not CI)
  Fixtures/                     # BFCL/IFEval/MTEB corpora (Bundle.module, never CWD)
  .github/workflows/
    build.yml                   # build + lint + fixture-unit-tests (cheap, every PR)
    eval-nightly.yml            # workflow_dispatch + cron: real lanes on self-hosted Apple Silicon
    rot-guard.yml               # fails if last successful eval-nightly older than cadence window
```

**Model discovery, hardware/skip predicates, fixture comparison** are consumed from
`ManifoldTestSupport.HardwareRequirements` / `ManifoldBackendTestKit` — not reimplemented (the audit
found these already centralize `~/Documents/Models`, `MANIFOLD_DISCOVER_LOCAL_MODELS`, GGUF/MLX scan).

---

## 5. Prerequisite (in MK, single PR): the #1997 scorer surface

The audit found `EvalScorer`/`Score`/`SemanticSimilarity` **do not exist in code** — only in the
plan doc. Build them in-core first (per #1997: ship the scorer + a live in-repo BFCL consumer so
it isn't inert scaffolding — the #2064 lesson). One coherent PR, not phased:

- `Sources/ManifoldInference/Eval/`: `protocol Scorer { func score(_:) -> Score }`, `Score`/`ScoreValue`,
  `ExactMatchScorer`, `ASTMatchScorer` (wraps the existing `ManifoldTools.ASTMatcher`),
  `SemanticSimilarityScorer` (cosine), all wrapping the **existing** `ConfusionCounts`/`MacroAveragedMetrics`
  (`ManifoldInference/Metrics/`, 90 LOC) rather than duplicating metric math.
- Wire BFCL's AST track to call `ASTMatchScorer` — the live consumer that proves it's not scaffolding.
- Gate: full affected target + the audit suites (`SilentCatchAuditTest`, schema/snapshot guards) per the draft-PR loop.

`manifold-eval` then *consumes* this surface; it does not fork scorers.

---

## 6. Lanes

| Lane | Scoring (deterministic, no judge) | Providers | New code |
|------|-----------------------------------|-----------|----------|
| Conformance (tool-call) | existing `ConformanceScorer` (fixed #2043) | all local | thin wrapper |
| BFCL-full | `ASTMatchScorer` over full corpus (~2k cases vs current 5) | all local + cloud | corpus + categories (relevance/parallel/multi-turn) |
| IFEval | programmatic verifiable constraints | all | new scorer + corpus |
| MTEB (subset: STS + retrieval) | cosine / nDCG via `SemanticSimilarity` | embedding backends (MLX, llama, nomic) | new lane |
| Vision (MMBench-style, multiple-choice) | exact-match | Ollama, MLX, (llama when #416 unblocks) | new lane, later phase |

Cloud (ALM/SaaS) runs lanes for **absolute score only** — never in a differential cohort, never an
oracle (it's nondeterministic and over the network). It is a scenario-design sanity check, per §2.4.

---

## 7. Differential oracle design (the heart, and the fragile part)

The "Ollama > llama ⇒ bug" signal is only real if confounds are controlled. Three cohorts:

- **Cohort A — same-weights (strong oracle):** pin the **identical GGUF** to Ollama (`Modelfile FROM
  ./x.gguf`) and manifold-llama. Now quant + checkpoint are held constant; remaining divergence is
  renderer/sampler/runtime → investigable.
- **Cohort B — same-family, different-runtime (trend only):** llama vs MLX. Quant differs (GGUF vs
  MLX 4-bit) → compare *trends over time within a backend*, never absolute cross-backend deltas.
- **Cohort C — cloud (absolute only):** no differential.

Controls (all required before a divergence is load-bearing — these *are* the §2.4 caveats):
1. **Prompt-byte capture + diff.** Capture each backend's rendered prompt bytes; a template divergence
   (Ollama's Go `Modelfile` vs llama's Jinja/GBNF vs MLX's swift-transformers path) is itself a
   first-class **finding**, not silent noise.
2. **Determinism pinning.** Greedy / `temp=0`, fixed seed where supported; report **variance over N
   repeats**, not means-only. Note the known landmines: Ollama seed plumbing is unreliable, and
   `Replayer.runOnce` currently hardcodes `repeatPenalty: 1.1` and never plumbs the recorded seed
   (#1997 §3) — both must be fixed in `RecordReDriver` (§9).
3. **Divergence triage.** Classify every divergence as quant / template / sampler / nondeterminism /
   **genuine-bug**; only residual unexplained divergence beyond a threshold is flagged for a human.
4. **Absence ≠ regression.** A missing model → `notMeasured` (the #2041 `CellStatus`), guarded by an
   artifact-hash + same-cell-set baseline so a missing GGUF never reads as a regression.

Framing: this is **divergence triage to focus human attention**, not automatic bug detection.

---

## 8. Replay-regression moat (#1997 §3, now demonstrable here)

This is the card that justifies the repo over the script. Deferred from #1997 precisely because it
needs a real local backend with changing bytes — which this repo has (manifold-llama, real GGUF).

- **Extract `RecordReDriver.reDrive(handle:record:) -> RunRecord`** from `Replayer.runOnce`'s body
  (do **not** add `Replayer.reproduceOutput` — keep `findingsRoot`/drift-refusal/findings-layout out
  of eval; eval composes `makeHandle + reDrive + score`).
- **Fix the config-lossy re-drive:** plumb the recorded seed + `topK`/`repeatPenalty` into generation.
- **`RegressionGate`:** re-drive a captured session against a *new* GGUF (re-quant / model upgrade),
  score both, and flag **score movement**. This only earns its keep when bytes differ — i.e.
  cross-quant, which is exactly what this repo can produce and core cannot. Lockstep with a
  manifold-llama consumer.

---

## 9. Report schema & output

Reuse, don't reinvent: collate to `ConformanceRecord` (#2041), render via `MatrixRenderer` (#2046)
to one leaderboard `MATRIX.md` (provider × lane × model) plus a `DIVERGENCE.md` (Cohort-A flagged
cells with triage classification). Keep a human transcript spot-check in the loop (the practice that
caught the #2043 scorer bug) — auto-rendering must not remove it.

---

## 10. Lockstep (core-bump.yml — maintainer-confirmed)

Add `manifold-eval` as a **4th dispatch target** in core's `core-bump.yml` so an MK release
auto-bumps its `ManifoldKit` + companion pins, same as the companions today. ⚠️ Known issue: the
2026-06 org move broke the `notify-companions` dispatch token (403); until the PAT is re-scoped,
the eval-repo bump must be dispatched manually each release, same as the companions currently are.

---

## 11. Ownership, cadence & rot-guard (the anti-rejection commitment)

- **Owner:** named maintainer (not "the team"). Required — no owner → no repo.
- **Cadence:** real lanes run on local/self-hosted Apple Silicon on a fixed schedule (proposal:
  nightly `eval-nightly.yml` + on-demand `workflow_dispatch`), writing a dated run under `runs/`.
- **Rot-guard (`rot-guard.yml`):** fails CI if (a) the last successful `eval-nightly` is older than
  the cadence window, or (b) the evaluated cell-manifest shrank vs the committed baseline. This is the
  structural answer to "fuzz rotted from per-PR → hand-run": staleness becomes a red check, not silence.

---

## 12. CI strategy

- **Per-PR (cheap, every PR):** `build.yml` — build + lint + **fixture-only** unit tests (collator,
  triage classifier, scorers on recorded fixtures). No models, no hardware. Safe for hosted runners.
- **Real evals:** never on hosted CI (hardware-gated, 10× billing, flaky). Self-hosted Apple Silicon
  via `eval-nightly.yml`. This matches the existing posture — these suites already `XCTSkip` in core CI.
- No new hosted-CI cost is added to MK or the companions.

---

## 13. Phasing (greenfield repo — internal phases are fine; MK-side PRs are single units)

The "no phased feature splits" rule targets CI-triggering PR storms in the **mature core repo**, not
the initial build-out of a greenfield repo whose tests mostly don't touch hosted CI.

| Phase | Deliverable | Repo |
|-------|-------------|------|
| **P0 (prereq)** | ✅ **DONE — shipped #2067** (`EvalScorer`/`Score`/`EvalRunOutput` in `ManifoldInference/Eval`, `BFCLASTScorer`/`BFCLNameOnlyScorer` in `ManifoldTools`, BFCLRunner routes through them). Residual: `ExactMatchScorer` not yet built — defer to P3 (IFEval/vision need it). | ManifoldKit |
| **P1** | ✅ **SHIPPED 2026-06-29** — repo live at `ManifoldKit/manifold-eval` (public). Separate-process `Collator` (with coreCommit / tooling-drift comparability guard) + `CrossRuntimeMatrix` + `manifold-eval collate` CLI; 9 tests; adversarially reviewed (zero-yield-leg + drift guards added). Depends only on ManifoldKit `exact("0.63.0")`. | manifold-eval |
| **P2** | ✅ **SHIPPED 2026-06-29** — P2.1 harness (manifold-eval #1, `735c3a3`) + P2.2 raw-prompt runner (manifold-llama #121, `bc7ec0b`), both adversarially reviewed (B1 deadlock + triage-determinism fixes), full gates green, merged. **Credibility gate PASSED:** same Qwen3-0.6B GGUF on Ollama + manifold-llama → byte-identical deterministic output, classified `identical`. Differential oracle proven. See §13b. | manifold-eval + manifold-llama |
| **P3** | ✅ **SHIPPED 2026-06-30** (overnight) — merged to manifold-eval main (green): `ExactMatchScorer` (#2), IFEval lane w/ real 541-case corpus (#4), MTEB-STS lane (#5), BFCL-full lane (#6). Each adversarially reviewed (caught: locale fold, IFEval verifier semantics, BFCL greedy→bipartite, MTEB tie-test gap) + fixed. **Follow-ups merged 2026-06-30:** CLI lane-runners `manifold-eval ifeval\|bfcl\|mteb` (#7); real corpora wired+verified (#9) — Gorilla v4 BFCL = 1,240 cases, STS-B = 1,379 pairs → nomic-embed Spearman 0.8425 (matches published ~0.85); corpora fetched to cache, not committed. | manifold-eval |
| **P4** | `RecordReDriver` + `RegressionGate` replay moat (lockstep w/ manifold-llama) | manifold-eval + manifold-llama |
| **P5** | core-bump.yml lockstep + rot-guard + cadence go-live | ManifoldKit + manifold-eval |
| **(later)** | Vision lane (gated on #416 for llama) | manifold-eval |

P0 is a hard prerequisite (the scorer must exist in-core first). P1→P2 are the credibility gates: if
the same-bytes differential doesn't produce a trustworthy signal, **stop** — the repo's headline value
is unproven and we fall back to the shipped in-place path.

---

## 13b. P2 detailed scope (sequenced 2026-06-29)

**P2 is the credibility gate** (§13): its job is to prove the same-bytes differential produces a
*trustworthy* signal. The design is built around making divergence *attributable*, not just measurable.
Sequencing: **P2.1 Ollama-harness first** (de-risk the harness live against local Ollama), **then P2.2
manifold-llama runner** (lockstep — unlocks the real same-GGUF Cohort A).

### Components

| # | Component | Where | Live dep |
|---|-----------|-------|----------|
| 1 | `DifferentialRecord` (promptHash, rawOutput, sampler config {temp,seed,topK,repeatPenalty}, cohort tag) | manifold-eval | none |
| 2 | Comparator + Cohort classifier + `DivergenceTriage` (the credibility logic) | manifold-eval | none (fixture-tested) |
| 3 | Prompt rendering seam — render ONCE via MK `JinjaPromptRenderer` + GGUF `chat_template`; + BOS normalization | manifold-eval (imports `ManifoldInference`) | none |
| 4 | Ollama raw-prompt driver (`/api/generate {raw:true}`, temp=0, seed) | manifold-eval | local Ollama (HTTP) |
| 5 | Determinism harness (N repeats → variance report) | manifold-eval | local Ollama |
| 6 | `DIVERGENCE.md` report + `manifold-eval diff` CLI | manifold-eval | none |
| 7 | **Raw-prompt eval runner emitting `DifferentialRecord` JSON** | **manifold-llama (lockstep PR)** | local GGUF |

Component 7 is unavoidable for the real Cohort A: only Ollama and llama.cpp load the **same GGUF**, and
manifold-eval cannot link llama (separate-process rule). No companion-free path to same-weights exists.

### DivergenceTriage states (the heart)

- **`identical`** — same promptHash + same output → no divergence.
- **`promptDivergence`** — promptHash differs → render/BOS control FAILED; comparison invalid (harness
  bug, not a model finding). The most important guard — catches when same-bytes wasn't achieved.
- **`samplerNondeterminism`** — same prompt, outputs differ, within-backend repeats also differ → noise.
- **`tokenizerDivergence`** — same prompt string, token-id streams differ → vocab/tokenize mismatch.
- **`genuineDivergence`** — same prompt, both deterministic, same vocab, outputs still differ → the real
  signal worth a human. Only this state is a bug candidate; everything above is confound-stripping.

### Controls (the verified §14.2 wrinkles become code)

- **BOS normalization** — Ollama `raw:true` adds no BOS; llama tokenizes `addBos:true`. Seam must emit
  matched token streams. *First thing to validate (token-id level, not text).*
- **Determinism pinning** — greedy/temp=0 (sidesteps Ollama's unreliable seed plumbing); report variance
  over N repeats before trusting any cross-backend delta.
- **prompt-hash** on every record so `promptDivergence` is detectable, never silent.

### P2.1 work-list (first `/ship` unit — manifold-eval only, live-testable vs local Ollama)

Components 1–6. Milestones: (a) determinism control green — same bytes → identical output at temp=0
across N repeats; (b) BOS/tokenizer parity proven at token-id level; (c) Ollama-vs-Ollama triage
classifies correctly on fixtures + live. Exit criterion: harness measurement fidelity proven before the
cross-repo change.

### P2.2 work-list (lockstep)

Component 7 in manifold-llama (a raw-prompt eval-runner subcommand: load GGUF → `generate(prompt:)` →
emit `DifferentialRecord` JSON), then the end-to-end Ollama↔llama.cpp Cohort A in manifold-eval. **The
credibility verdict is rendered here:** if same-GGUF Ollama↔llama diverges beyond sampler noise *after*
controls and it's not classifiable as prompt/tokenizer/nondeterminism, either the oracle works or a
confound remains — distinguishing the two is the gate. If unprovable, **stop** and fall back to in-place.

### Out of scope (later)

Cohort B/C trend analysis beyond recording; the replay moat (P4); cloud differential (absolute-only).

---

## 14. Risks & open questions

1. **Override risk.** This reverses a 3-day-old reviewed decision. If grounds §1 aren't real, the
   honest move is the in-place path. Re-confirm before P1.
2. **Same-bytes control feasibility — ✅ VERIFIED 2026-06-29 (Ollama 0.30.11, Llama-3.1-8B-Instruct
   Q4_K_M).** Cohort A is feasible via **prompt-level** same-bytes (not message-level):
   - Ollama imports the identical external GGUF (`ollama create -f Modelfile` `FROM ./x.gguf`) and
     dedups by hash → same weights leg solid.
   - Ollama 0.30.11 preserves the GGUF's embedded `tokenizer.chat_template` (Jinja), but also
     reports "using autodetected template llama3-instruct" (its own), and its Jinja engine ≠
     llama.cpp `minja`, and the template injects `date_string`/`bos_token` defaults — so
     **message-level rendering is NOT guaranteed byte-identical**. Do not rely on it.
   - **Both backends expose a raw-prompt path**, so we render the prompt ONCE (one renderer) and inject
     it: Ollama via `/api/generate {"raw":true}` (verified: bypasses template, returns correctly);
     manifold-llama via `LlamaBackend.generate(prompt:)` which tokenizes the string directly
     (`LlamaTokenization.tokenize(prompt, addBos: true)`) with no internal template step.
   - **Control detail for P2:** Ollama `raw:true` adds **no** special tokens; manifold-llama tokenizes
     with `addBos: true`. The harness must normalize BOS (feed the prompt without an explicit
     `<|begin_of_text|>` and account for the one-token asymmetry) or the token streams differ by the
     leading BOS. This is the single known control wrinkle — minor and deterministic.
   - **Net:** the headline differential survives at full strength; residual divergence collapses to
     tokenizer (same GGUF vocab → matches), sampler (temp=0 + seed; Ollama seed via `options.seed`,
     manifold-llama via config), and the BOS detail above.
3. **Replay determinism.** The moat depends on byte-deterministic re-drive; the documented seed/
   repeatPenalty losses must be fixed *and verified* (a re-drive that isn't bit-identical for
   identical config makes the score-movement gate cry wolf).
4. **Owner/cadence reality.** Without a committed owner the rot-guard just turns the repo red and
   nobody acts — the fuzz outcome with extra steps.
5. **swift-tools-version drift** across 4 pinned packages; keep ≤ CI toolchain ceiling.

---

## 15. Decision gate before any code

1. Confirm the §1 override rationale is the actual justification.
2. Name the owner + cadence (§11).
3. Approve P0 (the in-core scorer PR) as the first unit of work.
