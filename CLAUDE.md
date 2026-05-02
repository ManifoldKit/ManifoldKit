# BaseChatKit — Claude Code Instructions

## Targets

| Target | Role | ML deps |
|--------|------|---------|
| `BaseChatInference` | Inference orchestration — protocols, models, services (no persistence) | None |
| `BaseChatMCP` | Model Context Protocol client surface, descriptors, tool bridge (`MCPClient`, `MCPToolSource`) | None |
| `BaseChatRuntime` | Persistence-agnostic ports (`EndpointStore`, `SamplerPresetStore`, `BenchmarkCache`), use cases (`PromptContextPipeline`, `ChatExportService`, `SessionListService`), and session-list orchestration | None |
| `BaseChatPersistenceSwiftData` | SwiftData schema, `@Model` types, container factory, adapter implementations, and the full-stack `BaseChatBootstrap` | None |
| `BaseChatBackends` | MLX, llama.cpp, Foundation, cloud backends (depends on `BaseChatInference`) | MLX, LlamaSwift |
| `BaseChatUI` | SwiftUI chat-runtime views and view models (chat-only consumer stops here) | None |
| `BaseChatUIModelManagement` | Model browser/download/storage UI + cloud API endpoint editors | None |
| `BaseChatVoice` | Optional speech I/O adapters and voice composer accessory (depends on `BaseChatUI`) | None |
| `BaseChatTestSupport` | Shared mocks and fakes (`MockInferenceBackend`, `CharTokenizer`, etc.) | None |
| `BaseChatMLXIntegrationTests` | Xcode-only real MLX model E2E tests | MLX |

`BaseChatUI` depends on `BaseChatRuntime`, `BaseChatPersistenceSwiftData`, and `BaseChatInference`. Never import `BaseChatBackends` from UI, and never import `BaseChatUIModelManagement` from `BaseChatUI` (the v2.0 peel deliberately makes this a one-way edge — the back-edge would close a dep cycle, and a CI lint blocks the regression). `BaseChatUIModelManagement` depends on `BaseChatUI` (its views consume `ChatViewModel` via `@Environment`); cycle dissolved by closure-injecting `APIConfigurationView` into `ChatView` and `GenerationSettingsView`. `ChatView` and `GenerationSettingsView` are now generic over an `APIConfig: View` type and require an `apiConfiguration:` `@ViewBuilder` parameter — typically `{ APIConfigurationView() }` from `BaseChatUIModelManagement`. `BaseChatBackends` and `BaseChatMCP` depend on `BaseChatInference` directly (not `BaseChatRuntime` or `BaseChatPersistenceSwiftData`), so backend and MCP integrations stay free of SwiftData. Apps that only need inference orchestration can depend on `BaseChatInference` alone; apps that need persistence-agnostic orchestration (ports, use cases) can stop at `BaseChatRuntime` and supply their own adapters. Files that use `InferenceService` or other inference types directly must `import BaseChatInference` explicitly. `MCPCatalog` descriptors are trait-gated behind `MCPBuiltinCatalog`.

## Running tests

```bash
# Runs in CI — no hardware required (disable default MLX trait to skip heavy deps)
swift test --filter BaseChatCoreTests --disable-default-traits
swift test --filter BaseChatRuntimeTests --disable-default-traits
swift test --filter BaseChatPersistenceSwiftDataTests --disable-default-traits
swift test --filter BaseChatInferenceTests --disable-default-traits
swift test --filter BaseChatInferenceSwiftTestingTests --disable-default-traits
swift test --filter BaseChatUITests --disable-default-traits
swift test --filter BaseChatUIModelManagementTests --disable-default-traits
swift test --filter BaseChatMCPTests --disable-default-traits
swift test --filter BaseChatBackendsTests --disable-default-traits
swift test --filter BaseChatTestSupportTests --disable-default-traits
swift test --filter BaseChatAppIntentsTests --disable-default-traits
swift test --filter BaseChatServerTests --disable-default-traits --traits Server

# @ToolSchema macro (trait-gated; off by default — keeps swift-syntax out
# of default builds, ~647 source files saved). The macro plugin and the
# `@ToolSchema` declaration in BaseChatInference are wrapped in `#if Macros`,
# so the bare invocation runs zero macro tests.
swift test --filter ToolSchemaMacro --disable-default-traits --traits Macros

