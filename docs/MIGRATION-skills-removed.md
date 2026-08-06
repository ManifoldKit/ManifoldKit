# Migration: `ManifoldSkills` retired

**Audience:** consumer
**Status:** living

**This is a breaking change.** `ManifoldSkills` — Claude-Code-compatible
`SKILL.md` filesystem discovery and the `invoke_skill` dispatch tool — is
removed as of this release (#2434). There is no drop-in replacement for the
`SKILL.md` half; its `AGENTS.md` ambient-instruction half survives as a
separate product, `ManifoldAgentInstructions` (see below).

## Why it was removed

**The reason is zero adoption, not Apple duplication.** `ManifoldSkills` had
zero importers anywhere in `Sources/`, zero hits across the eight screened
consumer apps, and had carried `docs/PRODUCTION-READINESS.md`'s
"Zero-adopter" Experimental classification since it landed. It cost ~2,540 LOC
of source + tests, 50 public declarations, an API baseline, its own DocC
catalog, and a slot in 11 documents' worth of maintenance to carry a module
nothing used — the AGENTS.md § Public API design policy default (pre-1.0:
delete, don't deprecate) applied.

**Apple's WWDC-2026 `Skills` (Foundation Models, iOS/macOS 27+) is NOT a
replacement — it is a different feature that happens to share a noun.**
Apple's are **compile-time Swift literals** composed by a `@SkillsBuilder`
result builder: a skill is source code, baked into your binary at build time.
`ManifoldSkills` was **runtime `SKILL.md` filesystem discovery** — it scanned
`~/.config/agents/skills`, `~/.agents/skills`, `~/.claude/skills`,
`$PWD/.agents/skills`, and `$PWD/.claude/skills` at session start for
Claude-Code-compatible skill libraries, with `allowed-tools` containment that
failed closed and `references:` reads confined to the skill directory. If you
came here looking for a way to author a skill as a Swift literal, Apple's
`Skills` is what you want and this migration note doesn't apply to you — read
Apple's Foundation Models documentation instead. If you came here looking for
runtime discovery of Claude-Code-style `SKILL.md` libraries, there is
currently no ManifoldKit replacement; you would need to re-implement the
filesystem walk and YAML-frontmatter parsing yourself, or vendor the deleted
source from before this release's tag.

## What was removed

| Symbol | Kind | Was in |
|---|---|---|
| `Skill` | `public struct` | `Sources/ManifoldSkills/Skill.swift` (deleted) |
| `SkillLoader` | `public struct` | `Sources/ManifoldSkills/SkillLoader.swift` (deleted) |
| `SkillRegistry` | `public final class` | `Sources/ManifoldSkills/SkillRegistry.swift` (deleted) |
| `SkillToolSource` | `public final class` | `Sources/ManifoldSkills/SkillToolSource.swift` (deleted) — the `invoke_skill` `SessionToolSource` conformer |
| `SkillReferenceResolver` | `public struct` | `Sources/ManifoldSkills/SkillReferenceResolver.swift` (deleted) |
| `SkillDispatchError` | `public enum` | `Sources/ManifoldSkills/SkillToolSource.swift` (deleted) |
| `SkillReferenceError` | `public enum` | `Sources/ManifoldSkills/SkillReferenceResolver.swift` (deleted) |
| YAML frontmatter parsing (`YAMLFrontmatter` and friends) | `public` types | `Sources/ManifoldSkills/YAMLFrontmatter.swift` (deleted) |
| `ConversationEvent.skillInvoked(name:sessionID:)` | `EnumElement` | `Sources/ManifoldRuntime/Services/ConversationEvent.swift` |
| `ConversationEventKind.skillInvoked` | `EnumElement` | `Sources/ManifoldRuntime/Models/ConversationEventKind.swift` |

`ConversationEvent.skillInvoked` is a second, deliberate break bundled into
this same removal: the case existed solely to give host adapters something to
pattern-match "once skill identity is plumbed through" — its own doc comment
said as much — and it was never emitted by any producer. With `ManifoldSkills`
gone, the case documented a module that no longer exists, so it went with it
rather than being carried forward with rewritten documentation. Its
`ConversationEventKind` mirror (the string-keyed JSONL trace discriminant) is
removed alongside it; because the case was never emitted, no persisted trace
file can contain the `"skillInvoked"` raw value, so this is safe under
`ConversationEventKind`'s "existing raw values are immutable" wire contract —
nothing written to disk relied on it.

The product, target, and test target are gone from `Package.swift`; the
`ManifoldSkills.docc` catalog is gone; `docs/plans/inert-code-audit-2026-07.md`
and `docs/plans/api-v1-rationalisation-2026-07.md` are left as-is (closed,
historical planning records — not rewritten to describe a state that didn't
exist when they were written).

## Symptoms

```
no such module 'ManifoldSkills'
cannot find type 'Skill' in scope
cannot find 'SkillLoader' in scope
cannot find type 'SkillToolSource' in scope
type 'ConversationEvent' has no member 'skillInvoked'
type 'ConversationEventKind' has no member 'skillInvoked'
```

## What to do instead

**If you never linked `ManifoldSkills`:** nothing to do. It was never in the
`ManifoldKit` umbrella's re-exports, so `import ManifoldKit` alone was never
affected.

**If you linked `ManifoldSkills` for `AGENTS.md` ambient-instruction
loading:** switch the import. `AgentInstruction`, `AgentInstructionLoader`,
and `AgentInstructionContextProvider` moved unchanged (module rename only) to
a new product, `ManifoldAgentInstructions` — replace the
`.product(name: "ManifoldSkills", package: "ManifoldKit")` target dependency
in your `Package.swift` with:

```swift,no-build:Package.swift manifest fragment, not standalone Swift
.product(name: "ManifoldAgentInstructions", package: "ManifoldKit")
```

Where you previously wrote `import ManifoldSkills`, write this instead:

```swift
import ManifoldAgentInstructions
```

`ManifoldAgentInstructions` depends on `ManifoldInference` only (not
`ManifoldRuntime`, unlike the old `ManifoldSkills`), so it stays a light,
opt-in link. The recommended way to turn it on is the one-call recipe in
`ManifoldKit`'s `ConversationRuntimeOptions+AgentInstructions.swift`, wired
through the same `ConversationRuntimeOptions.pipeline` seam every other
`PromptContextPipeline` customization uses:

```swift,no-build:API-shape excerpt for assistants; intentionally terse, no imports or surrounding context
let options = ConversationRuntimeOptions.withAgentInstructions(
    currentDirectory: projectRoot
)
let (progress, task) = ManifoldBootstrap.build(
    configuration: configuration,
    runtimeOptions: options
)
```

This is opt-in by design — `ManifoldKit.quickStart(...)` does not call it, so
`AGENTS.md` loading only turns on when a host builds its own
`ConversationRuntimeOptions` this way and passes it through the manual
`ManifoldBootstrap.build(...)` path.

**If you linked `ManifoldSkills` for `SKILL.md` discovery or
`invoke_skill`:** there is no ManifoldKit replacement (see "Why it was
removed" above). Pin to a pre-#2434 tag if you need the deleted source as a
starting point to vendor your own copy.

**If you pattern-matched `ConversationEvent.skillInvoked` /
`ConversationEventKind.skillInvoked`:** drop the case from your `switch`. It
was never emitted (see above), so no producer callback needs replacing.
