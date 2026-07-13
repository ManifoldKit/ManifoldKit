# ``ManifoldAppEval``

A golden-scenario eval harness for apps built on ManifoldKit.

## Overview

`ManifoldAppEval` lets a host app write declarative "golden" fixtures — a
turn sequence plus checkpoints — and run them deterministically against a
scripted backend and in-memory stores, with no model, no network, and no
disk. It exists because the alternative (every app hand-rolling its own
scenario runner against `ConversationRuntime`) is exactly what fireside and
idlewick had already done before this module existed — the prior-art survey
that motivated generalizing the *harness spine*, never the *domain
vocabulary*, into core was `docs/plans/1993-eval-surface.md` in the
ManifoldKit repo (removed in a 2026-07 docs/plans hygiene pass; see git
history).

### The boundary: apps grading themselves, not MK grading itself

**`ManifoldAppEval` evaluates apps built on ManifoldKit. It is not
`manifold-eval`, which independently assures ManifoldKit itself.** Neither
replaces the other:

- `manifold-eval` (a separate repo) is the *outside grader* — it holds MK to
  account against benchmarks and regressions MK cannot self-certify.
- `ManifoldAppEval` (this module) ships *inside* the SDK so an app can hold
  *itself* to account: does my composition root still send/receive, still
  round-trip a tool call, still compress history correctly, after I bumped my
  ManifoldKit pin?

### The honest pitch

For a stock-composed app (default `ConversationRuntime`, default backends,
no custom domain logic), day-one goldens buy **upgrade-safety regression
coverage of the composition root** — proof that a ManifoldKit version bump
didn't silently change turn-loop behavior your app depends on. They do **not**
buy confidence in your app's own domain behavior (that's what your domain
scorers, plugged in via ``CheckpointScorer``, are for). Most apps' bug
history is dominated by exactly the former (a dependency bump changing
behavior underneath them), which is why the honest pitch is still a real one.

### Machine-checkable first, judge only for genuinely fuzzy assertions

Every built-in assertion (`requiredContent`, `forbiddenContent`,
`expectedEvents`, `expectedToolCalls`, `expectedCompression`,
`expectedContextSlots`) is exact and deterministic — string containment,
event-kind subsequence matching, payload counts. Prefer a machine-checkable
assertion over a fuzzy one every time one is expressible; reach for
``CheckpointScorer`` and a real domain scorer before considering a judge, and
reach for ``EvalJudge`` (via ``JudgedCheckpointScorer``) only when neither can
express the assertion — e.g. grading whether an extraction is "as good as" a
structurally-different-but-semantically-equivalent reference.

**Wave 2a (this module) ships the judge *seam*** — ``EvalJudge``,
``JudgeRequest``/``JudgeVerdict``, the content-addressed ``CachingJudge``
decorator, and the ``JudgedCheckpointScorer`` adapter — generalized out of
fireside's `ClaudeCodeJudge` (subprocess `claude -p`, prompt template,
JSON-envelope parsing, SHA-256 response cache). **It ships with no production
conformer in this repo.** First production conformer: fireside's
`ClaudeCodeJudge` reworked to conform to ``EvalJudge`` (fireside PR #901,
drafted against this branch); both PRs ready only after the next MK release —
protocol and conformer land in the same release train. Until then, the seam
is proven end-to-end in this repo's own tests via a fake conformer — a real
app wires a real judge in exactly the same shape.

A judged checkpoint's `custom` payload must declare a **`minScore` pass bar**;
``JudgedCheckpointScorer`` reduces the judge's continuous score to
pass/fail against it, so a judge score always carries verdict weight (a bare
`.number` is invisible to ``AppEvalVerdict/aggregate(_:)`` — see that
method's invariant note).

### Import discipline

Import `ManifoldAppEval` from **test targets or dedicated eval executables
only** — never from a shipped app target. It is not re-exported by the
`ManifoldKit` umbrella (the same policy as `ManifoldTools`, `ManifoldFuzz`,
and `ManifoldTelemetryOTLP`): an eval harness has no business linked into a
production binary.

### The escape hatch: `trace.events` is public API

The JSON fixture schema (``GoldenTaskFixture``) covers the portable 80% —
content containment, event-kind ordering, tool-call arguments, compression
and context-slot payloads. For anything beyond that,
``RuntimeScenarioRunner/Result/trace`` is documented, first-class public API:
assert on `result.trace.events` directly in Swift. The schema is not a wall —
it is the common path, not the only path.

## Experimental tier

`ManifoldAppEval` is in ManifoldKit's **experimental tier** (declared
2026-07-13) — it may break in any minor release, always migration-noted,
until it graduates. Graduation requires a real adopter: a shipping app or
companion that pins ManifoldKit and imports this module from non-test code.
Documentation and examples don't count as adoption. See
[docs/API-DESIGN.md § 7b](https://github.com/ManifoldKit/ManifoldKit/blob/main/docs/API-DESIGN.md)
for the full policy.

## Topics

### Runner

- ``RuntimeScenario``
- ``RuntimeScenarioRunner``
- ``ScriptedGenerationBackend``
- ``AppEvalStarterCorpus``
- ``EventSubsequenceChecker``
- ``FixedCountPreTurnCompressionPolicy``
- ``ContextWindowPreTurnCompressionPolicy``

### Schema

- ``GoldenTaskFixture``
- ``GoldenTurn``
- ``GoldenCheckpoint``
- ``GoldenTaskLoader``
- ``GoldenTaskMapper``

### Scoring

- ``ScenarioStateProbe``
- ``CheckpointScorer``
- ``CheckpointEvaluationContext``
- ``BuiltInCheckpointScorers``
- ``GoldenTaskRunner``

### Judge

- ``EvalJudge``
- ``JudgeRequest``
- ``JudgeVerdict``
- ``CachingJudge``
- ``JudgeCacheKey``
- ``JudgedCheckpointScorer``

### Report

- ``AppEvalOutcome``
- ``AppEvalVerdict``
- ``AppEvalMarkdownRenderer``
- ``AppEvalHistoryLedger``
