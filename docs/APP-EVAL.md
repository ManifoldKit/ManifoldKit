# ManifoldAppEval Adoption Walkthrough

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
.package(url: "https://github.com/ManifoldKit/ManifoldKit.git", from: "0.65.0"),
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
    func score(_ context: CheckpointEvaluationContext) async -> Score {
        guard let graph = context.snapshot as? MyGraphSnapshot else {
            return Score(value: .unavailable, explanation: "no graph snapshot available")
        }
        // ... your domain assertion, returning Score(value: .bool(...)) ...
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
        JudgedCheckpointScorer(id: "judge:extraction-quality", fixtureID: fixture.id, judge: cachedJudge)
    ]
)
```

A checkpoint routes to it by declaring
`"custom": { "judge:extraction-quality": { "candidate": "...", "reference": "...", "rubric": "..." } }`.
No judge wired in yet (`judge: nil`), or a judge call that throws, both score
`.unavailable` — never a fabricated pass or a `0.0` — so a fixture can declare
a judge-scored checkpoint before the app has a real conformer without
poisoning the aggregate verdict.

`CachingJudge` content-addresses responses by a SHA-256 of the request's
canonical serialization, so re-running the same fixture (CI re-run, local
iteration) never re-invokes the judge for a request it's already graded.

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
