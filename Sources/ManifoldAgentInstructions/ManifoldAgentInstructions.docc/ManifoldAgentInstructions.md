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
hand. `ManifoldKit`'s
`ConversationRuntimeOptions.addAgentInstructions(currentDirectory:stoppingAt:)`
is the supported one-call recipe — a `mutating func` that **adds** to any
pipeline already configured, the same shape as
`ManifoldBootstrap.addGenerationToolSources(viewModel:)`, not a factory that
replaces your options wholesale:

```swift,no-build:host-context (projectRoot, configuration) is illustrative, not defined in this snippet
import ManifoldKit

var options = ConversationRuntimeOptions()
options.addAgentInstructions(currentDirectory: projectRoot)
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

## Security

`AGENTS.md` files are untrusted on-disk content: whatever text they contain
is merged verbatim into the model's system preamble and treated as an
instruction. That is inherent to the ambient-instruction format — every
major agent tool that reads `AGENTS.md` works the same way — not a defect
specific to this module, but a host pointing `currentDirectory` at a
directory it doesn't control (an unreviewed clone, a user-selected folder)
is choosing to trust whatever `AGENTS.md` is found there.

``AgentInstructionLoader`` still enforces three concrete boundaries: the
`stoppingAt` containment check compares resolved path **components** (a
sibling directory sharing a string prefix, e.g. `proj-secrets` vs. `proj`,
cannot escape the boundary); a candidate `AGENTS.md` that is or sits behind a
symlink resolving outside its own directory is rejected rather than followed
(opening an untrusted cloned repo is exactly the scenario a planted
`AGENTS.md -> ~/.ssh/id_rsa` symlink would target); and a file larger than
``AgentInstructionLoader/maxFileSizeBytes`` (64 KB) is skipped rather than
read whole.

## Platform and sandboxing caveats

``AgentInstructionLoader/discover(from:stoppingAt:)`` is **macOS-only in v1**.
On other platforms it returns `[]` and logs a one-time warning — the same
contract the module's SKILL.md-discovery predecessor used, carried forward
because the underlying filesystem-walk constraint is unchanged. This means
`addAgentInstructions(currentDirectory:stoppingAt:)` still succeeds on iOS
(`.pipeline` is non-nil, the turn loop runs normally) but never loads
anything — there is no error or signal at the call site distinguishing "no
`AGENTS.md` found" from "unsupported platform."

The default `stoppingAt` (the current user's home directory) resolves to the
app's **container** directory in a sandboxed macOS app, not the real `$HOME`
a user would expect. A `currentDirectory` outside the container (a
user-selected folder reached via an open panel / security-scoped bookmark)
fails the containment check and yields `[]` with only a log line — pass an
explicit `stopDirectory` that actually bounds the intended tree in that case.

## Topics

### Discovery and merging

- ``AgentInstruction``
- ``AgentInstructionLoader``

### Prompt-pipeline integration

- ``AgentInstructionContextProvider``