# Apple Silicon only — MLX mock tests + llama.cpp
swift test --filter BaseChatBackendsTests --traits MLX,Llama

# Additional headless E2E coverage (mock backends; no special hardware).
# The trailing `\.` anchor is required — bare `BaseChatE2ETests` matches no class names.
swift test --filter "BaseChatE2ETests\." --disable-default-traits

# MCP built-in catalog descriptors (trait-gated)
swift test --filter BaseChatMCPTests --disable-default-traits --traits MCPBuiltinCatalog

# MCP E2E — requires npx installed and network access.
# The streamable-HTTP smoke is fast and stable; the everything-server smoke
# (`EverythingServerSmokeTests`) has hung for 28+ minutes on `mcp-server-everything`
# in past runs — filter to the streamable suite to avoid that path.
RUN_MCP_E2E=1 swift test --filter BaseChatMCPE2ESmokeTests --disable-default-traits

# Xcode-only — real MLX model inference (metallib required)
# Cannot run via swift test; MLX Metal shaders are only compiled by Xcode.
xcodebuild test -scheme BaseChatKit-Package -only-testing BaseChatMLXIntegrationTests -destination 'platform=macOS'

# Example app UI tests — prefer build-for-testing once, then targeted reruns
scripts/example-ui-tests.sh build-for-testing
scripts/example-ui-tests.sh test-without-building -only-testing:BaseChatDemoUITests/ChatFlowUITests/testEmptyStateShowsWelcome

# Real Ollama server E2E (requires Ollama running at localhost:11434).
# `--traits Ollama` is required — Ollama was dropped from default traits in v2.0,
# so the bare `--disable-default-traits` invocation runs zero tests.
swift test --filter OllamaE2ETests --disable-default-traits --traits Ollama

# Fuzz harness — requires Ollama running at localhost:11434
# The Fuzz trait gates real inference backends; without it, fuzz-chat builds mock-only.
# Always use #if Fuzz in addition to the backend trait (#if MLX, #if Llama) when
# writing tests that depend on real inference — keeps them out of --disable-default-traits CI runs.
scripts/fuzz.sh                    # 5-minute Ollama run (default)
scripts/fuzz.sh --with-llama --minutes 2  # Llama GGUF run

# Isolated Llama tests — runs each Llama-touching XCTestCase subclass in its
# own xctest process so llama.cpp / GGML / Metal global state cannot leak
# across classes. Use this when the in-process run accumulates state on a
# memory-pressured host. Wall-clock cost ~1-2 min (build is reused).
RUN_LLAMA_TESTS=1 BASECHAT_DISCOVER_LOCAL_MODELS=1 \
  LLAMA_TEST_MODEL=$HOME/Documents/Models/<model>.gguf \
  scripts/test-llama-isolated.sh
```

When writing hardware-gated tests, add `XCTSkipIf` guards at the top of the test rather than assuming the environment.

## Test conventions

- Use `XCTestCase` for new tests (existing Swift Testing suites use `@Suite`/`@Test` — match the file you're editing).
- Tests must honestly reflect their classification: a test that hits SwiftData is an integration test, not a unit test. Name and place it accordingly.
- Do not mock the persistence layer to make tests faster. Use in-memory SwiftData stores.
- Async tests: use real `async/await`, not `XCTestExpectation` wrappers unless testing callback-based code. Avoid artificial `sleep` or fixed timeouts — instead use `XCTestExpectation` / `XCTWaiter` with tight deadlines for callback-based code.
- After asserting an expected outcome, add a sabotage check: temporarily break the code path being tested and confirm the test fails. Remove the sabotage before committing.
- Performance tests use `measure { }` (XCTMeasure). Build all fixtures before the measure block.
- `withKnownIssue` is test debt, not a fix. Every use must have a `// FIXME: <issue URL>` comment on the line above. Remove the wrapper in the same PR that fixes the underlying bug. Never use it in critical E2E paths — see [TESTING.md §withKnownIssue Policy](TESTING.md#withknownissue-policy).

