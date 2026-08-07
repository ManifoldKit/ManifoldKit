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
| `ManifoldBootstrap.addToolSources(_:)` | Replaced the full session-tool-source set on every call. | **Merges** the passed sources into whatever is currently registered — including sources passed to `ManifoldBootstrap.build(sessionToolSources:)` / `init(sessionToolSources:)` at construction, *and* any source installed or swapped via a direct `conversationRuntime.updateSessionToolSources(_:)` call. Re-registering a source whose *dynamic type* is already present replaces **every** currently-registered source of that type (de-dup is type-keyed, not per-instance); every registered source of a *different* type is untouched. Two sources of the same dynamic type passed together in one call are both kept — de-duplication only ever consults sources registered by an *earlier*, separate call. |
| `ManifoldBootstrap.addGenerationToolSources(viewModel:)` (`ManifoldKit` umbrella, `Sources/ManifoldKit/ManifoldBootstrap+GenerationToolSources.swift`) | Convenience wrapper registering `ImageGenerationToolSource` / `VideoGenerationToolSource` / `WebSearchToolSource`, skipping any source whose backing service was nil and logging a warning if it skipped all three. | **Removed.** With an additive primitive its batching rationale is gone — call `addToolSources(_:)` directly with the sources you want. |
| `ConversationRuntime.updateSessionToolSources(_:)` | Replaced the full source list. | **Unchanged.** Still the per-turn wholesale-*swap* primitive (e.g. a demo's per-scenario source swap) — it now sits one layer below `addToolSources(_:)`, which is the accumulate layer. Call it directly only when you deliberately want a full-set replace. `ConversationRuntime` (not `ManifoldBootstrap`) is the single source of truth for what's currently registered — `addToolSources(_:)` keeps no separate copy, so it always merges against the runtime's real current state, including any direct swap made through this method. |

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
`ManifoldKit.quickStart(...)` caveat (#1903) and how to gate registration on
which services are actually wired. A source registered against a bootstrap
whose backing service is nil is still advertised to the model, but does not
throw when invoked — each source reports the failure as a `ToolResult`
instead: `ImageGenerationToolSource` / `VideoGenerationToolSource` preflight
and return `errorKind: .permanent`, while `WebSearchToolSource` has no
preflight and falls through its catch-all to `errorKind: .transient` (reads
as retryable to the model). See `GenerationComponents.md` for the full
breakdown.

## De-duplication

`addToolSources(_:)` de-duplicates on the *dynamic type* of each source, not
its identity or any `Equatable` conformance (`SessionToolSource` requires
neither). Re-registering a new instance of an already-registered type
removes **every** currently-registered source of that same type, not just
"the one it's implicitly replacing" — every registered source of a
*different* type is left untouched.

Two sources of the same dynamic type passed together in a **single**
`addToolSources(_:)` call are both kept — de-duplication only ever consults
sources registered by an *earlier, separate* call. So batching independent
sources into one call (the pattern the "Failure scenario" in #2440 calls out
as the only safe usage on `main`) still works exactly as before **for that
one call**. This does not extend across calls: if you batch two
`MCPToolSource` instances for different servers in one call, then later make
a *separate* call that registers a third, reconfigured `MCPToolSource`, that
later call removes **both** earlier instances — not just the one you meant
to reconfigure — because de-dup only ever sees "is this the same type",
never "is this the same logical entry". If your source type can represent
more than one independent registration (multiple MCP servers, multiple
per-feature sources of the same class), batch every instance you want to
keep into each call rather than relying on earlier calls to still be there:

```swift
import ManifoldPersistenceSwiftData
import ManifoldRuntime

/// Re-registering a source of a type that is already present removes EVERY
/// currently-registered source of that type — here, any existing
/// `HandoffToolSource` (there is normally only one). Any other previously
/// registered source (Skills, generation tools, a custom source) is left
/// untouched.
func rewireHandoff(bootstrap: ManifoldBootstrap, replacement: any SessionToolSource) async {
    await bootstrap.addToolSources([replacement])
}
```

## Companion backends

`manifold-mlx` / `manifold-llama` do not construct `SessionToolSource`
instances or call `addToolSources(_:)` / `addGenerationToolSources(_:)`, so
no source change is required beyond a rebuild against this version.
