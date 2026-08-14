# ManifoldAppEval Adoption Walkthrough

**Audience:** consumer
**Status:** living

A one-page guide to adding golden-scenario regression coverage to an app
built on ManifoldKit, via `ManifoldAppEval`. Two entry points are covered:
**(a)** an app that already has a test target and CI, and **(b)** a true
greenfield app with neither.

> **What this buys you.** For a stock-composed app, day-one goldens catch a
> ManifoldKit version bump silently changing turn-loop behavior your
> composition root depends on — send/receive, tool round trips, cancellation,
> compression. It does **not** by itself prove your app's own domain logic is
> correct; plug that in via `CheckpointScorer` (see step 4).

---

## 0. Add the dependency

```swift
.package(url: "https://github.com/ManifoldKit/ManifoldKit.git", from: "0.76.0"), // x-release-please-version
```

```swift
.testTarget(
    name: "AppEvalTests",
    dependencies: [
        "ManifoldAppEval",
        "ManifoldInference",
        "ManifoldRuntime",
    ]
)
```

`ManifoldAppEval` is deliberately **not** re-exported by the `ManifoldKit`
umbrella — import it explicitly, and only from a test target or a dedicated
eval executable (see the module's DocC page for why).

---

## 1. Write a golden fixture

A fixture is a turn sequence plus checkpoints. Author it as JSON — no Swift
required for the common cases:

```json
{
  "id": "send-receive-smoke",
  "turns": [
    { "kind": "send", "text": "Hello, world.", "cannedResponse": "Hello! How can I help?" }
  ],
  "checkpoints": [
    {
      "afterTurnIndex": 0,
      "label": "greets back",
      "requiredContent": ["Hello"],
      "expectedEvents": ["streamStarted", "tokenEmitted", "streamFinished"]
    }
  ]
}
```

`cannedResponse` is what the deterministic lane's scripted backend replays —
your fixture never talks to a real model, so it is exact and hermetic.

---

## 2. Load and run it

```swift
import XCTest
import ManifoldAppEval

final class AppEvalTests: XCTestCase {
    func test_sendReceiveSmoke() async throws {
        let url = Bundle.module.url(forResource: "send-receive-smoke", withExtension: "json")!
        let fixture = try GoldenTaskLoader.load(from: url)

        let outcome = try await GoldenTaskRunner.run(fixture)

        for result in outcome.checkpointResults {
            for (assertion, score) in result.scores {
                if case .bool(false) = score.value {
                    XCTFail("\(result.checkpoint.displayLabel) failed \(assertion): \(score.explanation ?? "")")
                }
            }
        }
    }
}
```

Bundle your fixtures as a `.copy` resource on the test target so
`Bundle.module` resolves them regardless of the process's working directory —
the same pattern `ManifoldTools.ScenarioLoader` uses for its built-in corpus.

---

## 3. Cover the common turn shapes

Three starting scenarios, ready to run without writing any fixture JSON at
all — good smoke coverage before you write your own:

```swift
import ManifoldAppEval

for scenario in AppEvalStarterCorpus.all {
    let result = try await RuntimeScenarioRunner.run(scenario)
    try result.checkPassed() // throws a descriptive error if the subsequence fails
}
```

`AppEvalStarterCorpus.all` covers: a send/receive smoke test, a tool
round-trip, and a mid-stream cancellation. Each is a `RuntimeScenario` you can
also copy and adapt directly in Swift when a fixture's declarative shape
isn't expressive enough — see the escape hatch below.

---

## 3b. Matching options for `requiredContent`/`forbiddenContent` (optional)

The built-in content-presence scorers default to **cumulative transcript,
case-sensitive** matching — every assistant message produced up to and
including the checkpoint's turn, exact case. That default never changes.

Apps whose own checkpoint semantics differ (e.g. a scene-scoped chat surface
that only cares about the current turn, and wants case-insensitive matching)
can call the built-in scorers directly with `ContentMatchOptions` instead of
forking them — from a custom `CheckpointScorer`, or from any code that holds a
`CheckpointEvaluationContext`:

```swift
import ManifoldAppEval

let score = BuiltInCheckpointScorers.scoreRequiredContent(
    context,
    options: .init(caseInsensitive: true, scope: .latestTurn)
)
```

- `caseInsensitive: Bool` (default `false`) — case-insensitive substring
  matching instead of exact case.
- `scope: ContentMatchOptions.Scope` (default `.cumulative`) — `.latestTurn`
  restricts matching to `CheckpointEvaluationContext/latestTurnVisibleText`,
  the assistant text from the checkpoint's own turn only (everything after
  the most recent user message), instead of the full cumulative transcript.