## Service sharing

`ChatViewModel.inferenceService` is `package`-visible by design — it was widened from `internal` to `package` during the v2.0 `BaseChatUIModelManagement` peel so views in that module (the peeled model-management surface) can read static capability queries off the service. Apps that need the same `InferenceService` instance in multiple components (e.g., a story engine, character creator) should still create it at the app level and inject it via the constructor:

```swift
let inference = InferenceService()
let chatVM = ChatViewModel(inferenceService: inference)
let storyStore = StoryStore(inferenceService: inference)
```

Do **not** widen `inferenceService` to `public`. Exposing the full `InferenceService` API on `ChatViewModel`'s public contract would lock in load-coordination internals that the framework needs the freedom to refactor. `package` lets the sibling `BaseChatUIModelManagement` module see what it needs without leaking the surface to host apps.

## Coding conventions

- **Concurrency**: async/await throughout. No Combine, no callback pyramids.
- **Observable state**: `@Observable` + `@MainActor`. Not `ObservableObject`/`@Published`.
- **Persistence**: SwiftData only. No CoreData.
- **Error handling**: only validate at system boundaries (user input, external APIs, file I/O). Don't add defensive guards for internal invariants that Swift's type system already enforces.
- **Comments**: explain *why*, not *what*. Omit when the code is self-evident.

## Platform policy

BaseChatKit targets **n-1**: the current Apple OS release and the one immediately before it.

| Platform | Current (n) | Minimum (n-1) |
|----------|-------------|---------------|
| macOS    | 26          | 15            |
| iOS      | 26          | 18            |

When Apple ships a new major OS each September, bump both minimums by one and remove any `#available` guards that were added to paper over the previous floor. Do not use `Atomic`, `OSAllocatedUnfairLock`, or other APIs that post-date the minimum without first checking their availability annotation.

## Hardware constraints (simulator / CI)

- `LlamaBackend` uses a global `llama_backend_init` — only one instance can exist per process. Tests must share a single instance or use `MockInferenceBackend`.
- Metal is unavailable in the simulator. Any test that touches `MLXBackend` or `LlamaBackend` will fail in CI — gate with `XCTSkipIf`.
- `FoundationBackend` requires iOS 26 / macOS 26. Gate accordingly.
- Context window is capped at 512 tokens in the simulator to avoid OOM.

## Tooling

| Script | Purpose |
|--------|---------|
| `scripts/test.sh` | Runs configured Swift test suites and prints an honest summary. |
| `scripts/example-ui-tests.sh` | `build-for-testing` / `test-without-building` for Example app XCUITests. |
| `scripts/clean-leaked-test-artifacts.sh` | Removes test fixtures that leaked into `~/Documents/Models/`. |
| `scripts/fuzz.sh` | Runs the BaseChatFuzz harness (default: 5 min against Ollama). Passes `--traits Fuzz,MLX,Llama` automatically. See [FUZZING.md](FUZZING.md). |

## Pre-push checklist

Before pushing any branch, run all CI-safe test suites locally and confirm zero failures. Use the **same two-invocation shape CI uses** (`.github/workflows/ci.yml`) — running each suite as a separate `swift test` call pays the build-graph + git-remote + test-bundle-link cost 9× instead of 2× and is ~4–5× slower for identical coverage.

