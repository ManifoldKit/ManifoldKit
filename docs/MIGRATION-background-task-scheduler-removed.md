# Migration: `BackgroundTaskScheduler` seam removed

**This is a breaking change.** ManifoldKit no longer ships an in-process
background-task scheduler protocol, its default implementation, or the
memory-budget watchdog type that backed it.

## Why

The seam had zero production instantiation: nothing in ManifoldKit itself, in
the Example apps, or in any known consumer repo (first-party apps, the
companion backend packages, or manifold-eval — verified via
`scripts/api-demotion-screen.sh`, clean across all six) ever constructed
`DefaultBackgroundTaskScheduler` outside of tests. The only conformer besides
the default implementation was `MockBackgroundTaskScheduler`, a test double
with no production caller. Per principle 10 ("shipped means live"), a type
with no live driver — public API held up entirely by its own test suite — is
not coverage of a real path, it's ceremony around a type that was never
finished. Rather than carry an unwired seam into the 1.0 stability promise,
it is deleted (plan §B.5, docs/plans/api-v1-rationalisation-2026-07.md).

This is a different feature from `ConversationRuntimeBackgroundBridge`, which
is unaffected: the bridge is a real, documented, tested integration point for
`BGContinuedProcessingTask` (see the `BackgroundTaskSupport` DocC article) and
ships unchanged. `ManifoldBackgroundTaskIdentifiers` — the enum of recommended
`BGTaskScheduler` identifier strings, including `continueGeneration`, which the
bridge's recipe uses — also ships unchanged; it has simply relocated to live
alongside the bridge (`ConversationRuntimeBackgroundBridge.swift`) since that
is its one live consumer.

## What was removed

| Removed | Where |
|---------|-------|
| `BackgroundTaskScheduler` (protocol) | `ManifoldRuntime` |
| `DefaultBackgroundTaskScheduler` | `ManifoldRuntime` |
| `MemoryBudget` (struct, incl. `.default`) | `ManifoldRuntime` |
| `MockBackgroundTaskScheduler` | `ManifoldTestSupport` |

`ManifoldBackgroundTaskIdentifiers` is **not** removed — it moved (same
module, same public API) into
`Sources/ManifoldRuntime/Services/ConversationRuntimeBackgroundBridge.swift`.

## How to migrate

If you were using `BackgroundTaskScheduler`/`DefaultBackgroundTaskScheduler` to
run in-process background work with a memory-budget watchdog, ManifoldKit does
not provide a replacement — the seam never had a live driver to migrate from.
Implement your own scheduling primitive (a `Task` + your own memory-pressure
observer, or `BGTaskScheduler` directly) suited to your app's actual
background-work shape. `ManifoldHardware`'s memory-pressure broadcasting
(device-capability primitives) remains available if you need a signal to build
on.

If you were only using `ManifoldBackgroundTaskIdentifiers`, no action is
needed — the import path (`ManifoldRuntime`) and the API are unchanged.

## Update (2026-07-15)

The claim above ("ships unchanged", "same public API") no longer holds as of
the D.2+D.3 residual sweep: `ConversationRuntimeBackgroundBridge` and
`ManifoldBackgroundTaskIdentifiers` were demoted `public` → `package` — zero
host apps across all six consumer repos constructed either type. This is a
different removal from the one this file documents (that one deleted an
unwired scheduler seam; this one narrows visibility on a real, tested,
documented integration point that simply had no adopter yet). See
`docs/MIGRATION-api-demotions-0.71.md` § D.2+D.3 and the rewritten
`BackgroundTaskSupport` DocC article, which now shows the still-public
``ConversationRuntime/cancelAllTurns()`` recipe hosts should use directly.
