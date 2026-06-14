# ManifoldKit — Claude Code Instructions

## Targets

No target in this repo has heavy ML dependencies — the MLX and llama.cpp families live in companion packages since v0.48 (see "Companion packages" below).

### Core / leaf modules (no SwiftData)

| Target | Role |
|--------|------|
| `ManifoldNetworking` | Leaf networking primitives (P1a #1608): `NetworkActivity` observability funnel, `PrivateIPClassifier`. Pure Foundation, zero upward deps. |
| `ManifoldSecrets` | Leaf security primitives (P1b #1609): `KeychainService`, `SecureEnclaveKeyManager`, `SecureBytes`. Pure Security framework, zero upward deps. |
| `ManifoldHardware` | Leaf device-capability + GGUF primitives (P1c #1610): device probing, memory-pressure broadcasting, GGUF parsing, load-plan logic. Zero deps. |
| `ManifoldModelCatalog` | Model discovery/catalog/benchmark + image/video-gen records (P1d #1611): `ModelInfo`, `ModelManifest`, `ModelCatalog`, `ModelStorageService`, `DiagnosticsService`, `SettingsService`, `ModelBenchmarkRunner`. Depends on `ManifoldHardware`, `ManifoldNetworking`, `ManifoldSecrets`. |
| `ManifoldContract` | The Contract kernel (P2a #1719): backend protocols (`InferenceBackend`, `EmbeddingBackend`), value/stream types (`GenerationConfig`, `GenerationEvent`, `Message`, `ToolDefinition`/`ToolCall`/`ToolResult`, streaming transforms). Depends on `ManifoldHardware` + `ManifoldModelCatalog` (`@_exported import`s both). Must NOT depend on `ManifoldInference` — `ManifoldContractNoEngineDependencyTests` is the tripwire. |

### Inference engine + runtime

| Target | Role |
|--------|------|
| `ManifoldInference` | Inference orchestration engine: `InferenceService`, `GenerationQueue`, `ModelRegistry`, tool subsystem (`ToolExecutor`, `ToolRegistry`, `GenerationToolDispatchLoop`), `PromptAssembler`, `ContextWindowManager`, `TranscriptHealer`, streaming. Depends on `ManifoldContract` (which it `@_exported import`s for source compatibility) + the four P1 leaves. No persistence ports. |
| `ManifoldRuntime` | Persistence ports (`MessageStore`, `SessionStore`, `EndpointStore`, `SamplerPresetStore`, `BenchmarkCache`, `WebSearchRuntime`), use cases (`PromptContextPipeline`, `ChatExportService`, `SessionListService`, `ConversationRuntime`), and session-list orchestration. Depends on `ManifoldInference`. |
| `ManifoldPersistenceSwiftData` | SwiftData schema, `@Model` types, container factory, adapter implementations, and the full-stack `ManifoldBootstrap`. |

### Backend families (inlets)

| Target | Role |
|--------|------|
| `ManifoldFoundation` | Apple Foundation Models bridge — gated by OS availability (`#if canImport(FoundationModels)`, iOS 26 / macOS 26+), no trait. Depends on `ManifoldContract` + `ManifoldInference` (the `FoundationBackends` registrar, relocated here in P7, needs the engine). |
| `ManifoldOllama` | Ollama (self-hosted / LAN) backend family: `OllamaBackend`, model list/probe services, NDJSON stream extractor, `OllamaBackends` registrar. Compiles unconditionally with unconditional consumer edges (the `Ollama` trait was retired in v0.48 PR A4). Depends on `ManifoldContract` + `ManifoldCloudCore`. Split out of `ManifoldCloud` in v0.48 (PR A1). |
| `ManifoldCloudSaaS` | SaaS backend family: Anthropic Claude, OpenAI Chat Completions, OpenAI Responses, LM Studio / custom OpenAI-compatible endpoints, `CloudSaaSBackends` registrar. Compiles unconditionally with unconditional consumer edges (the `CloudSaaS` trait was retired in v0.48 PR A4). Depends on `ManifoldContract` + `ManifoldCloudCore`. Split out of `ManifoldCloud` in v0.48 (PR A1). |
| `ManifoldCloud` | **Retired in P7 (#1837).** The re-export shim is gone — `import ManifoldCloud` no longer compiles. Import `ManifoldCloudCore` + the provider family (`ManifoldOllama` / `ManifoldCloudSaaS`), or the `ManifoldKit` umbrella. `DefaultWebSearchRuntime` moved to `ManifoldCloudCore`. See docs/MIGRATION-shims-retired.md. |
| `ManifoldCloudCore` | Shared SSE / TLS-pinning / DNS-rebind / URLSession infrastructure (`SSECloudBackend`, `PinnedSessionDelegate`, `DNSRebindingGuard`, `URLSessionProvider`, `CloudErrorSanitizer`, `ThinkingBlockManager`) plus the provider-agnostic encoding/parsing surface shared by both cloud families (`CloudMessageEncoder`, `CloudPayloadHandler`, `CloudHTTPProviderAdapter`, OpenAI-compatible Chat Completions parsing), and (since P7) `DefaultWebSearchRuntime` — the `WebSearchRuntime` port conformance relocated from the retired `ManifoldCloud` shim. Always linked; compiles unconditionally since v0.48 removed its trait gates. Depends on `ManifoldInference` + `ManifoldRuntime` (the latter for `DefaultWebSearchRuntime`'s port conformance — an un-gated library→library edge; see Package.swift comment). |
| `ManifoldBackends` | **Retired in P7 (#1837).** The umbrella re-export shim and its `DefaultBackends` cross-family glue are gone — `import ManifoldBackends` no longer compiles. Import the families directly (`ManifoldFoundation` / `ManifoldOllama` / `ManifoldCloudSaaS`) or the `ManifoldKit` umbrella; pass an explicit registrar list to `ManifoldKit.quickStart(backends:)` (or call `OllamaBackends`/`CloudSaaSBackends`/`FoundationBackends` `.register(with:)`) instead of `DefaultBackends.register(...)`. See docs/MIGRATION-shims-retired.md. |
| `ManifoldAnyLanguageModel` | AnyLanguageModel provider bridge (`AnyLanguageModelBackend` + URL resolver) for providers without a native backend — Gemini, xAI, Groq, Mistral, OpenRouter. Own product since v0.48 (PR A5; the `AnyLanguageModel` trait is retired); unconditional dep on the external AnyLanguageModel package; opt in by importing. Depends on `ManifoldInference`. |

**Companion packages (v0.48, PR C2 / #1749):** the heavy local-inference families live outside this repo. [`roryford/manifold-mlx`](https://github.com/roryford/manifold-mlx) hosts the MLX backend family (text inference, diffusion/image gen, video gen, vendored FluxSwift/StableDiffusion, MLX integration tests); [`roryford/manifold-llama`](https://github.com/roryford/manifold-llama) hosts the llama.cpp/GGUF family. Module names stay `ManifoldMLX` / `ManifoldLlama`. Consumers add the companion `.package(...)` and pass registrars: `try await ManifoldKit.quickStart(backends: [LlamaBackends.self])`. Their conventions, hardware constraints, and test docs live in those repos.

### MCP + tool + app-extension modules

| Target | Role |
|--------|------|
| `ManifoldMCP` | Model Context Protocol client surface, descriptors, transports, OAuth, tool bridge (`MCPClient`, `MCPToolSource`). Compiles unconditionally — the `MCP` and `MCPBuiltinCatalog` traits were retired in v0.48 (catalog descriptors included). Depends on `ManifoldInference`. |
| `ManifoldMCPHost` | Runtime-backed MCP server boundary: exposes sessions, messages, RAG documents, and send-message tools to external MCP clients. Depends on `ManifoldMCP` + `ManifoldRuntime`. |
| `ManifoldTools` | End-to-end tool-calling validation harness: fixed reference toolset, declarative scenario runner, JSONL transcript logger. Depends on `ManifoldInference`. |
| `ManifoldAppIntents` | AppIntent ↔ ToolDefinition bridge. Depends on `ManifoldInference`. |
| `ManifoldSkills` | Claude-Code-compatible SKILL.md filesystem discovery and `invoke_skill` dispatcher (macOS-only via `#if os(macOS)`). Depends on `ManifoldInference` + `ManifoldRuntime`. |
| `ManifoldMacrosPlugin` | Swift macro compiler plugin implementing `@ToolSchema`. Runs at build time (not linked into app binaries). Trait-gated behind `Macros` (off by default) to keep swift-syntax's ~647 files out of default builds. |

### UI modules

| Target | Role |
|--------|------|
| `ManifoldUI` | SwiftUI chat-runtime views and view models (chat-only consumer stops here). Depends on `ManifoldRuntime` + `ManifoldInference`. |
| `ManifoldUIModelManagement` | Model browser/download/storage UI + cloud API endpoint editors. Depends on `ManifoldUI` + `ManifoldRuntime` + `ManifoldInference` + `ManifoldHuggingFace`. |
| `ManifoldVoice` | Optional speech I/O adapters and voice composer accessory. Depends on `ManifoldUI`. |

### Discovery + server + fuzz

| Target | Role |
|--------|------|
| `ManifoldHuggingFace` | HuggingFace Hub search, browse, and download integration. Compiles unconditionally — the `HuggingFace` trait was retired in v0.48 (PR C2). Depends on `ManifoldInference`. |
| `ManifoldServer` | OpenAI-compatible HTTP server executable (Hummingbird). Trait-gated behind `Server`. |
| `ManifoldFuzz` | Fuzzing engine: corpus, runner, capture, detectors, sink. Backend-agnostic; depends on `ManifoldInference`. |
| `ManifoldFuzzBackends` | Real-backend factory shim for `fuzz-chat` (Ollama / OpenAI / Foundation — the MLX/Llama factories moved to the companion packages). Depends on `ManifoldFuzz` + `ManifoldInference` + the backend families (`ManifoldFoundation` / `ManifoldOllama` / `ManifoldCloudSaaS`). Unconditional since the `Fuzz` trait retired (PR C2). |
| `fuzz-chat` | Executable driver for fuzz campaigns against Ollama / OpenAI / Foundation / mock / chaos (default backend: ollama). Compiles unconditionally. Run via `scripts/fuzz.sh`. |
| `manifold-tools` | CLI executable for running tool-call validation scenarios from `ManifoldTools`. Links `ManifoldOllama` directly (the now-retired `ManifoldBackends` umbrella was deliberately never used here — #982 dual-llama Xcode-scheme hazard). |

### Test support targets

| Target | Role |
|--------|------|
| `ManifoldTestSupport` | Shared mocks and fakes (`MockInferenceBackend`, `CharTokenizer`, etc.). No XCTest dependency (see `ManifoldContractTestSupport`). Published as a `.library` product so companion backend packages (manifold-mlx / manifold-llama, #1749) can reuse the mocks. |
| `ManifoldContractTestSupport` | XCTest-dependent protocol contract mixins. Kept separate from `ManifoldTestSupport` so `fuzz-chat` can depend on the latter without pulling XCTest into a non-test binary (PR #1409). |
| `ManifoldBackendTestKit` | Importable backend contract-check machinery (`BackendContractChecks`, backend contract mixins, `FixtureComparator`, local-backend contract runner). Published as a `.library` product for companion backend packages. Links XCTest — same #1409 constraint as `ManifoldContractTestSupport`: never depend on it from an executable target (audit-enforced). Contract suites that use the capability-claims registry must NOT run under `swift test --parallel` (process-global registry — see its DocC catalog). |

### Umbrella

| Target | Role |
|--------|------|
| `ManifoldKit` | Umbrella re-export so app code can `import ManifoldKit` instead of stitching together 4–6 imports. Re-exports `ManifoldInference` + `ManifoldModelCatalog` + `ManifoldRuntime` + `ManifoldPersistenceSwiftData` + the backend families (`ManifoldFoundation` / `ManifoldOllama` / `ManifoldCloudSaaS` / `ManifoldCloudCore`) + `ManifoldUI` + `ManifoldSkills`. Specialised modules (UIModelManagement, MCP, Voice, AppIntents, …) stay explicit imports. |

**Dependency rules:** Never import any backend family target (`ManifoldFoundation` / `ManifoldOllama` / `ManifoldCloudSaaS`) from UI; never import `ManifoldUIModelManagement` from `ManifoldUI` (CI lint enforces this). `ManifoldUIModelManagement` depends on `ManifoldUI` — cycle dissolved by closure-injecting `APIConfigurationView` via `@ViewBuilder` parameter.

**Backend family deps (post-P2a #1719, post-v0.48 C2, post-P7 #1837):** `ManifoldOllama` and `ManifoldCloudSaaS` compile against `ManifoldContract` + `ManifoldCloudCore` without touching the engine directly; `ManifoldFoundation` compiles against `ManifoldContract` + `ManifoldInference` (its `FoundationBackends` registrar, relocated here in P7, needs the engine). `ManifoldCloudCore` depends on `ManifoldInference` + `ManifoldRuntime` (the latter for `DefaultWebSearchRuntime`'s `WebSearchRuntime` port conformance — an un-gated library→library edge; see Package.swift comment). `ManifoldMCP` depends on `ManifoldInference` (uses `ToolExecutor`, `ToolRegistry`). All backend-family edges are unconditional — the trait-gated consumer→family edges died with the v0.48 trait retirement. The companion-package families (`ManifoldMLX`, `ManifoldLlama`) depend on this package's `ManifoldInference` from their own repos.

The `ManifoldKit` umbrella re-exports the always-compiled families (Foundation + cloud) directly — the `ManifoldBackends` re-export shim was retired in P7 (#1837), so `import ManifoldBackends` no longer compiles (see docs/MIGRATION-shims-retired.md). `ManifoldMCP` (including the `MCPCatalog` descriptors) compiles unconditionally — the `MCP` and `MCPBuiltinCatalog` traits were retired in v0.48. The `ManifoldAnyLanguageModel` bridge is its own always-compiled product (PR A5) — never re-exported by the umbrella or `ManifoldKit`; consumers import it explicitly.

**Trait roster (post-C2):** there are **no default traits** — plain `swift build` is the full core build. Surviving opt-in traits: `Server`, `Macros`; WWDC stubs `SystemAIProviderExtension`, `CoreAI`. Everything else was retired across the v0.48 train: `MCP`, `MCPBuiltinCatalog`, `Voice`, `Tools`, `AppIntents`, `Skills`, `Ollama`, `CloudSaaS`, `AnyLanguageModel` (A-series), then `MLX`, `Llama`, `HuggingFace`, `Fuzz`, `FoundationOnly` (PR C2). See docs/MIGRATION-0.48.md.

## Running tests

Use `scripts/test.sh` — it runs configured suites and prints an honest summary. There are no default traits since v0.48 — plain `swift test` covers the full core surface (`--disable-default-traits` is obsolete). Key flags:
- `--skip-update` — skips per-invocation git-remote contact (drop only if you edited Package.swift)
- `--traits Server,Macros` — to include the opt-in trait surface
- `--profile local|ci|spike` — named gate shapes (see Pre-push checklist)

**Special cases:**
- Swift Testing must run in a separate process from XCTest (mixing causes libmalloc SIGABRT — see #681)
- MCP E2E: `RUN_MCP_E2E=1 swift test --filter ManifoldMCPE2ESmokeTests` — MCP test targets compile unconditionally (MCP trait retired in v0.48); the `RUN_MCP_E2E=1` env var still gates execution. Filter to the streamable suite; `EverythingServerSmokeTests` has hung 28+ min in past runs.
- Ollama E2E requires Ollama at localhost:11434 (the backend always compiles since v0.48; only the live server is required)
- MLX integration tests and the llama.cpp process-lifecycle constraints moved with the backends — see the manifold-mlx / manifold-llama repos' docs.
- `ManifoldE2ETests`: bare form `swift test --filter ManifoldE2ETests` runs the full suite; for narrower targeting anchor the regex (`--filter 'ManifoldE2ETests\.'` then test name). Bare-vs-anchored behavior shifted in swift-test post-v2.

## Test conventions

For trait conventions, suite layout, classification (Unit / Integration / E2E), and the per-backend conformance walkthrough, see [`Tests/README.md`](Tests/README.md). It is the canonical entry point for "how do I add a backend / test / suite?".

Four cross-cutting QA practices live outside the unit/integration/E2E pyramid — DX walkthroughs, audit tests, the audit sabotage suite, and cold-start conformance gates. See [`docs/QA-PRACTICES.md`](docs/QA-PRACTICES.md) for what each one catches, how to run it, and how to extend it.

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

The MLX and llama.cpp hardware constraints (global `llama_backend_init`, Metal-in-simulator gating, metallib guards) moved with the backends to the manifold-mlx / manifold-llama repos' docs. What remains relevant to core:

- `FoundationBackend` requires iOS 26 / macOS 26. Gate accordingly.
- Context window capped at 512 tokens in the simulator to avoid OOM.

## Tooling

| Script | Purpose |
|--------|---------|
| `scripts/test.sh` | Runs configured Swift test suites and prints an honest summary. |
| `scripts/example-ui-tests.sh` | `build-for-testing` / `test-without-building` for Example app XCUITests. |
| `scripts/clean-leaked-test-artifacts.sh` | Removes test fixtures that leaked into `~/Documents/Models/`. |
| `scripts/clean-build.sh` | Full `.build` wipe + `swift package resolve`. Use when builds fail with "XCFramework Info.plist not found" or other `workspace-state.json` desync errors after changing the trait set. |
| `scripts/fuzz.sh` | Runs the ManifoldFuzz harness (default: 5 min against Ollama). CI cadence: **weekly only** (`.github/workflows/fuzz-weekly.yml`, `workflow_dispatch`). PR / nightly / hosted-heartbeat tiers were retired 2026-05 — once a backend is mature the fuzzer goes quiet for months, so per-PR + nightly CI minutes did not pay off. Run `scripts/fuzz.sh` locally (and consider temporarily reintroducing a higher cadence) when adding a new backend or model family. |
| `scripts/test-ios-simulator.sh` | Runs `ModelContainerFileProtectionTests` on an iOS Simulator via xcodebuild. Required because `NSFileProtection*` is an iOS-only kernel feature skipped by the macOS `swift test` lane. |

**SwiftPM local-package consumers need explicit `name:`.** When adding `.package(path: ...)` references (worktrees, cold-start gates, scratch consumers), pass `name: "ManifoldKit"` explicitly — `.package(path:)` derives identity from the last path component, which breaks under non-default checkout paths.

## Pre-push checklist

**Pre-push (local, Apple Silicon):**

```bash
scripts/test.sh --profile local
```

Runs XCTest + Swift Testing on the full core surface plus the `Macros` trait. Two-invocation shape is preserved internally (XCTest filters, then `ManifoldInferenceSwiftTestingTests` in a separate process — mixing the two runners in one process triggers libmalloc SIGABRT, #681). The profile deliberately does NOT pass `--parallel` or `--num-workers`: explicit parallelism can surface process-global state races in `BackendContractChecks` when backend test classes interleave (fixed for claim-methods in #1601, but implicit scheduling matches historical behavior — keep it).

**Pre-push (CI repro — only when chasing a CI failure):**

```bash
scripts/test.sh --profile ci
```

Mirrors CI's two-invocation shape exactly. Use only when reproducing a CI failure; pre-push correctness is `--profile local`.

Both profiles respect explicit caller flags: `scripts/test.sh --profile local --filter ManifoldCoreTests` runs *just* that suite, but under the local trait set and worker count. `scripts/test.sh` is the source of truth for the gate shape — the long literal command no longer lives here.

**Spike gate** (bounded changes only): `scripts/test.sh --profile spike --spike-module <suite>` — runs `swift build --build-tests` + only the affected suite. Valid only when the diff touches one module and you've run the full suite once already on this branch. Full `--profile local` gate is mandatory before the final push and after any rebase.

**Optional-traits sweep** (whenever modifying a switched enum, a `GenerationEvent` / `GenerationConfig` / `BackendCapabilities`-shaped type, or any trait-gated source file):
```bash
swift build --build-tests --traits Server,Macros
```
Plain builds won't catch Server/Macros-gated switch exhaustiveness. The all-traits-on `--build-tests` is the cheapest single check.

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
chore: update swift-huggingface to 0.6.0
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

CI must pass all suites before merge. `ManifoldBackendsTests` covers the cloud/Foundation/mock surface — the MLX/Llama backend suites run in the companion repos' CI.

## Issue & PR hygiene

CI is macOS-only (10× billing). Cost scales with **run count**, and each run pays an ~8-min cold `swift build` floor before any test executes. Caching is two-tiered (see the `actions/cache@v5` step in `ci.yml`): compiled **own-module** artifacts (`.build/debug`) are deliberately *not* cached — SwiftPM embeds paths in module fingerprints, so restored objects go stale on miss; tried and reverted twice (#961/#1045 → #1036, ~13% worse). But SwiftPM **dependency** material *is* cached and live — `.build/artifacts` holds the prebuilt ~100 MB llama.cpp xcframework (the real win), plus `.build/checkouts`/`.build/repositories` for the clone phase. The residual floor is local-module + test compile and test execution, neither cacheable. The dominant cost lever is therefore **run count**, not per-run speed. Recent baseline: 183 PRs merged in 14 days across **384 CI runs** (a 2.1× re-run tax). (Note: GitHub's native merge queue is org-only and unavailable on this personal-account repo, so batching is a discipline, not something CI enforces.)

- **Batch toward an interior optimum, not "bigger is always better."** Two run-count reducers already ship and are doing real work: `concurrency: cancel-in-progress: true` (`ci.yml:53-55`) kills superseded in-flight runs on a force-push, and `dorny/paths-filter@v4` (`ci.yml:80`) skips jobs whose inputs didn't change. So the marginal cost of a *small, well-scoped* PR is already lower than the raw 384-runs figure implies — over-batching is no longer free. Prefer fewer, larger units of work, **but split when a diff exceeds ~40 changed files or ~800 net non-generated lines**: past that, review quality and conflict/revert risk dominate the saved cold-compile run. The target is the EOQ interior optimum, not maximal batch size.
- **No phased feature splits.** Ship a feature as one PR, not P0→P5 (Glass Box shipped as 8 separate PRs of ≤8 files each = 8 cold-compile runs for one feature). If it's too big to review at once, stack it behind a draft and merge the stack as one — do not open a CI-triggering PR per phase.
- **Don't open issues for follow-ups, phases, or "while I'm here" cleanups.** The tracker is for real bugs and feature asks with external visibility. Use code comments for cross-session notes. Default to no when considering opening an issue.
- **One feature = one PR across all backends.** Don't fan out per-backend (past storms hit 15–24 PRs/day). Ship as one PR with a backend checklist in the body.
- **Tests and docs ship in the feature PR**, not as follow-ups.
- **Single-file PRs are a smell.** Batch them. (19% of the last 14 days' PRs touched one file.)
- **Kill the re-run tax.** ~Half of CI compute is failed attempts. Run the full `scripts/test.sh --profile local` gate before *every* push — CI is the last check, not the iteration loop. A red run costs a full ~8-min cold compile at 10× billing.
- **Tracking issues**: use one issue with a checklist for multi-PR work. Existing umbrellas: #753 (tool calling), #754 (demo-picker test matrix), #755 (fuzz harness v2). Add to these rather than creating new ones in the same area.
