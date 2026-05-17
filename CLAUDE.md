# ManifoldKit — Claude Code Instructions

## Targets

| Target | Role | ML deps |
|--------|------|---------|
| `ManifoldKit` | Umbrella library that re-exports `ManifoldInference` + `ManifoldRuntime` + `ManifoldPersistenceSwiftData` + `ManifoldBackends` + `ManifoldUI` so app code can `import ManifoldKit` instead of stitching together 4–6 imports. Specialised modules (UIModelManagement, MCP, Voice, …) stay explicit imports. | None |
| `ManifoldInference` | Inference orchestration — backend protocols, generation events, prompt assembly, conversation records (no persistence ports) | None |
| `ManifoldMCP` | Model Context Protocol client surface, descriptors, tool bridge (`MCPClient`, `MCPToolSource`) | None |
| `ManifoldRuntime` | Persistence ports (`MessageStore`, `SessionStore`, `EndpointStore`, `SamplerPresetStore`, `BenchmarkCache`), use cases (`PromptContextPipeline`, `ChatExportService`, `SessionListService`, `ConversationRuntime`), and session-list orchestration | None |
| `ManifoldPersistenceSwiftData` | SwiftData schema, `@Model` types, container factory, adapter implementations, and the full-stack `ManifoldBootstrap` | None |
| `ManifoldCloudCore` | Shared SSE / TLS-pinning / DNS-rebind / URLSession infrastructure (`SSECloudBackend`, `PinnedSessionDelegate`, `DNSRebindingGuard`, `URLSessionProvider`, `CloudErrorSanitizer`, `ThinkingBlockManager`) | None |
| `ManifoldMLX` | MLX inference backend, resource arbiter, capability probe, MLX tool dialect (depends on `ManifoldInference`) | MLX |
| `ManifoldLlama` | llama.cpp (GGUF) inference, generation driver, embedding backend, GGUF tool-call parser (depends on `ManifoldInference`) | LlamaSwift |
| `ManifoldFoundation` | Apple Foundation Models bridge — gated by OS availability (iOS 26 / macOS 26+), no trait | None |
| `ManifoldCloud` | SaaS + LAN cloud backends: OpenAI Chat Completions, OpenAI Responses, Anthropic Claude, Ollama (depends on `ManifoldCloudCore`) | None |
| `ManifoldBackends` | Umbrella re-export module backed by `Sources/ManifoldBackendsUmbrella/`. Hosts cross-family glue (`DefaultBackends`, per-family `BackendRegistrar` conformances) and `@_exported import`s the four family targets so existing `import ManifoldBackends` consumers keep compiling. | MLX, LlamaSwift |
| `ManifoldUI` | SwiftUI chat-runtime views and view models (chat-only consumer stops here) | None |
| `ManifoldUIModelManagement` | Model browser/download/storage UI + cloud API endpoint editors | None |
| `ManifoldVoice` | Optional speech I/O adapters and voice composer accessory (depends on `ManifoldUI`) | None |
| `ManifoldTestSupport` | Shared mocks and fakes (`MockInferenceBackend`, `CharTokenizer`, etc.) | None |
| `ManifoldMLXIntegrationTests` | Xcode-only real MLX model E2E tests | MLX |

**Dependency rules:** Never import any backend family target (or the `ManifoldBackends` umbrella) from UI; never import `ManifoldUIModelManagement` from `ManifoldUI` (CI lint enforces this). `ManifoldUIModelManagement` depends on `ManifoldUI` — cycle dissolved by closure-injecting `APIConfigurationView` via `@ViewBuilder` parameter. The four family targets (`ManifoldMLX`, `ManifoldLlama`, `ManifoldFoundation`, `ManifoldCloud`) and `ManifoldMCP` depend on `ManifoldInference` directly (not `ManifoldRuntime`), keeping them free of SwiftData. `ManifoldCloud → ManifoldCloudCore` is unconditional (always linked together); the consumer→family edge is trait-gated (`MLX` for `ManifoldMLX`, `Llama` for `ManifoldLlama`, `CloudSaaS || Ollama` for `ManifoldCloud`; `ManifoldCloudCore` and `ManifoldFoundation` are always linked). The umbrella `ManifoldBackends` re-exports each family conditionally so `import ManifoldBackends` keeps working in any trait combination. `MCPCatalog` descriptors are trait-gated behind `MCPBuiltinCatalog`.

## Running tests

Use `scripts/test.sh` — it runs configured suites and prints an honest summary. Key flags:
- `--disable-default-traits` — excludes MLX/Llama/hardware-gated tests (required for CI)
- `--skip-update` — skips per-invocation git-remote contact (drop only if you edited Package.swift)
- `--traits MLX,Llama,MCPBuiltinCatalog,Ollama,CloudSaaS,HuggingFace` — for full-traits builds

