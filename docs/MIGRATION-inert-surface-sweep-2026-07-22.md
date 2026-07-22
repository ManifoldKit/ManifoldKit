# Migration: inert-surface sweep (2026-07-22)

**Audience:** consumer
**Status:** living

**This is a breaking change.** Part of the #2128 inert-surface campaign. Two
public surfaces with **zero adopters** — verified across the 2026-07-22
eight-consumer screen (all first-party apps + manifold-eval + both companion
packages) and with no in-repo reader — were removed. If your app or package
referenced any of the symbols below, pin to an earlier ManifoldKit version or
open an issue; none were reachable by any surveyed consumer.

The same PR added the `InertSurfaceAuditTest` tripwire so a *new* public symbol
with no reference can no longer ship silently.

## A. `ToolCallConformanceCache` and its adapters — removed

The tool-call conformance **cache** was a write-path spike that was never wired
to a reader: no `ManifoldBootstrap.toolCallConformanceCache` consumer existed in
core, and the eight-consumer screen found none downstream. Removed:

- `ToolCallConformanceCache` (protocol) — `ManifoldRuntime`
- `InMemoryToolCallConformanceCache` (actor) — `ManifoldRuntime`
- `SwiftDataToolCallConformanceCache` (adapter) — `ManifoldPersistenceSwiftData`
- `ManifoldBootstrap.toolCallConformanceCache` (property) — and its construction
  in every bootstrap path

**Retained** (still `public`, unchanged):

- The value types `ToolCallConformance`, `ToolCallConformanceKey`,
  `ToolCallCapability`, `ToolCallConformanceSource` — the dialect vocabulary the
  companion backends consume.
- The `ToolCallConformanceRecord` `@Model` and its **V11 schema**. Dropping a
  persisted `@Model` requires a new schema version + a lightweight migration, a
  cost not worth paying for dead storage — the table is simply left in place and
  will be removed at the next schema revision. **No data migration is required
  by this release**; existing databases open unchanged.

**If you constructed the cache directly** (`InMemoryToolCallConformanceCache()`
or read `bootstrap.toolCallConformanceCache`): there is no replacement — the
feature had no live path. Measure conformance with the `ManifoldTools` /
`ManifoldAppEval` harnesses and hold the verdict in your own store if you need
one.

## B. Orphaned `CloudMessageEncoder` methods — removed

Two `CloudMessageEncoder` methods and one supporting type had zero callers; the
live turn path already covers their behavior privately. Removed from
`ManifoldCloudCore`:

- `CloudMessageEncoder.encodeToolResults(_:)`
- `CloudMessageEncoder.annotateCacheBreakpoints(plan:systemPrompt:systemBlock:toolEntries:)`
- `CacheBreakpointPlan` (struct) — only ever `annotateCacheBreakpoints`'s parameter

**Where the behavior lives now** (unchanged, already the shipping path):

- Tool-result encoding: `CloudMessageEncoder.encodeMessages(...,
  toolAwareHistory:)` (each backend's `buildRequest` already routes tool
  results through the tool-aware history path).
- Claude prompt-cache breakpoints: `ClaudeBackend.buildRequest` attaches
  `cache_control` inline, gated on `ClaudeBackend.cachePolicy`.

Both live paths keep their existing test coverage (`ClaudePromptCacheTests` and
the per-backend tool-calling suites), so no coverage was lost.