`GoldenTaskRunner`'s own built-in scoring always uses the defaults — these
options are an opt-in seam for scorers you register yourself, not a per-checkpoint
schema field.

---

## 4. Plug in your own domain scorer (optional)

For state your app owns that the trace can't see (a SwiftData-backed
executor's extracted state, a vector store's document count, …), conform to
``ScenarioStateProbe`` and ``CheckpointScorer``:

```swift
import ManifoldAppEval

struct MyAppProbe: ScenarioStateProbe {
    func snapshot(after checkpoint: GoldenCheckpoint, runResult: RuntimeScenarioRunner.Result) async -> (any Sendable)? {
        await myExtractionPipeline.awaitSettled()
        return await myExtractionPipeline.currentGraphSnapshot()
    }
}

struct MyGraphScorer: CheckpointScorer {
    let id = "my-graph-scorer"
    func score(_ context: CheckpointEvaluationContext) async -> EvalScore {
        guard let graph = context.snapshot as? MyGraphSnapshot else {
            return EvalScore(value: .unavailable, explanation: "no graph snapshot available")
        }
        // ... your domain assertion, returning EvalScore(value: .bool(...)) ...
    }
}

let outcome = try await GoldenTaskRunner.run(
    fixture,
    probe: MyAppProbe(),
    customScorers: [MyGraphScorer()]
)
```

A checkpoint routes to `MyGraphScorer` by declaring
`"custom": { "my-graph-scorer": { ...opaque JSON... } }`.

---

## 4b. Judge-scored assertions (last resort, not first choice)

For a genuinely fuzzy assertion no combination of the built-ins or a
deterministic `CheckpointScorer` can express — "is this extraction as good as
the reference", not "does this substring appear" — route a checkpoint through
a registered `EvalJudge` via `JudgedCheckpointScorer`:

```swift
import ManifoldAppEval

struct MyJudge: EvalJudge {
    func judge(_ request: JudgeRequest) async throws -> JudgeVerdict {
        // Call out to whatever grades this (a subprocess, an HTTP endpoint —
        // ManifoldAppEval has no opinion; see fireside's ClaudeCodeJudge for
        // the reference conformer this seam was generalized from).
    }
}

let cachedJudge = CachingJudge(
    underlying: MyJudge(),
    directory: myAppSupportDirectory.appendingPathComponent("judge-cache")
)

let outcome = try await GoldenTaskRunner.run(
    fixture,
    customScorers: [
        JudgedCheckpointScorer(id: "judge:extraction-quality", judge: cachedJudge)
    ]
)
```

A checkpoint routes to it by declaring
`"custom": { "judge:extraction-quality": { "candidate": "...", "reference": "...", "rubric": "...", "minScore": 0.7 } }`.

**`minScore` is required** — it is the pass bar the judge's continuous score
is reduced against (`score >= minScore` → pass). Without it a judge score
would be verdict-inert: the aggregate verdict only fails on boolean failures,
so a `0.0` judge score with no bar would still exit `0`. A payload that omits
`minScore` scores a *failing* checkpoint (with a validation explanation) until
you declare one — a judge assertion with no pass bar must never be able to
pass.

No judge wired in yet (`judge: nil`), or a judge call that throws, both score
`.unavailable` — never a fabricated pass or a `0.0` — so a fixture can declare
a judge-scored checkpoint before the app has a real conformer without
poisoning the aggregate verdict.

