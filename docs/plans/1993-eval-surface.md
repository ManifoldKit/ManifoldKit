# Plan: ManifoldKit eval surface (#1993)

> **VERDICT (2026-06-21, post-review): DO NOT BUILD `ManifoldEval`.** Three independent reviewers (architecture critic, downstream-consumer critic, comparative-frameworks research) converged: the dedup premise of #1993 is refuted. The `EvalScorer`/`EvalRunOutput` abstraction below fits **neither** app (Fireside scores a live SwiftData graph, not generation text; Idlewick scores a multi-turn offline opcode log, not a single run). Net cross-app deletion ≈ **71 LOC** (`ConfusionCounts`) for Fireside, **~0** for Idlewick. **Action: ship only the `ConfusionCounts` pure-math struct into an existing target + document existing seams (`GenerationCompletion.Reason`, `RunRecord`, detectors, `Replayer`). Revisit at N=3.** A *separate, product-motivated* on-device-eval opportunity exists (see "Review verdict" at end) but must not be justified on #1993's dedup grounds. The design below is retained as the rejected proposal + rationale.

**Status:** ~~DRAFT for adversarial review~~ REVIEWED & REJECTED — 2026-06-21
**Issue:** [#1993](https://github.com/roryford/ManifoldKit/issues/1993) (proposed `ManifoldEval` companion)
**Related:** #1930 (OTel GenAI span export — composes, does not overlap), #1992 (structured-output grammar — sibling extraction)

## TL;DR

The issue proposes extracting a `ManifoldEval` **companion package** from Idlewick's `NarrationEval` + Fireside's `FiresideEval`. Two deep dives found:

1. The two apps' eval harnesses are **~90% domain-coupled** and **not the same shape** (Fireside scores a live `GenerationStream` against golden graph snapshots; Idlewick scores a persisted event log offline). There is **no large shared body to dedupe**.
2. MK **already owns ~70–80% of a general eval harness** inside `ManifoldFuzz` (capture/replay/detectors/corpus/findings/sink) plus core primitives (`RepetitionDetector`, `ThinkingTransform`, `InferenceMetricSink`, `GenerationCompletion.Reason`).
3. The genuine gap is the difference between **bug-hunting** (fuzz: "does the output have artifacts?") and **correctness measurement** (eval: "is the output correct?").

**Recommendation:** Do **not** build a companion repo. Add a thin **`ManifoldEval` module inside this package**, depending on `ManifoldFuzz`, that supplies the three missing eval primitives and reuses the existing fuzz spine. Domain scoring stays in each app.

## What already exists (reuse, do not rebuild)

| Capability | Location | Role in eval |
|---|---|---|
| Deterministic capture | `ManifoldFuzz/EventRecorder.swift`, `RunRecord.swift` | Capture a run's exact prompt+config+events |
| Deterministic replay | `ManifoldFuzz/Replay/Replayer.swift`, `Shrinker.swift` | Re-drive deterministic backends; refuses cloud |
| Hygiene detectors (11+) | `ManifoldFuzz/Detectors/` | looping, thinking-block, template-leak, tool-call validity (incl. schema), memory/concurrency |
| Loop detection | `ManifoldInference/Services/RepetitionDetector.swift` | `looksLikeLooping` + `repetitionRate` |
| CoT stripping | `ManifoldContract/ThinkingTransform.swift` | reasoning/visible separation |
| Corpus + mutation | `ManifoldFuzz/Corpus.swift`, `Mutators/` | seed-driven inputs |
| Findings dedup + severity | `ManifoldFuzz/Finding.swift`, `Sink/FindingsSink.swift` | flaky→confirmed model |
| Scenario invariants | `ManifoldFuzz/Scenarios/FuzzScenario.swift` | `invariantHeld: Bool` checkpoints |
| Backend rotation | `ManifoldFuzz/RotatingFuzzFactory.swift`, `ParallelFuzzWorkers.swift` | run across models (rotation, not matrix) |
| Telemetry sink | `ManifoldInference/Metrics/InferenceMetric{,Sink}.swift` | TTFT/ITL/cost capture |
| Stream-outcome | `GenerationCompletion.Reason`, `RunRecord.stopReason` | completed/length/toolLimit/cancelled/error |
| Event fixtures | `ManifoldBackendTestKit/FixtureComparator.swift` | event-sequence match (NOT semantic) |

## The genuine gaps (the whole of "eval" vs "fuzz")

1. **Golden-fixture / expected-vs-actual comparison.** No `compare(actual, expected)` for *semantic* output. `FixtureComparator` matches event sequences for contract tests, not answers.
2. **Scoring primitives.** No precision/recall/F1/confusion matrix anywhere. Lift `ConfusionCounts` (~93 LOC) from Fireside — pure, zero coupling.
3. **Backend-matrix sweep.** N fixtures × M backends × K models as a first-class cross-product with per-cell aggregation. Rotation exists; systematic sweep + aggregation does not.

Everything else in #1993's A/B/C is already in MK or is app-domain code that should not move.

## Proposed design

### Module placement

New target **`ManifoldEval`** in `Package.swift`, depending on `ManifoldFuzz` (+ `ManifoldInference`, `ManifoldContract`). Rationale for a separate module rather than folding into `ManifoldFuzz`: keep fuzz's CLI/corpus/campaign weight off consumers who only want "score this output." `ManifoldFuzz` stays bug-hunting; `ManifoldEval` is correctness measurement; both share `RunRecord`/`EventRecorder`/detectors.

> Open question for review: is a new module worth it vs. an `Eval/` sub-namespace inside `ManifoldFuzz`? The deciding factor is whether a consumer wants scoring without the fuzz dependency surface.

### Core API surface (v1)

```swift
// 1. Scoring primitives (pure, no MK deps)
public struct ConfusionCounts: Sendable, Equatable {
    public let truePositives, falsePositives, falseNegatives: Int
    public var precision: Double { /* ... */ }
    public var recall: Double { /* ... */ }
    public var f1: Double { /* ... */ }
}
public struct MacroAveragedMetrics: Sendable { /* mean of per-class P/R/F1 */ }

// 2. A scorer judges one run's output against an expectation.
public protocol EvalScorer: Sendable {
    associatedtype Expected: Sendable
    associatedtype Score: Sendable
    func score(output: EvalRunOutput, expected: Expected) async -> Score
}

// EvalRunOutput is a thin view over a captured RunRecord (visible text,
// thinking text, tool calls, stop reason, metrics) — no domain types.
public struct EvalRunOutput: Sendable { /* from RunRecord */ }

// 3. A fixture pairs an input with its expectation.
public struct EvalFixture<Expected: Sendable>: Sendable {
    public let id: String
    public let prompt: [Message]
    public let config: GenerationConfig
    public let expected: Expected
}

// 4. Backend-matrix runner: fixtures × backends, capture + score + aggregate.
public struct BackendConfig: Sendable {
    public let name: String
    public let make: @Sendable () async throws -> InferenceBackend
}
public struct EvalMatrixRunner {
    public func run<S: EvalScorer>(
        fixtures: [EvalFixture<S.Expected>],
        backends: [BackendConfig],
        scorer: S
    ) async -> EvalReport<S.Score>
}

// 5. Built-in hygiene scorers wrap existing detectors so every eval run also
//    reports loops / template-leaks / thinking-block breakage for free.
public struct HygieneScorer: EvalScorer { /* runs the ManifoldFuzz detector set */ }
```

### How the spine is reused

- `EvalMatrixRunner` drives each `BackendConfig` × fixture through `InferenceService`/`GenerationQueue`, captures with the existing `EventRecorder` → `RunRecord`.
- `EvalRunOutput` is a projection of `RunRecord` (no new capture path).
- `HygieneScorer` calls the existing `DetectorRegistry` over the `RunRecord`.
- Deterministic re-runs (regression mode) reuse `Replayer`.

### v1 vs later

**v1:** `ConfusionCounts`/`MacroAveragedMetrics`, `EvalScorer`/`EvalFixture`/`EvalRunOutput`, `HygieneScorer`, single-backend run + score.
**Later:** `EvalMatrixRunner` cross-product + aggregation, golden-dataset on-disk format, trend/history reporting, report formatter.

## What stays out (explicitly not extracted)

- Fireside's `GoldenStoryScorer`, `EvalReportFormatter`, extraction state machine, graph/compression usage — domain.
- Idlewick's opcode-switch metrics, mood-slope, replay scripts — domain.
- Fireside's telemetry status-string mappers — app-specific.
- Golden **datasets** themselves — app-domain, never shared.

## Migration / payoff

- Fireside: deletes its `ConfusionCounts` reimplementation + `BackendMatrixRunner` shell; keeps `GoldenStoryScorer` as a conforming `EvalScorer`.
- Idlewick: `NarrationEval` becomes a conforming `EvalScorer`; gets hygiene scoring + matrix runner for free.
- MK: gains its first correctness-eval surface; `ManifoldFuzz` unchanged.

## Open questions for adversarial review

1. **Companion vs in-package module vs fold-into-Fuzz** — is the dependency-weight argument for a separate module real, or is it premature modularity?
2. **Does this actually let Idlewick/Fireside delete code**, or does the domain coupling mean they keep everything and just conform a protocol (low payoff)?
3. **Is the `EvalScorer` protocol the right abstraction**, or should eval be data-first (JSON fixture + declarative assertions, à la promptfoo/OpenAI Evals) rather than code-first?
4. **Backend-matrix determinism** — cloud backends can't replay; how does the matrix runner handle non-deterministic cells (multi-sample + variance, or exclude)?
5. **Overlap with #1930** — should scoring consume metric spans, or stay on `RunRecord`?
6. **Is "eval" even MK's job?** — or should MK expose the seams (capture/replay/detectors) and let eval frameworks (promptfoo/Inspect/OpenAI Evals) integrate, rather than ship its own?

---

## Review verdict (2026-06-21)

Three reviewers, ground-truthed against the actual code in MK + both apps.

### 1. Architecture critic — "don't build at N=2"
- **Payoff ≈ 775 LOC cross-app, mostly a 71-LOC P/R/F1 struct.** Not worth a new module's permanent CI cold-compile floor + maintenance.
- **Two motivating facts in the draft are wrong:** Fireside's `BackendMatrixRunner` is in the *app target*, not the eval package; Idlewick scores a *live HTTP chronicle on game opcodes*, not an offline log via the proposed projection.
- **Reuse claim inflated:** `EventRecorder` is standalone, but every detector consumes `RunRecord` (23-param fuzz-shaped init — eval would fabricate stub `seed`/`corpusId`/`harness`); `Replayer` only works for `supportsDeterministicReplay` backends (useless for cloud eval).
- **Separate-module rationale weak:** `ManifoldFuzz` depends only on `ManifoldInference`; CLI/factories are separate targets. Only extra weight is a 60K bundle, which `ManifoldEval` links transitively anyway. If anything ships, fold into `ManifoldFuzz`, don't add a target.

### 2. Consumer-fit critic (Idlewick + Fireside maintainers) — "we'd refuse v1"
- **The protocol fits neither judge.** `GoldenStoryScorer.score(graphState:checkpoint:)` reads a live SwiftData graph (entities/facts/relationships) + `ModelContext`, never generation text — `EvalRunOutput` carries none of it. `NarrationEval.evaluate(events:)` reads a windowed multi-actor opcode log; 3 of its 4 checks (speech novelty, do-nothing rate, mood slope) are temporal/aggregate and uncomputable from one run. Both would be **fake conformances** that ignore `EvalRunOutput`.
- **Canned/replay claims wrong:** Fireside's `EvalCannedMode` substitutes recorded text into the *live extraction+graph-merge pipeline* (model out of loop, pipeline runs); Idlewick's `ReplayVerifier` is a model-free state-machine self-test. Neither is MK's finding-hash `Replayer`.
- **Deletion ledger:** Fireside ~71 LOC (~1.5%), Idlewick ~0. Both keep ~99% of their eval code.
- **Ordering backwards:** v1 ships the smallest shared footprint (scoring math) and defers the app-shaped, unsharable parts (matrix as v1 for Fireside; offline-log scoring for Idlewick; report formatting for both).
- **Ask:** ship `ConfusionCounts` + (maybe) a stream-outcome enum — but MK already exposes `GenerationCompletion.Reason`/`RunRecord.stopReason`, so even that may just need documenting.

### 3. Comparative-frameworks research — "if you ever build eval, here's what good looks like"
(Not a dedup justification — a *product* signal. Decoupled from #1993.)
- **Shared field architecture:** Dataset/Fixture → Task/Solver → **Scorer (per-sample `Score`: value/answer/explanation/metadata)** → **Metric (aggregate: accuracy/mean/stderr)** → Experiment/baseline. The draft collapses Scorer+Metric and omits the per-sample `Score` + the Experiment/baseline noun.
- **Variance is the settled answer, not exclusion:** eval of sampling backends = run-N + reduce (`epochs`/trials/**pass@k**). Deterministic *replay* is for local regression only. The draft's "punt cloud cells" is the wrong frame.
- **Two table-stakes scorers omitted:** **semantic similarity** (nearly free — MK already ships on-device `NLEmbeddingBackend` + cosine in `RAGService`; highest-value for these apps' prose output, unlike P/R/F1) and **LLM-as-judge** (`LLMRubricScorer`, defer to v1.x but define the shape).
- **Code-first core + data-first loader** (Inspect model): `Codable EvalFixture` + JSON/JSONL loader + built-in declarative scorers (exact/contains/json-schema), with domain `EvalScorer` for the 20%.
- **MK's genuinely-ownable differentiation** (no Python incumbent has these): deterministic **local-replay regression** ("did re-quantizing the GGUF move the score?"), **fully on-device eval** (scorer + similarity + local judge, no API key), **hygiene-as-a-scorer** (the 16 fuzz detectors as correctness signals), tool-call/grammar conformance scoring (with #1992).

### Reconciliation
The three are not in conflict: critics answer **"should we build this dedup play now?"** (no), the researcher answers **"what would a good eval product look like?"** (decoupled, future, product-justified). The dedup rationale in #1993 is dead. The on-device-eval *product* idea is alive but belongs in its own issue, gated on product intent, not on deduping two apps that share no eval shape.

### Decided action
1. Ship `ConfusionCounts` (+ macro-averaging) as a pure util in an existing target (`ManifoldInference` or `ManifoldFuzz`); Fireside deletes its copy.
2. Document the existing seams as the "eval primitives" answer: `GenerationCompletion.Reason`, `RunRecord`, `EventRecorder`, the detector set, `Replayer` (fuzz-regression only).
3. Re-scope #1993 to (1)+(2); do not build a module or companion.
4. If MK wants an eval *product*, open a fresh issue framed on the on-device differentiation + Inspect-style architecture above — not on dedup.
