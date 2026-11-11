# App-eval runtime candidates and required evidence

**Audience:** consumer
**Status:** living

Judged checkpoints now grade executed output or app state. The old
`JudgedCheckpointScorer(id:judge:)` initializer is removed; supply an explicit
runtime extractor. Remove `candidate` from fixture custom payloads. Fixtures
retain `rubric`, a required finite `minScore` in 0...1, and optional `reference`
and grounding `content`. Legacy fixture candidates are rejected rather than
silently reused.

```swift
import ManifoldAppEval

func outputJudgeScorer(judge: any EvalJudge) -> JudgedCheckpointScorer {
    JudgedCheckpointScorer(id: "judge:quality", judge: judge) { context in
        context.latestTurnVisibleText
    }
}
```

For app state, cast `context.snapshot` to your own Sendable snapshot type,
serialize the observed value, and throw if the snapshot is missing or extraction
fails. Never return a fixture candidate or an empty substitute for missing
state. An actually observed empty output is valid input to a judge, which can
measure its quality. `EvalJudge`, `JudgeRequest` and `CachingJudge` remain
available for explicit offline grading of caller-supplied data. Runtime
candidate changes produce different content-addressed cache keys.

`AppEvalVerdict` adds `indeterminate`, with exit code **3**. Update exhaustive
switches and CLI documentation. A required unavailable score, unassessed raw
number, empty run, empty fixture or empty required checkpoint cannot return
PASS. A measured `.bool(false)` still wins over incomplete evidence and errors;
otherwise run errors win over indeterminate evidence. Invalid thresholds,
invalid judge scores, missing snapshots and judge failures are unavailable
evidence rather than measured assertion failures.

Numeric gate measurements need an explicit app-owned threshold reduction to
`.bool`, retaining the measured rate and threshold in metadata. There is no
universal numeric pass threshold. Informational measurements need an explicit
report policy:

```swift
import ManifoldAppEval
import ManifoldInference

let checkpoint = CheckpointOutcome(
    label: "response", afterTurnIndex: 0,
    scores: [
        "valid": EvalScore(value: .bool(true)),
        "latency-ms": EvalScore(value: .number(120)),
    ],
    informationalScoreIDs: ["latency-ms"]
)
let fixture = FixtureOutcome(fixtureID: "response", checkpoints: [checkpoint])
let outcome = AppEvalOutcome(fixtures: [fixture])
assert(outcome.verdict == .pass)
```

Use `FixtureOutcome(..., isInformational: true)` for an entirely diagnostic
fixture, such as deliberately malformed per-turn classifier samples. Its own
measured verdict remains visible; it does not drive the overall gate. A run
containing only informational fixtures or only optional measurements remains
indeterminate. `GoldenTaskRunner` treats every declared assertion as required.

The Markdown report labels informational measurements and fixtures explicitly.
The history ledger writes **schema version 2**, including fixture
`isInformational` and optional `indeterminateCheckpointLabels`. It still reads
version-1 rows, which retain their original verdict; historical PASS rows do not
retroactively establish complete evidence under the new policy.

Known consumers must adopt the same core revision before publication. Idlewick's
assessed PASS/WARN rates remain below its existing hard-failure bar, with rate
and status retained in metadata; schema/F1 and inapplicable mood/repetition
observations are explicitly informational. Insufficient required samples now
exit 3. Fireside's canned lane reports declared graph and scene-plan assertions
as incomplete while their evidence is unavailable.

Scorers that need ordered user and assistant messages can read
`CheckpointEvaluationContext.producedMessages`, populated from the executed
runtime store. `nil` distinguishes a missing transcript from an observed empty
array. `systemPrompt` carries the executed scenario's configured prompt.
Fireside checks required text against the configured prompt and executed
transcript, and forbidden text against the current assistant scene. Injected
context slots are outside this check. Expected substrings remain in fixture
payloads.