`CachingJudge` content-addresses responses by a SHA-256 of the request's
*content* fields (content/candidate/reference/rubric — the diagnostic `id` is
excluded, so renaming a fixture or checkpoint never re-bills identical
judgments), so re-running the same fixture (CI re-run, local iteration) never
re-invokes the judge for a request it's already graded. That claim holds only
*within one keying scheme*: if you're migrating from a bespoke judge cache
(e.g. one keyed on `sha256(prompt)`, as fireside's original `ClaudeCodeJudge`
cache was), the existing entries won't match `CachingJudge`'s keys — expect a
one-time cold cache and a full re-bill on the first post-migration run.

---

## 5. Beyond the schema: assert on the trace directly

The JSON schema covers the portable 80%. For anything else — a very specific
event ordering, a payload shape the built-ins don't cover — assert directly
on the trace in Swift:

```swift
let result = try await RuntimeScenarioRunner.run(myScenario)
XCTAssertEventSubsequence(result.trace.events, contains: [.contextAssembled, .historyCompressed])
// or read result.trace.events / result.producedMessages directly for anything bespoke.
```

`RuntimeScenarioRunner.Result.trace` is documented, first-class public API —
not a private implementation detail you're reaching around.

---

## Entry point (a): app with an existing test target and CI

If you already have an XCTest target and a `ci.yml`, steps 0–4 above are the
whole adoption: add the dependency, add fixtures + tests, add a Markdown
report/ledger step to CI if you want the trend history:

```yaml
      - name: App-eval deterministic lane
        run: swift test --filter AppEvalTests
```

No new CI infrastructure needed — it's a normal, hermetic `swift test`
target: no model download, no network, no disk beyond the ledger file.

---

## Entry point (b): true greenfield — no test target, no CI yet

Starting from an app with zero test infrastructure:

### b.1 Add a test target via XcodeGen

```yaml
# project.yml
targets:
  MyApp:
    # ... existing app target ...
  AppEvalTests:
    type: bundle.unit-test
    platform: iOS
    sources: [AppEvalTests]
    dependencies:
      - target: MyApp
    settings:
      base:
        SWIFT_VERSION: 6.0
```

Then `xcodegen generate` and add the `ManifoldAppEval` package dependency in
Xcode (or in `project.yml`'s `packages:` section, referencing it from the
target).

### b.2 Minimal `ci.yml` for the deterministic lane

```yaml
name: ci
on: [pull_request, push]
jobs:
  app-eval:
    runs-on: macos-15
    steps:
      - uses: actions/checkout@v4
      - uses: maxim-lobanov/setup-xcode@v1
        with:
          xcode-version: latest-stable
      - name: Run deterministic app-eval lane
        run: |
          xcodebuild test \
            -project MyApp.xcodeproj \
            -scheme AppEvalTests \
            -destination 'platform=iOS Simulator,name=iPhone 16'
```

This is green in hosted CI by construction: the deterministic lane never
downloads a model, never hits a network, and never touches the real
filesystem beyond the fixtures you bundled and (optionally) an appended
`history.jsonl` ledger line.

### b.3 Grow from there

Start with the starter corpus (step 3) plus one or two fixtures for your
app's most load-bearing flows. Add `AppEvalOutcome` + `AppEvalMarkdownRenderer`
+ `AppEvalHistoryLedger` once you want a rendered report and a trend history
across runs — neither is required for the gate itself, which is just
"every checkpoint scored true or unavailable."

---

## Reference

- `GoldenTaskFixture` / `GoldenTurn` / `GoldenCheckpoint` — the JSON schema (`Sources/ManifoldAppEval/Schema/`)
- `GoldenTaskRunner` — drives fixtures and scores checkpoints (`Sources/ManifoldAppEval/Scoring/`)
- `AppEvalOutcome` / `AppEvalMarkdownRenderer` / `AppEvalHistoryLedger` — reporting (`Sources/ManifoldAppEval/Report/`)
- `EvalJudge` / `JudgeRequest` / `JudgeVerdict` / `CachingJudge` / `JudgedCheckpointScorer` — the judge seam, last resort for genuinely fuzzy assertions (`Sources/ManifoldAppEval/Judge/`)
- The module's DocC page — the ManifoldAppEval vs. manifold-eval boundary, the honest pitch, and the machine-checkable-first policy in full.
