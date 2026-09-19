# ManifoldKit — instructions for AI coding assistants

This is the canonical entry point for every AI coding assistant working in this
repository. Read it at session start. Detailed, task-specific guidance is
preserved in [AGENTS.reference.md](AGENTS.reference.md); read the sections it
points to before changing the corresponding surface. `CLAUDE.md` is a thin
Claude-specific adapter and must not duplicate cross-tool rules.

## Session bootstrap

1. Read the relevant sections of `AGENTS.reference.md` for the surface you
   are changing. In a maintainer environment configured with the Estate,
   also read `~/Repos/roryford/estate/policies/DIGEST.md`.
2. Read the non-empty known-issues buffer: `.agents/known-issues.md` when
   present, otherwise the legacy `.claude/known-issues.md`. Append new
   symptom → cause → fix entries to the file that already exists. Never create
   the other file; if both exist, report the fork rather than choosing one;
   maintainers consult `~/Repos/roryford/estate/policies/knowledge-capture.md`.
3. Follow the build, test, coding, and PR rules below.

These steps are required in every harness. Claude may inject some of this
context, but other harnesses do not.

## Invariants

- ManifoldKit supports sustained production development. Keep docs, examples,
  migration paths, and public APIs aligned.
- Dependencies flow UI → Runtime → Inference → Contract → leaves. UI never
  imports a backend family. `ConversationRuntime` is the single turn loop.
- Heavy dependencies are opt-in through traits or companion packages.
- Every rule and guard has an enforced tripwire plus a sabotage test.
- Tests use real async behavior and in-memory persistence stores; never mock
  persistence. Ship tests with behavior changes.
- Errors stay visible: no `try?` in production code, and no silent shell
  failure. Use `do`/`catch` with logging.
- Use `@Observable` + `@MainActor`, explicit actor isolation, and
  async/await. Do not use Combine, callback pyramids, `Task.detached` from a
  main-actor class, or `@unchecked Sendable` as a race fix.
- Breaking changes are deliberate: update migration docs and changelog, then
  build known consumers before release.
- No secret enters the repository, including ignored files. Templates contain
  references only.

The complete rationale and enforcement map remains in
`AGENTS.reference.md#part-0--principles`.

## Common LLM hallucinations to avoid

The umbrella module is `ManifoldKit`; use `import ManifoldKit` for the
common surface. Specialized products such as
`ManifoldUIModelManagement`, `ManifoldMCP`, and `ManifoldVoice` remain
explicit imports. MLX and llama.cpp are companion packages, not traits.
There are no default traits; `Macros` and `Server` are opt-in.

Bootstrap through `ManifoldBootstrap.build(...)` from async context, or use
`ManifoldKit.quickStart(backends:)` for the single-session path. Send with
`try await vm.sendMessage("hello")` or `await vm.sendMessage()`;
`vm.send(_:)` is deleted.

`BackendName` is an extensible struct, not an enum. Compare with typed
identifiers such as `BackendName.foundation.rawValue`, and parse persisted
legacy values with `BackendName.parse(_:)`.

Local model loading belongs on `ChatViewModel.dispatchSelectedLoad()` or
`vm.dispatchSelectedLoad()`; Foundation Models use
`vm.loadFoundationModelIfAvailable()`. Themes are SwiftUI environment
styles, not view-model properties.

For tool calling, register tools and place definitions on the generation
configuration: create `var config = GenerationConfig.default`, then assign
`config.tools = registry.definitions`.

The `@ToolSchema` macro requires `--traits Macros` (or a package trait
configuration). Local 3B–8B instruct models generally need a curated tool set.

Before producing consumer code, read the full recipes and current API details
in `AGENTS.reference.md#part-1--using-manifoldkit-consumers`. That reference
contains the canonical bootstrap, messages, backend identity, theming, tool
calling, cloud endpoint, trait, and concurrency guidance. Do not rely on
memorized pre-1.0 API knowledge.

## Contributor workflow

Read `AGENTS.reference.md#part-2--contributing-to-manifoldkit-internal-conventions`
before editing source, tests, package structure, documentation gates, or
release machinery. It contains the target map, service-sharing rules, public
API policy, Swift concurrency traps, platform policy, and release procedure.

Build and test from the repository root:

```bash
swift build
scripts/test.sh --profile local
```

`scripts/test.sh --profile local` is the full pre-push gate. Its default
diagnostics live under this worktree's `test-diagnostics/`, and the full profile
assigns child invocations distinct labelled paths. Never infer success from
piped or tailed output; preserve the script's exit status. In a configured
Estate maintainer environment, also run the estate fail-open lint over the
branch diff.

Tests:

- Use XCTest for new suites; retain Swift Testing only in files that already
  use it, following `Tests/README.md`.
- Use in-memory stores for persistence tests.
- Exercise degraded paths and prove new guards can fail.
- A suite that reads or executes a file must be selected when that file changes.
- Run full affected targets and all cross-cutting audits; a narrow filter is
  only an iteration aid.

Production code:

- Prefer small, explicit public APIs and update migration material for removals.
- Keep service instances shared through the bootstrap/runtime graph.
- Preserve strict Swift 6 actor isolation.
- Support the platform and Xcode floors recorded in the package and reference.
- Use `scripts/affected-suites.sh` and the reference target map to resolve
  affected suites rather than guessing.

## Documentation and release

Documentation changes must keep snippets, DocC, examples, README claims,
production-readiness status, and migration indexes consistent. The complete
documentation gates and batching rules live in
`AGENTS.reference.md#documentation-gates`.

Use Conventional Commits. Before pushing, run the full local gate and inspect
the branch diff for silent shell failures. Maintainers in a configured Estate
environment also run its fail-open lint. For a PR, use the draft-PR review and
verification loop in the reference. The PR owner, after review and required
checks pass, authorizes merge or auto-merge.

Releases follow `AGENTS.reference.md#release-workflow`. Its pre-bump demo
build, API/migration checks, companion ordering, release-please behavior, and
post-release verification are mandatory. Never improvise a release from this
summary.

## Scope index

Read these sections of `AGENTS.reference.md` when applicable:

- consumer/API work: Part 1 in full;
- module or package changes: Targets, Tooling, Public API design policy;
- concurrency or persistence: Coding conventions and Swift 6 gotchas;
- tests or CI: Running tests, Test conventions, Documentation gates;
- docs/examples: Documentation gates and contributor hygiene;
- releases: Commit style, Release workflow, PR workflow;
- UI/server/fuzz/companion work: the matching target and hardware sections.

Contributor and release work must use the draft-PR review loop, the full local
gate, and the complete release workflow in `AGENTS.reference.md`; no release
may skip companion and post-release verification.
