# ``ManifoldAppEval``

A golden-scenario eval harness for apps built on ManifoldKit.

## Overview

`ManifoldAppEval` lets a host app write declarative "golden" fixtures — a
turn sequence plus checkpoints — and run them deterministically against a
scripted backend and in-memory stores, with no model, no network, and no
disk. It exists because the alternative (every app hand-rolling its own
scenario runner against `ConversationRuntime`) is exactly what fireside and
idlewick had already done before this module existed — see
`docs/plans/1993-eval-surface.md` in the ManifoldKit repo for the prior-art
survey that motivated generalizing the *harness spine*, never the *domain
vocabulary*, into core.

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

### Machine-checkable first, judge later

Every built-in assertion (`requiredContent`, `forbiddenContent`,
`expectedEvents`, `expectedToolCalls`, `expectedCompression`,
`expectedContextSlots`) is exact and deterministic — string containment,
event-kind subsequence matching, payload counts. There is **no LLM-judge
seam in wave 1**: a judge protocol only ships once a real conformer exists to
prove it against (see the module's design doc, wave 2). Prefer a
machine-checkable assertion over a fuzzy one every time one is expressible;
reach for ``CheckpointScorer`` and a real domain scorer only when it isn't.

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

### Report

- ``AppEvalOutcome``
- ``AppEvalVerdict``
- ``AppEvalMarkdownRenderer``
- ``AppEvalHistoryLedger``