```bash
# 1. XCTest suites — single invocation, all filters at once
scripts/test.sh --filter BaseChatCoreTests --filter BaseChatRuntimeTests \
  --filter BaseChatPersistenceSwiftDataTests --filter BaseChatUITests \
  --filter BaseChatUIModelManagementTests --filter BaseChatMCPTests \
  --filter BaseChatBackendsTests --filter BaseChatInferenceTests \
  --filter BaseChatTestSupportTests --filter BaseChatAppIntentsTests \
  --filter BaseChatServerTests \
  --disable-default-traits --skip-update

# 2. Swift Testing — must run in a separate process (XCTest+Swift Testing
#    in one process triggers a libmalloc SIGABRT — see #681)
scripts/test.sh --filter BaseChatInferenceSwiftTestingTests \
  --disable-default-traits --skip-update
```

`--skip-update` skips the per-invocation git-remote contact for every dependency (Package.resolved already pins the graph). Drop it only if you've just edited Package.swift.

Never push based on a subset passing. After rebasing, always re-run the full suite before pushing — conflicts can silently break tests that compiled fine before.

### Strong-machine variant: run both invocations concurrently

The two invocations are separate processes — the libmalloc SIGABRT only triggers when XCTest + Swift Testing share a single process (issue #681). On a multi-core machine you can pre-build once and run them in parallel:

```bash
swift build --build-tests --disable-default-traits

(scripts/test.sh \
   --filter BaseChatCoreTests --filter BaseChatRuntimeTests \
   --filter BaseChatPersistenceSwiftDataTests --filter BaseChatUITests \
   --filter BaseChatUIModelManagementTests --filter BaseChatMCPTests \
   --filter BaseChatBackendsTests --filter BaseChatInferenceTests \
   --filter BaseChatTestSupportTests --filter BaseChatAppIntentsTests \
   --filter BaseChatServerTests \
   --disable-default-traits --skip-update) &
XCTEST_PID=$!

(TMPDIR=/tmp/bck-st-$$ mkdir -p /tmp/bck-st-$$ && \
 TMPDIR=/tmp/bck-st-$$ scripts/test.sh \
   --filter BaseChatInferenceSwiftTestingTests \
   --disable-default-traits --skip-update) &
ST_PID=$!

wait $XCTEST_PID; XCTEST_RC=$?
wait $ST_PID;     ST_RC=$?
[[ $XCTEST_RC -eq 0 && $ST_RC -eq 0 ]] || { echo "FAILED (XCTest=$XCTEST_RC, SwiftTesting=$ST_RC)"; exit 1; }
```

Per-shell `TMPDIR` keeps `scripts/test.sh`'s `test_output.txt` from clobbering. Wall-clock ≈ max(batch1, batch2) instead of sum.

Within-batch parallelism (`--parallel`) is still blocked by the `UserDefaults.standard` race in `test_autoSelectFirstRunModel_*` and download-tests legacy-key reads — tracked in issue #910.

### Spike gate (bounded changes only)

For changes scoped to a single module or a CI-fix push where you've already validated the rest, you may run only the affected slice:

```bash
swift build --build-tests --disable-default-traits   # cheap compile gate
scripts/test.sh --filter <OnlyAffectedSuite> --disable-default-traits --skip-update
```

This is a **spike gate**, not the pre-push gate. Use it only when:
- The diff touches one module (e.g. only `BaseChatBackends`), AND
- You've run the full suite once already on this branch and the change since then is bounded (e.g. fixing a CI failure, addressing a single review comment).

The full two-invocation gate above is mandatory before the **final push** of a branch and after any rebase.

### Trait-combo build sweep (only when needed)

A full-traits build is needed only when a PR adds/modifies a switched enum in a trait-gated file (per past incidents where default-trait build missed CloudSaaS/Ollama-gated cases):

```bash
swift build --build-tests --traits MLX,Llama,MCPBuiltinCatalog,Ollama,CloudSaaS,HuggingFace
```

Skip it for pure logic/test changes that don't touch enum surfaces.

When changing behavior of any function or type, grep for ALL test references across the entire `Tests/` directory, not just the obvious test file. Behavior changes require updating every test that asserts on the old behavior:

```bash
grep -r "functionOrTypeName" Tests/
```

CI runs on macOS (10x billing multiplier). Each failed push wastes ~25 billed minutes. Test locally first.

## Error handling in recoverable paths

Never use `assertionFailure` or `fatalError` for conditions that have fallback logic. These trap in debug builds (including `swift test`), crashing the test process even when tests pass. Use `Log.*` warnings instead. Reserve `assertionFailure` for true programmer errors with no recovery path.

## Commit style

This repo uses Conventional Commits. Release Please reads these to determine version bumps and generate the changelog.

```
feat: add streaming cancellation to FoundationBackend
fix: prevent context overflow when system prompt exceeds budget
perf: cache tokenizer lookups in ContextWindowManager
test: add XCTMeasure baselines for trimMessages hot path
chore: update mlx-swift-lm to 2.31.0
docs: clarify TokenizerProvider fallback behaviour
```

- `feat` → MINOR bump
- `fix` → PATCH bump
- Everything else → no release
- `BREAKING CHANGE:` in the commit footer → MAJOR bump

**Enforced surface: PR titles.** All PRs squash-merge, so Release Please reads the *PR title*, not the individual commit messages on the branch. CI lints the PR title via `amannn/action-semantic-pull-request`. Individual commit messages on a feature branch should follow the same format as a matter of habit, but they are not linted and can be rewritten freely during review.

## Release workflow

Release Please auto-creates a release PR after `feat:` or `fix:` merges. The auto-generated one-liner bullets **must be rewritten before merging** — a pre-merge hook and the `changelog-lint` CI job both block the merge until this is done.

BaseChatKit uses a **Prisma-style Highlights format** for release notes (adopted v0.11.2, PR #649). Structure:

```markdown
## [X.Y.Z](https://…/compare/vA.B.C...vX.Y.Z) (YYYY-MM-DD)

### Highlights

#### Short verb-led headline

2–3 sentences: the problem, what shipped, how it fits together.

` ` `swift
// 4–8 lines showing the new API in use
` ` `

One more sentence of caveats or opt-in/out semantics.

See [#N], [#M].

### Features

- **scope:** what changed ([#N])

### Fixes

- **scope:** what changed — why it matters ([#N])
```

Aim for 1–3 Highlights (one per headline theme). Each Highlight gets a short prose paragraph and a runnable code snippet if it introduces or changes a public API. Small features and routine fixes live as one-line bullets in the Features/Fixes sections below. Pre-0.11.2 releases stay in their original `**Bold title** —` prose format — don't retrofit.

### Workflow steps

1. Release Please opens PR titled `chore(main): release X.Y.Z`.
2. Check out the release branch via the existing worktree at `.claude/worktrees/agent-ae95b0e8` (branch `release-please--branches--main`) — or create a fresh worktree. Do **not** `git checkout` the branch in the main repo; it's held by that worktree.
3. Rewrite the CHANGELOG.md entry in the Prisma format above. Use the `## Release Note` sections of the included `feat:`/`fix:` PRs as source material — they're written at PR time when context is fresh.
4. Amend the Release Please commit and force-push: `git commit --amend --no-edit && git push --force-with-lease`.
5. Merge the release PR. The release PR's `gh pr merge` is blocked by a hook on unrewriten CHANGELOGs — once the rewrite is in, merge via `gh api -X PUT repos/roryford/BaseChatKit/pulls/<N>/merge -f merge_method=squash`.
6. The `sync-release-notes` workflow copies the CHANGELOG section into the GitHub release body on merge. If you retroactively edit CHANGELOG later, resync manually: `awk '/^## \[/{n++; if(n==2) exit} n==1' CHANGELOG.md > /tmp/body.md && gh release edit vX.Y.Z --notes-file /tmp/body.md`.

### `changelog-lint` rules

The CI lint rejects auto-generated output and requires evidence of a manual rewrite. The regex accepts either format:

- `^### ` (Prisma-style subheading — the default since v0.11.2)
- `^\*\*[^*]+\*\* — ` (bold title + em-dash prose — legacy, still accepted)

The lint also rejects any `* lowercase` Release Please bullet that slips through unrewriten.

## PR workflow

All changes go through PRs — direct pushes to `main` are blocked for everyone.

1. Branch off `main`
2. Write code, commit with conventional commits
3. Open a PR: `gh pr create --title "feat: ..." --body "..."`
4. Report the PR URL — the maintainer reviews and merges manually
5. Do NOT pass `--auto` or `--merge` — merges require human approval

CI must pass (`BaseChatCoreTests` + `BaseChatRuntimeTests` + `BaseChatPersistenceSwiftDataTests` + `BaseChatInferenceTests` + `BaseChatInferenceSwiftTestingTests` + `BaseChatUITests` + `BaseChatUIModelManagementTests` + `BaseChatMCPTests` + `BaseChatBackendsTests` + `BaseChatTestSupportTests` + `BaseChatAppIntentsTests`) before merge is allowed.

`BaseChatBackendsTests` runs in CI without hardware traits — only cloud backend and SSE tests execute; MLX and Llama tests are excluded by `#if MLX`/`#if Llama` conditional compilation. Run with `--traits MLX,Llama` locally on Apple Silicon before merging backend changes. `BaseChatE2ETests` requires physical hardware and does not run in CI.

## Issue & PR hygiene

CI is macOS-only (10× billing) and runs ~5 minutes per push. Each unnecessary PR or issue costs real money and the maintainer's attention. The default is **fewer, larger units of work**.

### Don't open GitHub issues for follow-ups, phases, or "while I'm here" cleanups

The issue tracker is for things that need cross-session memory **and** external visibility (real bugs, real feature asks, things a future contributor would search for). It is **not**:

- A scratchpad for ideas surfaced during a session.
- Cross-session memory for Claude Code (use the memory system or `TODO.md` instead).
- A pre-written list of PR titles waiting to be opened.
- A way to track sub-phases of a larger effort (use a checklist on the parent issue).

If you find yourself wanting to open more than **one** issue in a session, stop. Either fold the work into the current PR, add it as a checkbox on an existing tracking issue, or leave a `// TODO:` comment in the code. Don't ask the user "should I open an issue for this?" — default to no.

When an issue genuinely is needed, the bar is: would an external contributor benefit from seeing this in the open queue? If no, don't open it.

### One feature = one PR, even across backends

A change like "tool calling" or "thinking budget" touches MLX + Llama + Foundation + Cloud + fixtures. Ship it as **one PR with a backend checklist in the body**, not five PRs. Per-backend fan-out drove past PR storms (15–24 PRs in a day). Reviewers see the cross-cutting types once, CI runs once.

Exceptions: when one backend is genuinely blocked (e.g., waiting on an upstream fix), ship the unblocked backends and add a `track:` comment on the umbrella issue listing what's left.

### Tests and docs ship in the feature PR

Don't open standalone `test:` or `docs:` PRs for in-flight features. Acceptance tests belong in the PR that introduces the capability — splitting them costs CI minutes and invents merge conflicts. The same applies to demo scenarios that exercise a new capability: they ship with the capability, not as a follow-up.

Standalone `test:`/`docs:` PRs are appropriate only for already-shipped features (e.g., adding coverage for a corner case discovered later, or rewriting prose that's now wrong).

### Single-file PRs are a smell

Before opening a PR that touches one file, check whether there's a sibling PR you could batch into. If you've opened 3+ single-file PRs in a row, the third should have been part of the first.

### Tracking issues

When work genuinely needs to be split across multiple PRs (e.g., depends on a prerequisite landing first), use **one** tracking issue with a checklist of PR-sized batches. Don't open one issue per batch. Existing tracking umbrellas:

- #753 — tool calling coordinated rollout
- #754 — demo-picker test-suite matrix
- #755 — fuzz harness v2

Add to these instead of creating new umbrellas in the same area.
