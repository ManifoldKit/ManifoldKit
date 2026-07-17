# Lifecycle Signals

Observe generation and model-load lifecycle the same way ManifoldKit does
internally, instead of re-deriving phase from raw events.

## Overview

Two lifecycles matter to a host app: **a generation turn** (queued through
streaming through done/failed) and **a model load** (idle through loading
through loaded/failed). Each has exactly one canonical signal:

| Lifecycle | Canonical signal | Owner |
|---|---|---|
| Generation turn | ``GenerationStream/phase`` | one instance per in-flight request (`ManifoldContract`) |
| Model load | `ModelLoadStatus` via ``ModelLoadCoordinator/statusUpdates()`` | one multi-observer stream per `InferenceService` (`ManifoldInference`) |

This mirrors the ownership decision recorded in
[`docs/API-DESIGN.md` § 2](https://github.com/ManifoldKit/ManifoldKit/blob/main/docs/API-DESIGN.md#2-layer-ownership-map):
generation lifecycle is stream-scoped, load lifecycle is coordinator-scoped.
Two older signals — `BackendActivityPhase` and `ModelLoadReadinessState` — are
**legacy**, described at the bottom of this article; new code should not add
consumers of either.

## Generation lifecycle: `GenerationStream.phase`

``GenerationStream`` wraps every generation's event stream with an
`@Observable`, `@MainActor` `phase` property so a view can show a connecting /
loading / streaming / stalled / retrying indicator without polling raw
``GenerationEvent``s or reimplementing a state machine over them:

```swift,no-build
import ManifoldInference

let (_, stream) = try inferenceService.enqueue(messages: history, config: config)

// `stream.phase` is `@Observable` — read it directly in SwiftUI body code,
// or poll it from a non-UI observer.
switch stream.phase {
case .queued:      showQueuedIndicator()
case .connecting:  showConnectingIndicator()
case .loading:     showColdStartIndicator()      // e.g. Ollama pulling a model
case .streaming:   showTypingIndicator()
case .stalled:     showStalledWarning()
case .retrying(let attempt, let of): showRetrying(attempt, of)
case .done:        hideIndicator()
case .failed(let message): showError(message)
}

for try await event in stream {
    // Content still arrives on `events` / the `AsyncSequence` conformance —
    // `phase` is lifecycle-only and never gates iteration.
    if case .token(let chunk) = event { responseText += chunk }
}
```

`phase` is genuinely live on the real generation path, not a decorative
field nobody writes to:

- `GenerationQueue` drives `.queued` → `.connecting` → `.streaming` →
  `.done`/`.failed` for every request
  (`Sources/ManifoldInference/Services/GenerationQueue.swift:859,1009,1070,1077,1184-1185`).
- The idle-timeout monitor built into ``GenerationStream`` itself drives
  `.stalled` when no event arrives within half the configured timeout
  (`Sources/ManifoldContract/GenerationStream.swift`, `withIdleTimeout`).
- The cloud SSE runner holds `.loading` from connect until the first real
  token — `.streaming` would be a lie during that gap — and drives
  `.retrying(attempt:of:)` on reconnect
  (`Sources/ManifoldCloudCore/SSEGenerationTaskRunner.swift:78,186`).
- Ollama's cold-start model pull surfaces through the same `.loading` phase
  (`Sources/ManifoldOllama/OllamaBackend.swift:760-769`).

What was missing (tracked as #2128's `.phase` item) was an in-repo
**consumer** — nothing in `ManifoldUI` read `stream.phase`; the shipped chat
surface renders a separately hand-maintained state machine instead (see
"Legacy signals" below). That is a documentation and adoption gap, not a dead
write path — treat `GenerationStream.phase` as the one to build against.

## Model-load lifecycle: `ModelLoadStatus`

`ModelLoadCoordinator` is the single load state machine every consumer of an
`InferenceService` shares — the origin app's `ChatViewModel` and any headless
model-selection surface both watch the same load without clobbering each
other's callbacks. `statusUpdates()` is the fan-out seam:

```swift,no-build
import ManifoldInference

let coordinator = inferenceService.modelLoadCoordinator

Task {
    for await status in coordinator.statusUpdates() {
        switch status {
        case .idle:
            hideLoadIndicator()
        case .loading(let progress):
            showLoadProgress(progress)   // `progress` is nil for backends that never report a fraction
        case .loaded:
            hideLoadIndicator()
        case .failed(let reason):
            showLoadError(reason)
        }
    }
}
```

`ModelLoadCoordinator` is already reachable from the public bootstrap
surface with no additional wiring:

```swift,no-build
import ManifoldKit

let bootstrap = /* from ManifoldBootstrap.build(...) */
for await status in bootstrap.inferenceService.modelLoadCoordinator.statusUpdates() {
    // same ModelLoadStatus stream a headless consumer would use.
}
```

`ChatViewModel.modelLoadState` is a convenience `@Observable` projection of
the same underlying state for SwiftUI call sites that only need the latest
value rather than a stream; it is not a second lifecycle, just a
single-observer read of the coordinator's status.

## Legacy signals (slated for demotion after app migration)

Two older signals overlap the pair above. They are not removed by this
article — only documented as the losers, per the v1-rationalisation plan's
"one lifecycle signal" decision (B.4): the origin app must migrate onto the
canonical signals first (plan B.0), and only then do these demote.

- **`BackendActivityPhase`** (`Sources/ManifoldInference/Models/BackendActivityPhase.swift`)
  — a hand-maintained `idle`/`modelLoading`/`waitingForFirstToken`/`streaming`/
  `stalled`/`retrying` enum driven through `ActivityPhaseStateMachine` and
  rendered directly by the origin app's input bar. It duplicates most of what
  `GenerationStream.phase` already reports.
- **`ModelLoadReadinessState`** (`Sources/ManifoldInference/Services/InferenceService.swift`)
  — an older `idle`/`loading(progress:)`/`ready` polling enum, still used
  internally by `InferenceService.waitUntilModelReady(...)` to block turn
  start until a model is ready. It predates `ModelLoadStatus` and does not
  carry a failure reason.

Do not add new consumers of either. New UI or headless surfaces should read
`GenerationStream.phase` and `ModelLoadStatus` instead.
