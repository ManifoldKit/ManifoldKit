# ``ManifoldAgentInstructions``

Discover `AGENTS.md` ambient instruction files on disk and inject them into a
turn's system preamble.

## Overview

`AGENTS.md` is the cross-tool ambient-instruction standard (60k+ repos) read
by agent tools at session start — a plain-markdown file, no YAML frontmatter,
walked upward from a working directory to a stop point and merged
closest-wins. `ManifoldAgentInstructions` ships three types:
``AgentInstruction``, a single discovered file; ``AgentInstructionLoader``,
the upward filesystem walk plus merge; and ``AgentInstructionContextProvider``,
a `PromptContextProvider` (`ManifoldInference`) conformer that turns a merged
result into a `PromptSlot` at the `.systemPreamble` position.

This module was extracted from `ManifoldSkills` (#2434), which retired for
zero adoption. `AGENTS.md` loading was the one piece of that module with a
real use case, so it survives as its own product rather than going with the
rest — see
[docs/MIGRATION-skills-removed.md](https://github.com/ManifoldKit/ManifoldKit/blob/main/docs/MIGRATION-skills-removed.md).
Despite that shared history, this module is unrelated to Apple's
Foundation Models `Skills` (WWDC 2026) — Apple's are compile-time Swift
literals, this is runtime filesystem discovery of a plain-markdown file.

The module depends on `ManifoldInference` only (not `ManifoldRuntime`), so it
stays a light, opt-in link.

## Experimental tier

`ManifoldAgentInstructions` is in ManifoldKit's **experimental tier**
(zero-adopter sub-tier) — it may break in any minor release, always
migration-noted, until it graduates. Graduation requires a real external
adopter: a shipping app or companion that pins ManifoldKit and imports this
module from non-test code. See
[docs/API-DESIGN.md § 7b](https://github.com/ManifoldKit/ManifoldKit/blob/main/docs/API-DESIGN.md)
for the full policy, and
[docs/PRODUCTION-READINESS.md](https://github.com/ManifoldKit/ManifoldKit/blob/main/docs/PRODUCTION-READINESS.md)
for the current tier assignment.

## Direct use

The loader and provider both work standalone, with no `ManifoldRuntime` /
`ManifoldBootstrap` dependency:

```swift
import Foundation
import ManifoldAgentInstructions

let loader = AgentInstructionLoader()
let instructions = loader.discover(
    from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
)
let merged = loader.merged(instructions)
```

`discover(from:stoppingAt:)` walks upward from `from` to `stoppingAt`
(defaulting to the user's home directory) and returns every `AGENTS.md` found,
root-to-leaf. `merged(_:)` joins their contents with a `---` separator so an
LLM can distinguish instruction scopes; it returns `nil` for an empty input.

## Wiring into a bootstrap

A host wiring `ManifoldBootstrap` doesn't need to compose the pipeline by
hand. `ManifoldKit`'s `ConversationRuntimeOptions.withAgentInstructions(currentDirectory:stoppingAt:)`
is the supported one-call recipe:

```swift,no-build:host-context (projectRoot, configuration) is illustrative, not defined in this snippet
import ManifoldKit

let options = ConversationRuntimeOptions.withAgentInstructions(
    currentDirectory: projectRoot
)
let (progress, task) = ManifoldBootstrap.build(
    configuration: configuration,
    runtimeOptions: options
)
```

This is **opt-in by design** — `ManifoldKit.quickStart(...)` does not call it,
so `AGENTS.md` loading only turns on when a host builds its own
`ConversationRuntimeOptions` this way and passes it through the manual
`ManifoldBootstrap.build(...)` path. The pipeline is consumed once, at
`ConversationRuntime` construction, so this must be set **before** bootstrap
runs, not after.

## Platform availability

``AgentInstructionLoader/discover(from:stoppingAt:)`` is **macOS-only in v1**.
On other platforms it returns `[]` and logs a one-time warning — the same
contract the module's SKILL.md-discovery predecessor used, carried forward
because the underlying filesystem-walk constraint is unchanged.

## Topics

### Discovery and merging

- ``AgentInstruction``
- ``AgentInstructionLoader``

### Prompt-pipeline integration

- ``AgentInstructionContextProvider``
