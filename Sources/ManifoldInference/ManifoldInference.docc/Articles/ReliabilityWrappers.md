# Reliability Wrappers

Compose backends for cross-provider failover and configure per-backend retry, without writing a state machine.

## Overview

Two `InferenceBackend` decorators cover the reliability concerns that come up
once an app talks to more than one backend or one flaky network: **failing
over** to another backend when the current one won't serve a request, and
**retrying** a single backend's transient errors before giving up on it.
They compose independently — a fallback chain can wrap backends that
themselves retry internally, and each concern is a separate, focused type
rather than one large configuration surface:

| Concern | Type | Composes | Visibility |
|---|---|---|---|
| Cross-backend failover on error | ``FallbackBackend`` | An ordered list of `InferenceBackend`s | public |
| Per-attempt backoff/retry policy | ``RetryStrategy`` / ``ExponentialBackoffStrategy`` | Any `async throws` operation, via ``withRetry(strategy:sleeper:operation:)`` | public |
| Capability-based backend selection | `RouterBackend` | An ordered list of `InferenceBackend`s | `package` — no adopter as of the 2026-07 inert-surface sweep (#2128); demoted alongside this article, not deleted, so it re-promotes on a first real one |

## `FallbackBackend` — cross-backend failover

Use ``withFallbacks(_:policy:)`` to compose backends in priority order — put
your cheapest / lowest-latency / most-preferred backend first:

```swift,no-build
import ManifoldInference

let backend = primary.withFallbacks([secondary, tertiary])

let (_, stream) = try inferenceService.enqueue(messages: history, config: config)
```

`FallbackBackend` advances to the next backend in the chain on a *routable*
error (per ``FallbackPolicy/shouldAdvance``) — auth failures, bad requests,
and similar non-transient errors are not routed around, since the next
backend wouldn't help either. If every backend fails, the chain throws a
``FallbackExhaustedError`` that aggregates each backend's error in attempt
order, so you can inspect the whole failure chain rather than only the last
one.

### The streaming rule: fallback stops once content has streamed

A user has already seen partial output once the first
``GenerationEvent/token(_:)`` (or ``GenerationEvent/thinkingToken(_:)``)
reaches them, so transparently failing over mid-stream would mean silently
mixing two backends' output in one reply. `FallbackBackend` enforces this:
once a content token has been forwarded, a subsequent error propagates
instead of advancing — unless ``FallbackPolicy/advanceAfterFirstToken`` is
set, in which case the partial output is discarded and the turn restarts
cleanly on the next backend.

### Composing with per-backend retry

`FallbackBackend` and per-backend retry are orthogonal — set
``FallbackPolicy/perBackendRetries`` to have each backend retry its own
transient errors (via ``withRetry(strategy:sleeper:operation:)`` with
``ExponentialBackoffStrategy``) *before* the chain advances to the next
backend:

```swift,no-build
let policy = FallbackPolicy(perBackendRetries: 2)
let backend = primary.withFallbacks([secondary], policy: policy)
```

Read it as two independent dials: `perBackendRetries` controls how hard a
single backend is retried before giving up on it; the fallback chain controls
what happens once you *do* give up on it.

## `RetryStrategy` — per-attempt backoff policy

``RetryStrategy`` is the pluggable policy behind ``withRetry(strategy:sleeper:operation:)``:
given the error, the zero-based attempt number, and cumulative delay so far,
it returns the delay before the next attempt or `nil` to stop retrying.
``ExponentialBackoffStrategy`` is the shipped implementation — exponential
backoff with 25% jitter and a total-delay cap, honoring a cloud backend's
`Retry-After` header when one is present:

```swift,no-build
import ManifoldInference

let result = try await withRetry(
    strategy: ExponentialBackoffStrategy(maxRetries: 3, baseDelay: 1.0, maxTotalDelay: 60.0)
) {
    try await myFlakyCall()
}
```

Only errors conforming to `BackendError` with `isRetryable == true` are
retried at all — everything else propagates on the first throw. Once the
strategy returns `nil` (retries exhausted, or the total delay budget would be
exceeded), `withRetry` throws ``RetryExhaustedError``, wrapping the last
underlying error so callers can distinguish "failed after retries" from a
single failure.

### How cloud backends plug in a strategy

`ManifoldCloudCore`'s `SSEGenerationTaskRunner` — the shared SSE
infrastructure both the Ollama and CloudSaaS backend families use — wraps its
connection-retry budget in `withRetry`. A `RetryExhaustedError` from that
budget running out reaches `InferenceService.enqueue`/`.generate`'s
`GenerationStream.events` as its own concrete type, alongside
`InferenceError`/`CloudBackendError` — see `ManifoldRuntime`'s
"Error handling at the boundary" article for the full catalog of what
escapes at the four public turn-loop boundaries.

Write a custom ``RetryStrategy`` when you need a different backoff shape
(fixed delay, a different jitter distribution, a strategy that never retries
rate limits) — `withRetry` doesn't know or care which one it's holding.

## Choosing between them (and `RouterBackend`)

- **One backend, want it to survive transient blips** — `RetryStrategy` via
  `withRetry`, or lean on the retry already built into the cloud backend
  families.
- **Multiple backends, want automatic failover on error** — `FallbackBackend`.
- **Multiple *already-loaded* backends, want to pick one per request by
  capability** (e.g. route classification to a small local model, reasoning
  to a larger one) rather than by failure — that was `RouterBackend`'s job.
  It is `package`-visibility only as of the 2026-07 inert-surface sweep: well
  tested (`RouterBackendTests`), but zero adopters found in the 2026-07-21
  eight-app consumer screen. It is not deleted — a host that needs
  capability-based multiplexing across already-loaded backends is the
  re-promotion trigger; open an issue describing the use case in the
  meantime.
