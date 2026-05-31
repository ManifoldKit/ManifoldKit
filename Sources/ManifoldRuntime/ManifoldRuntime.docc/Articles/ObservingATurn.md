# Observing a Turn

Subscribe to the live event flow from a `ConversationRuntime` without competing with the primary consumer.

## When to use

Every ``ConversationRuntime`` exposes a primary ``ConversationRuntime/events`` stream that delivers the full ``ConversationEvent`` sequence for every turn. That stream is **single-consumer by design** — when two tasks iterate it concurrently, only one sees each event. Common adapters such as `ChatViewModel` own the primary stream and drain it continuously on a long-lived task.

Use ``ConversationRuntime/addEventTap(bufferingPolicy:)`` when you need a **second independent view** of the same event flow:

- Diagnostic tooling or loggers that must not interfere with the primary adapter.
- Test assertions that observe the live event sequence alongside a UI adapter.
- Analytics or telemetry sinks that need every token delta without risk of starving the main consumer.
- Concurrent feature code (e.g. a summarisation sidekick) that watches the turn stream without owning it.

For single-consumer flows where `events` is not already taken — bare scripts, lightweight CLIs, one-off utilities — iterating `events` directly is simpler.

## Installing a tap

`addEventTap` returns an `AsyncStream<ConversationEvent>` that begins delivering events immediately. Install it before driving the turn you want to observe, then drain it on a `Task`:

```swift,no-build
import ManifoldRuntime

let tap = runtime.addEventTap()

Task {
    for await event in tap {
        switch event {
        case let .tokenEmitted(_, delta):
            print("delta:", delta)
        case let .streamFinished(_, reason):
            print("finished:", reason)
            break
        default:
            break
        }
    }
}

try await runtime.processTurn(input)
```

The tap stream finishes normally when the runtime terminates. You do not need to explicitly remove it — when the iterating `Task` is cancelled or goes out of scope the stream's `onTermination` handler automatically deregisters the tap from the registry.

## Using ConversationEventRecorder

For the common testing pattern of "capture everything, then assert", ``ConversationEventRecorder`` wraps a tap and accumulates the full event array:

```swift,no-build
import ManifoldRuntime

let recorder = ConversationEventRecorder()
let drainTask = await recorder.start(on: runtime)

let turn = try await runtime.processTurnWithOutcome(input)
await turn?.outcome          // wait for turn to complete

drainTask.cancel()
await drainTask.value        // let recorder observe the final streamFinished

let trace = await recorder.trace
let tokens = trace.compactMap { event -> String? in
    guard case let .tokenEmitted(_, delta) = event else { return nil }
    return delta
}.joined()
print(tokens)
```

`ConversationEventRecorder` is an `actor`, so `trace` is safe to read from any isolation context.

## Saving a trace for debugging

After draining a ``ConversationEventRecorder``, wrap the raw event array in a
``ConversationEventTrace`` and call ``ConversationEventTrace/save(to:)`` to
persist the turn as a JSONL file. Each line is a JSON object with three fields:
`index` (0-based position), `kind` (the ``ConversationEventKind`` raw value),
and `summary` (a human-readable one-liner derived from the event's associated
values — the token delta for `.tokenEmitted`, the finish reason for
`.streamFinished`, the slot count for `.contextAssembled`, and so on).

```swift,no-build
import ManifoldRuntime

let recorder = ConversationEventRecorder()
let drainTask = await recorder.start(on: runtime)

let turn = try await runtime.processTurnWithOutcome(input)
await turn?.outcome
drainTask.cancel()
await drainTask.value

let trace = await ConversationEventTrace(recorder: recorder)

// Inspect kinds inline
print(trace.kinds) // [.contextAssembled, .streamStarted, .tokenEmitted, ...]

// Save to disk for golden-trace comparison (P3) or offline debugging
let url = URL(fileURLWithPath: "/tmp/turn.jsonl")
try trace.save(to: url)
```

The JSONL format is intentionally minimal so it remains readable in any text
editor and diff-friendly in version control. A future P3 pass will add a
structured read path for golden-trace regression testing.

## Backpressure tradeoff

The default buffering policy for taps is `.unbounded`, which means events accumulate in memory if the consumer lags. This eliminates any risk of the tap consumer blocking the turn loop or missing events during a burst.

Pass a bounded policy when you need explicit backpressure semantics — for example, a tap consumer that writes to disk and must cap memory usage:

```swift,no-build
let tap = runtime.addEventTap(bufferingPolicy: .bufferingNewest(200))
```

Bounded taps drop events when the consumer falls behind. The primary ``ConversationRuntime/events`` stream uses `.bufferingOldest(500)` — a different policy — so a slow bounded tap does not affect it.

## Running scenarios

``RuntimeScenarioRunner`` lets you drive a complete multi-turn conversation against a scripted or real backend in a single call, with the recorded trace returned for inspection.

In `.scripted` mode the runner wires up a ``ScriptedGenerationBackend`` from the scenario's embedded turn script, records the full ``ConversationEvent`` trace, and checks the structural subsequence automatically:

```swift,no-build
import ManifoldTestSupport

let result = try await RuntimeScenarioRunner.run(.basicTokenStream)
RuntimeScenarioRunner.assert(result: result)  // calls XCTFail if subsequence fails
```

All built-in scenarios are collected in ``RuntimeScenarioRegistry/all``. Iterate it in a test matrix to cover every registered scenario in one loop:

```swift,no-build
for scenario in RuntimeScenarioRegistry.all {
    let result = try await RuntimeScenarioRunner.run(scenario)
    RuntimeScenarioRunner.assert(result: result)
}
```

For live-backend runs, pass `.live(backend:)` — the runner uses the same structural assertions but does not check token content:

```swift,no-build
let result = try await RuntimeScenarioRunner.run(
    .basicTokenStream,
    mode: .live(backend: myRealBackend)
)
RuntimeScenarioRunner.assert(result: result)
```

## Re-entrancy rule (yield-outside-lock)

If you implement a custom continuation-based observer, be aware of the **yield-outside-lock invariant** that ``EventTapRegistry`` maintains:

The registry's `broadcast` method snapshots registered continuations under a `Mutex` lock, releases the lock, and only then calls `yield` on each continuation. This ordering is required because `AsyncStream.Continuation.onTermination` fires synchronously on the thread that detects cancellation, which calls back into the registry to deregister. Calling `yield` while the lock is held would cause a re-entrant deadlock in that path.

Custom wrappers that layer additional synchronisation around a tap continuation must respect the same contract: never call `yield` or `finish` while holding a lock that the `onTermination` handler also tries to acquire.