**Special cases:**
- MLX integration tests require Xcode (Metal shaders): `scripts/test-mlx-integration.sh`
- Swift Testing must run in a separate process from XCTest (mixing causes libmalloc SIGABRT — see #681)
- MCP E2E: `RUN_MCP_E2E=1 swift test --traits MCP --filter ManifoldMCPE2ESmokeTests` — `MCP` isn't in the default trait set (defaults are MLX/Llama/HuggingFace), so the trait flag is required or the filter matches zero compiled tests and the build emits `error: fatalError`. Filter to the streamable suite; `EverythingServerSmokeTests` has hung 28+ min in past runs.
- Ollama E2E requires Ollama at localhost:11434 and `--traits Ollama` (dropped from defaults in v2.0)
- Llama: in-process runs are safe — `LlamaBackendProcessLifecycle` latches `llama_backend_init` exactly once per process (was a per-class isolation script pre-#1319)
- `ManifoldE2ETests`: bare form `swift test --filter ManifoldE2ETests --disable-default-traits` runs the full suite; for narrower targeting anchor the regex (`--filter 'ManifoldE2ETests\.'` then test name). Bare-vs-anchored behavior shifted in swift-test post-v2.

## Test conventions

For trait conventions, suite layout, classification (Unit / Integration / E2E), and the per-backend conformance walkthrough, see [`Tests/README.md`](Tests/README.md). It is the canonical entry point for "how do I add a backend / test / suite?".

- Use `XCTestCase` for new tests; match `@Suite`/`@Test` in files that already use Swift Testing.
- A test that hits SwiftData is an integration test — name and place it accordingly.
- Do not mock the persistence layer. Use in-memory SwiftData stores.
- Async tests: use real `async/await`. Use `XCTestExpectation`/`XCTWaiter` with tight deadlines for callback-based code only.
- After asserting an expected outcome, add a sabotage check to confirm the test fails when the code path breaks. Remove before committing.
- `withKnownIssue` is test debt. Every use requires `// FIXME: <issue URL>` above it. Never in critical E2E paths.
- Never call `MockURLProtocol.reset()` across suites — `canInit(with:)` returns true whenever any stubs are registered (global state). Use UUID-based hostnames per suite (`http://ollama-\(UUID()).test`) to isolate stubs instead.

## Service sharing

`ChatViewModel.inferenceService` is `internal`. Sibling modules read from `ChatViewModel.modelRegistry` (a `@MainActor @Observable ModelRegistry`). Apps needing the same `InferenceService` in multiple components create it at the app level and inject via constructor. Do not widen `inferenceService` past `internal`.

## Turn-loop orchestration

`ConversationRuntime` (`Sources/ManifoldRuntime/Services/ConversationRuntime.swift`) is the single turn loop — owns `send`, `regenerate`, `edit`, `cancel`, and `branch`. No alternative path. Host apps get a configured runtime via `ManifoldBootstrap` and forward user actions to it.

## Coding conventions

- **Concurrency**: async/await throughout. No Combine, no callback pyramids.
- **Observable state**: `@Observable` + `@MainActor`. Not `ObservableObject`/`@Published`.

### Swift 6 concurrency gotchas

These patterns either produce `#SendingRisksDataRace` in strict Swift 6 builds or compile while hiding a real race. Fix the isolation boundary instead of silencing the compiler.

1. **Non-isolated `async` helpers that receive `@MainActor`-capturing closures.** A `with*` helper whose body is `() async throws -> R` sends the closure away from the caller's actor. When the body closes over `@MainActor` state, annotate the closure explicitly, for example `try await withErrorHandler({ ... }) { @MainActor in try await container.generate(...) }`. Watch `withTaskGroup`, `withCheckedContinuation`, and pre-Swift-6 library helpers.
2. **`@unchecked Sendable` is not a race fix.** A mutable capture box such as `final class Capture: @unchecked Sendable { var message: String? }` is only safe for synchronous same-thread callbacks read back immediately on the same actor. For escaping callbacks or C/library callbacks that can fire on another thread, use an `actor` or a real lock (`OSAllocatedUnfairLock`/`Mutex` where available).
3. **`@preconcurrency import` is narrow.** It can suppress missing `Sendable` annotations from older libraries, but it does not suppress region-based isolation errors such as the non-isolated closure-sending pattern above. Do not use it as a blanket Swift 6 escape hatch.
4. **`AsyncStream<T>` inherits `T`'s sendability.** `AsyncStream<Generation>` is `Sendable` only while `Generation` is. If an upstream library adds a non-`Sendable` field, errors often appear at call sites; keep explicit stream annotations like `let stream: AsyncStream<Generation> = ...` so failures point at the declaration.
5. **Never use `Task.detached` inside `@MainActor` classes.** `Task { }` inherits the current actor; `Task.detached { }` does not, and the compiler may not warn when it captures mutable `@MainActor` properties. Use `Task { }` and let the callee hop off-actor for expensive non-UI work.
6. **Never block in `deinit` under `@MainActor` ownership.** `DispatchSemaphore.wait()` in `deinit` either freezes the UI or deadlocks the actor. For async C cleanup, mirror `LlamaBackend`'s retain/detach/release pattern: capture the resource strongly into a `Task.detached`, hop off-actor, then release.

- **Persistence**: SwiftData only. No CoreData.
- **Error handling**: validate at system boundaries only. Don't guard internal invariants the type system already enforces.
- **Comments**: explain *why*, not *what*.
- **Inject `UserDefaults`.** Production code must accept `userDefaults: UserDefaults = .standard` rather than touching `UserDefaults.standard` directly. `swift test --parallel` (default in CI as of v0.16.1) makes shared-instance access flaky. Bitten twice: #734, #761.
- **Trait gating: gate consumer→library edges, not library→library.** Wrap `M-Tests → M` and `cli-using-M → M` package edges in `.when(traits: ["M"])`. Do NOT gate `M → L` while `M`'s sources still import `L` unconditionally. `PackageTraitGateAuditTest` is a tripwire but doesn't catch every shape — sweep with the trait-combo build below when adding a trait.

## Platform policy

ManifoldKit targets **n-1**: the current Apple OS release and the one immediately before it.

| Platform | Current (n) | Minimum (n-1) |
|----------|-------------|---------------|
| macOS    | 26          | 15            |
| iOS      | 26          | 18            |

When Apple ships a new major OS each September, bump both minimums and remove `#available` guards added for the previous floor. Do not use `Atomic`, `OSAllocatedUnfairLock`, or other APIs that post-date the minimum without checking their availability.

**`swift-tools-version` ceiling = installed Xcode toolchain.** Xcode 26.x ships Swift 6.2.x, not 6.3 — bumping the tools version above what CI runners have breaks `resolve-check` and `fuzz`.

## Hardware constraints (simulator / CI)

- `LlamaBackend` uses a global `llama_backend_init` — only one instance per process. Tests must share a single instance or use `MockInferenceBackend`.
- Metal is unavailable in the simulator. Gate any `MLXBackend`/`LlamaBackend` test with `XCTSkipIf`.
- `FoundationBackend` requires iOS 26 / macOS 26. Gate accordingly.
- Context window capped at 512 tokens in the simulator to avoid OOM.
- `MLX.Memory.cacheLimit` / `clearCache()` require the metallib. Calling them without a successful `loadModelContainer` triggers "Failed to load default metallib" and aborts the test process. Guard on container presence as the proxy.

## Tooling

| Script | Purpose |
|--------|---------|
| `scripts/test.sh` | Runs configured Swift test suites and prints an honest summary. |
| `scripts/example-ui-tests.sh` | `build-for-testing` / `test-without-building` for Example app XCUITests. |
| `scripts/clean-leaked-test-artifacts.sh` | Removes test fixtures that leaked into `~/Documents/Models/`. |
| `scripts/clean-build.sh` | Full `.build` wipe + `swift package resolve`. Use when builds fail with "XCFramework Info.plist not found" or other `workspace-state.json` desync errors after changing the trait set. |
| `scripts/fuzz.sh` | Runs the ManifoldFuzz harness (default: 5 min against Ollama). |
| `scripts/test-mlx-integration.sh` | Runs `ManifoldMLXIntegrationTests` with discovery env vars patched into `.xctestrun`. Use instead of bare `xcodebuild test`. See #986. |
| `scripts/test-ios-simulator.sh` | Runs `ModelContainerFileProtectionTests` on an iOS Simulator via xcodebuild. Required because `NSFileProtection*` is an iOS-only kernel feature skipped by the macOS `swift test` lane. |

**SwiftPM local-package consumers need explicit `name:`.** When adding `.package(path: ...)` references (worktrees, cold-start gates, scratch consumers), pass `name: "ManifoldKit"` explicitly — `.package(path:)` derives identity from the last path component, which breaks under non-default checkout paths.

## Pre-push checklist

Run the same two-invocation shape CI uses (see `.github/workflows/ci.yml`). Running each suite as a separate `swift test` call is ~4–5× slower — don't do it.

```bash
# 1. XCTest suites
scripts/test.sh --filter ManifoldCoreTests --filter ManifoldRuntimeTests \
  --filter ManifoldPersistenceSwiftDataTests --filter ManifoldUITests \
  --filter ManifoldUIModelManagementTests --filter ManifoldMCPTests \
  --filter ManifoldBackendsTests --filter ManifoldInferenceTests \
  --filter ManifoldTestSupportTests --filter ManifoldAppIntentsTests \
  --filter ManifoldServerTests \
  --disable-default-traits --skip-update

# 2. Swift Testing — separate process (mixing with XCTest causes libmalloc SIGABRT — #681)
scripts/test.sh --filter ManifoldInferenceSwiftTestingTests \
  --disable-default-traits --skip-update
```

**Spike gate** (bounded changes only): `swift build --build-tests --disable-default-traits` then run only the affected suite. Valid only when the diff touches one module and you've run the full suite once already on this branch. Full two-invocation gate is mandatory before the final push and after any rebase.

**Trait-combo sweep** (whenever modifying a switched enum, a `GenerationEvent` / `GenerationConfig` / `BackendCapabilities`-shaped type, or any trait-gated source file):
```bash
swift build --build-tests --traits MLX,Llama,Ollama,CloudSaaS,MCP,MCPBuiltinCatalog,HuggingFace,Fuzz
```
Default-trait builds won't catch CloudSaaS- or Ollama-gated switch exhaustiveness. The all-traits-on `--build-tests` is the cheapest single check.

CI runs on macOS (10× billing). Each failed push wastes ~25 billed minutes. Test locally first.

When changing behavior of any function or type, grep for ALL test references across `Tests/` — not just the obvious test file.

## Error handling

Never use `assertionFailure`/`fatalError` for conditions that have fallback logic — they trap in `swift test`. Use `Log.*` warnings. Reserve `assertionFailure` for true programmer errors with no recovery path.

`try?` is banned in production code. `SilentCatchAuditTest` (in `ManifoldInferenceTests`) fails CI if `try?` appears in error-propagation paths. Use `do/catch` with `Log.*` so the error is visible. Optional decoding at trust boundaries is the only legitimate exception.

## Commit style

Conventional Commits. Release Please reads these for version bumps.

```
feat: add streaming cancellation to FoundationBackend
fix: prevent context overflow when system prompt exceeds budget
perf: cache tokenizer lookups in ContextWindowManager
test: add XCTMeasure baselines for trimMessages hot path
chore: update mlx-swift-lm to 2.31.0
```

- `feat` → MINOR, `fix` → PATCH, `BREAKING CHANGE:` footer → MAJOR, everything else → no release
- **CI lints PR titles** (squash-merge means Release Please reads the PR title, not branch commits). Individual branch commits should follow the format but aren't linted.

## Release workflow

Release Please auto-creates a release PR after `feat:`/`fix:` merges. The auto-generated bullets **must be rewritten** before merging — `changelog-lint` CI and a pre-merge hook both block until done.

Use **Prisma-style Highlights format** (adopted v0.11.2, PR #649): `### Highlights` with short verb-led headlines, 2–3 sentences of context, and a runnable code snippet for new/changed public APIs. Small features and fixes go as one-line bullets under `### Features`/`### Fixes`. Pre-0.11.2 entries stay in their original format.

Workflow: check out the release branch via its worktree, rewrite CHANGELOG.md, amend + force-push, then merge via `gh api -X PUT repos/roryford/ManifoldKit/pulls/<N>/merge -f merge_method=squash`.

`README.md` install-pin examples (`from: "x.y.z"`) are bumped automatically by Release Please via the `extra-files` entry in `release-please-config.json` — do not update them manually between releases.

`changelog-lint` accepts: `^### ` (Prisma subheading) or `^\*\*[^*]+\*\* — ` (legacy bold+em-dash). Rejects any unrewritten `* lowercase` Release Please bullet.

## PR workflow

All changes go through PRs — direct pushes to `main` are blocked.

1. Branch off `main`, commit with conventional commits
2. `gh pr create --title "feat: ..." --body "..."`
3. Report the PR URL — maintainer reviews and merges manually
4. Do NOT pass `--auto` or `--merge`

CI must pass all suites before merge. `ManifoldBackendsTests` runs without hardware traits in CI — run with `--traits MLX,Llama` locally before merging backend changes.

## Issue & PR hygiene

CI is macOS-only (10× billing), ~5 min per push. Default is **fewer, larger units of work**.

- **Don't open issues for follow-ups, phases, or "while I'm here" cleanups.** The tracker is for real bugs and feature asks with external visibility. Use `TODO.md` or code comments for cross-session notes. Default to no when considering opening an issue.
- **One feature = one PR across all backends.** Don't fan out per-backend (past storms hit 15–24 PRs/day). Ship as one PR with a backend checklist in the body.
- **Tests and docs ship in the feature PR**, not as follow-ups.
- **Single-file PRs are a smell.** Batch them.
- **Tracking issues**: use one issue with a checklist for multi-PR work. Existing umbrellas: #753 (tool calling), #754 (demo-picker test matrix), #755 (fuzz harness v2). Add to these rather than creating new ones in the same area.
