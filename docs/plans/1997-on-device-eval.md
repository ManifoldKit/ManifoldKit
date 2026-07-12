# Plan: On-device LLM eval surface — Phase 1 (#1997)

> **Status:** v3 — converged after TWO adversarial review rounds (3 reviewers on the v1
> strawman, 2 on the v2 revision). Ground-truthed against MK source 2026-06-28. The
> product-motivated successor that `docs/plans/1993-eval-surface.md` step 4 invited (that
> plan was rejected and removed in a 2026-07 docs/plans hygiene pass; see git history) —
> justified on on-device differentiation, NOT on deduping downstream apps (rejected at N=2).
>
> **Headline decision (v3):** Ship the **scorer surface + BFCL adoption** in-core now. **Move
> the replay-regression "moat" OUT of Phase 1** to a manifold-llama lockstep follow-up — it
> cannot be honestly demonstrated in this repo (see §3). This inverts v2's "lead with the moat."

## 1. Thesis (unchanged) and what survives review

MK should own **on-device, deterministic LLM eval**. The genuinely ownable card no HTTP-client
framework can reproduce is **byte-deterministic re-drive of a captured local-model session +
detect whether the score moved** ("did re-quantizing / upgrading the GGUF change correctness?").

The two review rounds confirmed the *direction* and demolished the *in-core demonstration* of
the moat. What survives as **Phase 1 (shippable, demonstrable in this repo)**:
- A small, honest **scorer surface** in `ManifoldInference`.
- A **real in-repo consumer** (BFCL's AST track) that adopts it — proving it's live, not scaffolding.

What moves to a **cross-repo lockstep follow-up**: the replay-regression gate (§3).

## 2. The decisive finding: why the moat can't ship in-core

Both v2 reviewers, independently, killed "lead with the moat in Phase 1":

1. **The in-core regression test is green by construction.** Deterministic replay ⇒ identical
   output bytes ⇒ any pure scorer returns an identical value ⇒ "assert the score didn't move"
   is *tautologically true*. It tests the replay machinery, not the scorer — an inert
   #2064-shaped test. (A `MockInferenceBackend` emits scripted tokens regardless of config, so
   re-drive-and-compare *cannot fail*.)
2. **Byte-determinism and score-movement are in direct tension.** The scorer only earns its
   keep when bytes *differ* (GGUF re-quant, model upgrade) — which only happens **cross-repo**
   (real local-backend factories live in `manifold-llama` / `manifold-mlx`, not here).
3. **In-core determinism witnesses are untrustworthy.** `OllamaFuzzFactory` inherits
   `supportsDeterministicReplay == true` by default, but the protocol's own doc hedges "verify
   first — Ollama seed plumbing varies" (`FuzzBackendFactory.swift:18-20`). Worse, the existing
   re-drive path `runOnce` **never plumbs the recorded seed into generation** and **hardcodes
   `repeatPenalty: 1.1`** (`Replayer.swift:331-336`) — so even the baseline re-drive is
   config-lossy and not faithfully deterministic for *scoring*.
4. **Cosine is the worst scorer for the gate anyway.** Where the scorer matters (bytes differ),
   §6's own caveat applies: cosine is uncalibrated and measures topicality, not correctness — a
   real regression (wrong city, negated claim) can read "stable." So similarity is *vacuous*
   in-core and *untrustworthy* cross-repo. Decouple it from the gate entirely.

**Conclusion:** shipping `reproduceOutput` + a regression gate in-core would freeze a public
fuzz API for a use case no in-core backend can exercise, behind a test that can never go red.
Don't. Ship the seam *with* its real consumer (manifold-llama), as a re-drive **primitive**.

## 3. The replay-regression gate → cross-repo lockstep follow-up (NOT Phase 1)

