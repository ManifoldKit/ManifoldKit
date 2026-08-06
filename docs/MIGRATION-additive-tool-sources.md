# Migration: `addToolSources(_:)` is now additive; `addGenerationToolSources(viewModel:)` removed

**Audience:** consumer
**Status:** living

**Applies to:** any host app calling `ManifoldBootstrap.addToolSources(_:)`
more than once (including once at `ManifoldBootstrap.build(sessionToolSources:)`
construction time plus a later call), or calling the retired
`addGenerationToolSources(viewModel:)` convenience wrapper.

## Why

`ManifoldBootstrap.addToolSources(_:)` was named as an accumulator but
behaved as a wholesale replace — it forwarded straight to
`ConversationRuntime.updateSessionToolSources(_:)`, which replaces the full
session-tool-source list. Two independent registrations — a build-time
`sessionToolSources:` install plus a later `addToolSources(_:)` call, or two
separate `addToolSources(_:)` calls from different parts of a host app —
silently destroyed each other depending on call order, with no warning and
no error.

`addGenerationToolSources(viewModel:)` (the `ManifoldKit`-umbrella
convenience that registered `ImageGenerationToolSource` /
`VideoGenerationToolSource` / `WebSearchToolSource` in one call) forwarded to
`addToolSources(_:)` under the hood, so it inherited the same clobber —
while its own doc comment used purely additive language ("Registers …"),
masking the defect. See
[#2440](https://github.com/ManifoldKit/ManifoldKit/issues/2440) for the full
writeup and a reachable-from-public-API failure scenario.

## What changed

| Symbol | Before | After |
|---|---|---|
| `ManifoldBootstrap.addToolSources(_:)` | Replaced the full session-tool-source set on every call. | **Merges** the passed sources into whatever is already registered — including sources passed to `ManifoldBootstrap.build(sessionToolSources:)` / `init(sessionToolSources:)` at construction. Re-registering a source whose *dynamic type* is already present replaces only that entry; every other registered source is untouched. |
| `ManifoldBootstrap.addGenerationToolSources(viewModel:)` (`ManifoldKit` umbrella, `Sources/ManifoldKit/ManifoldBootstrap+GenerationToolSources.swift`) | Convenience wrapper registering `ImageGenerationToolSource` / `VideoGenerationToolSource` / `WebSearchToolSource`, skipping any source whose backing service was nil and logging a warning if it skipped all three. | **Removed.** With an additive primitive its batching rationale is gone — call `addToolSources(_:)` directly with the sources you want. |
| `ConversationRuntime.updateSessionToolSources(_:)` | Replaced the full source list. | **Unchanged.** Still the per-turn wholesale-*swap* primitive (e.g. a demo's per-scenario source swap) — it now sits one layer below `addToolSources(_:)`, which is the accumulate layer. Call it directly only when you deliberately want a full-set replace. |

## Migrating

**If you already called `addToolSources(_:)` more than once** (build-time
`sessionToolSources:` plus a later call, or multiple calls from different
parts of your app): no source change is required. The clobber this note
describes is fixed — every source you registered is now advertised
together. Double check you were not relying on the old replace behavior to
*intentionally* drop a previously-registered source; if you were, batch your
sources into a single `addToolSources(_:)` call instead, or call
`bootstrap.conversationRuntime.updateSessionToolSources(_:)` directly for a
deliberate wholesale swap.

**If you called `addGenerationToolSources(viewModel:)`:**

```
value of type 'ManifoldBootstrap' has no member 'addGenerationToolSources'
```

Register the generation tool sources directly instead:

```swift
import ManifoldPersistenceSwiftData
import ManifoldRuntime

/// Registers the given session tool sources against `bootstrap`.
/// `addToolSources(_:)` accumulates — an earlier registration from another
/// part of the app is not disturbed.
func registerToolSources(
    bootstrap: ManifoldBootstrap,
    sources: [any SessionToolSource]
) async {
    await bootstrap.addToolSources(sources)
}
```

Unlike the old wrapper, `addToolSources(_:)` does not skip a source whose
backing service is nil and does not log a warning when it does — see
[`GenerationComponents.md`](../Sources/ManifoldUI/ManifoldUI.docc/Articles/GenerationComponents.md)
("Registering tool sources") for the full recipe, including the
`ManifoldKit.quickStart(...)` caveat (#1903): a source registered against a
quickStart-built bootstrap is advertised to the model but throws when
invoked, since the underlying generation service is nil.

## De-duplication

`addToolSources(_:)` de-duplicates on the *dynamic type* of each source, not
its identity or any `Equatable` conformance (`SessionToolSource` requires
neither). Re-registering a new instance of an already-registered type
replaces only that entry:

```swift
import ManifoldPersistenceSwiftData
import ManifoldRuntime

/// Re-registering a source of a type that is already present (e.g. a
/// reconfigured `HandoffToolSource`) swaps only that entry — any other
/// previously registered source (Skills, generation tools, a custom
/// source) is left untouched.
func rewireHandoff(bootstrap: ManifoldBootstrap, replacement: any SessionToolSource) async {
    await bootstrap.addToolSources([replacement])
}
```

## Companion backends

`manifold-mlx` / `manifold-llama` do not construct `SessionToolSource`
instances or call `addToolSources(_:)` / `addGenerationToolSources(_:)`, so
no source change is required beyond a rebuild against this version.