When it lands (separate effort, lockstep with a manifold-llama consumer):
- **Extract, don't bolt on.** Pull `runOnce`'s body into a free
  `RecordReDriver.reDrive(handle:record:) -> RunRecord` primitive. Do NOT add a hash-resolving
  `Replayer.reproduceOutput` — that drags `findingsRoot`, drift refusal, and the
  `findings/<detector>/<hash>/record.json` layout (whose only writer is fuzz's `FindingsSink`)
  into the eval surface. Eval composes `makeHandle + reDrive + score`.
- **Fix the config-lossy re-drive:** plumb the recorded seed (and `topK`/`repeatPenalty`) into
  `GenerationConfig` so "the score moved" compares against a faithful baseline.
- **Use a meaningful deterministic scorer** (exact-match / AST equality), not cosine.
- **Non-tautological test:** drive *two different* backends; assert the score *moves* on
  divergence and *holds* on identical re-drive. (A genuine red-capable assertion — what v2's
  §7 liveness gate failed to require.)

## 4. Phase 1 deliverables (the demonstrable, fuzz-decoupled core)

| # | Piece | Module | Notes |
|---|---|---|---|
| 1 | `ScoreValue` enum (`number`/`bool`/`unavailable`) + `Score {value, answer, explanation, metadata}` | `ManifoldInference` | All three cases have a live consumer this PR: `number` (similarity cosine), `bool` (BFCL AST match), `unavailable` (similarity degenerate/no-signal — never `number(0)`). `category`/`dict` deferred (no consumer; additive when hygiene/ConformanceScorer migrates). `Score` intentionally not `Codable` yet. `var doubleValue: Double?` convenience. |
| 2 | `EvalScorer { associatedtype Expected; func score(output:expected:) }` + `EvalRunOutput` projection | `ManifoldInference` | Expected-vs-actual only. Zero fuzz deps. |
| 3 | `SemanticSimilarityScorer` (standalone, NOT tied to any gate) | `ManifoldInference` | Required `threshold`; internal L2-norm (don't assume `NLEmbedding` normalized); **detect zero-norm post-embed → explicit no-signal** (`NLEmbeddingBackend.embed` silently returns a zero vector for empty/unembeddable text, `NLEmbeddingBackend.swift:79` — cosine 0.0 must NOT read as "maximally wrong"). Ships the §6 caveat. |
| 4 | **First real consumer:** BFCL **AST track** (`ASTMatcher`/`BFCLRunner`) emits `[Score]` | `ManifoldTools/BFCL` | Maps cleanly: per-case `Score{value: .bool(matched), explanation: bestFailures.first}`. Replaces inline `astMatched += 1` counters. Two scorers (AST + name-only) over the same output validate the heterogeneous-scorer design. **Leave `ConformanceScorer` on `ConfusionCounts`** — its set-valued confusion counts do NOT collapse to one `ScoreValue`; forcing it would be a fake conformance. |
| 5 | `Metric` protocol + retrofit onto `MacroAveragedMetrics` **with `BFCLRunner` as the real caller** | `ManifoldInference` | **Only if** it cleanly abstracts the metric MK already ships. If it can't cover `MacroAveragedMetrics`/`ConfusionCounts`, it's the wrong abstraction — **defer to Phase 2**, don't ship a lone toy `MeanAccuracy` conformance (speculative generality). |

**Cut from Phase 1** (agree across all reviewers): `HygieneScorer` (needs the detector-protocol
`DetectorInput` narrowing first — only ~3 of 11 detectors fire on an eval capture; §ex-4),
JSONL/`EvalFixture` loader, backend-matrix runner, `epochs`/pass@k, `LLMRubricScorer`, report
formatter, and the replay-regression gate (§3, → cross-repo lockstep).

## 5. Liveness (the #2064 gate, corrected)

The anti-inert-scaffolding proof for Phase 1 is **BFCL adoption (#4) itself** — a real in-repo
consumer with an actual ground truth, not a self-contained test the test itself writes. Scorer
unit tests live in `ManifoldInferenceTests` (the scorers have no fuzz dep). There is no
replay-gate test in Phase 1 because there is no replay gate in Phase 1.

## 6. Must-ship caveat for `SemanticSimilarityScorer`

> Uses Apple's general-purpose `NLEmbedding` (sentence vectors), NOT an eval-tuned model.
> Cosine measures *topical relatedness*, not *correctness*: a wrong-but-on-topic answer can
> score as high as the right one. It is a **screening signal for free-form prose**, not a
> graded verdict for factual/short-answer tasks — use exact/contains/rubric scorers for those.
> `value` is raw cosine over L2-normalized vectors; `threshold` is caller-supplied (promptfoo
> uses 0.75 as a starting point, not a guarantee). Empty/unembeddable text yields an explicit
> "no signal", never `0.0`.

## 7. Scope / PR shape

Phase 1 (#1–4, +#5 if it earns it) is one PR, comfortably under CLAUDE.md's ~800-LOC / ~40-file
threshold — it's value types + one scorer + a BFCL refactor, no new target, no fuzz API change.
This is the smallest **demonstrable-in-this-repo** shippable core. The replay seam (§3) is a
separate, later, cross-repo-lockstep effort.

## 8. Honest ledger — corrections accumulated across both rounds

- ❌ v1 "the moat is a thin `Replayer` wrapper" — wrong; `Replayer` is finding-hash-repro-shaped
  (`runOnce` private, `:323`), surfaces no output.
- ❌ v1 "+4 public snapshot inits trips the api-break gate" — wrong; additive API doesn't trip
  breakage-mode digester.
- ❌ v1 "hygiene-as-a-scorer, for free" — wrong; ~3 of 11 detectors fire on a stubbed eval record.
- ❌ v1/v2 "`NLEmbedding` is L2-normalized" — unverified; normalize defensively + handle zero-vector.
- ❌ v2 "lead with the moat; in-core mock/Ollama proves the mechanism" — wrong; tautological
  (mock) / unverified (Ollama) + config-lossy re-drive. Moat moves cross-repo.
- ✅ v2 placement split (scorers in Inference, gate in Fuzz) — holds; Fuzz→Inference edge exists
  (`Package.swift:920`). v3 keeps scorers in Inference and removes the in-core gate.
- ✅ v2 `ScoreValue` enum — holds, refined during impl to `number`/`bool`/`unavailable` (all three have a live consumer this PR; `unavailable` replaces a metadata flag for the similarity no-signal path). `category`/`dict` deferred until a real consumer exists.

## 9. Decision needed

Build Phase 1 (§4)? It's small, fully demonstrable in-repo via BFCL, freezes no fuzz API, and
de-risks the eval `Score`/`Metric` shape against a real consumer before any cross-repo work. The
moat is preserved as a *direction* with a concrete, honest landing path (§3) — just not in this PR.
