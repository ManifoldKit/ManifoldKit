# Changelog

## [0.21.0](https://github.com/roryford/ManifoldKit/compare/v0.20.0...v0.21.0) — 2026-05-09

### Highlights

#### RAG Phase 2 — document library UI and source citations ([#1157](https://github.com/roryford/ManifoldKit/issues/1157))

Phase 1 shipped the engine (`FlatFileVectorStore`, `RAGService`, `ConversationRuntime` wiring). Phase 2 makes RAG reachable without writing any plumbing. A new `DocumentLibrarySheet` lets users add `.txt`/`.pdf` files directly from a sidebar button; each ingested document is chunked, indexed, and retrieved automatically on every turn. Retrieved passages now surface as a collapsed "Sources" disclosure beneath the assistant bubble via the new `CitationsView` — mirroring the existing `ThinkingBlockView` idiom. `RAGService` gains a `retrieve(query:limit:)` method that returns both the prompt slot and per-hit `Citation` provenance in one call; the existing `retrieveSlots` is kept as a compatibility shim.

```swift
// Enable RAG when bootstrapping — keyword fallback runs without an embedding model
let runtime = try ManifoldBootstrap(
    configuration: config,
    ragConfiguration: RAGConfiguration(),
    inferenceService: inferenceService,
    makeModelContainer: { container }
)

// Citations are attached to the assistant ChatMessageRecord automatically
// and rendered by MessageBubbleView — no host-app changes required.
let assistant: ChatMessageRecord = ...
if let citations = assistant.citations {
    CitationsView(citations: citations) // collapsed "Sources" disclosure
}
```

### Fixes

* **tests:** make `DemoScenarioOllamaE2ETests` compile so all 4 tests register ([#1154](https://github.com/roryford/ManifoldKit/issues/1154))

## [0.20.0] — 2026-05-09

### Highlights

#### Renamed BaseChatKit → ManifoldKit

The package, all 28 targets, all `BaseChat`-prefixed public types, the `bck-tools` CLI, and the GitHub repository have been renamed. The new name captures the architecture: one runtime surface over many backends.

- Update SPM dependencies: `roryford/BaseChatKit` → `roryford/ManifoldKit` (GitHub redirects the old URL, but explicit is better)
- Update imports: `import BaseChatKit` → `import ManifoldKit` (and `BaseChatInference` → `ManifoldInference`, etc. for sub-modules)
- Renamed public types: `BaseChatBootstrap` → `ManifoldBootstrap`, `BaseChatConfiguration` → `ManifoldConfiguration`, `BaseChatSchemaV3/V4/V5` → `ManifoldSchemaV3/V4/V5`, `BaseChatMigrationPlan` → `ManifoldMigrationPlan`, `BaseChatBackgroundTaskIdentifiers` → `ManifoldBackgroundTaskIdentifiers`
- The CLI binary `bck-tools` is now `manifold-tools`

```swift
// Before
import BaseChatKit
let bootstrap = try BaseChatBootstrap(...)

// After
import ManifoldKit
let bootstrap = try ManifoldBootstrap(...)
```

Internal env vars also rename (`BASECHAT_FUZZ_*` / `BASECHAT_DISCOVER_LOCAL_MODELS` / `BASECHAT_DEMO_SANDBOX_ROOT` → `MANIFOLD_*`). CI and developer scripts pick up the new names automatically; no external consumers exist for these.

#### BREAKING — local stores and cache directories reset

- SwiftData stores under the old `BaseChatSchemaV*` namespace are orphaned (clean break, pre-1.0)
- `~/Library/Caches/BaseChatKit/` and `~/Library/Application Support/BaseChatKit/` are orphaned
- `BGTaskSchedulerPermittedIdentifiers` whitelist must update from `com.basechatkit.background.*` → `com.manifoldkit.background.*`
- SBOM `purl` re-keyed to `pkg:swift/ManifoldKit@*`
- HTTP relay header `X-BaseChat-Prefill-Progress` → `X-Manifold-Prefill-Progress`
- Log subsystem flipped from `com.basechatkit` to `com.manifoldkit` (Console.app + os_log filters need re-anchoring)
- E2E test sentinel `~/.basechatkit_real_e2e` → `~/.manifoldkit_real_e2e` (developers: `mv` your existing sentinel)

#### Preserved identifiers (intentionally NOT renamed)

Several `basechat`/`com.basechat.*` identifiers are kept for backward compatibility with installed apps and registered third-party state. Renaming these would silently break user data:

- **OAuth callback scheme `basechat://`** — registered with GitHub / Linear / Notion as the redirect URL for MCP server OAuth flows. Flipping it would break every existing user's MCP authorization.
- **Keychain account `com.basechat.resumedata.hmac`** — HMAC key for HuggingFace background-download resume blobs. Renaming orphans every existing resumable download.
- **Prometheus metric prefix `basechat_*`** — exported by `ManifoldServer`. Metric-name change would break customer dashboards / alerting rules.
- **CLI command name `basechat-server`** — user-facing binary invocation in `ManifoldServer`. Stays for muscle memory.
- **OAuth dynamic-client-registration softwareID `basechat-client`** — identifier sent to upstream IdPs during DCR.
- **SQLite migration filename prefix `basechat-v3-…`** — referenced in test fixtures that exercise V3-era persisted file shapes; renaming buys nothing.

### Other changes

_(any non-rename work that ships in this cut goes here)_



## [0.19.0](https://github.com/roryford/BaseChatKit/compare/v0.18.0...v0.19.0) (2026-05-09)

This release closes a driver-first improvement plan that dissolved seven structural drivers in BCK's surface. The headline shifts: `import BaseChatKit` is the canonical app-level import; `BackendName` is a real Swift enum; `BaseChatBackends` splits into five trait-gated products; backend capabilities now derive from a `ModelManifest` rather than hardcoded constants; the four `*Input` structs in `ConversationRuntime` collapse into one `TurnInput`; and `RAG` ships as a first-class knowledge-base module.

### ⚠ BREAKING CHANGES

* **`BackendName` raw value flip** — `BackendName.foundation` is now `"foundation"` (was `"Apple"`); the other five cases use lowercase canonical strings. Code that hardcoded the legacy strings (`if name == "Apple"`) breaks. Use `BackendName.<case>.rawValue` for new comparisons and `BackendName.parse(_:)` at every persistence boundary — it accepts both new and legacy forms so already-stored sessions migrate transparently.
* **`BaseChatBackends` split into five products** — `BaseChatCloudCore`, `BaseChatMLX`, `BaseChatLlama`, `BaseChatFoundation`, `BaseChatCloud` are now publicly exposed alongside the umbrella. `import BaseChatBackends` keeps working. Code that did `@testable import BaseChatBackends` to reach internals now needs `@testable import BaseChat<Family>` for the family that owns the symbol.
* **`ConversationRuntime` input collapse** — `SendInput` / `RegenerateInput` / `EditInput` / `BranchInput` are deprecated in favor of one `TurnInput { kind: TurnKind, config: TurnConfig }`. The public `runtime.send(_:)` / `regenerate(_:)` / `edit(_:)` / `branch(_:)` method names stay; the legacy structs forward via deprecation shim.
* **`SendMessageError` replaces `NoResponseError`** — `ChatViewModel.sendMessage(_:)` now throws `.noActiveSession` / `.noModelLoaded` / `.empty` / `.runtime(Error)` instead of masking three distinct failure modes as one opaque error. Switch on the case to distinguish.
* **`MessageStore` / `SessionStore` moved to `BaseChatRuntime`** — Persistence-port protocols belong with the turn loop. Consumers that conformed to or imported these protocols from `BaseChatInference` may need to add `import BaseChatRuntime`. Records (`ChatMessageRecord`, `MessagePart`, `MessageRole`) stay in `BaseChatInference`.
* **`InferenceService.enqueue([Message])`** — A typed overload replaces the deprecated `[(role: String, content: String)]` tuple form. Use `Message.user(_)` / `.system(_)` / `.assistant(_)` to avoid stringly-typed roles.

### Highlights

#### `import BaseChatKit` is the canonical app-level import ([#1147](https://github.com/roryford/BaseChatKit/issues/1147))

The new `BaseChatKit` umbrella product re-exports the four core modules (`BaseChatRuntime`, `BaseChatPersistenceSwiftData`, `BaseChatBackends`, `BaseChatUI`), so a hello-world chat app needs one import instead of six. The README's Quick Start drops to five lines. Specialized features (`BaseChatMCP`, `BaseChatVoice`, `BaseChatHuggingFace`, `BaseChatUIModelManagement`) remain opt-in. The cold-start CI gate now consumes `import BaseChatKit` from outside the package as the load-bearing tripwire for the umbrella's documented contract.

```swift
import SwiftUI
import BaseChatKit  // re-exports Runtime + Persistence + Backends + UI

@main struct DemoApp: App {
    var body: some Scene { WindowGroup { ChatView(viewModel: chatViewModel) } }
}
```

#### `BackendName` is a Swift enum with raw-value flip ([#1147](https://github.com/roryford/BaseChatKit/issues/1147))

`BackendName` is now a real `enum: String, Sendable, CaseIterable, Codable, Hashable` — switch statements over the active backend can be exhaustive again. Raw values are lowercased canonical (`"foundation"`, `"ollama"`, `"claude"`, etc.); `BackendName.foundation` no longer secretly equals `"Apple"`. The new `BackendName.parse(_:)` accepts both 0.19+ canonical strings AND legacy 0.18 forms (`"Apple"`, `"Ollama"`, `"llama.cpp"`) so persisted session metadata migrates without a schema bump.

```swift
switch vm.activeBackendName.flatMap(BackendName.parse) {
case .foundation: // ...
case .ollama, .claude, .openAI, .mlx, .llama: // ...
case .none: // mock backend or custom cloud provider
}
```

#### `BaseChatBackends` split into five trait-gated products ([#1146](https://github.com/roryford/BaseChatKit/issues/1146))

The 11.7k-LOC monolithic `BaseChatBackends` target is split into `BaseChatCloudCore` (always linked — URLSessionProvider, redirect guard, SSE base), `BaseChatMLX` (`MLX` trait), `BaseChatLlama` (`Llama` trait), `BaseChatFoundation` (OS availability, no trait), and `BaseChatCloud` (`CloudSaaS` or `Ollama` trait — OpenAI, Claude, Ollama). Three cross-family stub files (`ClaudeBackendStub`, `OpenAIBackendStub`, `OllamaBackendStub`) are deleted — per-target trait gating now does what they faked. `BaseChatBackends` remains as a thin re-export umbrella so `import BaseChatBackends` keeps compiling. Trait-combo CI builds are now ~5× faster because a one-line MLX change no longer rebuilds the cloud backends.

#### `ModelManifest` derives backend capabilities from model truth ([#1141](https://github.com/roryford/BaseChatKit/issues/1141))

Backend capabilities used to be hardcoded constants — `MLXBackend` claimed 8192 max context regardless of the loaded model, `OpenAIBackend` silently dropped `seed` even though the API accepts it, `OllamaBackend`'s thinking-tag fallback was hardwired to `<think>` Qwen3 markers. The new `ModelManifest` is a per-model source of truth (context window from `config.json`, `supportsSeed` from a vendored prefix table for cloud models, `thinkingMarkers` from the auto-detected `/api/show` template scan). `BackendCapabilities` becomes a derived view; `ContextWindowManager` reads the manifest's true context window. A new contract test asserts the cross-backend invariant that any backend emitting `.thinkingToken` events reports `supportsThinking == true`.

```swift
public struct ModelManifest: Sendable, Equatable {
    let contextWindow: Int
    let supportsTools: Bool
    let supportsThinking: Bool
    let thinkingMarkers: ThinkingMarkers?
    let supportsSeed: Bool
    let supportedSamplingParameters: SamplingParameterSet
    let modelIdentifier: String
    let producerKind: ProducerKind  // .local / .cloud / .lan
}
```

#### `TurnInput` collapses ConversationRuntime input shape; typed `SendMessageError` ([#1145](https://github.com/roryford/BaseChatKit/issues/1145))

The four `*Input` structs in `ConversationRuntime` duplicated ~14 sampling/streaming/loop-detection knobs each — adding a knob was a 5-touch change. They collapse into one `TurnInput { kind: TurnKind, config: TurnConfig }`; a single `processTurn` body replaces four near-duplicate branches. `ChatViewModel.sendMessage(_:)` now propagates a typed `SendMessageError` enum (`.noActiveSession`, `.noModelLoaded`, `.empty`, `.runtime(Error)`) instead of masking three distinct failure modes. `configure(bootstrap:)` is the canonical wiring; `configure(runtime:)` and `configure(_:)` are deprecated shims. `InferenceService.enqueue([Message])` replaces the role-string tuple form.

```swift
do {
    try await vm.sendMessage("hi")
} catch SendMessageError.noModelLoaded {
    showModelPicker = true
} catch SendMessageError.noActiveSession {
    await vm.startNewSession()
} catch let SendMessageError.runtime(err) {
    activeError = err
}
```

#### RAG knowledge base ([b9c00a4](https://github.com/roryford/BaseChatKit/commit/b9c00a4c09f1785637efbfbaf442f6a0489d6abe))

Document ingestion, vector store, and retrieval-augmented context are now first-class — chat sessions can cite indexed knowledge instead of relying on the model's parametric memory. Embedding production goes through the existing `LlamaEmbeddingBackend` / `nomic-embed` path; retrieval is wired into `PromptContextPipeline` so the runtime composes prompts that interleave conversation history with retrieved chunks.

### Features

* **`MLXResourceArbiter`** — Per-instance cache accounting for multi-MLX-backend hosts. Two MLX backends in the same process (e.g. chat + embeddings) no longer trample each other's `MLX.Memory.cacheLimit`; `clearCache()` only fires when the last claim releases. New `BackendCapabilities.sharesMLXProcessResources` flag tells supervisors when to serialize lifecycle hooks ([#1144](https://github.com/roryford/BaseChatKit/issues/1144)).
* **`ToolArgumentCoercer` recurses into nested schemas** — Tool calls with `parameters: { type: object, properties: { filter: { type: object, properties: { ... } } } }` now type-coerce nested fields. Bounded depth of 8 prevents pathological schemas. Small open-weight models — the original motivating use case — stop bouncing on nested-typo arguments ([#1144](https://github.com/roryford/BaseChatKit/issues/1144)).
* **`FoundationOnly` trait + App Store-lean profile** — A new opt-in trait that excludes MLX (~100 MB) and llama.cpp (~600 MB), keeping the BCK overhead under 5 MB for indie iOS 26+/macOS 26+ apps that only need Foundation Models. CI gate asserts the bundle stays small. New `Templates/PrivacyInfo.xcprivacy` covers BCK's three triggered Required Reason API categories. New `docs/AppStoreSubmission.md` checklist covers encryption export, privacy manifest, ATS, mic entitlement, iOS 18 vs 26 targeting ([#1139](https://github.com/roryford/BaseChatKit/issues/1139)).
* **AGENTS.md + `.cursorrules` + README CI gate** — AI-assistant-grade documentation covering imports, message types, tool-calling pitfalls, and the four common LLM hallucinations that an AI coding assistant trips over when extending BCK. New `scripts/check-readme.sh` CI gate prevents stale install pins or deleted-API references from sneaking back in. README install pins corrected from `from: "1.0.0"` (which never existed) to current ([#1136](https://github.com/roryford/BaseChatKit/issues/1136)).
* **Persistence ports relocated** — `MessageStore` / `SessionStore` and their post-write hooks moved from `BaseChatInference` to `BaseChatRuntime`, where the turn loop owns them. Records stay in `BaseChatInference` because the dep DAG locks them there. New `ProtocolLocationAuditTest` pins both locations to prevent future drift ([#1140](https://github.com/roryford/BaseChatKit/issues/1140)).
* **Typed `BackendName` constants and `loadFoundationModelIfAvailable()`** — Earlier in the cycle, `BaseChatInference` exposed a `BackendName` namespace with typed constants for the strings returned by `InferenceService.activeBackendName`. `ChatViewModel.loadFoundationModelIfAvailable()` refreshes the registry, selects the Foundation model, and dispatches a load in one call. The deprecated `loadModel(from:contextSize:)` overload is removed ([#1131](https://github.com/roryford/BaseChatKit/issues/1131)).

### Fixes

* **Cross-origin redirect credential strip** — A new `RedirectGuardDelegate` revalidates redirect URLs through `DNSRebindingGuard`, strips `Authorization` / `Cookie` / `Proxy-Authorization` / `X-API-*` headers on cross-origin redirects, rejects scheme downgrades, and caps hop count. `URLSessionFactory.background()` and a SwiftSyntax lint rule make `URLSessionProvider` the only construction site for `URLSession` instances. `BackgroundDownloadManager` resume blobs are now HMAC-SHA256-tagged with a per-install Keychain key — local-file-write attackers can no longer steer downloads. `MCPContentSanitizer` strips 8-bit CSI, OSC, DCS, and SOS/PM/APC sequences ([#1138](https://github.com/roryford/BaseChatKit/issues/1138)).
* **Llama E2E basic suite no longer requests thinking** — Disables thinking blocks in the basic real-inference suite so the test isn't load-bearing on a model's reasoning behavior ([#1137](https://github.com/roryford/BaseChatKit/issues/1137)).

## [0.18.0](https://github.com/roryford/BaseChatKit/compare/v0.17.8...v0.18.0) (2026-05-08)

### Highlights

#### `ChatView` without `apiConfiguration` (BYO-UI path) ([#1128](https://github.com/roryford/BaseChatKit/issues/1128))

Apps that don't ship `BaseChatUIModelManagement` — or that surface API settings elsewhere — can now construct `ChatView` without an `apiConfiguration` closure. New convenience initializers are gated on `APIConfig == EmptyView`, so the empty configuration surface is statically erased rather than rendered as an empty container. The README and `BaseChatUI` DocC also document the BYO-UI path using `BaseChatInference` + `BaseChatBackends` directly, with a copy-paste `Package.swift` and minimal SwiftUI wiring.

```swift
import BaseChatUI

struct ContentView: View {
    @Binding var showModelManagement: Bool
    var body: some View {
        // No apiConfiguration: { ... } closure required.
        ChatView(showModelManagement: $showModelManagement)
    }
}
```

#### Typed `BackendName` constants and `loadFoundationModelIfAvailable()` ergonomics ([#1114](https://github.com/roryford/BaseChatKit/issues/1114))

`BaseChatInference` now exposes a `BackendName` namespace with typed constants (`.foundation`, `.ollama`, `.claude`, `.openAI`, `.mlx`, `.llama`) for the strings returned by `InferenceService.activeBackendName`, replacing magic-string comparisons in host code. `ChatViewModel.loadFoundationModelIfAvailable()` refreshes the registry, selects the Foundation model, and dispatches a load in one call — without the first-launch gate that `autoSelectFirstRunModel()` enforces. The pre-1.0 deprecated `InferenceService.loadModel(from:contextSize:)` overload is removed; callers should migrate to `loadModel(from:plan:)` paired with `ModelLoadPlan.compute(for:)`.

```swift
if vm.activeBackendName == BackendName.foundation {
    // Foundation-specific UX
}

vm.loadFoundationModelIfAvailable()
```

### Features

* **`bck-tools test-uplift` control CLI** — The Tools-trait `bck-tools` executable gains a `test-uplift` subcommand with `status` / `pause` / `resume` / `stop` operations against the overnight orchestrator state at `~/.claude/state/bck-test-uplift/`. `status` pretty-prints phase, in-flight workers, queue, and blockers (with a `blockers.tsv` fallback) ([#1127](https://github.com/roryford/BaseChatKit/issues/1127))

### Fixes

* **Cloud backends fail closed on unsupported grammar** — `SSECloudBackend` now runs the grammar preflight before opening any network request, so Claude / OpenAI / Ollama throw `InferenceError.unsupportedGrammar(reason:)` synchronously instead of silently dropping the constraint mid-stream ([#1122](https://github.com/roryford/BaseChatKit/issues/1122))
* **Server stops generation on client disconnect** — The default `ChatCompletionsAdapter` now calls `backend.stopGeneration()` when the SSE stream is cancelled, clearing `isGenerating` within ~500 ms instead of letting the backend run until the next request ([#1123](https://github.com/roryford/BaseChatKit/issues/1123))
* **`ModelStorageService` default scope is per-app** — Two BCK-based apps on the same device no longer see each other's locally-discovered GGUFs by default; pass `baseDirectory:` at init to opt into a shared model pool ([#1126](https://github.com/roryford/BaseChatKit/issues/1126))
* **`BaseChatFuzzBackends` no longer imports `BaseChatTestSupport`** — A library product reaching for test-only utilities was an architectural violation. The small surface `BaseChatFuzzBackends` actually used has been inlined as `FuzzModelDiscovery` / `FuzzModelLoadPlan`, and over-public test scaffolding types in `BaseChatTestSupport` (`CharTokenizer`, `ImageFixtures`, `TimeoutError`, `ConversationRuntimeScenario`, `HardwareRequirements`) are now `internal` ([#1116](https://github.com/roryford/BaseChatKit/issues/1116), [#1117](https://github.com/roryford/BaseChatKit/issues/1117))
* **Deflaked `ConversationRuntime` back-to-back token-usage assertion** — `test_send_tokenUsageEventPinsPerStreamUsageAcrossBackToBackSends` ordered the persisted assistants by `timestamp`, but two back-to-back `runtime.send` calls produce `ChatMessageRecord`s built with the default `Date()` argument within the same microsecond on a fast runner, falling back to non-deterministic dictionary-iteration order. The test now resolves the assistants via the `tokenUsageRecorded` event's `messageID`, which arrives in deterministic turn order ([#1130](https://github.com/roryford/BaseChatKit/issues/1130))
* **Deprecation messages name their replacement APIs** — `@available(*, deprecated, message:)` strings across `BaseChatBackends`, `BaseChatInference`, `BaseChatMCP`, and `BaseChatUIModelManagement` now identify the replacement API (and any type changes — e.g. `MCPOAuth.accessToken: String` → `accessTokenData: Data`) so callers can migrate without chasing tracking issues ([#1118](https://github.com/roryford/BaseChatKit/issues/1118))

## [0.17.8](https://github.com/roryford/BaseChatKit/compare/v0.17.7...v0.17.8) (2026-05-08)


### Features

* **Scripted-driver ergonomics and per-app model storage** — `ChatViewModel` gains `sendMessage(_ text: String) async throws -> ChatMessageRecord` (drives one turn without set-then-observe boilerplate) and `lastTurnState: TurnState` (`.idle / .generating / .completed(record) / .failed(error)`). `ModelStorageService.modelsDirectory` now defaults to `<Application Support>/<bundleIdentifier>/Models` so multiple BCK-based apps on the same device each see only their own models; pass `baseDirectory:` at init to opt into a shared pool ([#1111](https://github.com/roryford/BaseChatKit/issues/1111))

## [0.17.7](https://github.com/roryford/BaseChatKit/compare/v0.17.6...v0.17.7) (2026-05-08)

### Features

* **`ModelLoadPlan.compute(for:)` strategy overload** — `ModelLoadPlan` gains a `compute(for:requestedContextSize:)` overload that accepts a `ModelInfo` value and selects the appropriate loading strategy automatically. Consumers no longer need to map `ModelInfo` properties to strategy parameters by hand ([#1099](https://github.com/roryford/BaseChatKit/issues/1099))

### Fixes

* **SwiftData store path scoped per bundle identifier** — The default SwiftData store path is now derived from the host app's bundle identifier, preventing two apps that both embed BaseChatKit from colliding on the same store file ([#1100](https://github.com/roryford/BaseChatKit/issues/1100))
* **Cold-start CI gate is self-validating** — CI now triggers on changes to `scripts/cold-start*.sh`, so edits to the gate scripts themselves are validated in the same run ([#1103](https://github.com/roryford/BaseChatKit/issues/1103))
* **Tier-1 cold-start script is worktree-portable** — `.package(name:)` is now pinned in the tier-1 cold-start script, fixing resolution failures when the script runs from inside a Git worktree ([#1102](https://github.com/roryford/BaseChatKit/issues/1102))

## [0.17.6](https://github.com/roryford/BaseChatKit/compare/v0.17.5...v0.17.6) (2026-05-08)

### Fixes

* **Full-trait test suite: 5 failures resolved** — Fixes `MLXDiffusionBackend.unloadModel()` crashing before any model is loaded, `detectPreset` tests hitting a Metal fatal-error path under `swift test`, `FoundationBackend` tests failing instead of skipping when Apple Intelligence isn't ready, the `APIConfigurationView` snapshot assertion matching the wrong string, and `test_z_contract_metaContract` seeing an empty claims registry due to `class setUp()` ordering ([bfbcf66](https://github.com/roryford/BaseChatKit/commit/bfbcf660a4405cb29cc46b6993c70a458d8aa73a))

## [0.17.5](https://github.com/roryford/BaseChatKit/compare/v0.17.4...v0.17.5) (2026-05-08)

### Fixes

* **Grammar fail-closed for cloud backends** — `InferenceService` now throws `InferenceError.unsupportedGrammar(reason:)` synchronously when `GenerationConfig.grammar` is set on a backend that does not support grammar-constrained sampling; Claude, OpenAI, and Ollama backends are now covered ([5afd8fc](https://github.com/roryford/BaseChatKit/commit/5afd8fc46c62c9288e1e18a3c2a11b16a3be61b5))
* **Backend generation halts on SSE disconnect** — Cancelling an SSE connection now triggers `stopGeneration()`, preventing the backend from continuing to emit tokens after the client disconnects ([08880b2](https://github.com/roryford/BaseChatKit/commit/08880b234fd374a040fdf97fd108af7d86343476))
* **Streaming usage chunk gating corrected** — The final content chunk no longer carries a `usage` payload; a trailing usage-only chunk is appended only when `stream_options.include_usage: true`, matching the OpenAI spec ([4443f40](https://github.com/roryford/BaseChatKit/commit/4443f40383bade65bac7a40f62fb609201f07098))
* **llama.swift pin reverted** — The 2.9050.0 pin caused CI tree-read failures and has been rolled back to the previous stable version ([27027f8](https://github.com/roryford/BaseChatKit/commit/27027f8a1b3ced6a5fdc9e6efcd8b16f05f0cb9e))
* **Package.resolved regenerated** — Synced `originHash` and default-trait dependencies after the T1.5 test-uplift round ([0b14ef2](https://github.com/roryford/BaseChatKit/commit/0b14ef2c3792c5ecd64cdfc6eee3e56e79ad558b))

## [0.17.4](https://github.com/roryford/BaseChatKit/compare/v0.17.3...v0.17.4) (2026-05-06)


### Fixes

* **Swift 6 `@Sendable` error in `MLXGenerationDriver`** — The body and handler closures passed to `withErrorHandler` were not marked `@Sendable`, causing a `#SendingRisksDataRace` compile error for consumers building with Swift 6 strict concurrency. All captured parameters already conform to `Sendable`; both closures are now explicitly annotated ([#1068](https://github.com/roryford/BaseChatKit/issues/1068))
* **`mlx-swift-examples` removed from dependency graph** — The upstream package declared `platforms: [.iOS(.v16)]` while its dependency `mlx-swift` requires iOS 17, triggering SPM platform-validation errors on Xcode 15+. The `StableDiffusion` library (9 files, MIT © 2024 ml-explore) is now vendored in `Sources/StableDiffusion/` with `#if MLX` guards; `mlx-swift-examples` and its transitive `GzipSwift` dependency are no longer in the resolved graph ([#1068](https://github.com/roryford/BaseChatKit/issues/1068))

## [0.17.3](https://github.com/roryford/BaseChatKit/compare/v0.17.2...v0.17.3) (2026-05-06)

### Fixes

* **Search scope resets on clear** — `clearSearch()` now resets `searchScope` to `.titles` synchronously. Previously, clearing a search query while the Messages scope tab was selected left the tab stuck on "Messages" for the next query ([92c9676](https://github.com/roryford/BaseChatKit/commit/92c96763d42b5d45fc2c05eb1bbd7c7871467096))
* **Appearance mode, AFM label, toolbar overflow** — Three UI fixes: appearance mode now takes effect via `.preferredColorScheme` on the `WindowGroup`; the sidebar model label shows "Apple Intelligence" when the Foundation backend is active with no explicit model selected; toolbar action buttons are individually wrapped in `ToolbarItem` to prevent overflow clipping ([faba071](https://github.com/roryford/BaseChatKit/commit/faba071b3dff43c175f9405fda12da2b7d149715))

## [0.17.2](https://github.com/roryford/BaseChatKit/compare/v0.17.1...v0.17.2) (2026-05-06)

### Highlights

#### Decouple `BaseChatUI` from `BaseChatPersistenceSwiftData`

`BaseChatUI` no longer imports `BaseChatPersistenceSwiftData`. A new `ChatRuntimeBootstrap` protocol replaces the concrete `BaseChatBootstrap` dependency in view-model wiring, and endpoint state now flows through `APIEndpointRecord` (a value type) plus `EndpointStore` instead of SwiftData `@Model` objects. Host apps that inject a bootstrap via `configure(_:)` get the same behaviour; apps that reference `APIEndpoint` directly in their chat UI layer need to switch to `APIEndpointRecord`.

```swift
// Before
func configure(_ bootstrap: BaseChatBootstrap) { ... }

// After — accepts any ChatRuntimeBootstrap conformer
func configure(_ bootstrap: any ChatRuntimeBootstrap) { ... }
```

See [#1060](https://github.com/roryford/BaseChatKit/pull/1060).

#### Observe turn outcomes and token usage via `ConversationEvent`

`ConversationRuntime` now emits `ConversationEvent.tokenUsageRecorded(messageID:promptTokens:completionTokens:)` after each assistant turn and `sessionTouchFailed(sessionID:)` when a session-list update fails without aborting the turn. Subscribe to `runtime.events` to wire usage data into analytics or surface non-fatal persistence warnings.

```swift
for await event in runtime.events {
    if case .tokenUsageRecorded(let id, let prompt, let completion) = event {
        analytics.record(messageID: id, tokens: prompt + completion)
    }
}
```

See [#1060](https://github.com/roryford/BaseChatKit/pull/1060).

#### Llama XTC and Mirostat V2 samplers

`LlamaGenerationDriver` now wires XTC and Mirostat V2 sampling from `GenerationConfig.llamaXTC` / `llamaMirostat` through to the llama.cpp sampler chain. Both samplers are opt-in per request; existing generation behaviour is unchanged when neither option is set.

```swift
let config = GenerationConfig(
    llamaXTC: LlamaXTCSamplerOptions(probability: 0.5, threshold: 0.1),
    llamaMirostat: LlamaMirostatV2SamplerOptions(tau: 5.0, eta: 0.1)
)
```

See [#1061](https://github.com/roryford/BaseChatKit/pull/1061).

### Features

* **Backend capability honesty** — `BackendVisionCapability` centralizes image-input gating across all backends; `BackendCapabilities` gains `supportsGuidedStructuredOutput` and `preferredStructuredOutputSupport`; server validates unsupported tools and response formats before dispatch, returning OpenAI-compatible `invalid_request_error` envelopes ([#1060](https://github.com/roryford/BaseChatKit/issues/1060))
* **Runtime observability** — finish-state coverage for success, cancellation, stream errors, empty output, and thinking-only turns; `GenerationQueue` warns when thinking hints target non-thinking backends ([#1060](https://github.com/roryford/BaseChatKit/issues/1060))

### Fixes

* **FoundationBackend cancellation race** — `stopGeneration()` now clears `isGenerating` synchronously and guards stale-defer cleanup from clobbering a newer generation ([#1060](https://github.com/roryford/BaseChatKit/issues/1060))

## [0.17.1](https://github.com/roryford/BaseChatKit/compare/v0.17.0...v0.17.1) (2026-05-05)

### Highlights

#### Route structured outputs by backend capability

`GenerationConfig` now accepts a runtime-only `structuredOutput` strategy, and `StructuredOutputRouter` picks the strongest representation a backend can actually honor — GBNF when available, guided decoding when supported, JSON Schema when possible, and JSON prompting as the fallback. Callers can describe the target once and let capability routing choose the enforcement mechanism instead of branching per backend in app code.

```swift
struct Event: Decodable { let title: String }

let target = StructuredOutputTarget.guided(Event.self)
let strategy = StructuredOutputRouter.selectStrategy(
    capabilities: backend.capabilities,
    target: target
)

let config = GenerationConfig(structuredOutput: strategy)
```

See [#1054](https://github.com/roryford/BaseChatKit/pull/1054).

#### Keep image attachments visible while full assets load

Image parts now carry an optional `ImagePlaceholderHash` generated during draft staging, pending payload ingest, and runtime send paths. Chat bubbles and draft thumbnails render a blurred color grid immediately, then crossfade to the decoded asset once bytes load from memory or persistence, while legacy stored images keep working without migration.

#### Treat multi-component image models as one installable package

Diffusers-style Hugging Face packages now write a narrow readiness manifest and only surface in the model browser once every required component is present. Downloads report aggregate progress and finalize atomically, so half-downloaded image models no longer appear ready to use.

### Features

* **Image loading placeholders** — `MessagePart.image` carries an optional `ImagePlaceholderHash`; chat bubbles render a blurred color grid immediately and crossfade once the full asset loads, with no migration needed for legacy stored images ([#1047](https://github.com/roryford/BaseChatKit/pull/1047))
* **Structured output routing** — `StructuredOutputStrategy`, `StructuredOutputTarget`, and `StructuredOutputRouter` let callers describe the output shape once and pick the strongest enforcement mechanism a backend supports ([#1054](https://github.com/roryford/BaseChatKit/pull/1054))
* **Default load options** — `kvCacheQuantization` defaults to `.q8` and `flashAttention` enables on non-simulator hardware; existing `BackendLoadOptions` overrides are respected ([#1046](https://github.com/roryford/BaseChatKit/pull/1046))
* **HuggingFace multi-component packages** — diffusers-style image model packages surface in the model browser only when every required component is present; downloads report aggregate progress and finalize atomically ([#1053](https://github.com/roryford/BaseChatKit/pull/1053))
* **CI build cache** — experimental SwiftPM `.build/debug` cache path with mtime normalization improves incremental reuse on CI cache hits ([#1045](https://github.com/roryford/BaseChatKit/pull/1045))

### Fixes

* **Foundation multimodal gate** — vision attachment attempts on `FoundationBackend` now surface a clear backend-agnostic error rather than silently dropping the image, pending the public FoundationModels SDK gaining image input support ([#1050](https://github.com/roryford/BaseChatKit/pull/1050))
* **MLX Gemma4 MoE crash** — `fatalError` on mixture-of-experts weight mismatch converted to a thrown `InferenceError.inferenceFailure` callers can surface gracefully ([#1055](https://github.com/roryford/BaseChatKit/pull/1055))
* **Demo scenario tool flows** — scripted demo scenarios and their UI/E2E assertions around completed tool calls and approval flows repaired ([#1057](https://github.com/roryford/BaseChatKit/pull/1057))
* **KV reuse test assertion** — system-prompt-change test now permits shared template tokens while still catching body reuse, eliminating a false-positive flake ([#1048](https://github.com/roryford/BaseChatKit/pull/1048))
* **GGUF test fixture** — backend tests prefer the smallest available GGUF to keep runs leaner ([#1044](https://github.com/roryford/BaseChatKit/issues/1044))

## [0.17.0](https://github.com/roryford/BaseChatKit/compare/v0.16.4...v0.17.0) (2026-05-05)

### Highlights

#### XTC and Mirostat v2 samplers complete the modern llama.cpp surface

DRY shipped in v0.16.4; this release adds the remaining two samplers from [#1021](https://github.com/roryford/BaseChatKit/issues/1021) — XTC ("Exclude Top Choices") and Mirostat v2. Both are llama.cpp-only and live behind nullable `GenerationConfig` fields so existing callers keep their bit-identical sampler chain. XTC inserts immediately after the temperature step to trim high-probability tokens for variety; Mirostat v2 replaces the temperature + dist tail with an entropy-controlled selector when active.

```swift
var config = GenerationConfig()
config.llamaXTC = LlamaXTCSamplerOptions(probability: 0.5, threshold: 0.10, minKeep: 1)
config.llamaMirostatV2 = LlamaMirostatV2SamplerOptions(tau: 5.0, eta: 0.1)
```

Each sampler advertises through `GenerationParameter.llamaXTC` / `.llamaMirostatV2` so UI and `RouterBackend` can dispatch on the new capabilities. Defaults mirror llama.cpp's `common_params_sampling`. With this, [#1021](https://github.com/roryford/BaseChatKit/issues/1021) is complete.

#### Per-message context menu with extensibility seam

The chat UI now ships a default context menu on every message bubble — Copy, Regenerate (assistant only), Branch from here, and Delete — wired to the existing `ConversationRuntime` actions. Right-click on macOS, long-press on iOS, both via the same `.contextMenu { }` modifier. Hosts can append items via a new `contextMenuItems:` `@ViewBuilder` parameter on `ChatView`, mirroring the existing `apiConfiguration:` injection pattern; the closure receives the `ChatMessageRecord` so menu items can vary by role or content.

```swift
ChatView(viewModel: viewModel, contextMenuItems: { message in
    Button("Copy as Markdown") { copyMarkdown(message) }
    if message.role == .assistant {
        Button("Share via AirDrop") { share(message) }
    }
})
```

`ChatViewModel` gains public `deleteMessage(id:)` and `branch(from:)` methods plus an `onSessionBranched: (UUID) async -> Void` callback so hosts can refresh their sidebar and select the new session when the runtime forks. Closes [#1011](https://github.com/roryford/BaseChatKit/issues/1011).

#### FoundationBackend multimodal gap documented

Audited Apple FoundationModels in Xcode 26.4: `Transcript.Segment` / `Prompt` / `LanguageModelSession.respond(to:)` carry no public image surface. `BackendCapabilities.supportsVision` is now explicitly `false` for `FoundationBackend` (previously fell through to the protocol default), and a regression-guard test fails CI if that flips without `MessagePart.image` actually being wired through the SDK. Only Llama remains on the [#20](https://github.com/roryford/BaseChatKit/issues/20) umbrella, blocked upstream by the missing `mtmd.h` in the xcframework ([#416](https://github.com/roryford/BaseChatKit/issues/416)).

### Features

* **backends:** add llama XTC sampler option ([#1037](https://github.com/roryford/BaseChatKit/pull/1037))
* **backends:** add llama mirostat v2 sampler option ([#1037](https://github.com/roryford/BaseChatKit/pull/1037))
* **ui:** add per-message context menu with copy/regenerate/branch/delete + `contextMenuItems` extensibility seam ([#1039](https://github.com/roryford/BaseChatKit/pull/1039))

### Documentation

* **foundation:** document multimodal gap and explicitly gate `supportsVision` capability flag ([#1038](https://github.com/roryford/BaseChatKit/pull/1038))

### Performance

* **ci:** revert `.build/debug` cache spike from PR #961 — 8-run measurement showed median 263s vs 253s baseline; no measurable wins (Lever C of [#953](https://github.com/roryford/BaseChatKit/issues/953)) ([#1036](https://github.com/roryford/BaseChatKit/pull/1036))

## [0.16.4](https://github.com/roryford/BaseChatKit/compare/v0.16.3...v0.16.4) (2026-05-05)

### Highlights

#### DRY sampler and penalty knob persistence for llama.cpp

llama.cpp's DRY (Don't Repeat Yourself) repetition penalty is now wired into `LlamaGenerationDriver` via `GenerationConfig`. DRY multiplier, allowed length, base, and sequence breakers are all exposed and default to llama.cpp's library defaults, so existing callers are unaffected. Sampler preset penalty knobs (`repetitionPenalty`, `presencePenalty`, `frequencyPenalty`, and the new DRY fields) are now persisted in SwiftData so they survive app restarts.

```swift
var config = GenerationConfig()
config.dryMultiplier = 0.8
config.dryAllowedLength = 2
config.dryBase = 1.75
config.drySequenceBreakers = ["\n", ":", "\"", "*"]
```

### Features

* **backends:** add llama DRY sampler option ([#1031](https://github.com/roryford/BaseChatKit/issues/1031)) ([fe34220](https://github.com/roryford/BaseChatKit/commit/fe3422049d1bc7201968b56fb761f1373219931a))
* **persistence:** persist sampler preset penalty knobs ([#1033](https://github.com/roryford/BaseChatKit/issues/1033)) ([c7ff806](https://github.com/roryford/BaseChatKit/commit/c7ff806b01c6bfa9afc359857db71ab5d75a6e42))
* **ui:** add scroll-to-message request API ([#1030](https://github.com/roryford/BaseChatKit/issues/1030)) ([58947e9](https://github.com/roryford/BaseChatKit/commit/58947e95d97241e4cfd3d9d41fb11f9acba2ca0f))

## [0.16.3](https://github.com/roryford/BaseChatKit/compare/v0.16.2...v0.16.3) (2026-05-04)

### Highlights

#### Backend tuning knobs — per-generation samplers and load-time options

BaseChatKit ignored several `llama.cpp` and `mlx-swift-lm` knobs at the `GenerationConfig` boundary, and `LlamaGenerationDriver` hardcoded `top_k = 40` so any caller-supplied `GenerationConfig.topK` was silently dropped. This release surfaces those knobs through two value types — one for per-generation sampler controls, one for load-time context options — and fixes the `topK` bug. Defaults preserve historical behaviour bit-for-bit; every new field is optional and falls through to each backend's library default when unset.

```swift
// Per-generation sampler knobs (#1022) — added to GenerationConfig
var config = GenerationConfig()
config.presencePenalty = 0.6        // OpenAI-style additive
config.frequencyPenalty = 0.3
config.repetitionContextSize = 128  // window for repetitionPenalty
config.topK = 1                     // now actually applied on llama.cpp

// Load-time options (#1026) — applied at loadModel time
let backend = LlamaBackend()
backend.setLoadOptions(BackendLoadOptions(
    kvCacheQuantization: .q8,        // ~50% KV memory cut
    flashAttention: true,            // free perf on Metal at long context
    prefillBatchSize: 2048           // faster TTFT on long prompts
))
try await backend.loadModel(from: url, plan: plan)
```

`GenerationConfig` gains `presencePenalty`, `frequencyPenalty`, `repetitionContextSize`, `presenceContextSize`, and `frequencyContextSize` (the per-penalty windows are MLX-only; llama.cpp uses one shared window). The `GenerationParameter` capability enum gains matching `.minP`, `.repetitionPenalty`, `.presencePenalty`, and `.frequencyPenalty` cases so UI can render the right controls and `RouterBackend` can dispatch by required capability. MLX, llama.cpp, and Ollama backends all wire the new fields through to their native sampler APIs; OpenAI/Claude wiring is deferred (Claude's API doesn't support presence/frequency).

`BackendLoadOptions` is a separate type from `GenerationConfig` because llama.cpp wires KV cache quantization and Flash Attention into `ctxParams` at context-creation time — they cannot change per-generation without rebuilding the context. The split is deliberate so the API shape stays symmetric across MLX (which could change them per-generation) and llama. Calling `setLoadOptions` after a model is already loaded does not retune the live context. On the simulator, `flash_attn_type` is suppressed because Metal's FA kernels aren't reliable there. MLX silently ignores `flashAttention` because its SDPA path is always flash-attention-shaped.

The `LlamaGenerationDriver` `top_k` fix is a behaviour change for any caller that was setting `GenerationConfig.topK` and seeing no effect — `LlamaTopKConsumptionTests` uses `topK = 1` (greedy sampling) as the regression guard.

Default flips for `kvCacheQuantization = .q8` and `flashAttention = true` are deferred to issue [#1017](https://github.com/roryford/BaseChatKit/issues/1017) after the opt-in surface soaks. Persisting the new sampler fields through `SamplerPresetRecord` is deferred to [#1019](https://github.com/roryford/BaseChatKit/issues/1019) (requires `BaseChatSchemaV4` migration). DRY/XTC/mirostat samplers are tracked in [#1021](https://github.com/roryford/BaseChatKit/issues/1021).

See [#1022](https://github.com/roryford/BaseChatKit/pull/1022), [#1026](https://github.com/roryford/BaseChatKit/pull/1026).

## [0.16.2](https://github.com/roryford/BaseChatKit/compare/v0.16.1...v0.16.2) (2026-05-04)

### Highlights

#### End-to-end on-device image generation

v0.16.1 shipped `ImageGenerationBackend` as a protocol with no concrete conformers. This release closes the loop: a complete integration stack lands across nine PRs, making BaseChatKit a viable foundation for on-device image-generation apps alongside the text path it already serves. `ImageGenerationService` owns the backend lifecycle, `ImageGenerationRuntime` (in `BaseChatRuntime`) translates backend-level denoising events into `ImageRuntimeEvent`s keyed to message IDs and persists `.generatedImage` parts through the existing `MessageStore` port — no SwiftData migration required. `BaseChatBootstrap` gains an optional `imageGenerationService:` parameter; hosts that don't pass one get the identical text-only behaviour they had before.

```swift
let imageService = ImageGenerationService()
let bootstrap = try BaseChatBootstrap(
    configuration: config,
    imageGenerationService: imageService
)
#if MLX
imageService.registerMLXDiffusionBackend()  // Apple Silicon only
#endif
chatViewModel.configure(bootstrap)           // wires both runtimes in one call
```

The first concrete conformer, `MLXDiffusionBackend`, ships in `BaseChatBackends` behind the existing `MLX` trait and auto-detects SD 2.1 Base and SDXL Turbo layouts from the weights directory. `DiffusionModelCatalog` seeds the install UI with both models; `HuggingFaceService` gains a parallel `downloadDiffusionModel(from:to:progress:)` path for the multi-file safetensors layout. `MLXDiffusionBackend` depends on `mlx-swift-examples` at a revision pin (`357c97f`) pending the upstream library's next tagged release.

See [#1002](https://github.com/roryford/BaseChatKit/issues/1002), [#1003](https://github.com/roryford/BaseChatKit/pull/1003), [#1008](https://github.com/roryford/BaseChatKit/pull/1008), [#1009](https://github.com/roryford/BaseChatKit/pull/1009), [#1016](https://github.com/roryford/BaseChatKit/pull/1016), [#1018](https://github.com/roryford/BaseChatKit/pull/1018), [#1024](https://github.com/roryford/BaseChatKit/pull/1024), [#1025](https://github.com/roryford/BaseChatKit/pull/1025), [#1027](https://github.com/roryford/BaseChatKit/pull/1027), [#1028](https://github.com/roryford/BaseChatKit/pull/1028).

### Features

- **inference:** `ImageModelInfo` + `ImageModelFormat` value type for on-disk image models ([#1003](https://github.com/roryford/BaseChatKit/pull/1003))
- **inference:** `ImageGenerationService` — backend registration + lifecycle coordinator, sibling to `InferenceService` ([#1008](https://github.com/roryford/BaseChatKit/pull/1008))
- **inference:** `ImageModelLoadPlan` for diffusion memory pre-flight at load time ([#1009](https://github.com/roryford/BaseChatKit/pull/1009))
- **runtime:** `ImageGenerationRuntime` + `ImageRuntimeEvent` in `BaseChatRuntime` ([#1016](https://github.com/roryford/BaseChatKit/pull/1016))
- **huggingface:** diffusion download topology (multi-file safetensors) + `DownloadFileValidator` diffusion path ([#1018](https://github.com/roryford/BaseChatKit/pull/1018))
- **backends:** `MLXDiffusionBackend` — first `ImageGenerationBackend` conformer (SD 2.1 Base + SDXL Turbo, `MLX` trait) ([#1027](https://github.com/roryford/BaseChatKit/pull/1027))
- **ui:** `ChatViewModel.generateImage(prompt:config:)` + `imageGenerationProgress` observable dict ([#1024](https://github.com/roryford/BaseChatKit/pull/1024))
- **ui:** `ImageModelInstallView` + `DiffusionModelCatalog` in `BaseChatUIModelManagement` ([#1025](https://github.com/roryford/BaseChatKit/pull/1025))
- **persistence:** `BaseChatBootstrap` opt-in wiring — `imageGenerationService:` parameter + `configure(_:)` convenience ([#1028](https://github.com/roryford/BaseChatKit/pull/1028))

### Bug Fixes

- **runtime:** persist session B turn after switch-cancel-resend ([#1005](https://github.com/roryford/BaseChatKit/pull/1005))

## [0.16.1](https://github.com/roryford/BaseChatKit/compare/v0.16.0...v0.16.1) (2026-05-03)

### Highlights

#### ImageGenerationBackend — protocol foundation for on-device image generation

There was no stable contract for image-generation backends in BaseChatKit — any integration required host-app glue and a bespoke persistence strategy. `ImageGenerationBackend` defines the protocol surface (parallel to `InferenceBackend`, using `AnyObject + Sendable` to support the synchronous denoising loops that stable-diffusion.cpp conformers require) and introduces `MessagePart.generatedImage` for storing produced images in conversation history. No concrete backends ship in this release — the protocol and wire format are stable so downstream consumers can build against them now.

```swift
// Stub conformer — real diffusion backends implement this shape
final class MyDiffusionBackend: ImageGenerationBackend {
    var isLoaded: Bool { ... }
    func loadModel(_ config: ImageGenerationConfig) async throws { ... }
    func generate(_ config: ImageGenerationConfig) -> AsyncThrowingStream<ImageGenerationEvent, Error> { ... }
    func stopGeneration() { ... }
    func unloadModel() async { ... }
}
```

`ImageGenerationConfigSnapshot` is deliberately a separate type from `ImageGenerationConfig` so future runtime knobs do not silently change the on-disk wire format of saved image messages. No SwiftData migration needed — the new `.generatedImage` case is additive to the JSON-encoded `[MessagePart]` column.

See [#992](https://github.com/roryford/BaseChatKit/pull/992), [#987](https://github.com/roryford/BaseChatKit/issues/987), [#990](https://github.com/roryford/BaseChatKit/issues/990).

#### Bearer-token authentication for BaseChatServer

`BaseChatServer` had no authentication abstraction — hosts either used the raw `apiKey` field or handled auth outside the framework entirely. `RequestAuthMiddleware` is a new protocol with two built-in implementations: `AnonymousAuthMiddleware` (the default, zero behavior change for existing hosts) and `BearerTokenMiddleware` (constant-time `Authorization: Bearer <token>` validation with typed `AuthError` cases). `ServerApp.init` gains an optional `authMiddleware:` parameter; the legacy `apiKey` field is auto-wrapped as `BearerTokenMiddleware` so existing configuration compiles unchanged.

```swift
let server = ServerApp(
    configuration: config,
    authMiddleware: BearerTokenMiddleware(token: "secret", scopes: [.read, .write])
)
```

See [#994](https://github.com/roryford/BaseChatKit/pull/994), [#976](https://github.com/roryford/BaseChatKit/issues/976).

### Features

- **inference:** `ImageGenerationBackend` protocol + `MessagePart.generatedImage` case for on-device image generation ([#992](https://github.com/roryford/BaseChatKit/pull/992))
- **server:** `RequestAuthMiddleware` with `AnonymousAuthMiddleware` and `BearerTokenMiddleware` impls ([#994](https://github.com/roryford/BaseChatKit/pull/994))

### Bug Fixes

- **backends:** `OllamaBackend.processToolCalls` returns `Bool` to signal cancellation, preventing post-cancel `thinking` and `content` events from leaking when a single NDJSON line carries multiple payload fields ([#995](https://github.com/roryford/BaseChatKit/pull/995))

### Performance Improvements

- **test:** `swift test --parallel` enabled for the full XCTest batch; CI wall-clock drops ~47% and `scripts/test.sh` updated to parse streaming output mode ([#996](https://github.com/roryford/BaseChatKit/pull/996))

## [0.16.0](https://github.com/roryford/BaseChatKit/compare/v0.15.0...v0.16.0) (2026-05-03)

### Highlights

#### Verify downloaded weights with SHA-256

`DownloadableModel` and `CuratedModel` now accept an optional `expectedSHA256`. When set, `DownloadFileValidator` streams the SHA-256 digest as the file lands and rejects on mismatch — closing a Medium-severity finding from the April 2026 security review where a compromised mirror could serve tampered weights with valid GGUF magic bytes. Curated demo manifests can opt in per entry; user-supplied URLs stay unverified and are labeled as such in the model browser row.

```swift
CuratedModel(
    id: "smollm2-360m-instruct-q4-k-m",
    huggingFaceRepoID: "HuggingFaceTB/SmolLM2-360M-Instruct-GGUF",
    fileName: "smollm2-360m-instruct-q4_k_m.gguf",
    sizeBytes: 270_398_944,
    expectedSHA256: "5f3aa9..."  // populated from the HF LFS pointer
)
```

This is Phase 1 of [#367](https://github.com/roryford/BaseChatKit/issues/367); Phase 2 (Ed25519-signed manifests) and Phase 3 (strict mode where unverified downloads are rejected by default) remain. See [#978](https://github.com/roryford/BaseChatKit/pull/978).

#### `ModelInfo` factory for HuggingFace-sourced GGUFs

A new factory closes the awkward gap where post-download HF flows had to either hand-roll the public memberwise `ModelInfo.init` or fall back to `init?(ggufURL:)` (which re-reads file attributes the caller already had from the manifest).

```swift
guard let info = ModelInfo(
    huggingFaceRepoID: "Qwen/Qwen3-0.6B-GGUF",
    fileName: "Qwen3-0.6B-Q4_K_M.gguf",
    sizeBytes: 462_341_024,
    localURL: localPath
) else { return }
```

Trusts the caller-supplied `sizeBytes` (skipping the disk attributes lookup) but still reads the GGUF header so prompt-template detection, context length, architecture, raw chat template, and KV-cache estimate all populate. Adds an additive `huggingFaceRepoID: String?` stored property to `ModelInfo` for provenance — threaded through the public memberwise init with a default of `nil` so existing call sites compile unchanged. See [#981](https://github.com/roryford/BaseChatKit/pull/981).

### Bug Fixes

- **build:** trait-gate `BaseChatServer`'s `BaseChatBackends` dep — fixes "Multiple commands produce `llama.framework`" build error in `xcodebuild test` introduced by the v0.15.0 server-module collapse ([#983](https://github.com/roryford/BaseChatKit/pull/983))
- **build:** wrapper script for MLX integration tests with env passthrough — `scripts/test-mlx-integration.sh` patches `.xctestrun` so real-model tests don't silently `XCTSkip` ([#991](https://github.com/roryford/BaseChatKit/pull/991))
- **llama:** re-decode last 2 tokens batched in KV-reuse turn to match Metal kernel path — restores greedy determinism on Apple Silicon, where 1-token vs N-token decode kernels produced different FP accumulation ([#985](https://github.com/roryford/BaseChatKit/pull/985))
- **test:** chat-template the prompt in `test_fixture_eogTokenTerminatesStreamBeforeBudget_regression519` — modern instruct models only emit EOG inside a Jinja chat turn; the test now exercises the EOG path it was originally meant to guard ([#984](https://github.com/roryford/BaseChatKit/pull/984))

## [0.15.0](https://github.com/roryford/BaseChatKit/compare/v0.14.5...v0.15.0) (2026-05-02)

### Highlights

#### ConversationRuntime is the canonical turn-loop orchestrator

`ChatViewModel` previously fanned turn execution out through `GenerationCoordinator` (UI side, 613 LOC) and `ToolCallLoopOrchestrator` (inference side, 849 LOC), with a parallel "legacy" path kept alive for hosts that hadn't adopted `ConversationRuntime`. The cutover collapses both into the runtime: the UI turn loop, the tool-call loop, and the compaction trigger now live in one place. Net change is **−2255 LOC** with no behavior shift for hosts that go through `BaseChatBootstrap`.

```swift
// Default wiring — no code change needed
let bootstrap = BaseChatBootstrap.default()
let chatVM = bootstrap.chatViewModel

// Ad-hoc construction (e.g. tests, custom hosts) now takes a runtime
let chatVM = ChatViewModel(
    inferenceService: inference,
    conversationRuntime: ConversationRuntime(...)
)
```

**BREAKING:** hosts that build `ChatViewModel` directly must pass `conversationRuntime:` at init when they want a specific runtime. Without one, the view model spins up an in-memory runtime that's swapped to the SwiftData-backed one when `configure(persistence:)` runs — preserves single-process behavior, but multi-host setups should wire the runtime explicitly. Closes [#947]. See [#963].

#### Vision input across Claude and OpenAI

Both `ClaudeBackend` and `OpenAIBackend` now accept image content parts on user turns, matching the schemas each provider expects (`image` blocks with base64 source for Claude; `image_url` content parts for OpenAI). MLX vision shipped earlier ([#904](https://github.com/roryford/BaseChatKit/issues/904)); this release brings the cloud backends to parity. `LlamaBackend` multimodal remains tracked separately.

```swift
let imageData = try Data(contentsOf: imageURL)
let message = Message(
    role: .user,
    parts: [
        .text("What's in this image?"),
        .image(imageData, mimeType: "image/jpeg")
    ]
)
try await backend.generate(messages: [message], ...)
```

See [#944], [#960].

#### Trait-gating recovers default-build wall time + CI structural cost reduction

The previous release inadvertently doubled per-PR CI wall time by adding `Hummingbird` (and its swift-nio + NIOSSL + BoringSSL + AsyncHTTPClient transitive graph, ~18 pins) to the default build. `BaseChatServer` now sits behind a new `Server` SwiftPM trait, and the `@ToolSchema` macro plugin (~647 source files of swift-syntax) sits behind a new `Macros` trait — both off by default. A new `Package.resolved` budget check fails any PR that adds >2 new pins unless explicitly labeled `deps-ok`, preventing this exact regression in the future. Three more CI structural fixes (build-modes.full → nightly, security-audits batched, 7 lint jobs → 1) cut per-PR macOS wall time substantially.

```bash
# Server (HTTP API) — now opt-in
swift test --filter BaseChatServerTests --disable-default-traits --traits Server
swift run --traits Server BaseChatServer

# @ToolSchema macro — now opt-in
swift test --filter ToolSchemaMacro --disable-default-traits --traits Macros
```

**BREAKING:** consumers depending on `BaseChatServerCore` or running the `BaseChatServer` executable must add `--traits Server` (or list `Server` in their manifest); the same applies to `Macros` for `@ToolSchema` users. Without the trait, the targets still build but the executable prints a no-op message and exits cleanly. See [#946], [#957], [#954], [#955], [#956], [#961].

### Features

- **claude:** image content blocks for vision models ([#944](https://github.com/roryford/BaseChatKit/issues/944))
- **openai:** image_url content parts for vision models ([#960](https://github.com/roryford/BaseChatKit/issues/960))
- **runtime:** ConversationRuntime is the canonical turn-loop orchestrator ([#947](https://github.com/roryford/BaseChatKit/issues/947), [#963](https://github.com/roryford/BaseChatKit/issues/963))
- **server:** trait-gate BaseChatServer + add Package.resolved budget guardrail ([#946](https://github.com/roryford/BaseChatKit/issues/946))

### Performance Improvements

- **build:** trait-gate `@ToolSchema` macro behind `Macros` trait ([#957](https://github.com/roryford/BaseChatKit/issues/957))
- **ci:** batch security-audits' default-trait invocations ([#954](https://github.com/roryford/BaseChatKit/issues/954))
- **ci:** consolidate 7 ubuntu lint jobs into one runner ([#956](https://github.com/roryford/BaseChatKit/issues/956))
- **ci:** move `build-modes.full` to nightly + workflow_dispatch ([#955](https://github.com/roryford/BaseChatKit/issues/955))
- **ci:** spike `.build/debug` caching with mtime fix — Lever C of [#953](https://github.com/roryford/BaseChatKit/issues/953) ([#961](https://github.com/roryford/BaseChatKit/issues/961))

### Tests

- **userdefaults:** isolate `UserDefaults.standard` reads in download tests + add tripwire ([#910](https://github.com/roryford/BaseChatKit/issues/910), [#962](https://github.com/roryford/BaseChatKit/issues/962))

## [0.14.5](https://github.com/roryford/BaseChatKit/compare/v0.14.4...v0.14.5) (2026-05-02)

### Highlights

#### BaseChatServer — OpenAI-compatible local HTTP API

Embedding BCK inference in a separate process (a Python script, VS Code extension, shell tool) previously required manual HTTP wiring or a custom adapter per backend. `BaseChatServer` is a new executable target that wraps any registered inference backend — Ollama, Llama, MLX, Foundation, or cloud SaaS — behind an OpenAI-compatible HTTP surface: `/v1/chat/completions` (streaming and non-streaming), `/v1/models`, `/health`, and `/metrics`. Bearer auth, CORS, and a concurrency gate (`AsyncSemaphore`) are included out of the box.

```swift
// Launch from the command line:
// BaseChatServer --backend ollama --port 8080
// BaseChatServer --backend llama --model-path /path/to/model.gguf --api-key secret

// Or embed in an app target:
let config = ServerConfiguration(port: 8080, parallelGenerations: 2)
let server = ServerApp(configuration: config, backendProvider: provider)
try await server.run()
```

Three targets ship: `BaseChatServerCore` (protocols, adapters, HTTP plumbing), `BaseChatServerBackends` (trait-aware backend selection actor), and a thin `BaseChatServer` executable. The server stays out of `BaseChatUI` and `BaseChatRuntime`; opt in by adding the new targets to your app explicitly. Closes [#744].

#### MCP v1.1 polish — Foundation Models compatibility and tool error UX

Foundation Models enforces a stricter JSON Schema subset and caps registered tool count, causing silent filtering or registration failures for apps using BCK's built-in MCP integration. Tool call errors also surfaced as raw JSON in the chat UI. `MCPToolSource` now filters MCP tool schemas to the Foundation Models subset before registration and caps advertised tools at 16, while preserving dispatch for any tool beyond that cap. `ToolResult` gains structured error presentation strings and permission-denied re-auth CTA metadata, rendered by a new `ToolErrorView` in `BaseChatUI`.

```swift
// No API change needed — filtering happens inside MCPToolSource automatically.
let source = MCPToolSource(client: client)
// Tools beyond index 15 are hidden from Foundation's advertised list
// but remain fully dispatchable when called by name.
```

See [#792], [#940].

### Features

- **server:** add OpenAI-compatible BaseChatServer ([#939])
- **mcp:** Foundation Models schema filtering, 16-tool cap, and ToolResult error UX ([#940])

## [0.14.4](https://github.com/roryford/BaseChatKit/compare/v0.14.3...v0.14.4) (2026-05-01)

### Highlights

#### Llama backend offloads to Metal by default

A hardcoded `n_gpu_layers = 0` in `LlamaModelLoader` was paying a ~8x perf cost on every GGUF load in the name of an OOM scenario that no longer reproduces on current macOS. The default flips back to full Metal offload (`n_gpu_layers = 99`); an `LLAMA_FORCE_CPU_ONLY=1` env var keeps the CPU-only path one flag away for hosts that genuinely need it. A 4B chat model now loads in ~0.28 s instead of ~2.28 s, and a 26B MoE GGUF that originally motivated the workaround loads cleanly with ~520 MiB on the GPU.

```swift
// Default: all layers on Metal
let backend = LlamaBackend()
try await backend.loadModel(from: gguf, plan: .standard)

// Opt back into CPU-only on a constrained host:
//   LLAMA_FORCE_CPU_ONLY=1 ./MyApp
```

The simulator branch is unchanged — Metal stays disabled there because it isn't reliable. See [#938].

#### Example demo ships a working MCP integration

The demo's Connected Services sheet used to land on "No services configured" because the `MCPBuiltinCatalog` trait was off. With it enabled on the Example app, the catalog now lists Notion / Linear / GitHub plus, on macOS, a credential-free "Demo Echo (local, via npx)" entry that needs only Node on PATH. A new `mcp-echo` scenario card invokes `everything__echo` against the live MCP server, demonstrating tool calling end-to-end through MCP rather than only through the scripted backend.

```swift
// Lives in the Example target, not Sources/BaseChatMCP/
let descriptor = MCPServerDescriptor(
    id: "demo-echo",
    transport: .stdio(.npx(package: "@modelcontextprotocol/server-everything"))
)
```

`Sources/BaseChatMCP/` is unchanged. The descriptor and the new scenario both live in the Example target so the framework's public surface doesn't grow. See [#934].

### Features

- **fuzz:** parallel fuzz workers with deterministic seed sharding and findings-merge across isolated worker processes ([#920])
- **demo:** ship working MCP server and tool-calling-via-MCP scenario ([#934])

### Fixes

- **llama:** env-gate the `n_gpu_layers=0` TEMP — Metal offload is now the default, with `LLAMA_FORCE_CPU_ONLY=1` as the opt-out ([#938])
- guard `BaseChatVoice` in the iOS Simulator so the demo launches cleanly, and refresh CLAUDE.md / README to reflect the `BaseChatRuntime` + `BaseChatPersistenceSwiftData` split ([#931])
- opt in local model discovery for hardware / capability checks, and standardize pin hashing between the secure-enclave key manager and the pinned-session delegate ([#929])

## [0.14.3](https://github.com/roryford/BaseChatKit/compare/v0.14.2...v0.14.3) (2026-05-01)

### Highlights

#### Security defaults tighten around tools, OAuth, and downloads

AppIntent-backed tools now require approval by default, MCP OAuth tokens persist through the configured Keychain instead of an in-memory fallback, and model download plans can carry SHA-256 expectations that are enforced when present. These changes keep the default path safer without removing explicit opt-outs for read-only AppIntents, ephemeral token stores, or model metadata that does not yet provide checksums.

```swift
let tool = AppIntentToolExecutor(MyIntent.self)
let readOnlyTool = AppIntentToolExecutor(MyReadOnlyIntent.self, approvalPolicy: .readOnlyAutoApprove)
let tokenStore = MCPOAuthTokenStore.keychain()
let plan = ModelDownloadPlan.singleFile(
    url: modelURL,
    expectedChecksum: .init(algorithm: .sha256, hexDigest: expectedSHA256)
)
```

Checksum verification is skipped when no expected digest is provided, so existing model catalogs continue to download while metadata plumbing rolls forward. See [#921], [#924], [#926].

#### MCP and clipboard traffic stay inside reviewed boundaries

MCP streamable HTTP and OAuth requests now route through a shared session boundary, revalidate request-time and redirect destinations against the SSRF policy, and fail closed when the runtime network kill-switch is active. Chat copy actions use a single clipboard helper; on iOS it writes local-only, expiring pasteboard items so copied model output is less likely to sync across devices.

```swift
MCPTransportConfiguration(
    endpoint: serverURL,
    headers: [:],
    authorization: authorization,
    session: myPinnedSession
)
```

Explicit session injection remains available for hosts that need their own pinned or audited transport stack. See [#922], [#923], [#925].

### Features

- **downloads:** add `ModelFileChecksum` metadata and enforce SHA-256 validation when a model download plan provides an expected digest ([#924])

### Fixes

- **appintents:** require approval for `AppIntentToolExecutor` calls by default, with `.readOnlyAutoApprove` as an explicit opt-out for read-only intents ([#921])
- **clipboard:** route chat/code copy actions through `ClipboardWriter`; iOS copies are local-only and expire, while macOS keeps the existing `NSPasteboard` behavior ([#922])
- **mcp:** route default MCP HTTP/OAuth networking through `MCPURLSessionFactory` so the network-disabled boundary returns `MCPError.networkUnavailable` instead of using `URLSession.shared` directly ([#923])
- **mcp:** revalidate transport and OAuth request destinations, including redirects, before dispatching network calls ([#925])
- **mcp:** back `MCPOAuthTokenStore.keychain` with persistent Keychain storage and surface Keychain failures through the token store API ([#926])

[#921]: https://github.com/roryford/BaseChatKit/issues/921
[#922]: https://github.com/roryford/BaseChatKit/issues/922
[#923]: https://github.com/roryford/BaseChatKit/issues/923
[#924]: https://github.com/roryford/BaseChatKit/issues/924
[#925]: https://github.com/roryford/BaseChatKit/issues/925
[#926]: https://github.com/roryford/BaseChatKit/issues/926

## [0.14.2](https://github.com/roryford/BaseChatKit/compare/v0.14.1...v0.14.2) (2026-04-30)

### Highlights

#### Vision attachments land on the MLX path; mmproj scaffolding ready on llama.cpp

Image inputs now flow through the MLX chat path end-to-end: `ChatInputBar` adds an attachment picker, image I/O is moved off the main thread via `Task.detached(.userInitiated)`, and `MLXBackend.loadModel` deduplicates `ModelCapabilityProbe` so `config.json` is read once instead of three times per load. On the llama.cpp side, this release wires `MultimodalProjectorConfigurable`, `ModelInfo.mmprojURL` (auto-detected from `mmproj*.gguf` siblings), and `CuratedModel.mmprojFileName` straight through to `LlamaBackend` — `LlamaBackend.capabilities.supportsVision` is now driven by mmproj presence. Image inference itself still throws a clear `inferenceFailure` until the vendored `mattt/llama.swift` xcframework exposes `clip.h` / `mtmd.h`; this PR is the scaffolding that makes that future xcframework bump a one-line change.

```swift
// MLX vision attachment, picked up automatically when the model supports it
let parts: [MessagePart] = [
    .image(data: pngData, mimeType: "image/png"),
    .text("What's in this image?"),
]
try await chatViewModel.sendMessage(parts: parts)

// llama.cpp mmproj — auto-detected when the projector lives next to the GGUF
let info = ModelInfo(ggufURL: gemmaURL)
// info.mmprojURL → file:///…/mmproj-Gemma-4-2B.gguf
// backend.capabilities.supportsVision == true
```

See [#906], [#904] (commit [c4cb638]).

#### Phase 5 security hardening — `SecureBytes`, KV-cache wipe, Secure Enclave

API keys no longer round-trip through the Swift `String` heap on their way from the Keychain to an HTTP header. `SecureBytes` moves into `BaseChatInference/Security/` (raised to `package` visibility) so `KeychainService.retrieveSecure(account:)` can copy raw bytes directly into the zeroing buffer; the `String` is materialized only at the single `setValue(_:forHTTPHeaderField:)` call and dropped immediately. KV-cache residue is the second pass: `InferenceBackend.secureWipe()` (default no-op) is now called from `ChatViewModel.clearChat()` and `switchToSession()`. `LlamaBackend` zeros the KV tensor data via `llama_memory_clear(mem, true)`; `MLXBackend` evicts pooled Metal buffers via `Memory.clearCache()`. The third lever is `SecureEnclaveKeyManager`: an SE-resident P-256 keypair with ECIES wrap/unwrap, gracefully degrading to `.notAvailable` in Simulator and unsigned `swift test` runner environments.

```swift
// SecureBytes — no String allocation between Keychain and header
guard let key = keychain.retrieveSecure(account: "openai") else { return }
defer { key.zero() }
request.setValue("Bearer \(key.stringValue)", forHTTPHeaderField: "Authorization")

// secureWipe is now wired into chat lifecycle transitions
chatViewModel.clearChat()        // resetConversation() + secureWipe()
chatViewModel.switchToSession(s) // resetConversation() + secureWipe()
```

`SecureEnclaveKeyManager.isAvailable` returns `false` in Simulator and maps `errSecMissingEntitlement` (-34018) to `.notAvailable`, so unsigned test runners do not fail the security suite.

See [#907] (closes #730, #714 Phase 5).

### Features

- **runtime:** new non-blocking `BaseChatRuntime.build(...)` factory plus a `RuntimeBootstrapMilestone` event stream so app shells can surface bootstrap progress without blocking. The existing `BaseChatRuntime` initializer is preserved for backward compatibility ([#909])
- **llama:** `MultimodalProjectorConfigurable` opt-in protocol + `LlamaBackend` conformance; `ModelInfo.mmprojURL` auto-detection; `CuratedModel.mmprojFileName` / `DownloadableModel.mmprojFileName` for download UIs ([#906])
- **mlx:** image attachments wired through `ChatInputBar` and the MLX chat flow; image I/O moved off the main thread; `requiresVLMFactory(at:precomputedCapabilities:)` overload removes a redundant `config.json` read on every model load ([c4cb638])

### Fixes

- **openai:** `jsonMode` is now treated as a runtime-only per-request hint — removed from `GenerationConfig`'s `CodingKeys`, encoder, and decoder (legacy payloads with stale `"jsonMode": true` decode to `false`); for Ollama's OpenAI-compatible adapter, `OpenAIBackend` now also sets the legacy top-level `"format": "json"` alongside `response_format` so both providers see the request the way they expect ([#900])

[#900]: https://github.com/roryford/BaseChatKit/issues/900
[#904]: https://github.com/roryford/BaseChatKit/issues/904
[#906]: https://github.com/roryford/BaseChatKit/issues/906
[#907]: https://github.com/roryford/BaseChatKit/issues/907
[#909]: https://github.com/roryford/BaseChatKit/issues/909
[c4cb638]: https://github.com/roryford/BaseChatKit/commit/c4cb638f71af151e86248578536bc78f4660b96a

## [0.14.1](https://github.com/roryford/BaseChatKit/compare/v0.14.0...v0.14.1) (2026-04-29)

### Highlights

#### `BaseChatVoice` — opt-in speech input for chat composers

A new `Voice` trait gates a `BaseChatVoice` module that adds speech-to-text input, wake-word phrase detection, and a `WakeWordToast` UI accessory. The module slots into the existing composer-accessory seam, so a chat surface can adopt voice input without restructuring its view hierarchy. Wake-word detection runs on-device only.

The trait is opt-in; consumers that don't enable it pay no compile or binary cost. Hosts that turn it on must declare `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` in `Info.plist` and accept the documented simulator-microphone limitation. The demo app's voice accessory wiring shows the integration end-to-end.

See [#445](https://github.com/roryford/BaseChatKit/issues/445), [#887](https://github.com/roryford/BaseChatKit/pull/887).

#### Trait-gate HuggingFace; add opt-in `AnyLanguageModel` bridge

The HuggingFace search/download/validation surface moves out of `BaseChatInference` into a dedicated `BaseChatHuggingFace` target behind the default-on `HuggingFace` trait. Consumers that don't need the stock downloader can pass `--disable-default-traits` to drop it from the build graph entirely while keeping the surrounding inference orchestration. Existing consumers see no behavior change because the trait is default-on.

A new opt-in `AnyLanguageModel` trait adds a thin `InferenceBackend` adapter that bridges any `AnyLanguageModel`-conforming provider into BaseChatKit's inference pipeline, without folding those integrations into BaseChatKit proper. The bridge is default-off because it pulls a new transitive dependency.

See [#280](https://github.com/roryford/BaseChatKit/issues/280), [#896](https://github.com/roryford/BaseChatKit/pull/896).

### Features

- **voice:** new `BaseChatVoice` module behind the opt-in `Voice` trait — speech-to-text input, wake-word detection, `WakeWordToast` composer accessory, demo-app voice wiring, and required-permission docs ([#887](https://github.com/roryford/BaseChatKit/pull/887))
- **inference:** HuggingFace surface moved into a dedicated `BaseChatHuggingFace` target behind the default-on `HuggingFace` trait; protocol hooks remain in `BaseChatInference` so UI/examples compile with or without it ([#896](https://github.com/roryford/BaseChatKit/pull/896))
- **inference:** new opt-in `BaseChatAnyLanguageModelBridge` target behind the `AnyLanguageModel` trait, exposing a thin `InferenceBackend` adapter and dedicated tests ([#896](https://github.com/roryford/BaseChatKit/pull/896))

## [0.14.0](https://github.com/roryford/BaseChatKit/compare/v0.13.3...v0.14.0) (2026-04-29)

### Highlights

#### Persistence and command APIs are now `async throws`

Phase 0 of the runtime ports refactor showed that synchronous command APIs forced every adapter to dual-write — eager-reload now, consume events later — which undermines the single-source-of-truth event-stream shape that later phases need. v0.14.0 makes the prerequisite breaking move: `ChatPersistenceProvider` protocol methods, and the public mutators on `ChatViewModel` and `SessionManagerViewModel`, are now `async throws`. The result is one consistent async surface that future phases can compose against without compatibility shims.

```swift
// Before
sessionManager.configure(persistence: provider)
sessionManager.createSession(title: "New chat")

// After
sessionManager.configure(persistence: provider, autoLoad: true)
try await sessionManager.createSession(title: "New chat")
```

`SessionManagerViewModel.configure` gains a required `autoLoad: Bool` parameter (no default) so the behavior change is loud at every call site. Pass `true` to preserve pre-Phase-1.0 behavior, `false` if your bootstrap will call `await loadSessions()` itself; `configure(runtime:)` passes `autoLoad: true` automatically. `ChatViewModel.onFirstMessage` is now an `async` closure — typed-variable consumers must drop any `@MainActor` annotation. `stopGeneration()` deliberately stays synchronous so toolbar handlers and `scenePhase` teardown sites do not need `Task { … }` wrappers.

This is Phase 1.0 of the runtime ports refactor. Phase 1.1 (extracting `SessionListService`, already merged) and the upcoming Phase 1.2 `ConversationRuntime` extraction both depend on this surface.

See [#883], [#876].

### ⚠ BREAKING CHANGES

* `ChatPersistenceProvider` and the public command APIs on `ChatViewModel` / `SessionManagerViewModel` are now `async throws` ([#883](https://github.com/roryford/BaseChatKit/issues/883))
* `SessionManagerViewModel.configure(persistence:)` becomes `configure(persistence:autoLoad:diagnostics:)` with a required `autoLoad` parameter ([#883](https://github.com/roryford/BaseChatKit/issues/883))
* `ChatViewModel.onFirstMessage` is now an `async` closure ([#883](https://github.com/roryford/BaseChatKit/issues/883))

## [0.13.3](https://github.com/roryford/BaseChatKit/compare/v0.13.2...v0.13.3) (2026-04-28)

### Highlights

#### Sort order picker on the Model Selection tab

The Model Selection tab now exposes a sort-order control alongside the search field, with four orderings: `Alphabetical`, `Type`, `Size (Smallest First)`, and `Capability / Speed`. The comparator is extracted as `static ModelSelectionTabView.sortModels(_:by:)` so host apps and tests can drive it directly without mounting the view.

```swift
let ordered = ModelSelectionTabView.sortModels(
    models,
    by: .sizeSmallestFirst
)
```

All four orderings have name-based tie-breakers via `localizedStandardCompare`, and the picker selection is `@State` on the view — no host wiring required. See [#879](https://github.com/roryford/BaseChatKit/pull/879).

#### TTFT performance test no longer SIGTRAPs at process exit

`IntegratedStreamingPerformanceTests.testPerf_timeToFirstToken_realisticBackend` was fulfilling its measure-block expectation as soon as the first token arrived, leaving the unstructured `sendMessage()` task in flight past `tearDown()` — the task could then touch an invalidated `ModelContext` and trip a SIGTRAP at process exit. The fix splits the wait into a `firstTokenExp` (timed via `stopMeasuring()`) plus a separate `drainExp` that resolves only after `sendMessage()` fully returns, so the task is always joined inside the measure block.

A side-effect of the new pattern: per-iteration TTFT is now measured cleanly. The previous orphan-task arrangement leaked work between iterations and inflated the average to ~745 ms; corrected runs report ~104 ms with sub-1% relative standard deviation. See [#879](https://github.com/roryford/BaseChatKit/pull/879).

### Features

- **model-management:** `ModelSelectionSortOrder` enum and sort picker on the Model Selection tab; comparator is a public `static` helper on `ModelSelectionTabView` for unit testing ([#879](https://github.com/roryford/BaseChatKit/pull/879))

### Fixes

- **tests:** join the in-flight `sendMessage()` task inside the TTFT measure block so it cannot outlive `tearDown()` and access an invalidated `ModelContext`; corrects per-iteration measurement drift as a side-effect ([#879](https://github.com/roryford/BaseChatKit/pull/879))
- **demo:** small UX polish to the demo app's sidebar, memory indicator, and connected-services view; new `DemoNowTool` ([#879](https://github.com/roryford/BaseChatKit/pull/879))

## [0.13.2](https://github.com/roryford/BaseChatKit/compare/v0.13.1...v0.13.2) (2026-04-28)

### Highlights

#### Runtime bootstrap surface for app assembly

Previously, apps had to wire `InferenceService`, SwiftData containers, and session management into view lifecycle hooks — code that ran too late for some setup and was scattered across unrelated views. `BaseChatRuntime` in `BaseChatCore` establishes a first-class bootstrap contract: it installs `BaseChatConfiguration`, builds the inference service, SwiftData `ModelContainer`, and `SwiftDataPersistenceProvider` in a fixed order at app-assembly time, then exposes `configure(runtime:)` extensions on both `ChatViewModel` and `SessionManagerViewModel` for wiring everything in one call.

```swift
let runtime = try BaseChatRuntime(configuration: .default)
chatViewModel.configure(runtime: runtime)
sessionManagerViewModel.configure(runtime: runtime)
```

Apps that need a custom `InferenceService` (e.g. a `ToolRegistry` or approval gate) can pass it in; the runtime uses that instance and builds the rest around it. Apps using a custom `ChatPersistenceProvider` should continue calling `configure(persistence:)` directly — full custom-provider support is tracked in [#872](https://github.com/roryford/BaseChatKit/issues/872).

A companion `CompiledBackends` contract in `BaseChatInference` gives the runtime a single source of truth for which backends are compiled in (build profile, inference traits, local model types, remote providers), so `DefaultBackends`, `APIProvider.availableInBuild`, and `FrameworkCapabilityService` no longer maintain separate static trait logic. Host apps can switch over `CompiledBackends.current.buildProfile` (`.offline`, `.selfHosted`, `.saas`, `.full`) to decide what UI to show at startup without importing `BaseChatBackends`.

See [#866](https://github.com/roryford/BaseChatKit/pull/866), [#867](https://github.com/roryford/BaseChatKit/pull/867), [#869](https://github.com/roryford/BaseChatKit/pull/869), [#871](https://github.com/roryford/BaseChatKit/pull/871).

### Features

- **core:** new `BaseChatRuntime` type wires inference, SwiftData container, and persistence in a fixed bootstrap order; `configure(runtime:)` extensions on `ChatViewModel` and `SessionManagerViewModel` ([#866](https://github.com/roryford/BaseChatKit/pull/866))
- **inference:** `CompiledBackends` struct and `BackendBuildProfile` enum consolidate build-trait queries; removes scattered static trait checks from `DefaultBackends`, `APIProvider`, and `FrameworkCapabilityService` ([#867](https://github.com/roryford/BaseChatKit/pull/867))
- **examples:** MinimalExample and demo app migrated to runtime-first app assembly; README and DocC updated with `BaseChatRuntime` guidance and migration path from `configure(persistence:)` ([#869](https://github.com/roryford/BaseChatKit/pull/869))

### Fixes

- **example:** move SwiftData fetches and initial-model dispatch out of `MinimalExampleApp.init()` into a `.task { }` modifier so the first frame is not blocked on schema compilation ([#871](https://github.com/roryford/BaseChatKit/pull/871))
- **docs:** README + DocC migration prose now covers both `ChatViewModel.configure(runtime:)` and `SessionManagerViewModel.configure(runtime:)` ([#871](https://github.com/roryford/BaseChatKit/pull/871))

## [0.13.1](https://github.com/roryford/BaseChatKit/compare/v0.13.0...v0.13.1) (2026-04-27)

### Highlights

#### File-spilling action for oversize tool results

Tool results that exceed a byte threshold can now be diverted to disk and replaced with a path-bearing message, so the agent loop continues without blowing the context window. The pattern mirrors Goose AI's large-response handler — the spilled file stays available for follow-up tools (`read_file`, `grep`, etc.) to act on selectively.

```swift
let policy = ToolOutputPolicy(
    threshold: 32_000,
    action: .spillToFile(threshold: 32_000) { byteCount, url in
        "Tool result was \(byteCount) bytes; stored at \(url.path) for follow-up reads."
    }
)
```

Spills land under `Caches/BaseChatKit/tool-spills/`; iOS writes use `NSFileProtectionCompleteUntilFirstUserAuthentication`. `ToolSpillReaper.cleanOldSpills(maxAge:)` runs from `InferenceService.init` (default 7 days) so spills don't accumulate across sessions, and IO failure degrades gracefully to truncate semantics with a `Log.inference.warning` rather than trapping. The host app is responsible for registering a file-reading tool — the policy doesn't gate on its presence, by design. See [#846](https://github.com/roryford/BaseChatKit/issues/846), [#859](https://github.com/roryford/BaseChatKit/pull/859).

### Features

- **tools:** new `OversizeAction.spillToFile(threshold:message:)` case on `ToolOutputPolicy`, plus `ToolSpillReaper` reaper wired into `InferenceService.init` ([#846](https://github.com/roryford/BaseChatKit/issues/846), [#859](https://github.com/roryford/BaseChatKit/pull/859))
- **chore:** address 4 governance findings — README platform floor now matches `Package.swift` (iOS 18 / macOS 15), API-key memory claim narrowed to match `docs/FIPS.md`, `.claude/settings.local.json` moved to per-developer (gitignored), Conventional Commit policy clarified as PR-title-only enforcement ([#833](https://github.com/roryford/BaseChatKit/issues/833), [#859](https://github.com/roryford/BaseChatKit/pull/859))

### Fixes

- **fuzz:** align fuzz backend configuration — extracts real fuzz factories into a shared `BaseChatFuzzBackends` target, rewires `fuzz-chat` and the fuzz tests to use it, and aligns MLX/GGUF model discovery with env-driven overrides so the Xcode-hosted MLX runner reads the same campaign inputs as the shell wrapper ([#857](https://github.com/roryford/BaseChatKit/pull/857))

## [0.13.0](https://github.com/roryford/BaseChatKit/compare/v0.12.5...v0.13.0) (2026-04-27)

### Highlights

#### Goose Tier 1 patterns — argument coercion, structured loop findings, fast-backend slot

Ports four self-contained patterns from Goose AI's agent runtime. Three harden BCK's tool-calling path; one opens the door to multi-model dispatch. `ToolRegistry` now coerces top-level string arguments to the schema-declared primitive type before validation, so models that emit `"42"` (string) when the schema declares `integer`, or `"true"` when the schema declares `boolean`, no longer fail validation. Coercion only applies at the top level — nested objects and arrays pass through unchanged. Default ON; opt out with `registry.coercesArguments = false`.

`TurnHistoryCompressor` gains a `CompactionTrigger` (`.automatic`, `.toolLoop`, `.manual`); the default budget compressor appends a context-appropriate continuation prompt so models do not acknowledge that summarization happened. Existing custom compressors keep working unchanged via a default protocol extension.

`ToolLoopEvent.loopDetected` now carries a `ToolLoopFinding` payload with a stable `findingID` (`"REP-001"`), `toolName`, `reason`, and `repetitionCount`. **Breaking** — pattern matches must extract from the finding instead of binding the bare name:

```swift
case .loopDetected(let finding) where finding.findingID == "REP-001":
    print("loop on \(finding.toolName) ×\(finding.repetitionCount): \(finding.reason)")
```

`InferenceService` gains an optional `fastBackend` slot for routing lightweight subtasks (future LLM-driven summarization, session naming) to a smaller model first, with primary-backend fallback on failure. Additive and opt-in — hosts that don't set `fastBackend` see no change. The deferred file-spilling pattern from Goose is tracked in [#846](https://github.com/roryford/BaseChatKit/issues/846).

See [#852](https://github.com/roryford/BaseChatKit/pull/852).

#### Cross-backend tool-call unification — typed lifecycle + MCP error taxonomy

`GenerationEvent` gains typed lifecycle phases for tool dispatch so consumers can drive UI spinners and throbbers without string-matching streaming text. The new cases cover approval gating, registry execution, and synthesized non-dispatch outcomes (denial, identical-call short-circuit, byte-budget exhaustion). Duration is measured against the monotonic `DispatchTime` clock so wall-clock jumps don't skew it.

`MCPError` now maps exhaustively to `ToolResult.ErrorKind` via a package-scoped mapper. MCP tool failures surface alongside native tool failures using the same nine `ErrorKind` cases the orchestrator already distinguishes — cross-backend tool-calling code (Wave 1 of [#753](https://github.com/roryford/BaseChatKit/issues/753)) no longer needs a parallel error path for MCP.

```swift
for try await event in stream.events {
    switch event {
    case .toolDispatchStarted(let dispatch):
        spinner.start(toolName: dispatch.toolName)
    case .toolDispatchCompleted(let outcome):
        spinner.stop(durationMs: outcome.durationMs)
    default: break
    }
}
```

See [#849](https://github.com/roryford/BaseChatKit/pull/849), [#848](https://github.com/roryford/BaseChatKit/pull/848).

### Features

- **inference:** Goose Tier 1 patterns — `ToolArgumentCoercer`, `CompactionTrigger`, `ToolLoopFinding` (REP-001), optional `fastBackend` slot ([#852](https://github.com/roryford/BaseChatKit/pull/852))
- **inference:** typed tool-dispatch lifecycle events on `GenerationEvent` with monotonic duration measurement ([#849](https://github.com/roryford/BaseChatKit/pull/849))
- **mcp:** exhaustive `MCPError` → `ToolResult.ErrorKind` mapping via `MCPErrorMapping.swift`, replacing the executor-local mapping path ([#848](https://github.com/roryford/BaseChatKit/pull/848))
- **demo:** tool-call error scenarios — invalid args, rate-limit retry, MCP failure — with scripted-backend turn sequences for UITests ([#850](https://github.com/roryford/BaseChatKit/pull/850))

### Fixes

- **fuzz:** Ollama trait gap + empty-arg expansion + thinking-loop guard ([#844](https://github.com/roryford/BaseChatKit/pull/844))

### Internal

- **core:** SwiftData round-trip coverage for `ChatMessage.contentParts` containing `.text`/`.toolCall`/`.toolResult`, plus pinned discriminator strings + legacy `isError` decode regression ([#847](https://github.com/roryford/BaseChatKit/pull/847))
- **backends:** demote `MLXToolCallParser` from `public` to `package` — never intended as a public API ([#851](https://github.com/roryford/BaseChatKit/pull/851))

## [0.12.5](https://github.com/roryford/BaseChatKit/compare/v0.12.4...v0.12.5) (2026-04-27)

### Highlights

#### Llama tool calling — Gemma 4 native format + GBNF schema pre-validator

Gemma 4 GGUF models loaded via llama.cpp now do tool calling. Pass `ToolDefinition` values in `GenerationConfig.tools`, select the `.gemma4` prompt template, and the framework injects `<|tool>` declaration blocks into the system turn and parses `<|tool_call>…<|end_of_turn>` tokens off the stream into `GenerationEvent.toolCall` events. The wire shape (`ToolCall(id:toolName:arguments:)`) matches `FoundationBackend` (#812), MLX, Ollama, Claude, and OpenAI — orchestrator and detectors don't care which backend produced the call.

```swift
let backend = LlamaBackend()
try await backend.loadModel(from: ggufURL, plan: plan)

var config = GenerationConfig()
config.tools = [getWeatherTool]   // ToolDefinition with JSON-Schema parameters
config.promptTemplate = .gemma4

let stream = try backend.generate(
    prompt: "What's the weather in Paris?",
    systemPrompt: "You are a helpful assistant.",
    config: config
)
for try await event in stream.events {
    if case .toolCall(let call) = event { /* dispatch */ }
}
```

A separate `GBNFSchemaPreValidator` guards GBNF grammar compilation against CVE-2026-2069 (buffer overflow in `llama_grammar_advance_stack()`; the vendored llama.cpp build b8772 is pre-fix). The validator rejects schema combiners and nullable union types before they reach `llama_sampler_init_grammar`, with index-qualified failure paths so tool authors get an actionable error. See `LLAMA_CONTRACT.md` § Security for the upgrade procedure once the xcframework pin moves past b8773. See [#836](https://github.com/roryford/BaseChatKit/pull/836), [#414](https://github.com/roryford/BaseChatKit/issues/414), [#609](https://github.com/roryford/BaseChatKit/issues/609).

#### Fuzz detectors — calibration corpus + FP/TP gate

`ToolCallValidityDetector` (shipped in v0.12.4 with three sub-checks at `.flaky` severity) now has a 265-record labeled corpus and a `CalibrationTests` harness that gates each single-turn detector at FP rate < 2% and TP rate > 80%. This is the prerequisite for promoting detectors from `.flaky` to `.confirmed` — sub-checks that pass calibration get routed into the high-signal tier, the noisy ones stay quarantined.

```swift
swift test --filter CalibrationTests --disable-default-traits --traits Fuzz
// Each detector is run against ~210 good + ~55 bad records;
// gate fails if FP ≥ 2% or TP ≤ 80% per sub-check.
```

The corpus runs locally and on the nightly job, not per-PR — the gate is load-bearing for severity decisions, not a CI tripwire on every push. New detectors register a coverage exemption via `coverageExempt` with a tracking-issue link until their corpus records are authored. See [#837](https://github.com/roryford/BaseChatKit/pull/837), [#488](https://github.com/roryford/BaseChatKit/issues/488).

#### Share + Action extension recipes

`BaseChatDemo` ships two iOS app extensions — Share and Action — that show how to pipe content from the system Share sheet or action row into a new BaseChatKit chat session. The extensions are intentionally thin: they write a `PendingSharePayload` to an App Group `UserDefaults` key and complete immediately. The host app drains the payload on the next foreground transition and hands it to `ChatViewModel.ingestPendingPayload(_:intent:)` — no inference happens inside the extension sandbox.

```swift
// In your App body:
.onChange(of: scenePhase) { _, newPhase in
    if newPhase == .active { checkForPendingSharePayload() }
}
.task(id: payloadID) { await viewModel.ingestPendingPayload(payload, intent: .summarise) }
```

The companion `.task(id:)` modifier handles the cold-launch race where `scenePhase` fires `.active` before the SwiftData container finishes initialising. See `docs/share-action-extension-recipe.md` for the full integration guide. See [#840](https://github.com/roryford/BaseChatKit/pull/840).

### Features

- **llama:** Gemma 4 tool calling via `<|tool_call>` parser + `GBNFSchemaPreValidator` guarding against CVE-2026-2069 ([#836](https://github.com/roryford/BaseChatKit/pull/836))
- **fuzz:** 265-record calibration corpus + `CalibrationTests` FP/TP gate (FP < 2% / TP > 80% per sub-check) for detector severity promotion ([#837](https://github.com/roryford/BaseChatKit/pull/837))
- **example:** Share + Action extension targets in `BaseChatDemo` with App Group `UserDefaults` handoff and `ChatViewModel.ingestPendingPayload(_:intent:)` ([#840](https://github.com/roryford/BaseChatKit/pull/840))

### Internal

- **inference:** injectable `Sleeper` and `JitterProvider` closures on `RetryStrategy` / `withRetry` / `SSECloudBackend` for deterministic retry tests, with NaN-safe jitter clamping and ms-rounded delay logging ([#839](https://github.com/roryford/BaseChatKit/pull/839))

## [0.12.4](https://github.com/roryford/BaseChatKit/compare/v0.12.3...v0.12.4) (2026-04-27)

### Highlights

#### `FoundationBackend` learns tool calling

Apple's on-device Foundation Models SDK (Xcode 26.4) doesn't expose a function-calling surface, but it does expose `GuidedGeneration` over `Generable` / `GenerationSchema`. `FoundationBackend` now synthesizes tool calling on top of that channel: registered `ToolDefinition`s compile into a `(text | tool_call)` sum-type schema via `DynamicGenerationSchema`, the on-device model produces a constrained envelope, and the existing `ToolCallLoopOrchestrator` drives the round trip — same loop the cloud and MLX backends use. The wire shape (`ToolCall(id:toolName:arguments:)`) matches MLX/Ollama/Claude/OpenAI exactly, and the tool surface respects the v0.12.1 `MCPToolFilter` 16-tool cap.

```swift
let backend = FoundationBackend()
try await backend.loadModel(from: url, plan: plan)

var config = GenerationConfig()
config.tools = [getWeatherTool]   // ToolDefinition with JSON-Schema parameters

let stream = try backend.generate(
    prompt: "What's the weather in Paris?",
    systemPrompt: "You are a helpful assistant.",
    config: config
)
for try await event in stream.events {
    if case .toolCall(let call) = event { /* dispatch */ }
}
```

Apps with no tools registered are unaffected — the existing text-only path is unchanged. Schema-build failures (unsupported JSON-Schema construct in a registered tool) log a warning and fall back to plain generation rather than crashing. See [#812](https://github.com/roryford/BaseChatKit/pull/812), [#434](https://github.com/roryford/BaseChatKit/issues/434).

#### Capability-aware backend routing

When an app holds two or more loaded backends — say a small local model plus a more capable cloud one — `RouterBackend` now dispatches each request to the first child whose `BackendCapabilities` satisfies the request's `requiredCapabilities`. The new `GenerationConfig.requiredCapabilities` field is open by default (empty set), so existing call sites are unaffected; opt in per request when you need a specific guarantee like tool calling or a minimum context window.

```swift
let router = RouterBackend(children: [smallLocal, capableCloud])

let config = GenerationConfig(
    requiredCapabilities: [.toolCalling, .minContextTokens(8_000)]
)
let stream = try router.generate(prompt: prompt, systemPrompt: nil, config: config)
```

If no child satisfies the requirements `RouterBackend` throws `InferenceError.noBackendSatisfiesRequirements` listing the missing capabilities — picking a model is the host's job, not the router's. Single-child dispatch per request: no fan-out, retry, or load-balancing. Lifecycle ops (`stopGeneration`, `unloadModel`, `resetConversation`) fan out to every child; `loadModel` is rejected on the router. See [#810](https://github.com/roryford/BaseChatKit/pull/810), [#438](https://github.com/roryford/BaseChatKit/issues/438), [#439](https://github.com/roryford/BaseChatKit/issues/439).

#### MLX KV cache reuse across turns

Local MLX models now reuse the longest-common-prefix KV cache across turns, so a multi-turn conversation no longer re-prefills the system prompt + history on every send. After a successful generate, `MLXBackend` snapshots the prompt-only KV state on the main actor; the next turn restores the snapshot if the new prompt's token-id prefix matches and continues from there. Cache invalidation covers `loadModel`, `unloadModel`, `resetConversation`, prefix mismatch, and direct `_inject` writes; the snapshot is `@MainActor`-pinned to avoid racing the GPU scheduler.

```swift
// First turn: full prefill.
let s1 = try backend.generate(prompt: p1, systemPrompt: sys, config: config)
for try await _ in s1.events {}

// Second turn: shared prefix → KV restored, only the delta is prefilled.
let s2 = try backend.generate(prompt: p1 + " Tell me more.", systemPrompt: sys, config: config)
```

Token-id-level matching (not string-level), single-snapshot cap (no LRU memory growth). See [#814](https://github.com/roryford/BaseChatKit/pull/814), [#749](https://github.com/roryford/BaseChatKit/issues/749).

### Features

- **inference:** `RouterBackend` + `GenerationConfig.requiredCapabilities` for capability-aware multi-backend dispatch ([#810](https://github.com/roryford/BaseChatKit/pull/810))
- **inference:** opt-in `TurnHistoryCompressor` on `ToolCallLoopOrchestrator` folds older agent-loop rounds into a `step N: tool(args) → result` summary while keeping the most recent N verbatim — `BudgetTurnHistoryCompressor` ships in-tree, default is no-op so existing callers are unaffected ([#811](https://github.com/roryford/BaseChatKit/pull/811))
- **foundation:** tool calling on `FoundationBackend` via `Generable` / `GuidedGeneration` ([#812](https://github.com/roryford/BaseChatKit/pull/812))
- **fuzz:** `ToolCallValidityDetector` with five sub-checks (`malformed-json-args`, `schema-violation`, `id-reuse`, `orphan-result`, `toolchoice-violation`) — `id-reuse` and `orphan-result` ship at `.confirmed` (zero-FP-by-construction transcript invariants), the others at `.flaky` pending the calibration corpus in [#488](https://github.com/roryford/BaseChatKit/issues/488); `RunRecord` now carries `toolCalls`/`toolResults`/`toolDefinitions` for replay; `--tools` flag on `fuzz-chat` injects a `SyntheticToolset` ([#813](https://github.com/roryford/BaseChatKit/pull/813))
- **backends:** MLX KV cache prefix reuse across turns ([#814](https://github.com/roryford/BaseChatKit/pull/814))

### Fixes

- **mlx:** skip the inference step in `Gemma4MoESmokeTests` so the C++ broadcast-shape abort (`MLX/ErrorHandler.swift:343 Fatal error: [broadcast_shapes] Shapes (20) and (39) cannot be broadcast`) no longer kills the whole test process — `setUp()` still validates VLM-factory routing on hardware, only `generate()` is `XCTSkip`-ped, with a `FIXME` pointing at [#802](https://github.com/roryford/BaseChatKit/issues/802) so the skip is lifted when upstream `mlx-swift-lm` ships the fix ([#835](https://github.com/roryford/BaseChatKit/pull/835))

## [0.12.3](https://github.com/roryford/BaseChatKit/compare/v0.12.2...v0.12.3) (2026-04-27)

### Highlights

#### Priority-aware prompt budget allocation

`PromptAssembler` now treats slots by *role* instead of by insertion order. A new `PromptSlotRole` enum (`system`, `characterContext`, `userInstruction`, `ragRetrieved`, `archivalMemory`, `graphRetrieval`, `toolResult`) drives a `BudgetPolicy` so consumers can declare per-role caps and trim priority — RAG snippets get dropped before character context when the budget gets tight, and `.system` is never trimmed.

```swift
let policy = BudgetPolicy.default.with(
    priority: [.system: 100, .characterContext: 80, .userInstruction: 60, .ragRetrieved: 20],
    caps: [.ragRetrieved: 1024]
)
let assembled = PromptAssembler.assemble(
    slots: [PromptSlot(id: "char", role: .characterContext, content: charCard),
            PromptSlot(id: "rag",  role: .ragRetrieved,     content: retrievedDocs)],
    messages: history, systemPrompt: sys,
    contextSize: 8192, responseBuffer: 1024,
    tokenizer: tokenizer, policy: policy
)
```

Existing call sites default to `.userInstruction` — no source-level breaking change. The allocator is now drop-only (a slot is admitted in full or dropped wholesale), which fixes a real correctness bug where the prior implementation reduced `ResolvedSlot.tokenCount` to fit a cap without actually truncating content, so `budgetBreakdown` under-reported what the model received.

See [#819](https://github.com/roryford/BaseChatKit/pull/819).

#### Built-in conversation export — markdown + JSONL

`BaseChatCore` now ships a `ConversationExportFormat` protocol with two built-in implementations (`MarkdownExportFormat`, `JSONLExportFormat`) and a `ConversationExporter` that produces a `ShareableFile` for `ShareLink`. `BaseChatUI` adds a drop-in `ExportButton` toolbar item — apps no longer hand-roll session serialisation.

```swift
import BaseChatCore
import BaseChatUI

ChatView()
    .toolbar {
        ExportButton(session: session, format: MarkdownExportFormat())
    }
```

Filename sanitisation falls back to `chat` for empty/whitespace-only titles, replaces banned path characters with `_`, and caps the stem at 80 chars. JSONL writes one valid JSON object per `\n`-terminated line for streaming consumers; the markdown formatter skips thinking-only and tool-only turns so the output stays user-readable.

See [#820](https://github.com/roryford/BaseChatKit/pull/820).

#### iOS background-task scheduling with a memory-budget contract

Apps running extraction pipelines, vector indexing, or other post-generation work now share a single seam — `BackgroundTaskScheduler` — instead of each wiring `BGTaskScheduler` and watchdog logic independently. `DefaultBackgroundTaskScheduler` submits a `BGProcessingTaskRequest` on iOS, runs inline on macOS, and samples `phys_footprint` against a `MemoryBudget` ceiling — when the sampled footprint exceeds the ceiling, the worker `Task` is cancelled and the closure observes `Task.isCancelled` to settle gracefully.

```swift
let scheduler: any BackgroundTaskScheduler = DefaultBackgroundTaskScheduler()
try await scheduler.schedule(
    identifier: "com.app.indexer",
    budget: MemoryBudget(ceiling: 256_000_000, sampleInterval: .seconds(2))
) {
    try await indexer.runUntilDoneOrCancelled()
}
```

`MockBackgroundTaskScheduler` ships in `BaseChatTestSupport` with `simulateMemoryBudgetExceeded(identifier:)` so the cancellation contract is testable deterministically. `ChatViewModel` wire-up for `PostGenerationTask` dispatch is deferred to the PR that introduces #111.

See [#829](https://github.com/roryford/BaseChatKit/pull/829).

### Features

- **inference:** typed `PromptSlotRole` + `BudgetPolicy` for priority-aware prompt budget allocation ([#819](https://github.com/roryford/BaseChatKit/pull/819))
- **core:** `ConversationExportFormat` protocol with `MarkdownExportFormat` + `JSONLExportFormat`, plus a `BaseChatUI` `ExportButton` ([#820](https://github.com/roryford/BaseChatKit/pull/820))
- **core:** `BackgroundTaskScheduler` protocol + iOS `BGTaskScheduler` impl with shared memory-budget cancellation contract ([#829](https://github.com/roryford/BaseChatKit/pull/829))

### Security & supply chain

- **security:** `SECURITY.md` + `THREAT_MODEL.md` + indexed `CONTRIBUTING.md` ([#823](https://github.com/roryford/BaseChatKit/pull/823))
- **security:** FIPS 140-3 posture documentation ([#821](https://github.com/roryford/BaseChatKit/pull/821))
- **security:** `sandbox-exec` net-deny test harness — verifies offline-mode backends don't leak network calls ([#827](https://github.com/roryford/BaseChatKit/pull/827))
- **security:** `SecureBytes` zeroing assertion via DEBUG inspection seam ([#824](https://github.com/roryford/BaseChatKit/pull/824))
- **release:** build-provenance attestations + CycloneDX SBOM emitted on release ([#828](https://github.com/roryford/BaseChatKit/pull/828))
- **repo:** `CODEOWNERS` for security-sensitive paths ([#822](https://github.com/roryford/BaseChatKit/pull/822))

### CI & tooling

- **ci:** `offline` / `ollama` / `saas` / `full` build-mode matrix + binary symbol audit ([#832](https://github.com/roryford/BaseChatKit/pull/832))
- **fuzz:** `RunRecord.rendered` now flows through the real markdown transform pipeline ([#830](https://github.com/roryford/BaseChatKit/pull/830))
- **fuzz:** explicit `supportsDeterministicReplay` contract pins for `FoundationFuzzFactory` and `LlamaFuzzFactory` ([#825](https://github.com/roryford/BaseChatKit/pull/825), [#831](https://github.com/roryford/BaseChatKit/pull/831))
- **perf:** integrated streaming performance suite gated by `RUN_SLOW_TESTS=1` ([#826](https://github.com/roryford/BaseChatKit/pull/826))

### Docs

- **plans:** `BaseChatServer` implementation plan for #744 ([#806](https://github.com/roryford/BaseChatKit/pull/806))

### Dependencies

- **deps:** `github.com/mattt/llama.swift` 2.8936.0 → 2.8941.0 ([#818](https://github.com/roryford/BaseChatKit/pull/818))
- **deps:** `dorny/paths-filter` 3 → 4 ([#817](https://github.com/roryford/BaseChatKit/pull/817))
- **deps:** `trufflesecurity/trufflehog` 3.94.3 → 3.95.2 ([#816](https://github.com/roryford/BaseChatKit/pull/816))
- **deps:** `googleapis/release-please-action` 4 → 5 ([#815](https://github.com/roryford/BaseChatKit/pull/815))

## [0.12.2](https://github.com/roryford/BaseChatKit/compare/v0.12.1...v0.12.2) (2026-04-26)

### Highlights

#### Forward `prefill_progress` SSE events from cooperating upstream servers

Long-context local models can spend 5–30 seconds evaluating a prompt before the first token, and the OpenAI wire protocol has no signal for it — chat UIs are stuck showing nothing until the first content delta. `OpenAIBackend` now forwards `prefill_progress` SSE events from cooperating upstream servers (e.g. the planned `BaseChatServer` proxy in #744), surfaced as a new `GenerationEvent.prefillProgress(nPast:nTotal:tokensPerSecond:)` case so views can show "evaluating prompt 70%" instead of a blank screen.

```swift
let config = GenerationConfig(streamPrefillProgress: true)
let stream = try backend.generate(prompt: prompt, systemPrompt: nil, config: config)
for try await event in stream.events {
    if case .prefillProgress(let nPast, let nTotal, _) = event {
        promptProgress = Double(nPast) / Double(nTotal)
    }
}
```

Off by default for OpenAI wire compatibility — opt in with `streamPrefillProgress: true` and the backend adds an `X-BaseChat-Prefill-Progress: true` request header so cooperating servers know to emit the events. Producer wiring for local backends (Llama, MLX, Foundation) is tracked separately under #746.

#### Per-PR CI runtime cut by ~43%

CI on a typical PR went from ~6m26s to ~3m41s by moving two non-correctness suites — `TrafficBoundaryAuditTest` (source-tree regex audit, ~50s) and `LargeSessionListPerformanceTests` (XCTMeasure baselines on a 1000-session SwiftData fixture, ~65s) — to a new `nightly-slow-tests.yml` workflow. Both still run unconditionally on local `swift test` (no env gate) and on the nightly job (`RUN_SLOW_TESTS=1`), so the boundary-rule signal and perf regression detection are preserved without paying ~115s of test-execution time on every PR.

See [#803], [#804].

### Features

- **openai:** forward `prefill_progress` SSE events from compatible upstream servers ([#804](https://github.com/roryford/BaseChatKit/issues/804))

### Fixes

- **tests:** add `.prefillProgress` arm to the Ollama-trait replay switch — was breaking local Ollama E2E and the planned `--traits Ollama` CI tier ([#808](https://github.com/roryford/BaseChatKit/issues/808))

### Performance Improvements

- **ci:** move `TrafficBoundaryAuditTest` + `LargeSessionListPerformanceTests` to a nightly workflow — drops per-PR CI from ~6m26s to ~3m41s ([#803](https://github.com/roryford/BaseChatKit/issues/803))

## [0.12.1](https://github.com/roryford/BaseChatKit/compare/v0.12.0...v0.12.1) (2026-04-26)

### Highlights

#### Bridge any `AppIntent` into the tool-calling pipeline

Hosts that wanted to expose `AppIntent`s — Shortcuts actions, Siri-callable verbs, Spotlight commands — as model-callable tools previously had to hand-write a `ToolExecutor` per intent and re-encode every `@Parameter` declaration into JSON Schema by hand. v0.12.1 ships a new optional `BaseChatAppIntents` module that wraps any `AppIntent & Decodable` in an `AppIntentToolExecutor`, derives the tool's JSON Schema from `@Parameter` reflection, decodes the model's argument payload into a fresh intent instance, runs `perform()`, and surfaces the result through the standard `ToolResult` shape.

```swift
import BaseChatAppIntents

let registry = ToolRegistry()
registry.register(AppIntentToolExecutor(SetReminderIntent.self))
inferenceService.toolRegistry = registry
```

Schema synthesis covers `String`, `Int`/`Int32`/`Int64`, `Double`/`Float`/`CGFloat`, `Bool`, `Date` (decoded as ISO-8601 to match the advertised `format: date-time`), `URL`, optionals (recursive, marked non-required), and `IntentEnumParameter`-conforming enums (rendered as `enum: [...]`). Authorisation failures classify as `.permissionDenied`, decode failures as `.invalidArguments`. The module depends only on `BaseChatInference` and is gated `@available(iOS 26, macOS 26, *)`, so apps with older deployment floors can opt in behind `if #available`.

See [#798](https://github.com/roryford/BaseChatKit/pull/798).

#### Narrow the MCP tool surface when Apple's Foundation Models backend is active

Apple's on-device Foundation Models tool-calling surface rejects schemas that use `oneOf`, `anyOf`, `$ref`, or deeply nested objects/arrays — and caps the visible tool set per generation. Apps wiring `BaseChatMCP` against an MCP server that exposes 50+ tools (Notion, Linear, GitHub) would silently fail when Foundation Models was the active backend. v0.12.1 adds two cooperating filters: a schema-compatibility walker that visits every JSON Schema sub-keyword (`allOf`, `not`, `additionalProperties`, `$defs`, `prefixItems`, …) and a public 16-tool cap.

```swift
let names = await source.foundationModelsEnabledNames()  // schema-compatible + capped to 16
let filter = MCPToolFilter(allowedNames: Set(names))
await source.register(in: registry, filter: filter)
```

The cap (`MCPToolFilter.foundationModelsToolCap = 16`) is public so apps can reuse the constant in their own UI. The demo's Connected Services sheet now shows "Connected · X of Y tools enabled" with a footnote whenever the cap is biting, so users see *why* a tool went missing.

See [#797](https://github.com/roryford/BaseChatKit/pull/797).

### Features

- **appintents:** new optional `BaseChatAppIntents` module — `AppIntentToolExecutor` bridges any `AppIntent` into the tool-calling pipeline with auto-synthesised JSON Schema, ISO-8601 date handling, and `IntentEnumParameter`-driven enum support ([#798](https://github.com/roryford/BaseChatKit/pull/798))
- **mcp:** `MCPToolSource.foundationModelsCompatibleNames(maxDepth:)` rejects `oneOf`/`anyOf`/`$ref` and any object/array nesting beyond `maxDepth` (default 4); recursion now traverses every JSON Schema sub-keyword instead of just `properties`/`items` ([#797](https://github.com/roryford/BaseChatKit/pull/797))
- **mcp:** `MCPToolFilter.foundationModelsToolCap = 16` and `MCPToolSource.foundationModelsEnabledNames(maxDepth:cap:)` compose the schema filter with the Foundation Models tool-count cap, sorted lexicographically for stable UI counts ([#797](https://github.com/roryford/BaseChatKit/pull/797))
- **example:** demo app registers `basechatdemo://` so production AppIntent invocations from Shortcuts / Siri / Spotlight actually reach `.onOpenURL` instead of dying silently at the URL-scheme dispatch ([#799](https://github.com/roryford/BaseChatKit/pull/799))
- **example:** `InboundPayload.attachments` now survives the App Group envelope round trip end-to-end, so future inbound surfaces (Share / Action Extensions) can carry `MessagePart` payloads — images, tool calls, tool results — without losing them ([#799](https://github.com/roryford/BaseChatKit/pull/799))

## [0.12.0](https://github.com/roryford/BaseChatKit/compare/v0.11.8...v0.12.0) (2026-04-26)

### Highlights

#### Compose backend registration with `BackendRegistrar`

`DefaultBackends.register(with:)` was a single closure that conditionally registered every shipped backend, which forced apps that only wanted one slice of the matrix (cloud-only, local-only) to pull the whole module and made parallel work on MLX, Llama, and cloud collide on the same file. v0.12.0 introduces a `BackendRegistrar` protocol and four per-backend conformers — `MLXBackends`, `LlamaBackends`, `FoundationBackends`, `CloudBackends` — each owning its own factory and `declareSupport` calls. `DefaultBackends.register` is now a fold over `DefaultBackends.registrars`, preserving the single-call API for existing consumers while opening up explicit per-backend composition.

```swift
let service = InferenceService()

// Existing one-call API still works — no migration required.
DefaultBackends.register(with: service)

// Or compose explicitly:
MLXBackends.register(with: service)
CloudBackends.register(with: service)
```

Each registrar is unconditionally `public` at file scope; trait gates live inside the function body so a disabled trait is a no-op rather than a missing-symbol link error.

See [#794](https://github.com/roryford/BaseChatKit/pull/794).

#### Peel `BaseChatUIModelManagement` out of `BaseChatUI`

The model browser, downloader, storage panels, and cloud API endpoint editors lived in `BaseChatUI` whether a host used them or not — ~1,800 LOC of management surface a chat-only embedded consumer would always ship. v0.12.0 moves those views (plus `ModelManagementViewModel`) into a new `BaseChatUIModelManagement` product. `BaseChatUI` now contains only the chat-runtime surface; consumers that need the management UI add one product dependency and one import.

```swift
import BaseChatUI
import BaseChatUIModelManagement   // new — pulls in ModelManagementSheet, APIConfigurationView, etc.

ChatView(
    showModelManagement: $showModelManagement,
    apiConfiguration: { APIConfigurationView() }
)
```

`ChatView` and `GenerationSettingsView` previously instantiated `APIConfigurationView()` directly, which would have closed a dep cycle the moment that view moved. Both are now generic over an `APIConfig: View` type built from a `@ViewBuilder` closure, so `BaseChatUI` never imports the peeled module. There is no default no-op overload by design — callers must pass the closure intentionally so a silent `EmptyView()` regression cannot ship. A CI lint locks the one-way edge by failing if any file under `Sources/BaseChatUI/` ever introduces `import BaseChatUIModelManagement`. A codemod at `scripts/migrate-uimm-imports.sh` adds the new import to every consumer file that uses one of the moved symbols.

**BREAKING:** every `ChatView(...)` and `GenerationSettingsView(...)` call site must now pass `apiConfiguration: { APIConfigurationView() }`.

See [#796](https://github.com/roryford/BaseChatKit/pull/796).

#### Drop `Ollama` from default traits

`Ollama` shipped in `Package.swift`'s `.default(enabledTraits:)` since the trait system landed, with a deprecation note that it would move out at the next major. v0.12.0 carries through.

```swift
.default(enabledTraits: ["MLX", "Llama"])   // Ollama removed
```

Hosts that bundle `OllamaBackend` now need `--traits Ollama` (or an explicit list in their `Package.swift`). Apps that never used Ollama keep working unchanged.

See [#796](https://github.com/roryford/BaseChatKit/pull/796).

### Features

- **backends:** `BackendRegistrar` protocol + per-backend `MLXBackends` / `LlamaBackends` / `FoundationBackends` / `CloudBackends` register hooks ([#794](https://github.com/roryford/BaseChatKit/pull/794))
- **ui:** new `BaseChatUIModelManagement` product housing model browser, downloader, storage panels, and cloud API endpoint editors ([#796](https://github.com/roryford/BaseChatKit/pull/796))
- **ui:** `ChatView` and `GenerationSettingsView` are now generic over `APIConfig: View` and accept an `apiConfiguration:` `@ViewBuilder` parameter ([#796](https://github.com/roryford/BaseChatKit/pull/796))
- **build:** `Ollama` removed from default traits — hosts opt in explicitly ([#796](https://github.com/roryford/BaseChatKit/pull/796))

## [0.11.8](https://github.com/roryford/BaseChatKit/compare/v0.11.7...v0.11.8) (2026-04-26)

### Highlights

#### BCK apps can now call tools on any MCP server

Before this release, BCK apps required hand-written `ToolExecutor` implementations for every external integration. `BaseChatMCP` plugs the framework into the entire Model Context Protocol ecosystem — any server that speaks MCP (Notion, Linear, GitHub, local filesystem tools, and hundreds of community servers) becomes available to the model in one `connect` call.

```swift
let client = MCPClient()
let source = try await client.connect(MCPCatalog.notion)
await source.register(in: toolRegistry)
// Notion tools (namespaced notion__*) are now available to the model.
```

OAuth 2.1 with PKCE and Dynamic Client Registration is built in; providers like Notion, Linear, and GitHub authenticate without custom auth code. Approval is a first-class `MCPApprovalPolicy` (per-call, per-turn, session, or persistent), routed through the same `ToolApprovalGate` as hand-written tools.

Enable with the `MCP` trait in your package manifest. Built-in provider descriptors (Notion, Linear, GitHub) require the additional `MCPBuiltinCatalog` trait.

Not in v1: MCP Resources, Prompts, Sampling, image/audio content passthrough, partial-progress notifications. Tracked in [#792].

See [#625], [#790].

### Features

- **mcp:** `BaseChatMCP` module — MCP server tools consumed as `ToolDefinition`s ([#790])
- **mcp:** OAuth 2.1 + PKCE + Dynamic Client Registration + RFC 8414 metadata + RFC 9207 `iss` validation ([#790])
- **mcp:** Stdio transport (macOS) and Streamable HTTP transport (iOS + macOS) ([#790])
- **mcp:** Built-in catalog for Notion, Linear, GitHub behind `MCPBuiltinCatalog` trait ([#790])
- **inference:** `SSEStreamParser` named-event mode, also adopted by `OpenAIResponsesBackend` ([#790])

## [0.11.7](https://github.com/roryford/BaseChatKit/compare/v0.11.6...v0.11.7) (2026-04-26)

### Highlights

#### Tool calling on every cloud backend

OpenAI Chat Completions, OpenAI Responses, Anthropic Messages, and Ollama now implement the framework `ToolCall` contract that `ToolCallLoopOrchestrator` already consumes (see #779 in 0.11.6). Each backend speaks its own wire dialect — `tools` + `tool_choice` for the OpenAI family, `content_block_start{tool_use}` + `input_json_delta` indexed by content-block index for Anthropic, NDJSON whole-call envelopes for Ollama — but every backend produces the same `GenerationEvent.toolCall` stream. Streaming-argument deltas (`.toolCallStart`, `.toolCallArgumentsDelta`) ride the same shape on backends that opt in via the new `BackendCapabilities.streamsToolCallArguments`.

```swift
let backend = ClaudeBackend(apiKey: ...)
let registry = ToolRegistry(policy: ToolOutputPolicy())
registry.register(WeatherTool())
let orchestrator = ToolCallLoopOrchestrator(backend: backend, registry: registry)
for try await event in orchestrator.run(initialPrompt: "what's it like in Tokyo?", systemPrompt: nil, config: config) {
    switch event {
    case .toolCallStart(let id, let name): print("→", name, id)
    case .toolCallArgumentsDelta(_, let frag): print(frag, terminator: "")
    case .toolResult(let r): print("✓", r.content.prefix(64))
    default: break
    }
}
```

Three wire-format caveats worth knowing: Anthropic's `tool_use.input` arrives as a parsed JSON object (not a stringified blob like OpenAI), so `ClaudeBackend.decodeArgumentsForReplay` round-trips it through `JSONSerialization` with `{}` fallback. `tool_choice:none` does not exist on the Anthropic wire; the framework drops the `tools` field entirely. Per-block `.toolCall` finalization timing differs across backends — Claude fires per-block on `content_block_stop`, both OpenAI variants batch at end-of-stream — all three are compatible with the orchestrator's collect-and-dispatch contract, but consumers reading the raw event stream should not assume strictly-batched semantics. See [#783], [#789].

#### Parallel tool dispatch, opt-in per executor

`ToolCallLoopOrchestrator` dispatches multi-call rounds via `withTaskGroup` when every executor in the round opts in via the new `ToolExecutor.supportsConcurrentDispatch` (default `false` — sequential semantics preserved). Result order in the next-turn prompt is determined by batch-index sort regardless of completion order, so prefix-cache reuse stays stable across runs. Cancellation drops late results: any task that returns after cancellation is observed must not produce phantom `.toolResult` events — both the sequential and parallel paths re-check `Task.isCancelled` between yields. See [#783].

### Features

- **inference:** streaming tool-call delta events (`.toolCallStart`, `.toolCallArgumentsDelta`) and `BackendCapabilities.streamsToolCallArguments` ([#783])
- **inference:** `ToolExecutor.supportsConcurrentDispatch` for opt-in parallel dispatch with batch-order result preservation ([#783])
- **cloud:** OpenAI Chat Completions tool calling — `tools` + `tool_choice` request encoding, sticky-id buffering for compat servers (Together, Groq) that drop `id` after the first delta, streaming + non-streaming whole-message paths ([#789])
- **cloud:** OpenAI Responses tool calling — `function_call` items keyed by `item_id` with `call_id` exposed downstream; finalises on `response.completed` ([#789])
- **cloud:** Anthropic Messages tool calling — `tool_use` content blocks indexed by content-block index, per-block `.toolCall` finalization on `content_block_stop`, tool-result-as-user-role history ([#789])
- **cloud:** Ollama `/api/chat` tool calling — `tools` request envelope, whole-call NDJSON streaming, synthesized stable `callId` matching the convention from `MLXToolCallParser` ([#789])

### Fixes

- **test:** declare `BaseChatTools` dependency on `BaseChatE2ETests` — `xcodebuild test` was failing the link step for `BaseChatMLXIntegrationTests` because `swift test` resolved the missing import via a transitive path ([#784])

## [0.11.6](https://github.com/roryford/BaseChatKit/compare/v0.11.5...v0.11.6) (2026-04-25)

### Highlights

#### Reusable agent-loop orchestrator and tool-output budget

`ToolCallLoopOrchestrator` lands as a public, generic agent-loop driver in `BaseChatInference`. It runs the generate → tool-call → execute → feed-result → generate cycle directly on top of `InferenceBackend` + `ToolExecutor` (or `ToolRegistry`), with cancellation, step budget, per-step timeout, and identical-call loop detection built in. `InferenceService` is unchanged — callers wanting a structured `tool` role still route through `GenerationCoordinator`.

```swift
let orchestrator = ToolCallLoopOrchestrator(
    backend: backend,
    registry: registry,
    policy: ToolCallLoopPolicy(maxSteps: 8, loopDetectionWindow: 3)
)
for try await event in orchestrator.run(initialPrompt: "...", systemPrompt: nil, config: config) {
    switch event {
    case .token(let s):       print(s, terminator: "")
    case .toolCall(let call): print("→", call.toolName)
    case .toolResult(let r):  print("←", r.content.prefix(64))
    case .stepLimitReached, .loopDetected, .finished, .usage: break
    }
}
```

Alongside the orchestrator, `ToolRegistry` gains an explicit `ToolOutputPolicy` (default `maxBytes: 32_768`, `.rejectWithError`) applied at dispatch exit, with UTF-8-boundary-safe truncation and a documented reentrancy contract that warns when `unregister` collides with an in-flight dispatch. See [#443], [#628], [#631].

#### Cross-cutting thinking infrastructure — OpenAI Responses, Jinja auto-discovery

A new `OpenAIResponsesBackend` targets `POST /v1/responses` and translates the named-event SSE stream (`response.reasoning_summary_text.delta` / `.done`, `response.output_text.delta`, `response.completed`) into `.thinkingToken` / `.thinkingComplete` / `.token` `GenerationEvent`s. The existing Chat Completions `OpenAIBackend` is untouched; `APIProvider.openAIResponses` is the new switch point because the two wire formats are incompatible enough to warrant separate provider cases.

For local backends, `PromptTemplateDetector.detectThinkingMarkers(from:)` scans Jinja chat templates for `<think>`, `<thinking>`, `<reasoning>`, `<reflection>`, and Gemma-style markers and returns the matching `ThinkingMarkers` preset. `MLXBackend` reads `tokenizer_config.json` at load time and `LlamaBackend` reads `tokenizer.chat_template` via `llama_model_meta_val_str`, both caching the auto-detected preset. The hardcoded `?? .qwen3` fallback is gone — `GenerationConfig.thinkingMarkers = nil` now means "use the backend's auto-detected markers"; non-nil overrides. Existing callers with explicit markers are unaffected. See [#598], [#479], [#551].

#### Session sidebar search and pagination

The session sidebar gains a `.searchable` bar with a Titles / Messages scope picker, 200ms input debounce, and a "No results" empty state. Title search filters the loaded list in memory; Messages mode calls a new `SwiftDataPersistenceProvider.searchMessages(query:limit:)` that runs `localizedStandardContains` directly in-store (capped at 100 hits, with snippet previews highlighted via `AttributedString`). The list itself paginates at 50 sessions per page through a `fetchSessions(offset:limit:)` overload and `SessionManagerViewModel.loadNextPage()`, fetching the next page when the last loaded row appears. Swipe-to-rename and swipe-to-delete are preserved across both filtered and paginated views; baseline performance tests cover 1000 sessions / 50K messages. See [#246].

### Features

- **inference:** `ToolCallLoopOrchestrator` reusable agent-loop primitive with cancellation, step budget, per-step timeout, and identical-call loop detection ([#779])
- **inference:** explicit `ToolOutputPolicy` on `ToolRegistry` with UTF-8-safe truncation and documented reentrancy contract ([#779])
- **cloud:** `OpenAIResponsesBackend` for `POST /v1/responses` with reasoning-summary → thinking-event translation ([#780])
- **inference:** Jinja chat-template auto-discovery of thinking markers across MLX and Llama backends ([#780])
- **ui:** session list search (titles + message content), 50-per-page pagination, snippet previews ([#778])

### Fixes

- **inference:** `InferenceService` queue auto-drains on stream termination via `defer` in `activeTask` — consumers no longer need to call `generationDidFinish()`, which is now a deprecated no-op for backward compatibility ([#781])

## [0.11.5](https://github.com/roryford/BaseChatKit/compare/v0.11.4...v0.11.5) (2026-04-25)

### Highlights

#### Tool-call reliability — heal, cancel, and MLX parity

Three interlocking pieces land together to make tool calling robust end-to-end. `TranscriptHealer` scans the loaded transcript on every session reload and synthesises a `.cancelled` `ToolResult` for any orphaned `ToolCall` — the tool call that was in-flight when the user killed the app and never received a response. Without the heal pass, the next cloud turn would send the transcript with an unanswered `tool_calls` entry, which Claude and OpenAI reject. The cooperative cancellation contract in `ToolRegistry.dispatch` closes the symmetric gap: when the user taps Stop while a tool is executing, the registry synthesises a `.cancelled` result rather than force-closing the stream, so the session stays self-consistent for replay. On the local side, `MLXBackend` now emits `tool_calls` via the same `GenerationEvent.toolCall` path as cloud backends, bringing tool-calling to on-device Gemma 4 and other instruction-tuned MLX models. See [#629], [#622], [#725].

#### Thinking tokens — live display and multi-turn Claude

`ThinkingBlockView` previously only rendered completed reasoning blocks. It now updates token-by-token as the stream arrives, using the same `AsyncStream`-backed pipeline as the main text display — no extra state, no flicker. On the cloud side, `ClaudeBackend` now preserves `thinking` blocks in the assistant turn when constructing multi-turn request history. The Anthropic API requires thinking blocks to be echoed back verbatim; without this, every Turn 2+ request to a thinking-enabled Claude model would fail with a 400. See [#767], [#776], [#604].

#### Sampling config parity with mlx-swift-lm

`GenerationConfig` gains three optional fields — `minP: Float?`, `repetitionPenalty: Float?`, and `seed: UInt64?` — matching the full parameter surface of `mlx-swift-lm`'s `GenerateParameters`. `MLXBackend` seeds `MLXRandom` before each generation call so consecutive runs with the same seed produce identical output. `LlamaGenerationDriver` plumbs `minP` into `llama_sampler_init_min_p` and the seed into `llama_sampler_init_dist`; the `UInt64 → UInt32` truncation is documented. `FoundationBackend` and cloud backends ignore the new fields silently. All three are `nil` by default so no existing callers are affected. See [#773], [#750].

### Features

- **inference:** heal orphan tool calls on session reload — synthesises `.cancelled` stubs for in-flight tool calls that never received a response ([#774])
- **inference:** cooperative cancellation contract for in-flight tool execution — `ToolRegistry.dispatch` synthesises a `.cancelled` result on stop rather than force-closing the stream ([#775])
- **mlx:** tool calling support — `MLXBackend` emits `GenerationEvent.toolCall` events on-device ([#725])
- **inference:** `minP`, `repetitionPenalty`, `seed` on `GenerationConfig` for mlx-swift-lm parity ([#773])
- **cloud:** preserve thinking blocks across multi-turn Claude requests — echoes assistant `thinking` blocks verbatim in request history ([#776])
- **ui:** live streaming display for thinking tokens — `ThinkingBlockView` updates token-by-token as the stream arrives ([#767])
- **inference:** pause generation when `ProcessInfo.thermalState` reaches `.critical`, resume on `.serious` or below — surfaces as `GenerationEvent.diagnosticThrottle(reason:)` ([#764])
- **inference:** probe HF `config.json` for vision/audio capability before loading — populates `BackendCapabilities.supportsVision` / `supportsAudio` without requiring a full model load ([#762])
- **inference:** `ChatSessionIntent` App Intents seam for Siri and Spotlight integration ([#770])
- **ui:** `ChatViewModel.ingestPendingPayload` API for extension-driven sessions ([#763])
- **mlx:** route MoE Gemma 4 through `MLXVLM` factory — enables `mlx-community/gemma-4-*` model variants ([#769])
- **mlx:** support namespaced MLX model layouts and Gemma 4 architecture ([#742])
- **demo:** Demo Scenarios picker with three-layer test pattern ([#710])
- **test:** Package.swift hygiene and `#if` trait sanity audit rules (Phase 2B of [#714]) ([#740])

### Fixes

- **inference:** reject GGUF files without magic-bytes header in discovery — prevents silent load failures from truncated downloads ([#723])
- **ci:** eliminate post-merge main-branch CI flakes ([#761])
- **test:** correct `#if Ollama || CloudSaaS` gates that referenced CloudSaaS-only types — fixes `xcodebuild test` with default traits ([#777])
- **test:** handle `diagnosticThrottle` in trait-gated `switch` statements ([#772])
- **test:** stabilise test suite — grammar SIGABRT, KV cache cross-test leak, concurrency race, snapshot trait gap ([#760])
- **test:** stabilise macOS XCUITest suite ([#716])
- **test:** inject `UserDefaults` into `BackgroundDownloadManager` to remove `--parallel` flake ([#734])
- **test:** allowlist MLX tool-calling `try?` probes in `SilentCatchAuditTest` ([#743])

### Performance Improvements

- **mlx:** yield briefly every N tokens to prevent WindowServer GPU command-queue starvation — configurable via `GenerationConfig.yieldEveryNTokens`, defaults to 8 ([#766])
- **ci:** consolidate test runs and tighten path filters — reduces runner minutes per push ([#756])
- **ci:** skip `Package.resolved` verify step when dependencies unchanged ([#751])

## [0.11.4](https://github.com/roryford/BaseChatKit/compare/v0.11.3...v0.11.4) (2026-04-25)

### Highlights

#### Thinking model polish — Gemma 4 markers and VoiceOver support

Two gaps in the thinking-token pipeline closed. `PromptTemplate.gemma4.thinkingMarkers` previously returned `nil`, so Gemma 4 thinking streams passed through raw without stripping the `<|turn>think` / `<|end_of_turn>` block or emitting `.thinkingToken` events. It now returns a fully wired `ThinkingMarkers` preset handled correctly at chunk boundaries and on stream finalize. On the UI side, `MessageBubbleView` gains an accessibility label indicating when a message includes reasoning, and `ThinkingBlockView` exposes a proper label/hint pair so VoiceOver users can navigate to and expand reasoning blocks without the raw thinking content being read inline. See [#691], [#689].

### Features

- **inference:** add Gemma 4 thinking markers to PromptTemplate ([#691])
- **ui:** add VoiceOver labels and hints for thinking parts in MessageBubbleView and ThinkingBlockView ([#689])

### Bug Fixes

- **example:** prevent orphan empty session on AppIntent cold-launch — `DemoContentView` now checks `PendingPayloadBuffer` before seeding a blank session, so the intent's session is the only one created ([#692])

### Performance Improvements

- **ci:** run BaseChatInferenceTests with `--parallel` (~10 s saved per run), shorten SlowBackend concurrency test delays (~6.7 s saved), split OllamaThinkingE2ETests into its own file for targeted reruns ([#688])

## [0.11.3](https://github.com/roryford/BaseChatKit/compare/v0.11.2...v0.11.3) (2026-04-24)

### Highlights

#### Local-inference capability stack — grammar, KV cache, embeddings

BaseChatKit 0.11.3 lands three primitives that together let callers program against local inference with the richness remote backends have long offered: GBNF grammar-constrained sampling, KV-cache-aware prompt reuse, and a concrete embedding backend. All three are capability-flagged on `BackendCapabilities` so a single caller can cover cloud and local paths; all three default to `false`/`nil` so existing serialized `BackendCapabilities` payloads decode without migration.

```swift
// Grammar-constrained generation on LlamaBackend
var config = GenerationConfig()
config.grammar = #"root ::= "yes" | "no""#
_ = try await service.enqueue(messages: messages, grammar: config.grammar)

// Local embeddings — actor-confined, unit-normalized, cosine-ready
let embedder = LlamaEmbeddingBackend()
try await embedder.loadModel(from: gguf)
let vectors = try await embedder.embed(["hello", "world"])
```

`LlamaBackend` now computes the longest common prompt prefix across turns and trims only the diverging KV tail via `llama_memory_seq_rm`, improving Turn 2+ TTFT on long static system prompts by 5× or more. `LlamaEmbeddingBackend` wraps the BERT / Nomic / Jina / T5-encoder GGUF family with pooling-aware extraction and L2 normalization; on Apple Silicon with `nomic-embed-text-v1.5` Q8_0 it sustains ~4–5 ms per embed. See [#663], [#664], [#667], [#668], [#686], [#687].

#### Tool calling, end-to-end — with an approval gate

Tool calling ships every piece a host app needs in one release: a `ToolApprovalGate` protocol for per-call human approval, a `@ToolSchema` macro that derives `JSONSchemaValue` parameters from Swift structs at compile time, and a public `ToolInvocationView` + `UIToolApprovalGate` so pending → running → completed states render from a single SwiftUI view. The demo app ships the flagship empty-state moment — curated prompt button → thinking → sandboxed tool call → approval sheet → result in one tap.

```swift
@ToolSchema
struct WeatherArguments: Decodable, Sendable {
    /// City name (e.g. "San Francisco")
    let city: String
}

let gate = UIToolApprovalGate(policy: .askOncePerSession)
let service = InferenceService(toolRegistry: registry, toolApprovalGate: gate)
let chatVM = ChatViewModel(inferenceService: service, toolApprovalGate: gate)
```

The macro is a conservative subset — primitives, arrays, `Optional`, nested `@ToolSchema` types, String-raw-type enums, literal defaults — and emits compile-time diagnostics for unsupported shapes. Closes [#437]. See [#632], [#652], [#657], [#662], [#675].

### Features

- **embeddings:** `LlamaEmbeddingBackend` — concrete `EmbeddingBackend` for GGUF embedders ([#687])
- **inference:** add `BackendCapabilities.supportsThinking` flag ([#674])
- **inference:** add `ThinkingMarkers` presets and `forModel(named:)` lookup ([#672])
- **inference:** add `ToolApprovalGate` protocol for per-call tool approval ([#657])
- **inference:** expose `grammar:` parameter on `InferenceService.enqueue` / `GenerationCoordinator.enqueue` ([#686])
- **inference:** local-capability contract types for grammar, KV cache, and embeddings ([#663], [#664])
- **intents:** `AskBaseChatDemo` AppIntent via `InboundPayload` handoff ([#666])
- **llama:** GBNF grammar-constrained sampling in `LlamaBackend` ([#663], [#667])
- **llama:** KV cache persistence across turns — 5× TTFT improvement on long system prompts ([#663], [#668])
- **macros:** `@ToolSchema` macro — synthesize `ToolDefinition.parameters` from Swift structs ([#675])
- **tools:** add `SampleRepoSearchTool` and wire reference tools in demo ([#652])
- **ui:** `ToolInvocationView` + `UIToolApprovalGate` with demo empty-state moment — closes [#437] ([#662])

### Fixes

- **backends:** parse SSE `id:` fields and inject `Last-Event-ID` header on reconnect — prevents duplicate token replay across dropped streams ([#608], [#658])
- **backends:** prevent SIGTRAP when `FoundationModels` session is reused after task cancel ([#661])
- **ci:** add `--min-passed` flag to `scripts/test.sh` to catch silent suite skips ([#633], [#654])
- **ci:** escape regex metacharacters in suite-name crash detection — follow-up to [#633] ([af452ef])
- **ci:** revert `swift-tools-version` to 6.1 for CI toolchain compatibility ([#670])
- **downloads:** retry disk-jitter moves and exclude active temps from sweep — closes flaky downloads ([#599], [#601], [#656])
- **inference:** Package.resolved drift guard + FoundationBackend memory accumulation — cleans long-running memory growth ([#600], [#644], [#655])
- **swift:** Swift 6.3 warnings, Fuzz-trait docs, MLXFuzzTests gating ([#645], [#646], [#647], [#659])
- **test-support:** `withTimeout` hangs on non-cancellation-aware operations; wire `BaseChatTestSupportTests` to CI ([#685])
- **tests:** prevent `MockURLProtocol` crash on unregistered URLs in concurrent suites ([#660])

[#437]: https://github.com/roryford/BaseChatKit/issues/437
[#599]: https://github.com/roryford/BaseChatKit/issues/599
[#600]: https://github.com/roryford/BaseChatKit/issues/600
[#601]: https://github.com/roryford/BaseChatKit/issues/601
[#608]: https://github.com/roryford/BaseChatKit/issues/608
[#632]: https://github.com/roryford/BaseChatKit/issues/632
[#633]: https://github.com/roryford/BaseChatKit/issues/633
[#644]: https://github.com/roryford/BaseChatKit/issues/644
[#645]: https://github.com/roryford/BaseChatKit/issues/645
[#646]: https://github.com/roryford/BaseChatKit/issues/646
[#647]: https://github.com/roryford/BaseChatKit/issues/647
[#652]: https://github.com/roryford/BaseChatKit/issues/652
[#654]: https://github.com/roryford/BaseChatKit/issues/654
[#655]: https://github.com/roryford/BaseChatKit/issues/655
[#656]: https://github.com/roryford/BaseChatKit/issues/656
[#657]: https://github.com/roryford/BaseChatKit/issues/657
[#658]: https://github.com/roryford/BaseChatKit/issues/658
[#659]: https://github.com/roryford/BaseChatKit/issues/659
[#660]: https://github.com/roryford/BaseChatKit/issues/660
[#661]: https://github.com/roryford/BaseChatKit/issues/661
[#662]: https://github.com/roryford/BaseChatKit/issues/662
[#663]: https://github.com/roryford/BaseChatKit/issues/663
[#664]: https://github.com/roryford/BaseChatKit/issues/664
[#666]: https://github.com/roryford/BaseChatKit/issues/666
[#667]: https://github.com/roryford/BaseChatKit/issues/667
[#668]: https://github.com/roryford/BaseChatKit/issues/668
[#670]: https://github.com/roryford/BaseChatKit/issues/670
[#672]: https://github.com/roryford/BaseChatKit/issues/672
[#674]: https://github.com/roryford/BaseChatKit/issues/674
[#675]: https://github.com/roryford/BaseChatKit/issues/675
[#685]: https://github.com/roryford/BaseChatKit/issues/685
[#686]: https://github.com/roryford/BaseChatKit/issues/686
[#687]: https://github.com/roryford/BaseChatKit/issues/687
[af452ef]: https://github.com/roryford/BaseChatKit/commit/af452ef58fe2448cf2b9f20edeea0f600a373724

## [0.11.2](https://github.com/roryford/BaseChatKit/compare/v0.11.1...v0.11.2) (2026-04-23)

### Highlights

#### Tool calling lands end-to-end on Ollama

`MessagePart` now carries `.toolCall` and `.toolResult` cases, so transcripts hold structured tool invocations without a parallel schema. A new `ToolRegistry` owns definitions, `TypedToolExecutor` decodes arguments into your own Swift types, and `GenerationCoordinator` drives the loop — model → tool call → execute → feed result → model — with Ollama wired as the first backend.

```swift
let registry = ToolRegistry()
registry.register(WeatherTool())

let service = InferenceService(backend: OllamaBackend(), tools: registry)
let stream = try service.generate(prompt: "What's the weather in Tokyo?")
```

Errors are classified (`.notFound`, `.invalidArguments`, `.toolThrew`, `.cancelled`, `.timeout`) so orchestrators can tell "model asked for a tool that doesn't exist" apart from "the tool threw." Opt-in: existing callers that never register tools see no change.

See [#634](https://github.com/roryford/BaseChatKit/issues/634), [#635](https://github.com/roryford/BaseChatKit/issues/635), [#636](https://github.com/roryford/BaseChatKit/issues/636), [#640](https://github.com/roryford/BaseChatKit/issues/640).

#### `maxThinkingTokens = 0` now actually disables reasoning

The doc comment promised it worked on every backend. Only Ollama did. MLX and Llama silently treated `0` like `nil` and kept running their `ThinkingParser`, so `<think>` content leaked into the visible stream for anyone trying to suppress it.

```swift
let config = GenerationConfig(maxThinkingTokens: 0) // now honored on all backends
```

Fixed on `LlamaGenerationDriver` and `MLXBackend`. `ClaudeBackend` was already correct and got three regression tests to lock it in. See [#642](https://github.com/roryford/BaseChatKit/issues/642).

### Features

- **core:** add `MessagePart.toolCall` and `.toolResult` cases ([#634](https://github.com/roryford/BaseChatKit/issues/634))
- **inference:** `ToolRegistry`, `TypedToolExecutor`, and `ToolResult.errorKind` taxonomy ([#635](https://github.com/roryford/BaseChatKit/issues/635), closes [#618](https://github.com/roryford/BaseChatKit/issues/618) and [#624](https://github.com/roryford/BaseChatKit/issues/624))
- **inference:** `JSONSchemaValidator` with a practical JSON Schema Draft 2020-12 subset ([#636](https://github.com/roryford/BaseChatKit/issues/636))
- **inference:** tool-call dispatch loop + Ollama tool wiring ([#640](https://github.com/roryford/BaseChatKit/issues/640))

### Fixes

- **backends:** honor `maxThinkingTokens=0` on MLX, Llama, and Anthropic ([#642](https://github.com/roryford/BaseChatKit/issues/642))
- **tests:** raise `OllamaE2ETests` budget for thinking models — 64 tokens was consumed entirely by `<think>` blocks on qwen3.5, so the baseline tests now classify on `backend.isThinkingModel` and accept visible output or a complete thinking trace as evidence ([#643](https://github.com/roryford/BaseChatKit/issues/643), closes [#602](https://github.com/roryford/BaseChatKit/issues/602))
- gate `fuzz-chat` backends on the `Fuzz` trait and declare `BaseChatTools` resources ([#648](https://github.com/roryford/BaseChatKit/issues/648))

## [0.11.1](https://github.com/roryford/BaseChatKit/compare/v0.11.0...v0.11.1) (2026-04-21)

### Highlights

#### Remote-endpoint hardening closes SSRF and DNS-rebinding gaps

Canonical endpoint validation moves onto the actual cloud-connect code path (not just the UI save flow), a new `DNSRebindingGuard` blocks requests whose DNS resolves to RFC1918, link-local, multicast, IMDS, or other reserved addresses at request time, and `CustomHostTrustPolicy` lets apps opt into fail-closed TLS trust that requires explicit pins.

```swift
let config = BaseChatConfiguration(
    customHostTrustPolicy: .requireExplicitPins
)
// Register SPKI pins via PinnedSessionDelegate.pinnedHosts
// before the first request. Unpinned hosts are rejected.
```

`.platformDefault` stays the default, so existing apps see no behavior change until they opt in. See [#613](https://github.com/roryford/BaseChatKit/issues/613).

#### `OllamaBackend` stops silently losing context and leaking prompts

Four fixes motivated by silent-failure modes in Ollama's wire contract. `options.num_ctx` is now derived from `ModelLoadPlan` on every request with an 8192-token floor on `.cloud()`, closing the footgun where Ollama's server-side 2048-token default truncated multi-turn conversations with no error signal. Qwen3-style models that emit reasoning inline as `<think>…</think>` in `message.content` (instead of populating the dedicated `thinking` field) now route through `ThinkingParser` as a fallback. And model tags ending in `:cloud` — which Ollama v0.18.0+ silently routes to its hosted cloud service — are rejected at load time, so a local-first configuration can't accidentally leak prompts off-device.

See [#610](https://github.com/roryford/BaseChatKit/issues/610).

#### Backend-agnostic JSON mode

```swift
let config = GenerationConfig(jsonMode: true)
guard backend.capabilities.supportsNativeJSONMode else { return }
```

Maps to OpenAI's `response_format: { type: "json_object" }` and Ollama's `format: "json"` where supported. Backends without native JSON mode (Claude, Llama, MLX, Foundation) emit a `Log.inference.warning` naming the backend and the capability flag — callers branch on `backend.capabilities.supportsNativeJSONMode` rather than silently getting plain-text back. See [#615](https://github.com/roryford/BaseChatKit/issues/615).

## [0.11.0](https://github.com/roryford/BaseChatKit/compare/v0.10.2...v0.11.0) (2026-04-20)

### ⚠️ Breaking change

`maxThinkingTokens = nil` no longer reserves a 2048-token thinking budget on non-thinking Ollama models. Callers who want guaranteed budget reservation on unknown models should pass an explicit `N`.

### Highlights

#### Thinking tokens work on every backend

v0.10.0 shipped `ThinkingParser` for Ollama and Llama. This release extends the same pipeline to MLX and cloud, so `<think>` blocks from any backend stream as structured `GenerationEvent.thinkingToken` / `.thinkingComplete` events — and `ThinkingBlockView` renders them without any host-side changes.

```swift
for try await event in stream.events {
    switch event {
    case .thinkingToken(let text): /* reasoning chunk */
    case .thinkingComplete:        /* reasoning finished */
    case .token(let text):         /* visible output */
    }
}
```

`MLXBackend` now enforces `maxThinkingTokens` the same way `LlamaGenerationDriver` does, stopping a runaway reasoning model before it can OOM a 16 GB Mac. `ClaudeBackend` parses Anthropic extended-thinking content blocks, the OpenAI-compatible adapter parses reasoning deltas, and `LlamaBackend` gains thinking-marker detection for Llama 3 prompt templates (DeepSeek-R1 and peers), which previously only worked on ChatML-formatted GGUFs.

See [#589](https://github.com/roryford/BaseChatKit/issues/589), [#591](https://github.com/roryford/BaseChatKit/issues/591), [#592](https://github.com/roryford/BaseChatKit/issues/592).

#### Non-LM models fail fast at load instead of crashing mid-decode

```swift
do {
    try await backend.loadModel(from: url, plan: plan)
} catch InferenceError.unsupportedModelArchitecture(let kind) {
    // CLIP vision encoder, BERT embedder, Whisper, …
}
```

Both `MLXBackend` and `LlamaBackend` now throw `InferenceError.unsupportedModelArchitecture` at load time if handed a CLIP vision encoder, BERT embedder, Whisper audio model, or other non-LM weights — instead of crashing inside the decode loop. See [#591](https://github.com/roryford/BaseChatKit/issues/591), [#592](https://github.com/roryford/BaseChatKit/issues/592).

#### Ollama reasoning controls you can actually turn off

`OllamaBackend` probes `/api/show` at `loadModel` time to classify whether a model is thinking-capable, and `GenerationConfig.maxThinkingTokens = 0` is honored by forwarding `"think": false` — so reasoning-capable models like `gemma4` and `qwen3` skip chain-of-thought when the host opts out. `ContextWindowManager` reserves both visible and thinking budgets in its trim math, preventing reasoning-heavy responses from silently pushing prompt history out of context.

See [#595](https://github.com/roryford/BaseChatKit/issues/595), [#596](https://github.com/roryford/BaseChatKit/issues/596).

### Internal

- Three new fuzz scenarios (disable thinking, cancel mid-thought, retry after mid-thinking network flake) assert specific invariants on the consumer's event stream, catching regressions the random corpus can't reach reliably ([#590](https://github.com/roryford/BaseChatKit/issues/590)).

## [0.10.2](https://github.com/roryford/BaseChatKit/compare/v0.10.1...v0.10.2) (2026-04-19)

### Fixes

- **mlx:** multi-turn conversations now correctly recall prior messages
- **llama:** Llama-format models (SmolLM2, Mistral, and peers) no longer generate commentary about `<|im_start|>` tokens — responses are coherent from the first message
- **downloads:** MLX model downloads complete reliably and show correct progress
- **demo:** the demo app opens immediately on launch instead of showing a blank screen for several seconds

## [0.10.1](https://github.com/roryford/BaseChatKit/compare/v0.10.0...v0.10.1) (2026-04-19)

### Highlights

#### Fuzz detectors stop crying wolf on non-reasoning models

Live fuzz runs against Llama, Foundation, and MLX surfaced two detectors that flagged false positives. `ThinkingClassificationDetector` was firing on models that don't emit `<think>` markers — they have no reasoning blocks to leak. `TemplateTokenLeakDetector` was flagging template fragments that the model correctly echoed back from prompt input. Both now gate on the relevant precondition before raising a finding.

See [#569](https://github.com/roryford/BaseChatKit/issues/569), [#570](https://github.com/roryford/BaseChatKit/issues/570).

#### Small models can't get stuck in repetition loops anymore

`LlamaGenerationDriver` gains two repetition guards that break the token loop early instead of running to `maxTokens`. A single-token window catches trivial space/punctuation spam from tiny models like `smollm2-135m` (20 identical tokens in a row). A phrase-level sliding window catches multi-token loops — echoed prompts, HTML timestamp blocks, ASCII-art sequences — that the single-token guard misses (phrases 2–20 tokens, 3 consecutive repeats).

```swift
// Both guards run inside LlamaGenerationDriver's decode loop and
// terminate the stream cleanly with a .stopped event — no config
// flag needed; they just fire when the pattern is obvious.
```

See [#568](https://github.com/roryford/BaseChatKit/issues/568) (closes [#565](https://github.com/roryford/BaseChatKit/issues/565)).

### Fixes

- **fuzz:** `FuzzBackendFactory` teardown hook ensures `LlamaBackend.unloadAndWait()` completes before the CLI process exits, preventing the SIGABRT from ggml-metal's resource-set assertion ([#571](https://github.com/roryford/BaseChatKit/issues/571))

### Internal

- Llama, Foundation, and MLX native backends wired into the fuzz harness, so campaigns can run against all three without Ollama

## [0.10.0](https://github.com/roryford/BaseChatKit/compare/v0.9.2...v0.10.0) (2026-04-19)

**Thinking token support and a full chat-fuzzing harness** — two independent workstreams that both ship in this release. Reasoning models (Qwen3, DeepSeek-R1) now route `<think>…</think>` blocks into structured `MessagePart.thinking` parts instead of silently discarding them; they display as a collapsible "Reasoning" disclosure group in the UI and are excluded from the context window on subsequent turns so they don't consume token budget. Both `LlamaBackend` and `MLXBackend` are supported ([#476](https://github.com/roryford/BaseChatKit/issues/476)). A `ThinkingParser` holdback bug that split short visible tokens across chunk boundaries (causing `maxOutputTokens` to fire mid-word) was also fixed ([#558](https://github.com/roryford/BaseChatKit/issues/558)).

The fuzzing harness (`swift run fuzz-chat`, `scripts/fuzz.sh`) exercises real backends with randomly sampled prompts and anomaly detectors, writing findings to `tmp/fuzz/` with deterministic replay hashes ([#493](https://github.com/roryford/BaseChatKit/issues/493)). On day one it surfaced a production bug where `OllamaBackend` silently dropped the `thinking` field emitted by reasoning models ([#487](https://github.com/roryford/BaseChatKit/issues/487), fixed in [#536](https://github.com/roryford/BaseChatKit/issues/536)). This release ships the harness at full maturity: `--replay` with git-rev and model-hash drift detection ([#542](https://github.com/roryford/BaseChatKit/issues/542)), `--shrink` for greedy-delta minimal repros ([#547](https://github.com/roryford/BaseChatKit/issues/547)), `--model all` to rotate through every installed Ollama model ([#541](https://github.com/roryford/BaseChatKit/issues/541)), multi-turn `SessionScript` sequences with KV-collision and race-stall detectors ([#546](https://github.com/roryford/BaseChatKit/issues/546)), a `DetectorContract` protocol so every detector ships with positive/negative/boundary/adversarial coverage ([#539](https://github.com/roryford/BaseChatKit/issues/539)), and tiered CI jobs (per-PR smoke, nightly full, weekly extended) ([#549](https://github.com/roryford/BaseChatKit/issues/549)).

**Breaking change:** `FuzzRunner(config:backendProvider:)` is replaced by `FuzzRunner(config:factory:)` and the `public typealias BackendProvider` is removed. Wrap your closure in a `Sendable` struct conforming to `FuzzBackendFactory` ([#537](https://github.com/roryford/BaseChatKit/issues/537)).

## [0.9.2](https://github.com/roryford/BaseChatKit/compare/v0.9.1...v0.9.2) (2026-04-18)

### Highlights

#### Gemma 4 works, and architecture wins over Jinja when they disagree

First-class Gemma 4 support lands via a dedicated `.gemma4` template with the correct `<|turn>` / `<|end_of_turn>` delimiters and an explicit `<|turn>system` turn. Loading a Gemma 4 GGUF previously fell through to ChatML and emitted `<|im_start|>` tokens the model had never seen — producing garbage output. `gemma3` architectures also get wired up, mapping to the existing `.gemma` template.

```swift
let detected = PromptTemplateDetector.detect(from: metadata)
// detected == .gemma4 when general.architecture == "gemma4"
// even if metadata also carries a generic ChatML chat_template.
```

`PromptTemplateDetector.detect(from:)` now lets an unambiguous model architecture (phi, gemma, mistral) win over a conflicting Jinja chat template — because some phi3/phi4 GGUFs include `<|im_start|>` tokens in their template's compatibility branches and were being misidentified as ChatML.

See [#461](https://github.com/roryford/BaseChatKit/issues/461), fixes [#464](https://github.com/roryford/BaseChatKit/issues/464).

### Fixes

- **ui:** Device Info popover surfaces the actual loaded model name above the backend engine row, so users can confirm which model is active at a glance ([#466](https://github.com/roryford/BaseChatKit/issues/466))


## [0.9.1](https://github.com/roryford/BaseChatKit/compare/v0.9.0...v0.9.1) (2026-04-18)

### Highlights

#### Building blocks for tool calling land in the inference layer

Generic `ToolCall` and `ToolResult` value types in `BaseChatInference` give host apps a typed, backend-agnostic channel for function-calling. The full orchestrator arrives in v0.11.2 — this release ships the primitives underneath.

```swift
let call = ToolCall(id: "call_1", name: "weather", arguments: ["city": "Tokyo"])
let result = ToolResult.success(id: call.id, content: .text("24°C, clear"))
```

See [#433](https://github.com/roryford/BaseChatKit/issues/433).

#### Device-capability queries without manual tier math

Model-selection UIs can now ask "can this device run a model at tier X?" without inspecting weights directly. New helpers on `DeviceCapability` wrap the existing `ModelCapabilityTier` and `FrameworkCapabilityService` plumbing with a concise public surface.

```swift
if DeviceCapability.supports(tier: .balanced) { /* show bigger variants */ }
let top = DeviceCapability.highestSupportedTier(for: .gguf)
guard DeviceCapability.canLoadModel(estimatedMemoryMB: 4_200) else { return }
```

See [#447](https://github.com/roryford/BaseChatKit/issues/447).

#### Llama.cpp stability pass closes out four sharp edges

Four fixes that finish the stability work started in v0.9.0. `stopGeneration()` is now thread-safe against the decode loop ([#418](https://github.com/roryford/BaseChatKit/issues/418)). Context overflow in long multi-turn sessions is guarded at the prefill boundary ([#417](https://github.com/roryford/BaseChatKit/issues/417)). In-flight generation is aborted when the OS sends a memory-pressure notification — preventing Metal buffer revocation from crashing the process ([#415](https://github.com/roryford/BaseChatKit/issues/415)). And the `.mappable` load strategy rejects models whose file size can't plausibly fit available device memory, instead of returning a silent `.allow` that only fails later inside llama.cpp ([#448](https://github.com/roryford/BaseChatKit/issues/448)).

### Fixes

- **ipad:** model management sheet uses system popovers and a medium detent, matching the platform's expected presentation style for content management ([#345](https://github.com/roryford/BaseChatKit/issues/345), [#346](https://github.com/roryford/BaseChatKit/issues/346))

## [0.9.0](https://github.com/roryford/BaseChatKit/compare/v0.8.4...v0.9.0) (2026-04-18)

**Single-authority load plan replaces four scattered context clamps.** Loading a model used to consult four independent code paths to answer "how much context can this device handle, and will the model even fit": `DeviceCapabilityService.canLoadModel`, `DeviceCapabilityService.safeContextSize`, `MemoryGate.check`, and `LlamaBackend.computeRamSafeCap`. Each had different inputs and different blind spots, so iPad OOM crashes kept resurfacing from new angles ([#398](https://github.com/roryford/BaseChatKit/issues/398), [#400](https://github.com/roryford/BaseChatKit/issues/400), [#411](https://github.com/roryford/BaseChatKit/issues/411)) — every fix landed in one layer but left the other three uninformed.

### What's new

`ModelLoadPlan` is a public `Sendable` value type computed once at the UI entry point and consumed unmodified by the service facade and every backend ([#419](https://github.com/roryford/BaseChatKit/issues/419), [#420](https://github.com/roryford/BaseChatKit/issues/420), [#421](https://github.com/roryford/BaseChatKit/issues/421), [#422](https://github.com/roryford/BaseChatKit/issues/422)). It carries:

- `effectiveContextSize` — the authoritative `n_ctx` to pass to the backend.
- `verdict` — one of `.allow` / `.warn` / `.deny`.
- `reasons: [Reason]` — structured causes (`.insufficientResident`, `.insufficientKVCache`, `.trainedContextExceeded`, `.absoluteCeilingReached`, `.memoryCeilingReached`) so UIs can surface specific guidance instead of a generic "too big" string.

`LoadDenyPolicy` replaces `MemoryGate`'s two-way deny behavior with three cases — `.throwError`, `.warnOnly`, and `.custom(closure)`. The closure receives the full plan (including `reasons`) for nuanced decisions. Configure via `InferenceService.denyPolicy`; defaults to `.throwError` on iOS and `.warnOnly` on macOS.

### What's gone

- `MemoryGate` and `InferenceService.memoryGate` removed entirely ([#424](https://github.com/roryford/BaseChatKit/pull/424)).
- `DeviceCapabilityService.canLoadModel` and `.safeContextSize` deleted ([#427](https://github.com/roryford/BaseChatKit/pull/427)). UI recommendation callers migrated to `ModelLoadPlan.canRunModel(sizeBytes:physicalMemoryBytes:)`.
- `LlamaBackend` retry-on-nil halving loop, `computeRamSafeCap`, and GGUF metadata-extraction helpers — ~150 lines deleted. The plan already carries the authoritative `n_ctx`, so the backend never recomputes.

### ⚠ Breaking change

**`InferenceBackend.loadModel(from:contextSize:)` is removed.** The protocol's sole load method now takes a `ModelLoadPlan`. Migration is mechanical:

```swift
// Before
try await backend.loadModel(from: url, contextSize: 4096)

// After (local GGUF / MLX)
let plan = ModelLoadPlan.compute(
    for: model,
    requestedContextSize: 4096,
    strategy: .mappable
)
try await backend.loadModel(from: url, plan: plan)

// After (cloud — context is server-enforced)
try await backend.loadModel(from: url, plan: .cloud())

// After (Apple Foundation Models — system owns allocation)
try await backend.loadModel(from: url, plan: .systemManaged(requestedContextSize: 4096))
```

`InferenceService.loadModel(from:contextSize:)` remains for one release as a deprecated convenience that builds a plan internally. It will be removed in the next release.

### CI coverage fix

`BaseChatInferenceTests` is now part of the CI matrix, after a macOS-only test hang in [#426](https://github.com/roryford/BaseChatKit/pull/426) (closes [#425](https://github.com/roryford/BaseChatKit/issues/425)) shipped through the previous matrix unnoticed.

## [0.8.4](https://github.com/roryford/BaseChatKit/compare/v0.8.3...v0.8.4) (2026-04-16)

**Architecture-aware llama KV cache math** — Llama.cpp context clamps were deriving their pre-allocation ceiling from a flat `8 KB`/token heuristic, which significantly under-counts real KV cost on modern GQA models — a 7B at fp16 sits closer to `128 KB`/token — so the ceiling for large models was optimistic in a way that still pressed against iPad's jetsam budget. Context sizing now derives the per-token KV estimate from each model's actual layer and attention geometry: `block_count × (k_width + v_width) × bytes_per_element`, read from GGUF metadata at preload time (`DeviceCapabilityService.safeContextSize`) and from the loaded `llama_model *` at runtime (`LlamaBackend.computeRamSafeCap`), with a new `ModelInfo.estimatedKVBytesPerToken` threading the preload estimate through chat model loading. Models whose metadata is missing the architectural fields fall back to the legacy 8 KB/token constant, so nothing regresses for models the parser can't introspect. ([#403](https://github.com/roryford/BaseChatKit/pull/403), closes [#401](https://github.com/roryford/BaseChatKit/issues/401)).

## [0.8.3](https://github.com/roryford/BaseChatKit/compare/v0.8.2...v0.8.3) (2026-04-16)

**iPad crash loading long-context GGUF models** — Loading a 32K–128K context GGUF on iPad was silently over-allocating KV cache and pushing the app past its per-app jetsam limit, triggering a SIGKILL inside `llama_init_from_model`. The root cause was that context sizing consulted `ProcessInfo.physicalMemory` — roughly 8 GB on a modern iPad — rather than the allocation budget returned by `os_proc_available_memory()`, which is typically closer to 3 GB on the same device. Context sizing is now jetsam-aware at both layers: `DeviceCapabilityService.safeContextSize()` derives the ceiling from available memory at the UI layer, and `LlamaBackend.computeRamSafeCap()` does the same for its own pre-allocation cap. A 3-attempt retry loop in `LlamaBackend` also halves `n_ctx` on clean init failures to cover near-threshold cases that return nil rather than being SIGKILLed outright. Proper per-architecture KV math ([#400](https://github.com/roryford/BaseChatKit/issues/400), [#401](https://github.com/roryford/BaseChatKit/issues/401)) is tracked as follow-up work ([#399](https://github.com/roryford/BaseChatKit/pull/399), closes [#398](https://github.com/roryford/BaseChatKit/issues/398)).

### Bug Fixes

* clamp GGUF context size based on available memory to prevent iPad crashes ([#398](https://github.com/roryford/BaseChatKit/issues/398)) ([#399](https://github.com/roryford/BaseChatKit/issues/399)) ([65c4537](https://github.com/roryford/BaseChatKit/commit/65c4537016e610151557012bbcd0bf380e546aef))

## [0.8.2](https://github.com/roryford/BaseChatKit/compare/v0.8.1...v0.8.2) (2026-04-15)

**LlamaBackend stop-and-reload reliability** — Two fixes to the llama.cpp backend's lifecycle around stopping a generation and disposing of the model. Hitting Stop mid-generation used to leave KV cache state from the interrupted run, so the next user message failed with "Failed to decode prompt" until the model was reloaded; the cache is now cleared at the start of each generation instead of conditionally at the end, so the Stop / new-message cycle works without touching the model ([#396](https://github.com/roryford/BaseChatKit/pull/396), closes [#390](https://github.com/roryford/BaseChatKit/issues/390)). Separately, `unloadModel()` schedules its tear-down on a detached task and returns before the llama.cpp context has actually been freed, which races Metal's `MTLDevice` deinit at process exit and can abort the process with a GGML assertion — turning green test runs red. A new `unloadAndWait() async` method schedules the same tear-down and awaits its completion before returning. The existing fire-and-forget `unloadModel()` is unchanged, so the new API is purely additive — tests and programmatic reload loops opt in only where determinism matters ([#395](https://github.com/roryford/BaseChatKit/pull/395), closes [#391](https://github.com/roryford/BaseChatKit/issues/391)).

## [0.8.1](https://github.com/roryford/BaseChatKit/compare/v0.8.0...v0.8.1) (2026-04-15)

**macOS Model Management sheet and UI test reliability** — Host apps running BaseChatKit on native macOS 26 were seeing the Model Management sheet open with blank content under every tab — Select, Download, and Storage — leaving model selection and downloads unreachable from the demo app. The underlying cause was a SwiftUI layout interaction: a `NavigationStack`/`VStack`/`List` tree inside a macOS sheet has no intrinsic size, so the tab content collapsed to zero height. An explicit minimum frame on the macOS sheet now gives the content stable room to lay out; iOS and iPad are unchanged because they size via `.presentationDetents`. This release also restores macOS demo UI test visibility (the app stayed backgrounded under XCUITest so tests could only see the menu bar) and fixes three flaky iPhone compact session-management tests where the shared sidebar-reveal helper was tapping at an off-screen centroid.

### Bug Fixes

* **ui:** render Model Management sheet tab content on macOS ([#378](https://github.com/roryford/BaseChatKit/issues/378)) ([#381](https://github.com/roryford/BaseChatKit/issues/381)) ([17aa3af](https://github.com/roryford/BaseChatKit/commit/17aa3afc29c70ed0f25d3ba09e4f6a1d201869ab))
* **ui:** guard macOS demo toolbar and regression-test sheet layout ([#384](https://github.com/roryford/BaseChatKit/issues/384)) ([eca970d](https://github.com/roryford/BaseChatKit/commit/eca970dda22e9de81a55ae974add1688e83c4ef5))
* **test:** restore macOS demo UI test visibility ([#377](https://github.com/roryford/BaseChatKit/issues/377)) ([#386](https://github.com/roryford/BaseChatKit/pull/386)) ([29e2230](https://github.com/roryford/BaseChatKit/commit/29e223028f1e52f1b87cf5bb406009dac1959fb7))
* **test:** reveal sidebar reliably on iPhone compact ([#388](https://github.com/roryford/BaseChatKit/pull/388)) ([a7b3a73](https://github.com/roryford/BaseChatKit/commit/a7b3a736c91b6a1eebf63957b10e4830c898007b))

## [0.8.0](https://github.com/roryford/BaseChatKit/compare/v0.7.8...v0.8.0) (2026-04-14)

**Security hardening pass** — twelve defensive changes across transport, credentials, at-rest data, streaming, and downloads, driven by a framework-wide security architect review. Integrators of BaseChatKit now inherit a measurably tighter default posture: the surface area that a malicious custom endpoint or a tampered download can reach is smaller, errors fail closed where they should, and the public API tells integrators what went wrong instead of silently degrading.

### ⚠ BREAKING CHANGES

**`KeychainService.store` and `.delete` now throw `KeychainError` instead of returning `Bool`.** Previously, a failed Keychain write (device locked, missing entitlement, out of space) silently returned `false`, and every caller we surveyed either discarded the result or only surfaced a generic "failed to save" banner — the user would configure an API key, see it "save", then get auth failures later with no indication why. The throwing API forces the failure to be acknowledged. `KeychainError` conforms to `LocalizedError` and maps common `OSStatus` codes (`errSecInteractionNotAllowed`, `errSecMissingEntitlement`, `errSecDuplicateItem`, etc.) to short user-facing sentences; an `osStatus` accessor is available for programmatic recovery. `APIEndpoint.setAPIKey` and `.deleteAPIKey` propagate the same error. Migration is mechanical: wrap the call in `try` inside a `do`/`catch`, or use `try?` where fire-and-forget cleanup is acceptable. ([#363](https://github.com/roryford/BaseChatKit/issues/363))

### Network defenses

**SSRF blocked at custom-endpoint validation.** User-configurable API endpoints could previously target internal networks — a malicious or mistaken configuration pointing at `http://192.168.1.1` or `http://169.254.169.254` (AWS instance metadata) would turn the device into a proxy into the user's LAN or cloud-metadata surface. `APIEndpoint.validate()` now rejects RFC1918 ranges (10/8, 172.16/12, 192.168/16), link-local (169.254/16, fe80::/10), IPv6 unique-local (fc00::/7), IPv4-mapped IPv6 loopback, multicast, reserved ranges, and non-`http(s)` schemes. Loopback remains allowed for local dev servers (Ollama). A trailing-dot FQDN bypass (`https://192.168.1.1.`) was found during review and closed. ([#360](https://github.com/roryford/BaseChatKit/issues/360))

**Typed `APIEndpointValidationReason` surfaces specific rejection reasons in the settings UI.** Before, the settings row rendered every invalid endpoint as a generic "Incomplete" label — users had no way to know they'd typed a private IP vs. misspelled the host. `APIEndpoint.validate() -> Result<Void, APIEndpointValidationReason>` now returns one of nine specific cases (`.privateHost`, `.linkLocalHost`, `.ipv6UniqueLocal`, `.ipv4MappedLoopback`, `.multicastReserved`, `.unsupportedScheme(String)`, `.insecureScheme`, `.malformedURL`, `.emptyURL`), each with a short actionable `errorDescription` surfaced as a subtitle on the endpoint row. `isValid: Bool` is preserved as a derived convenience for callers that only need a yes/no. ([#368](https://github.com/roryford/BaseChatKit/issues/368))

**SSE streams bounded against hostile-server memory and rate attacks.** `SSEStreamParser` had no caps on per-event size, total stream size, or event frequency, so a malicious or misconfigured upstream could exhaust client memory or saturate the consumer. New `SSEStreamLimits` defaults to 1 MB per event, 50 MB per stream, and 5,000 events/second — well above any realistic provider throughput — and throws `SSEStreamError.eventTooLarge` / `.streamTooLarge` / `.eventRateExceeded` through the existing `AsyncThrowingStream` error path. Tunable globally via `BaseChatConfiguration.shared.sseStreamLimits` or per-backend. Applied to both SSE (OpenAI, Claude, custom) and NDJSON (Ollama) paths. ([#361](https://github.com/roryford/BaseChatKit/issues/361))

**Upstream error bodies sanitized before reaching the UI.** `CloudBackendError.serverError.message` previously passed raw upstream JSON/HTML/text directly to the user-facing error description, which risked content injection if any renderer downstream treated it as attributed text, and leaked multi-kilobyte HTML proxy pages into error banners. `CloudErrorSanitizer` now strips control / zero-width / bidi-override scalars, rejects HTML-shaped payloads (falling back to `"Server error from <host>"`), redacts JWT- and URL-shaped tokens, collapses whitespace, and caps the message at 256 characters. Raw bodies remain visible in Console at `.debug` privacy for diagnostics. Wired into OpenAI, Claude, and Ollama backends. ([#364](https://github.com/roryford/BaseChatKit/issues/364))

### Credentials & at-rest data

**SwiftData store protected at rest on iOS/tvOS/watchOS.** `ModelContainerFactory` now applies `NSFileProtectionCompleteUntilFirstUserAuthentication` to the store file and its WAL sidecars, so chat history, saved endpoints, and sampler presets are sealed until the user unlocks the device once after reboot — protecting the corpus against offline attacks on a powered-off or freshly-booted device while preserving background-task compatibility. Configurable via `BaseChatConfiguration.fileProtectionClass` (set `.complete` for stricter, `nil` to opt out). macOS and Mac Catalyst are no-ops — FileVault handles at-rest protection there. In-memory stores are unaffected. ([#371](https://github.com/roryford/BaseChatKit/issues/371))

**Orphaned Keychain items reaped on boot.** Previously, an `APIEndpoint` row could be deleted through the SwiftData context (or its row-delete could succeed while the `KeychainService.delete` failed) and the Keychain item for that UUID would remain indefinitely — there was no mechanism to reclaim it. `BaseChatBootstrap.reapOrphanedKeychainItems(in:)` now sweeps the framework's Keychain service namespace on `SwiftDataPersistenceProvider.init`, deleting any item whose account UUID doesn't match a live `APIEndpoint`. The sweep is sub-millisecond for a typical namespace and logs the reap count at `.info`. Opt out via `BaseChatConfiguration.keychainReaperEnabled = false` for test harnesses that populate the namespace independently. ([#372](https://github.com/roryford/BaseChatKit/issues/372))

### Downloads & model input

**Download file-name validation + stale temp-file sweep.** Model filenames come from external manifests (HuggingFace or user-supplied) and previously relied only on a URL-standardization + prefix check to prevent traversal. `DownloadableModel.validate(fileName:)` now enforces explicit per-component rules (`.pathTraversal`, `.backslash`, `.emptyComponent`, `.tooManyComponents`, `.hidden`, `.tooLong`, `.controlCharacter`) as a layer on top. In-flight downloads were also leaking temp files to `/tmp` on crash; `BackgroundDownloadManager.cleanupStaleTempFiles()` now runs on session reconnect, scoped to files matching the manager's own `basechatkit-dl-<UUID>.download` pattern older than 24 hours, and logs the reclaimed count. ([#365](https://github.com/roryford/BaseChatKit/issues/365))

**Quantization-extraction regex bounded against ReDoS.** The `DownloadableModel.quantization` getter used an unbounded quantifier `(?:_[A-Z0-9]+)*` on externally-controlled filenames, which — combined with the trailing literal — allowed catastrophic backtracking on crafted input (a measured 250 ms on a 1,000-char pathological string, worst case unbounded). The quantifier is now `{0,5}` (real-world tags never exceed two suffix components) and input is clipped to 128 characters before the regex runs. ([#362](https://github.com/roryford/BaseChatKit/issues/362))

### Documentation & small hardening

**DocC `SecurityModel` article** documenting the full threat model: certificate pinning (`PinnedSessionDelegate`), SSRF allowlist, Keychain scope, at-rest protection expectations, SSE caps, upstream sanitization, download validation, and explicit out-of-scope (DNS rebinding, prompt injection, compromised-host threats). Linked from the README. ([#369](https://github.com/roryford/BaseChatKit/issues/369))

**`PinnedSessionDelegate` defense-in-depth.** The pin documentation had a stale comment that claimed pin sets were "intentionally left empty" when in fact `loadDefaultPins()` was shipping GTS WE1 intermediate + GTS Root R4 backup pins — a future maintainer reading the comment might have deleted the population code as dead. A regression-guard CI test now asserts both `api.openai.com` and `api.anthropic.com` ship with ≥2 pins each (primary + rotation backup). A separate small hardening fix adds a `guard scalars.count >= 2` to `CloudErrorSanitizer.containsHTMLTag` against a range-trap that was unreachable-today but one code reorder from real. ([#359](https://github.com/roryford/BaseChatKit/issues/359), [#370](https://github.com/roryford/BaseChatKit/issues/370))

**Build hotfix for interleaved merges.** `CustomEndpointValidationTests` was added by #360 while #363 was in review; both PRs' CI passed against their own bases but main briefly failed to compile once both landed because the test called the pre-#363 non-throwing `KeychainService.delete`. One-line `try?` fix. ([#374](https://github.com/roryford/BaseChatKit/issues/374))

## [0.7.8](https://github.com/roryford/BaseChatKit/compare/v0.7.7...v0.7.8) (2026-04-14)

### Features

**Adaptive iPad UX for hardware keyboards and split-view workflows** — iPad users with a hardware keyboard can now drive the app entirely from key commands: Cmd+Return sends a message, Cmd+N opens a new chat, Cmd+, opens Settings, Cmd+Shift+M opens Model Management, and Cmd+Shift+K clears the current chat. Settings, API configuration, and chat-export panels now present as popovers anchored to their trigger controls when the app runs at a regular horizontal size class, keeping the chat and sidebar visible instead of covering them with a full sheet (iPhone retains the sheet presentation). The model management sheet on iPad honours a `.medium` detent so users can browse or switch models without losing the split-view context behind it. Closes #344, #345, #346. ([#352](https://github.com/roryford/BaseChatKit/issues/352))

### Performance Improvements

**Coalesced SwiftUI redraws during model loading** — `ChatViewModel.applyModelLoadProgress` transitioned its `activityPhase` on every 50 ms progress tick, producing up to 20 observable invalidations per second and re-rendering every view bound to the phase (chat view, input bar, progress indicators). Progress-driven phase transitions are now throttled to ~4 Hz while the first emission and the terminal 1.0 emission are preserved, so the progress bar still feels immediate at the start and end without the churn in between. ([#357](https://github.com/roryford/BaseChatKit/issues/357))

### Bug Fixes

**Stale token counts after memory-pressure unload or message edit** — `ChatViewModel.tokenCountCache` and its cached `CachingTokenizer` survived `unloadModel()`, so a memory-pressure unload followed by loading a different model could return token counts keyed by a reused message UUID against the wrong tokenizer, distorting context-window estimates and triggering premature trimming. The caches are now invalidated together with the tokenizer identity marker on unload, `editMessage()` drops the affected entry right after the persistence update, and both the per-message cache and the cached tokenizer are marked `@ObservationIgnored` so writes no longer churn SwiftUI invalidations. ([#356](https://github.com/roryford/BaseChatKit/issues/356))

**Hardened SSE cloud-backend contract and concurrency** — `SSECloudBackend.init` now requires an `SSEPayloadHandler`, turning what was previously a runtime `fatalError` on a missing `extractToken(from:)` / `extractUsage(from:)` / `isStreamEnd(_:)` / `extractStreamError(from:)` override into a compile-time error for any external subclass (closes [#328](https://github.com/roryford/BaseChatKit/issues/328)). Separately, the `WeakBox<GenerationStream>` used by `generate()` was declared `@unchecked Sendable` with no lock guarding its mutable value, leaving a latent race for callers not pinned to `@MainActor`; `generate()` now uses `AsyncThrowingStream.makeStream()` — the same pattern already in `LlamaBackend`, `MLXBackend`, and `FoundationBackend` — so the stream is captured directly by value and the unsynchronised indirection is gone (closes [#327](https://github.com/roryford/BaseChatKit/issues/327)).

**Model download resume data moved out of UserDefaults** — `BackgroundDownloadManager` previously wrote each in-flight download's resume blob to `UserDefaults` under `resumeData.<id>`. A multi-GB model interrupted mid-transfer could leave 20–50 MB sitting in the plist that iOS loads synchronously at every app launch, measurably slowing cold start, and the pending-downloads dictionary could be corrupted by a crash between a `set` and the system's write-back. Resume data is now written atomically to one binary file per download under `Caches/<bundle>.downloads/`, pending metadata is a single JSON file replaced via temp-file rename, and a launch-time sweep deletes orphaned resume files from previously crashed sessions. A one-time migration moves any existing UserDefaults data to the new location the first time the updated app runs. ([#330](https://github.com/roryford/BaseChatKit/issues/330))

**Restored BaseChatInference imports after the re-export removal** — v0.7.7 removed the `@_exported import BaseChatInference` from `BaseChatCore`, exposing three call sites that had been relying on the transitive re-export: `AppearanceMode+ColorScheme.swift` in the UI layer (closes [#341](https://github.com/roryford/BaseChatKit/issues/341)) and the demo app's `DemoContentView` and `BaseChatDemoApp` (closes [#343](https://github.com/roryford/BaseChatKit/issues/343)). All three now `import BaseChatInference` directly, restoring the `swift build` green. PR #343 additionally fixes an iPad-only bug where `ChatContentView.onAppear` created a new session via `sessionManager.createSession()` but never set `activeSession`, leaving the detail pane in the split view stuck on "No session selected" until the user tapped a row; the first session is now auto-selected on launch.

**MLX-trait test compilation on Apple Silicon** — `MLXBackendTests`, `MLXBackendGenerationTests`, and `MLXModelE2ETests` referenced `GenerationConfig` and `GenerationStream` from `BaseChatInference` but never imported the module. Because the `MLX` trait is disabled in CI, the failures only showed up locally when running `swift test --traits MLX,Llama`. Imports added; no runtime behaviour change. ([#350](https://github.com/roryford/BaseChatKit/issues/350), [#358](https://github.com/roryford/BaseChatKit/issues/358))

## [0.7.7](https://github.com/roryford/BaseChatKit/compare/v0.7.6...v0.7.7) (2026-04-13)


### Bug Fixes

* **arch:** remove @_exported import BaseChatInference re-export from BaseChatCore ([#338](https://github.com/roryford/BaseChatKit/issues/338)) ([13f3d46](https://github.com/roryford/BaseChatKit/commit/13f3d460e73713991a588cd6198970039e2c75cf))
* **arch:** remove SwiftUI from inference layer and deprecate maxTokens ([#332](https://github.com/roryford/BaseChatKit/issues/332)) ([2ab67c3](https://github.com/roryford/BaseChatKit/commit/2ab67c3f5dd7197a7fc48f0fcb7f275a06e03043))
* **concurrency:** serialize BackgroundDownloadManager.cancelDownload taskContext read on MainActor ([20c6126](https://github.com/roryford/BaseChatKit/commit/20c61268500368d9c120dd24cb679d0cfe2c7a4c))
* **security:** sanitize model.fileName against path traversal in download placement ([#331](https://github.com/roryford/BaseChatKit/issues/331)) ([20c6126](https://github.com/roryford/BaseChatKit/commit/20c61268500368d9c120dd24cb679d0cfe2c7a4c))

## [0.7.6](https://github.com/roryford/BaseChatKit/compare/v0.7.5...v0.7.6) (2026-04-12)

**Model browser overhaul — smarter downloads, resilient transfers, and device-aware recommendations** — Six improvements to the model download and browsing experience, covering the full lifecycle from finding a model to getting it running.

Downloads now survive network interruptions. When a transfer fails part-way through — timeout, dropped connection, or the app moving to background — the download manager stores the incomplete file and resumes from the byte offset where it left off on retry, rather than starting over. A retry button appears inline on the failed row. Stale download state from previous sessions is also reconciled on launch: orphaned in-memory entries are removed and a diagnostic log is emitted for each cleanup, eliminating the phantom progress rows that could appear after a crash or force-quit. ([#322](https://github.com/roryford/BaseChatKit/pull/322), [#320](https://github.com/roryford/BaseChatKit/pull/320))

The moment a download completes, a "Use \<ModelName\> now?" alert appears automatically if the finished model is not already the active selection. Tapping "Use Now" maps the downloaded file to the corresponding `ModelInfo` and switches the session immediately, removing the extra tap to the Select tab. The prompt is suppressed if the model is already loaded, and only one prompt can be pending at a time so back-to-back downloads don't stack alerts. ([#319](https://github.com/roryford/BaseChatKit/pull/319))

Disk space errors are now surfaced before and during download. When a model's declared size exceeds the volume's available capacity for important usage, the download button is grayed out and disabled proactively, with an "Insufficient storage" caption below it. If a download is attempted anyway and fails with an `insufficientDiskSpace` error, the error message is formatted as a human-readable string (e.g. "Not enough storage — this model needs 4.1 GB but only 1.2 GB is available") rather than a raw system error. A blue "In Use" badge also replaces the green "Downloaded" badge for the currently loaded model, so the active model is visually distinct from others that happen to be on disk. ([#321](https://github.com/roryford/BaseChatKit/pull/321))

Search results are now sorted by device compatibility rather than raw download count. Groups whose variants fit comfortably in device RAM appear before oversized models regardless of HuggingFace popularity, with download count used only to break ties within the same compatibility tier. Inside each disclosure group, the best-fitting variant (the largest quantization that passes the memory check, or the smallest when nothing fits) is sorted to the top and labelled "Recommended" or "Smallest available" with a green capsule badge — matching the existing "Curated" badge style — so the right quant is obvious without cross-referencing the device's RAM manually. The search pool is also doubled from 20 to 40 repos, surfacing more quant options per query. ([#325](https://github.com/roryford/BaseChatKit/pull/325), [#323](https://github.com/roryford/BaseChatKit/pull/323))

## [0.7.5](https://github.com/roryford/BaseChatKit/compare/v0.7.4...v0.7.5) (2026-04-12)

**Streaming performance fix and background-cancellation handler** — Two improvements targeting the chat UI's behaviour during and after active generation.

When an assistant reply grew beyond ~1 KB, the UI was calling `AttributedString(markdown:)` on the full accumulated text on every token delivery. With a 500-token response that is 500 full re-parses of an ever-longer string — O(N²) total work — causing visible lag on Apple Silicon at 2 KB and above. A new `MarkdownAttributedStringCache` memoizes the rendered `AttributedString` per block: stable blocks (everything except the last, still-growing line) are returned from cache in O(1), reducing total rendering work to O(N). ([#301](https://github.com/roryford/BaseChatKit/pull/301), closes [#245](https://github.com/roryford/BaseChatKit/issues/245))

`ChatViewModel` now exposes `handleScenePhaseChange(to:)` so host apps can cleanly cancel active generation when the app moves to `.background`. Without this, a user pressing the home button mid-stream left a zombie generation task running until the backend eventually timed out or was killed by the OS. The method is a no-op on `.active` and `.inactive`, making it safe to call unconditionally from `onChange(of: scenePhase)`. ([#302](https://github.com/roryford/BaseChatKit/pull/302), closes [#241](https://github.com/roryford/BaseChatKit/issues/241))

## [0.7.4](https://github.com/roryford/BaseChatKit/compare/v0.7.3...v0.7.4) (2026-04-12)

**Test workflow hardening and persistence cleanup** — A cancelled assistant response could be saved twice, leaving orphaned rows that resurfaced after reload and forced the main user-journey E2E to tolerate known issues. This change makes chat-message persistence behave like an upsert at the view-model boundary, removes the known-issue wrappers from the end-to-end journey, tightens MLX integration fixture detection so malformed local snapshots are skipped instead of failing the suite, and stabilizes the Example app's UI test contract with explicit accessibility hooks plus a scripted `build-for-testing` / `test-without-building` loop. The result is a test matrix that is both more trustworthy and much faster to debug when failures do happen. ([#297](https://github.com/roryford/BaseChatKit/pull/297))

## [0.7.3](https://github.com/roryford/BaseChatKit/compare/v0.7.2...v0.7.3) (2026-04-11)

**Load progress, an InferenceService audit, and internal hardening** — Three improvements from a focused audit of `InferenceService` and its supporting infrastructure.

`LlamaBackend` now adopts `LoadProgressReporting` using the llama.cpp C API's `progress_callback` hook, publishing real fractional progress through `InferenceService.modelLoadProgress` as weights load. `MLXBackend` adopts the same protocol with synthetic `0.0`/`1.0` bookends — the `mlx-swift-lm` local-directory load path exposes no granular progress hook, so the bookend approach replaces the previous flat spinner with a signal that reflects actual load state. The `LoadProgressReporting` infrastructure in `InferenceService` was complete but adopted by no production backend; both backends now wire into it. ([#290](https://github.com/roryford/BaseChatKit/pull/290))

The `unloadModel()` mid-stream safety invariant is now locked in by test. An audit of `InferenceService` confirmed that the existing guards — `stopGeneration()` nils `activeRequest` synchronously before the cancelled Task's defer fires, the auto-drain token guard prevents re-entry on a cancelled slot, and `enqueue()` rejects calls when `backend == nil` — are sufficient to prevent state corruption when a model is unloaded while generation is active. Two tests lock this in: one that unloads before any tokens flow and one that unloads after tokens start streaming, both verifying that `isModelLoaded`, `isGenerating`, and `hasQueuedRequests` are clean afterward and that a subsequent `enqueue()` correctly throws. ([#288](https://github.com/roryford/BaseChatKit/pull/288))

Two smaller improvements round out the release: `NSRegularExpression` for system prompt context substitution is now compiled once as a file-private top-level constant rather than on every generation call ([#287](https://github.com/roryford/BaseChatKit/pull/287)), and `BackgroundDownloadManager` is split into three focused files — the GGUF/MLX format validation logic extracted into a standalone `DownloadFileValidator` struct and the `URLSessionDownloadDelegate` conformance moved to its own extension file, reducing the main file from 821 to ~600 lines ([#289](https://github.com/roryford/BaseChatKit/pull/289)).

## [0.7.2](https://github.com/roryford/BaseChatKit/compare/v0.7.1...v0.7.2) (2026-04-11)

**Generation queue hardening — auto-drain and title generation race eliminated** — Two fixes targeting the InferenceService generation queue, both discovered during an audit of the service's blast radius against consumers like Fireside.

The first fix removes the manual `generationDidFinish()` contract that previously required every `enqueue()` caller to call back into the service after consuming its stream — failure to do so stalled the queue permanently with no error surfaced anywhere. The queue now auto-drains when the stream terminates: the `drainQueue()` task's defer block clears the active request and kicks the next item when the stream finishes, errors, or is cancelled. A token guard (`activeRequest?.token == next.token`) prevents re-entry when `cancel()` or `stopGeneration()` have already cleared the slot. `generationDidFinish()` is retained as a deprecated no-op so existing call sites compile unchanged. ([67ec85c](https://github.com/roryford/BaseChatKit/commit/67ec85c00f89e069b8c280a0cb5228e905a1b224))

The second fix routes title generation through `enqueue(priority: .background, sessionID: nil)` instead of the non-queued `generate()` path. Previously, `SessionManagerViewModel.generateTitle()` called `generate()` directly, which bypassed the priority queue, thermal gating, and session scoping. On MLXBackend, this meant a title generation and an active chat generation could race for the backend's main-thread lock, risking main-thread starvation mid-stream. Title requests now queue as background priority behind any active user-initiated generation, are subject to thermal gating, and drain automatically when complete. ([7afd4d6](https://github.com/roryford/BaseChatKit/commit/7afd4d6d40f415aa36b1d641e311e261ba2e6243))

## [0.7.1](https://github.com/roryford/BaseChatKit/compare/v0.7.0...v0.7.1) (2026-04-11)

**Accessibility contract tests and VoiceOver polish for chat UI** — The chat view's accessibility surface had no automated coverage because the existing snapshot harness captured view hierarchies via `Swift.dump()`, which strips accessibility labels. This release adds a ViewInspector-driven `ChatA11yContractTests` suite and tightens the labels VoiceOver users actually hear: message bubbles now announce `"User said: …"` / `"Assistant said: …"` instead of the raw enum rawValue, the context indicator reads `"Context used: 1234 of 4096 tokens"` at `"50 percent"`, and the error banner is exposed as an accessibility header with an `"Error: …"` prefix so screen-reader users can orient to it as a landmark. Existing visual snapshots and behaviour are unchanged. ([#258](https://github.com/roryford/BaseChatKit/pull/258))

## [0.7.0](https://github.com/roryford/BaseChatKit/compare/v0.6.0...v0.7.0) (2026-04-10)

**Structural slimming — inference target extracted, compression and macros retired** — 0.7.0 is the structural follow-up to 0.6.0's scope cut. Where 0.6.0 deleted subsystems with zero audited consumers and repositioned BCK around its operational-reliability guarantees, 0.7.0 finishes the job: the inference-orchestration surface is split into its own SPM target so UI-less consumers can drop SwiftData from their build graph, two subsystems that 0.6.0 deferred (the compression pipeline and the full macro engine) are now fully removed after their single remaining consumer vendored local copies, and the tool-calling removal trail from [#269](https://github.com/roryford/BaseChatKit/pull/269) is closed out by deleting the persisted `MessagePart` tool cases after a schema audit confirmed they were never populated in any shipped store. The canonical rationale for the slimming initiative remains in [docs/SCOPE_DECISION.md](https://github.com/roryford/BaseChatKit/blob/main/docs/SCOPE_DECISION.md); 0.7.0 is the structural correction that that document called for.

### New target: BaseChatInference

BCK's inference surface — `InferenceService`, backend protocols, generation events, context window management, prompt assembly, repetition detection, tokenizers, the capability API, and the framework configuration — now lives in a standalone `BaseChatInference` SPM target ([#271](https://github.com/roryford/BaseChatKit/pull/271)). Previously every consumer that imported `BaseChatCore` for inference orchestration also pulled in SwiftData, the `@Model` types, the persistence provider, and the chat export service, even if those consumers never touched persistence at all. Server-side runners, CLI tools, test harnesses, and host-app feature modules that compose their own persistence can now depend on `BaseChatInference` alone and leave `BaseChatCore` out of their build graph entirely. `BaseChatBackends` also sheds its dependency on `BaseChatCore` and now depends directly on `BaseChatInference`, so backend implementations are structurally incapable of reaching for SwiftData types. Existing apps that import `BaseChatCore` are unaffected: `BaseChatCore` contains `@_exported import BaseChatInference`, so every inference symbol is still reachable through the old import path with no source changes.

### Subsystems retired

Two complete subsystems leave BCK in this release after consumer audits confirmed both had only a single internal consumer that had since vendored its own local copy. The **compression pipeline** ([#276](https://github.com/roryford/BaseChatKit/pull/276)) removes roughly 3,240 lines across `AnchoredCompressor`, `ExtractiveCompressor`, `CompressionOrchestrator`, `ContextCompressor`, `CompressionMode`, `CompressibleMessage`, `CompressionStats`, the `CompressionIndicatorView` UI, and 13 compression test files spanning the Inference, UI, and E2E suites. The `compressionMode` field on `ChatSessionRecord` and the `compressionModeRaw` storage on the `@Model ChatSession` are also gone. History trimming now runs unconditionally through `ContextWindowManager.trimMessages`, which continues to honor pinned messages and the configured context window. The **macro engine** ([#275](https://github.com/roryford/BaseChatKit/pull/275)) removes `MacroExpander`, `MacroProvider`, `MacroContext`, `ChatViewModel.macroContext`, `ChatViewModel.macroExpansionEnabled`, and the `buildMacroContext()` helper. The simpler `systemPromptContext: [String: String]` API that shipped in 0.6.0 as [#265](https://github.com/roryford/BaseChatKit/pull/265) now serves as the sole expansion path — apps set `viewModel.systemPromptContext["userName"] = name` and the substitution runs as a non-recursive pass over the dict before the prompt is assembled.

The third refactor in this release closes the tool-calling removal trail from 0.6.0. [#270](https://github.com/roryford/BaseChatKit/pull/270) deletes the `MessagePart.toolCall` and `.toolResult` enum cases after a schema audit confirmed that no shipped SwiftData schema version ever populated them — the cases existed only in SwiftUI previews, Codable round-trip fixtures, and an unmerged feature branch. `ChatMessage.decode` already falls back to a text bubble on unknown discriminators, so any hypothetical legacy row containing a tool-case part degrades gracefully on load rather than crashing, and a regression test locks that fallback behavior in place.

### Breaking changes

Apps that directly reference any of the removed symbols will not compile against 0.7.0. The migration path for each is noted inline.

- `MacroExpander`, `MacroProvider`, and `MacroContext` public types — deleted. Apps that relied on custom `MacroProvider` registrations should vendor their own expansion layer.
- `ChatViewModel.macroContext` and `ChatViewModel.macroExpansionEnabled` — deleted. Migrate `viewModel.macroContext.userName = name` to `viewModel.systemPromptContext["userName"] = name`. The dictionary key is caller-controlled; the old API hardcoded fields such as `userName` and `charName`. If your template tokens were `{{user}}` or `{{char}}`, use `systemPromptContext["user"]` and `systemPromptContext["char"]`.
- `buildMacroContext()` helper on `ChatViewModel` — deleted alongside the rest of the macro surface.
- Built-in macro tokens such as `{{date}}`, `{{time}}`, `{{weekday}}`, `{{isodate}}`, `{{random::a::b}}`, and `{{lastMessage}}` no longer auto-expand. Compute the value at the call site and inject it via `systemPromptContext["date"] = ...` before calling `sendMessage`.
- `CompressionMode`, `CompressionOrchestrator`, `AnchoredCompressor`, `ExtractiveCompressor`, `CompressibleMessage`, `CompressionStats`, `CompressionResult`, `ContextCompressor`, and `CompressionIndicatorView` — deleted. Apps that need history summarization should pin to the 0.6.x line or vendor a local copy of the strategies.
- `ChatViewModel.compressionMode` and `ChatViewModel.lastCompressionStats` — deleted.
- `ChatSession.compressionMode` / `compressionModeRaw` and `ChatSessionRecord.compressionMode` — deleted.
- `ContextIndicatorView.init(usedTokens:maxTokens:lastCompressionStats:)` — the third parameter is removed; call the two-parameter form.
- `MessagePart.toolCall(id:name:arguments:)` and `MessagePart.toolResult(id:content:)` enum cases — deleted. Code that pattern-matches on `MessagePart` with an exhaustive switch must drop the corresponding arms.
- `BaseChatBackends` now depends on `BaseChatInference`, not `BaseChatCore`. Apps whose backend-adjacent code imported `BaseChatCore` transitively through `BaseChatBackends` may need to add an explicit `import BaseChatInference` (or keep `import BaseChatCore`, which re-exports the same symbols).
- `InferenceService.loadCloudBackend(from:)` and `SettingsService.effectiveTemperature`/`effectiveTopP`/`effectiveRepeatPenalty(session:)` now accept the new `APIEndpointRecord` / `ChatSessionRecord?` value types introduced in `BaseChatInference`. A `BaseChatCore` extension preserves the old `@Model APIEndpoint` and `@Model ChatSession` call sites via adapter overloads, so persistence-backed call sites compile unchanged.

### Compatibility and migration

Persisted data survives the upgrade. `ChatSession.compressionModeRaw` was an optional `String?` column with a nil default, so SwiftData's automatic schema migration silently drops it the next time the store is opened — there is no migration error and the inference pipeline no longer reads the value. Any `MessagePart` JSON rows that somehow contained a tool-case discriminator would decode to a plain text bubble through `ChatMessage.decode`'s existing fallback, though the audit in [#270](https://github.com/roryford/BaseChatKit/pull/270) confirmed no shipped schema version ever wrote such rows. Consumers that previously set `viewModel.macroContext.userName = name` should switch to `viewModel.systemPromptContext["userName"] = name` — the dict-based API is strictly simpler and has been available since 0.6.0 as the forward-compatible replacement. Consumers that need history compression should either pin to 0.6.x or vendor a local copy of the strategies; context trimming via `ContextWindowManager` remains in BCK unchanged.

### Size reduction

After 0.6.0's deletions and the structural changes in this release, BCK's source tree is roughly 35% smaller than the pre-slimming baseline.

## [0.6.0](https://github.com/roryford/BaseChatKit/compare/v0.5.4...v0.6.0) (2026-04-10)

**Slimming pass — BCK refocuses on production reliability** — A consumer audit of BaseChatKit's two known consumers (a private internal app and the public [ChatbotUI-iOS](https://github.com/roryford/ChatbotUI-iOS) demo) found that less than half of the codebase had real demand. Several large subsystems had zero consumers on either side, and several more were carrying public API surface that would have frozen into 1.0 commitments without any validating users. 0.6.0 is the correction: delete what nobody uses, add the small amount of new API that the audited apps actually need, and reposition BCK around the operational-reliability guarantees that make it valuable to the consumers that ship it. The full rationale, the audit table, and the "what's leaving / what's staying" decisions are recorded in [docs/SCOPE_DECISION.md](https://github.com/roryford/BaseChatKit/blob/main/docs/SCOPE_DECISION.md).

### What was removed

Three subsystems leave the public API this release. The **KoboldCpp backend** ([#266](https://github.com/roryford/BaseChatKit/pull/266)) is gone — zero references in either audited consumer, no evidence of external interest, and KoboldCpp's HTTP API is largely OpenAI-compatible, so apps that still need it can point the custom OpenAI-compatible endpoint path at a KoboldCpp server instead. The **server discovery subsystem** ([#268](https://github.com/roryford/BaseChatKit/pull/268)) — roughly 1,825 lines of Bonjour plus network port-scanning code built speculatively for a "find local LLM servers on the LAN" flow — also had zero consumers on either side; apps that need local discovery can implement their own scanner or use the existing custom-endpoint UI to enter URLs manually. The **tool calling public API surface** ([#269](https://github.com/roryford/BaseChatKit/pull/269)) — `ToolProvider`, `ToolCallingBackend`, and all tool-specific types — was experimental scaffolding that would have become a load-bearing 1.0 contract without any real users exercising it. Removing it now lets a future release ship a stable cross-backend tool-calling design without the burden of maintaining the current shape in parallel.

Note that the `BackendCapabilities.supportsToolCalling: Bool` property stays in place, since removing it is a separable breaking change and keeping the capability-advertising surface stable is useful for apps that want to light up tool UI when a stable contract ships. `MessagePart.toolCall` and `.toolResult` enum cases also remain in this release because they are persisted in the SwiftData schema and need a dedicated migration path.

### New API

A new `ChatViewModel.systemPromptContext: [String: String]` property ([#265](https://github.com/roryford/BaseChatKit/pull/265)) provides a simple key/value substitution pass for the system prompt — apps that want to inject a username, a persona name, or any other small value into their prompts no longer need to wire up a full `MacroProvider` registry. The substitution runs at the existing macro expansion site in `ChatViewModel+Generation`, immediately after `MacroExpander.expand()`, so applications that rely on the richer `macroContext` pipeline continue to work unchanged and `MacroExpander` wins on key collisions. Both APIs coexist in 0.6.0; the full macro system is deferred to a later release pending coordination with its one consumer.

### Positioning update

BCK's README and the new [docs/SCOPE_DECISION.md](https://github.com/roryford/BaseChatKit/blob/main/docs/SCOPE_DECISION.md) ([#264](https://github.com/roryford/BaseChatKit/pull/264)) now lead with the framework's actual value proposition: a drop-in chat framework with operational reliability guarantees — streaming resilience across transient network loss and provider errors, latest-wins model handoff so rapid model switches cannot corrupt active state, memory pressure auto-unload so iOS cannot silently page out a loaded model, a mock backend so apps can unit-test their streaming contracts without loading a real model, and certificate pinning on known cloud APIs so misconfigured devices cannot silently leak chat traffic. These are the production failure modes BCK has caught because it runs in apps that ship to real users on real networks. The docs also clarify that BCK and HuggingFace's [AnyLanguageModel](https://github.com/huggingface/swift-transformers) occupy adjacent rather than competing niches: AnyLanguageModel optimizes for provider abstraction, BCK optimizes for what happens when the demo ends.

### Breaking changes

Apps that directly reference any of the removed symbols will not compile against 0.6.0. The migration path for each is noted inline.

- `APIProvider.koboldCpp` enum case — use `APIProvider.custom` with a KoboldCpp endpoint URL.
- `ServerType.koboldCpp` enum case — removed along with the enum's owning subsystem.
- `KoboldCppBackend` class — instantiate a custom OpenAI-compatible backend pointed at your KoboldCpp server.
- `ServerDiscoveryService` protocol, `DiscoveredServer`, `ServerType`, `NetworkDiscoveryService`, `BonjourDiscoveryService`, `ServerDiscoveryView`, `ServerDiscoveryViewModel`, `MockServerDiscoveryService` — apps that need local server discovery should implement their own scanner or accept URLs via the existing custom-endpoint configuration UI.
- `BaseChatConfiguration.FeatureFlags.showServerDiscovery` — the flag and its associated UI are gone; remove the assignment.
- `ToolCallingBackend` protocol, `ToolProvider`, `ToolCall`, `ToolDefinition`, `ToolResult`, `ToolSchema`, `ToolCallingError`, `ToolCallObserver`, `MockToolProvider` — apps that depend on tool calling should pin to 0.5.x until a stable cross-backend contract is designed in a later release.
- `GenerationEvent.toolCall` case — removed alongside the tool calling API surface. Event handlers that exhaustively switched on the enum lose a case but gain nothing to handle.
- `StreamAction.noOp` case — unused in the remaining streaming paths.
- `ChatViewModel.toolProvider` and `ChatViewModel.toolCallObserver` public accessors — removed with the rest of the tool surface.

### Compatibility

Persisted data survives the upgrade. Any saved KoboldCpp endpoints in an app's SwiftData store silently convert to `APIProvider.custom` on load; there is no data loss, but users will see the provider label change in the settings UI. The `MessagePart.toolCall` and `.toolResult` enum cases are deliberately retained in `BaseChatSchemaV3` this release because removing them requires a SwiftData migration; a future release will address that with a proper schema version bump.

### Additional improvements shipped in 0.6.0

Several non-slimming improvements also land in this release: an explicit state machine for `ChatViewModel.activityPhase` that eliminates ambiguous intermediate states ([#261](https://github.com/roryford/BaseChatKit/pull/261)), a visible compression stats indicator so users can see when prompt compression is active and by how much ([#255](https://github.com/roryford/BaseChatKit/pull/255)), a new `OperationalError` type that surfaces previously silent `try?`/`catch` failures through a dedicated error channel ([#262](https://github.com/roryford/BaseChatKit/pull/262)), and several focused UX fixes in `ChatView`, `ChatInputBar`, `SessionListView`, and `ModelManagementSheet` ([#250](https://github.com/roryford/BaseChatKit/pull/250), [#251](https://github.com/roryford/BaseChatKit/pull/251), [#252](https://github.com/roryford/BaseChatKit/pull/252), [#253](https://github.com/roryford/BaseChatKit/pull/253)).

## [0.5.4](https://github.com/roryford/BaseChatKit/compare/v0.5.3...v0.5.4) (2026-04-10)

**Security and stability hardening** — Three fixes targeting resource leaks, memory safety, and conditional compilation correctness.

**Ephemeral API key zeroing** — `SSECloudBackend` previously stored in-memory API keys as plain Swift `String` values, which make no guarantee about zeroing backing memory on deallocation. Keys could linger in freed heap pages and be recoverable from a memory dump on a compromised device. Keys are now stored in a `SecureBytes` wrapper that uses `memset_s` (compiler-elision-safe) to zero its buffer whenever the key is replaced, `unloadModel()` is called, or the backend is deallocated. Keychain-backed storage remains the recommended path for production; the property documentation now makes the residual risk of transient `String` copies in HTTP headers explicit ([#236](https://github.com/roryford/BaseChatKit/pull/236)).

**llama.cpp RAII handle wrapping** — `LlamaBackend` held raw C pointers (`llama_model *`, `llama_context *`) as unmanaged stored properties. If the model-load path threw after the model was allocated but before the context was created, the model pointer leaked with no cleanup path. Both pointers are now wrapped in private RAII handle types that call the appropriate `llama_free_*` function on `deinit`, making cleanup unconditional regardless of how the load path exits ([#235](https://github.com/roryford/BaseChatKit/pull/235)).

**MLX and Llama trait propagation** — The `MLX` and `Llama` Swift package traits were not being forwarded as compilation conditions to dependent targets, causing `#if MLX` and `#if Llama` guards inside `BaseChatBackends` to evaluate incorrectly. Conditional compilation blocks that should have been excluded from CI builds were being compiled, and blocks that should have been included in hardware builds were being skipped. The trait definitions in `Package.swift` now correctly propagate to all targets that depend on the backend ([#233](https://github.com/roryford/BaseChatKit/pull/233)).

## [0.5.3](https://github.com/roryford/BaseChatKit/compare/v0.5.2...v0.5.3) (2026-04-10)

**Model-load progress and MLX cache tuning** — Two improvements to the local inference path.

`InferenceService` now publishes `modelLoadProgress: Double?` so UI code can render real fractional load progress instead of an indeterminate spinner. Backends with granular progress hooks can opt into the new `LoadProgressReporting` protocol to publish fractional updates as weights load; backends without it continue to work unchanged, showing `0.0` for the load duration. `ChatViewModel.activityPhase` automatically mirrors the value through `.modelLoading(progress:)`, so any view that already observes activity phase picks up the new behaviour without changes. llama.cpp and MLX backend adoption will follow in subsequent releases ([#230](https://github.com/roryford/BaseChatKit/pull/230)).

MLX's GPU buffer cache size is now consumer-tunable via `MLXBackend(cachePolicy:)`. The previous hardcoded 20 MB was inherited from the `mlx-swift-examples` LLMEval sample — a minimum-footprint demo value that was too small for sustained inference on Apple Silicon, forcing MLX to constantly evict and reallocate Metal buffers between forward passes. The new `.auto` default scales by physical memory: 64 MB on ~6 GB iOS devices through 1 GB on 36+ GB Macs. Consumer apps that have benchmarked their workloads can pass `.generous`, `.minimal`, or `.explicit(bytes:)` to the initialiser. All existing `MLXBackend()` call sites pick up the new default without any code changes ([#232](https://github.com/roryford/BaseChatKit/pull/232)).

## [0.5.2](https://github.com/roryford/BaseChatKit/compare/v0.5.1...v0.5.2) (2026-04-09)

**Demo app hardening** — A code review of the demo app uncovered a build failure, broken recovery UX, layout issues on large displays, and an overly strict memory gate that rejected models that would have loaded fine.

LlamaBackend failed to compile under Xcode 26 / Swift 6.3 due to three strict concurrency violations: a non-isolated global static, `NSLock.lock()` calls inside `Task.detached` async contexts, and a circular reference in `unloadModel()`. These are fixed with `nonisolated(unsafe)`, a synchronous lock wrapper, and direct lock/unlock calls respectively ([#228](https://github.com/roryford/BaseChatKit/pull/228)).

The error banner's Retry and Check API Key buttons previously just dismissed the error without performing any recovery. Retry now calls `regenerateLastResponse()`, and Check API Key opens the API configuration sheet. The model loading indicator also gains a Cancel button so users aren't forced to wait or force-quit during long loads ([#228](https://github.com/roryford/BaseChatKit/pull/228)).

Message bubbles are now capped at 700pt width so text stays readable on ultrawide and 5K displays, where the previous spacer-only constraint let bubbles stretch across the full window. The macOS demo window defaults to 900×700 with a 600×400 minimum to prevent unusable resize states ([#228](https://github.com/roryford/BaseChatKit/pull/228)).

The endpoint editor's Save button now requires a non-empty model name and trims whitespace. Endpoint deletion logs errors instead of silently swallowing them. The sidebar model section shows a loading spinner during model load and an error indicator on failure, eliminating the dead-end state new users hit when no model is available ([#228](https://github.com/roryford/BaseChatKit/pull/228)).

The `MemoryGate` resident strategy was multiplying the model file size by 1.20× to account for KV cache, but KV cache is allocated during inference, not at load time. This caused the gate to reject ~4.6 GB models on 16 GB devices when the process had already used 1–2 GB. The check now uses the raw file size ([#228](https://github.com/roryford/BaseChatKit/pull/228)).

## [0.5.1](https://github.com/roryford/BaseChatKit/compare/v0.5.0...v0.5.1) (2026-04-09)

**Stable model identity** — Model selection no longer silently resets after app restart, session switch, or model list refresh. `ModelInfo(ggufURL:)` and `ModelInfo(mlxDirectory:)` generated a random UUID on every call, so each `refreshModels()` rescan assigned new IDs to the same files on disk. Sessions persist `selectedModelID`, but the saved UUID never matched after a rescan — leaving users with "No model selected" despite having previously chosen one. IDs are now derived deterministically from the file path using UUID v5 (SHA-1, RFC 4122), so the same model file always produces the same identifier ([#224](https://github.com/roryford/BaseChatKit/pull/224)).

This release also adds 61 macOS control-visibility snapshot tests across ChatView, ModelManagementSheet, GenerationSettingsView, SessionListView, ChatExportSheet, and APIConfigurationView, and enables the Llama (GGUF) backend trait by default alongside MLX ([#223](https://github.com/roryford/BaseChatKit/pull/223), [#225](https://github.com/roryford/BaseChatKit/pull/225)).

## [0.5.0](https://github.com/roryford/BaseChatKit/compare/v0.4.1...v0.5.0) (2026-04-09)

**Breaking API improvements bundled with mlx-swift-lm migration** — An upstream change in mlx-swift-lm forced a breaking update to MLXBackend's model loading API. We used this as the trigger to ship six additional breaking improvements that fix real bugs, improve correctness, and reduce future maintenance cost.

mlx-swift-lm 2.31.3 declared `Hub` as a transitive dependency that Swift 6.3 / Xcode 26 now rejects. Commit `d1b14783` on mlx-swift-lm's main branch moves hub code to a new `MLXHuggingFace` target, but also changes the `loadModelContainer` signature. `MLXBackend` now uses the new `loadModelContainer(from:using:)` API with `TokenizerLoader` ([#221](https://github.com/roryford/BaseChatKit/pull/221)).

`SettingsService.globalTemperature`, `globalTopP`, and `globalRepeatPenalty` were `Float` properties that used `UserDefaults.float(forKey:)`, which returns 0 for missing keys — making it impossible to distinguish "user set temperature to 0.0" from "never configured." These are now `Float?`, with resolution helpers falling back to hardcoded defaults (0.7, 0.9, 1.1) when both session override and global are nil.

`ChatSessionRecord` stored compression mode, prompt template, and pinned message IDs as raw strings (`compressionModeRaw`, `promptTemplateRawValue`, `pinnedMessageIDsRaw`), accepting invalid values silently. These are now typed stored properties (`compressionMode: CompressionMode`, `promptTemplate: PromptTemplate?`, `pinnedMessageIDs: Set<UUID>`), with raw-to-typed conversion handled by `SwiftDataPersistenceProvider` at the persistence boundary.

`APIEndpoint.apiKey` was a computed property that performed Keychain I/O directly from a SwiftData `@Model`, breaking testability. The property is removed; callers now use `KeychainService.retrieve(account: endpoint.keychainAccount)` directly. `isValid` is now a pure structural check (URL scheme, host, HTTPS for non-localhost) and no longer queries the Keychain. Check `APIProvider.requiresAPIKey` separately for credential readiness.

`SessionManagerViewModel.deleteSession` and `renameSession` silently swallowed persistence errors. Both now throw, with a `guard let persistence` check matching `createSession`'s existing pattern. `SessionListView` surfaces errors via alert. The deprecated `configure(modelContext:)` convenience on both `ChatViewModel` and `SessionManagerViewModel` is removed — use `configure(persistence:)` with an explicit provider.

`BackendCapabilities` had two initializers: a 4-param convenience and a 12-param full init. The convenience is removed and all parameters on the single remaining init now have sensible defaults, so adding new capabilities in the future never forces changes to every backend or test mock.

### Migration guide

| Change | Migration |
|--------|-----------|
| `MLXBackend` loading API | Update custom MLX loading code to new `loadModelContainer(from:using:)` |
| `BackendCapabilities` 4-param init removed | Labeled-arg call sites compile unchanged; positional callers switch to labels |
| `ChatSessionRecord` raw string fields removed | Use `.compressionMode`, `.promptTemplate`, `.pinnedMessageIDs` |
| `APIEndpoint.apiKey` removed | Use `KeychainService.retrieve(account: endpoint.keychainAccount)` |
| `APIEndpoint.isValid` no longer checks API key | Check `APIProvider.requiresAPIKey` separately |
| `configure(modelContext:)` removed | Use `configure(persistence: SwiftDataPersistenceProvider(modelContext:))` |
| `deleteSession` / `renameSession` now throw | Wrap in `do/catch` |
| `globalTemperature` / `globalTopP` / `globalRepeatPenalty` are `Float?` | Handle optional; use `?? 0.7` etc. for display |

## [0.4.1](https://github.com/roryford/BaseChatKit/compare/v0.4.0...v0.4.1) (2026-04-08)

**Concurrency hardening and test coverage expansion** — A comprehensive codebase review uncovered three concurrency hazards that could cause data races under load, plus gaps in input validation and test coverage. This patch fixes all three races, adds URL validation to the endpoint editor, documents protocol threading contracts, and ships 117 new tests.

`MLXBackend` stored mutable state (`isModelLoaded`, `isGenerating`, `modelContainer`) without synchronization across `Task` boundaries — concurrent model loads and generation stops could race. The backend now uses `NSLock` matching the existing `LlamaBackend` pattern, with `unloadModel()` consolidated into a single critical section to prevent observable inconsistent state ([#218](https://github.com/roryford/BaseChatKit/pull/218)).

`ChatViewModel` looked up message indices via `firstIndex(where:)` and then mutated at that index, but any `await` between lookup and mutation could leave the index stale. A new `mutateMessage(id:_:)` helper combines lookup and mutation atomically, replacing four bare subscript sites. `InferenceService` also had a continuation leak: `AsyncThrowingStream.Continuation` objects could survive cancellation if an exception was thrown before cleanup ran — a `defer` block now guarantees cleanup in all paths.

The API endpoint editor previously accepted arbitrary URL strings with no validation. It now rejects malformed URLs, non-HTTP schemes, and plain HTTP to non-localhost addresses. The inline stream consumption logic in `ChatViewModel+Generation` has been replaced with `GenerationStreamConsumer.handle()`, removing duplicate code and the associated TODO. `CachingTokenizer` is now reused across generation cycles instead of being recreated each time, with identity-based invalidation that correctly handles both reference-type and value-type tokenizers.

Three protocols — `InferenceBackend`, `ToolProvider`, and `ServerDiscoveryService` — now document their threading contracts for downstream conformers. New tests cover `NetworkDiscoveryService` JSON parsing for all four server types (26 tests), UI view logic for `ChatInputBar`, `MessageBubbleView`, `APIConfiguration`, and `ModelManagementSheet` (91 tests), and backend contract enforcement for the three backends that were missing it.

## [0.4.0](https://github.com/roryford/BaseChatKit/compare/v0.3.10...v0.4.0) (2026-04-08)

**Public API surface cleanup for open-source release** — BaseChatKit previously exposed roughly a dozen internal implementation types as `public`, leaking details that external consumers should never depend on. This release narrows the public API to only the types, protocols, and services that framework consumers are meant to use, making the library safe to publish as a public Swift package.

Twelve types that existed solely to support internal cross-module wiring — GGUF metadata parsing (`GGUFMetadata`, `GGUFMetadataReader`, `GGUFReaderError`), prompt template detection (`PromptTemplateDetector`), tokenizer internals (`HeuristicTokenizer`, `CachingTokenizer`), SSE stream parsing (`SSEStreamParser`), compression strategy implementations (`AnchoredCompressor`, `ExtractiveCompressor`, `CompressionOrchestrator`), thermal pressure handling (`MemoryPressureHandler`), and the `withExponentialBackoff` convenience function — are now `package` or `internal` access. Types needed across BaseChatKit's own modules use Swift 5.9's `package` access level; types used only within `BaseChatCore` use `internal`. Consumer-facing types like `ModelContainerFactory` and `SwiftDataPersistenceProvider` remain `public` since the Example app and downstream projects instantiate them directly.

The unused direct dependency on `swift-transformers` (a transitive dependency of `mlx-swift-lm`) was removed, eliminating a build warning. Snapshot test reference files in `BaseChatSnapshotTests` are now excluded from the target, silencing the "25 unhandled files" warning. Six public API members that lacked documentation (`NetworkDiscoveryService.startDiscovery()`, `.stopDiscovery()`, `.probe(host:port:)`, `HuggingFaceService.init(hubClient:)`, `InferenceError.isRetryable`, `BackgroundDownloadManager.hasActiveDownloads`) received `///` doc comments. A stale screenshot placeholder comment was removed from the README. GitHub branch protection was updated to require one PR approval for merges to `main` ([#217](https://github.com/roryford/BaseChatKit/issues/217)).

### ⚠ Breaking changes

Downstream projects that reference any of the twelve internalized types by name will need to update. The affected types were never part of the intended public API, but code that imported them directly will see compile errors. If your project uses `HeuristicTokenizer`, `AnchoredCompressor`, `CompressionOrchestrator`, or `SSEStreamParser`, migrate to the public protocol equivalents (`TokenizerProvider`, `ContextCompressor`) or add `@testable import BaseChatCore` in test targets. `ModelContainerFactory` and `SwiftDataPersistenceProvider` remain public and require no changes.

## [0.3.10](https://github.com/roryford/BaseChatKit/compare/v0.3.9...v0.3.10) (2026-04-08)

### Features

**Full SwiftUI preview coverage and generation queue hardening** — Downstream consumers previously had to build and run the demo app to see how many BaseChatUI views rendered, since 12 of 28 views lacked Xcode canvas previews. Every view in the `BaseChatUI` module now ships with `#Preview` blocks covering key states (empty, populated, streaming, error), giving framework consumers instant visual feedback when integrating components. Self-contained views (SessionRowView, AssistantMarkdownView, MessagePartsView, ModelLoadingIndicatorView, StreamingCursorView, TypingIndicatorView) also have matching `.dump`-based snapshot tests for CI-friendly structural regression detection on both iOS and macOS. Environment-dependent views (ChatExportSheet, MessageActionMenu, SamplerPresetPickerView, ServerDiscoveryView, RemoteServerConfigSheet, SessionListView) get previews with minimal stub environments. The generation queue introduced in v0.3.8 received three correctness fixes from code review: `stopGeneration()` now sets the stream phase to `.failed("Cancelled")` before finishing continuations (previously left observers in a non-terminal state), `discardRequests(notMatching:)` passes a specific `InferenceError` instead of a generic `CancellationError` so thrown errors match the failure reason, and `generate()` is documented as the non-queued entry point for short-lived operations like title generation and compression. Snapshot test count increased from 13 to 25 ([#214](https://github.com/roryford/BaseChatKit/issues/214)).

## [0.3.9](https://github.com/roryford/BaseChatKit/compare/v0.3.8...v0.3.9) (2026-04-08)

### Features

**Real-device E2E test infrastructure** — The test suite previously relied entirely on mocks for backend validation: `MockInferenceBackend` faked token streams, and MLX tests injected a `MockMLXModelContainer` rather than loading real weights. This meant regressions in actual model loading, GPU inference, and HTTP streaming could pass the test suite undetected. Two new E2E test suites now exercise real backends on developer hardware. `OllamaE2ETests` hits a live local Ollama server, auto-discovers a model in the 7–8B parameter range via `/api/tags`, and runs six inference tests including streaming, system prompts, multi-turn generation, cancellation, and output token limits. `MLXModelE2ETests` loads real MLX model weights from disk, performs GPU-accelerated inference via Metal, and runs seven tests covering the same surface plus model reload. Both suites gate on hardware availability via `HardwareRequirements` — Ollama tests skip when no server is reachable, MLX tests skip without Apple Silicon or a Metal device. MLX E2E tests live in a dedicated `BaseChatMLXIntegrationTests` target because MLX's Metal shader library (metallib) is only compiled by Xcode's build system, not by `swift test`. The MLX trait is now default-enabled so Xcode resolves dependencies correctly; CI passes `--disable-default-traits` to avoid the metallib crash on headless runners. Unit tests for the new `HardwareRequirements` helpers (MLX directory validation, Ollama model selection) run in CI without hardware ([#213](https://github.com/roryford/BaseChatKit/issues/213)).

### Bug Fixes

**macOS model selection sheet rendered blank** — `ModelSelectTab` inside `ModelManagementSheet` displayed an empty view on macOS because the SwiftUI `Form` two-column layout pushed content outside the visible area. Fixed by applying the correct frame constraints for the macOS sheet presentation ([e483df9](https://github.com/roryford/BaseChatKit/commit/e483df9ec443163c5d0c48b8a62e166f712c009c)).

## [0.3.8](https://github.com/roryford/BaseChatKit/compare/v0.3.7...v0.3.8) (2026-04-08)

### Features

**Generation queue for multi-consumer inference** — `InferenceService` previously coordinated generation through a single `isGenerating` boolean, forcing secondary consumers (entity extraction, summarization, classification) to poll with `Task.sleep` before starting. It now manages a proper FIFO queue: `enqueue()` returns a `(GenerationRequestToken, GenerationStream)` immediately and the request executes when it reaches the front. Three priority levels (`.userInitiated`, `.normal`, `.background`) with FIFO within each level; max queue depth of 8. Background-priority requests are automatically dropped under serious or critical thermal pressure. `ChatViewModel` uses `.userInitiated` priority and suppresses the idle flash between queued generations via `hasQueuedRequests`. Session switches cancel stale requests via `discardRequests(notMatching:)`, and `stopGeneration()` drains the entire queue. Backends are untouched — all local backends (MLX, llama.cpp, Foundation) are single-generation by nature, so sequential queuing is the correct concurrency pattern. Closes [#204](https://github.com/roryford/BaseChatKit/issues/204) ([#209](https://github.com/roryford/BaseChatKit/issues/209)).

## [0.3.7](https://github.com/roryford/BaseChatKit/compare/v0.3.6...v0.3.7) (2026-04-07)


### Features

**Testable MLX generation and HuggingFace linker fix** — `MLXBackend.generate()` was completely untested: `ModelContainer` from `mlx-swift-lm` is a concrete class with no protocol, so there was no way to inject a mock without loading real weights on Apple Silicon. A new internal `MLXModelContainerProtocol` abstracts the two methods `MLXBackend` calls — `generate(messages:parameters:)` — and the real `ModelContainer` conforms via a one-line extension. `MLXBackend` now holds `any MLXModelContainerProtocol` and exposes a package-internal `_inject(_:)` method so tests can swap in a mock without touching production call sites. `MockMLXModelContainer` in `BaseChatTestSupport` yields injected token arrays, tracks call counts, and supports mid-stream cancellation with a tracked producer task wired to `continuation.onTermination` — making the cancellation test deterministic rather than racy. Five new tests run in CI without hardware: token streaming, output token limits, cancellation, error propagation from `generate()`, and a compile-time surface check for the `SendableLMInput` wrapper. The release also fixes a linker error (#205) that broke all test targets in downstream projects: `mlx-swift-lm 2.30.6` resolved a `swift-transformers` version whose transitive `HuggingFace.HubCache` symbols conflicted with the direct `swift-huggingface 0.9.0` pin. Updated to `mlx-swift 0.31.3`, `mlx-swift-lm 2.31.3`, and added `swift-transformers 1.2.0` as an explicit dependency ([#206](https://github.com/roryford/BaseChatKit/issues/206), closes [#205](https://github.com/roryford/BaseChatKit/issues/205)).

## [0.3.6](https://github.com/roryford/BaseChatKit/compare/v0.3.5...v0.3.6) (2026-04-07)

### Bug Fixes

**Swift 6.3 concurrency and SwiftData store collision fixes** — Swift 6.3 (released April 2026) tightened actor-isolation and `Sendable` enforcement in ways that produced compiler warnings across the framework, and CI (running Swift 6.0) rejected one pattern outright. `GenerationStream` is now a true `@MainActor`-isolated type — phase updates were already required on the main thread, so this matches the documented contract rather than changing it. All `setPhase` callsites in the cloud and local backends hop to `@MainActor` via `await MainActor.run { }`. Cloud backend subclasses (Claude, Kobold, Ollama, OpenAI) and `BackgroundDownloadManager` explicitly restate their `@unchecked Sendable` conformance, as Swift 6.3 requires subclasses to restate inherited conformances. `DeviceCapabilityService` replaces `UIDevice.current.model` — now `@MainActor`-isolated in Swift 6.3 — with `sysctl hw.machine` / `hw.model`, which is callable from any context. `StalledCallback.handler` is typed `(@Sendable () -> Void)?` so the Swift 6.0 region-based isolation checker can verify the weak capture of `GenerationStream` is safe. The demo app's SwiftData store is named `"BaseChatDemo"` to prevent it from writing to the generic `default.store` path shared by other apps, which caused an "unknown model version" crash on clean installs ([#203](https://github.com/roryford/BaseChatKit/issues/203)).

**SwiftData schema type alignment** — `memoryBytes` in `ModelBenchmarkCache` and its associated `ModelBenchmarkResult` struct used `UInt64` in one place and `Int64` in another. SwiftData hashes both to the same SQLite INTEGER column type, so no migration was needed, but the mismatch required explicit casting at every use site. Both are now consistently `Int64`.

## [0.3.5](https://github.com/roryford/BaseChatKit/compare/v0.3.4...v0.3.5) (2026-04-06)

### Features

**App-defined macros without forking the framework** — The macro system was a closed list: adding a domain-specific token like `{{chapterNumber}}` or `{{diceRoll}}` meant editing BaseChatKit itself, which made updating the dependency painful. Apps can now implement `MacroProvider` and register it at startup; the framework calls each provider in registration order and uses the first non-nil result, falling back to built-ins for standard tokens. The built-in set adds `{{modelName}}` and `{{messageCount}}`, both resolved automatically from the active session. The `{{roll:XdY}}` macro has moved out of core — it was specific to one consumer app and had no place in a generic framework; apps that need dice rolls register it themselves ([#103](https://github.com/roryford/BaseChatKit/issues/103)).

**Capability tiers in the model picker** — Choosing a model from the list required users to mentally translate file sizes and quantisation strings into a sense of what the model could do. `ModelInfo` now carries a capability tier — minimal, fast, balanced, capable, or frontier — estimated from file size and shown as a badge in the selection row. For apps that want measured data rather than estimates, `ModelBenchmarkRunner` provides a protocol and a default implementation that fires a short fixed prompt and records tokens per second; results are cached in SwiftData (schema v3) and survive app restart. Cloud model tiers are assigned statically at registration time and never require a benchmark run ([#104](https://github.com/roryford/BaseChatKit/issues/104)).

## [0.3.4](https://github.com/roryford/BaseChatKit/compare/v0.3.3...v0.3.4) (2026-04-06)

### Performance Improvements

**Faster generation on long conversations** — Each inference request previously re-tokenized every message in the history multiple times: the compression threshold check, the compressor, and prompt assembly all independently counted tokens for the same content. In a 50-message conversation this meant the same strings were processed three to five times before the first token was generated, with cost growing linearly with context length. The generation pipeline now shares a per-cycle token count cache so each unique string is tokenized exactly once regardless of how many subsystems need the count, and prompt assembly recovers its token totals as a byproduct of message trimming rather than making a separate pass. Time-to-first-token improves proportionally with conversation length. No API changes required ([#185](https://github.com/roryford/BaseChatKit/issues/185)).

## [0.3.3](https://github.com/roryford/BaseChatKit/compare/v0.3.2...v0.3.3) (2026-04-06)

### Features

**Backend reliability and streaming resilience overhaul** — Cloud backends could silently block for up to 20 minutes when servers stalled, models were evicted, or retries compounded against URLSession's 300-second timeout. This release introduces four structural refactors and addresses seven reliability issues ([#181](https://github.com/roryford/BaseChatKit/issues/181), [#182](https://github.com/roryford/BaseChatKit/issues/182), [#183](https://github.com/roryford/BaseChatKit/issues/183), [#184](https://github.com/roryford/BaseChatKit/issues/184), [#187](https://github.com/roryford/BaseChatKit/issues/187), [#188](https://github.com/roryford/BaseChatKit/issues/188), [#189](https://github.com/roryford/BaseChatKit/issues/189)).

`GenerationStream` separates content events from lifecycle state — consumers iterate `stream.events` for tokens while the UI observes `stream.phase` for connecting, streaming, stalled, retrying, and failed states without adding cases to `GenerationEvent`. The `.done` event case has been removed; stream termination is authoritative. `InferenceBackend.generate()` now returns `GenerationStream` instead of `AsyncThrowingStream<GenerationEvent, Error>`.

Retry is no longer opaque: `RetryStrategy` is a protocol with an injectable `ExponentialBackoffStrategy` default, and exhausted retries throw `RetryExhaustedError` wrapping the last error so callers can distinguish "failed after retries" from a single failure. Retry scope is narrowed to the HTTP connection phase only — mid-stream failures propagate immediately, preserving already-yielded tokens. The stream surfaces `.retrying(attempt:of:)` phase during retry attempts.

`URLSessionProvider` centralises session creation, eliminating four duplicated static session blocks and fixing ClaudeBackend's missing `timeoutIntervalForResource`. A `CircuitBreaker` actor with closed/open/halfOpen states is available for fast-failing repeatedly failing backends.

Idle stall detection fires `.stalled` at the midpoint of a configurable timeout and throws `CloudBackendError.timeout` at the full duration. `SSEStreamParser` no longer swallows I/O errors during cancellation, and now logs invalid UTF-8 byte sequences. `CloudBackendError.streamInterrupted` is split into `.streamInterrupted` (retryable) and `.backendDeallocated` (not retryable). OllamaBackend is migrated to an `SSECloudBackend` subclass and passes `keep_alive` (default 30 minutes) to reduce cold-start latency. ([#193](https://github.com/roryford/BaseChatKit/issues/193))

## [0.3.2](https://github.com/roryford/BaseChatKit/compare/v0.3.1...v0.3.2) (2026-04-06)


### Bug Fixes

**Compression system correctness** — Six bugs fixed in the context compression layer. `shouldCompress` now includes system prompt tokens in its utilization calculation, preventing late-triggering compression when the system prompt is large. The summary parser is now field-name-agnostic, so custom templates with underscored fields (e.g., `PLOT_THREADS`) are parsed correctly instead of silently dropping fields. `ExtractiveCompressor` caps candidate selection to the remaining budget after pinned messages, preventing over-budget output. Empty summaries from the LLM now fall back to extractive compression instead of injecting a useless `[Summary unavailable]` system message. A `Task.checkCancellation()` check before the inference call allows cancelled compressions to bail out early. ([#179](https://github.com/roryford/BaseChatKit/issues/179))

**CI crash from assertionFailure in debug builds** — `BaseChatSchemaV2`'s MessagePart encode/decode helpers used `assertionFailure` for recoverable conditions (malformed JSON, non-UTF-8 strings). These trap in debug builds including `swift test`, crashing the process with SIGTRAP (signal 5) even when all test assertions passed. Replaced with `Log.persistence` warnings so the existing fallback logic executes cleanly. Also fixed `ToolCall.parsedArguments()` where a `guard let` with `try` swallowed `JSONSerialization` errors as `CocoaError` instead of wrapping them in `ToolCallingError.invalidArguments`. ([#186](https://github.com/roryford/BaseChatKit/issues/186))

## [0.3.1](https://github.com/roryford/BaseChatKit/compare/v0.3.0...v0.3.1) (2026-04-06)

### Bug Fixes

**Test mocks aligned with GenerationEvent stream** — The v0.3.0 streaming API change (`AsyncThrowingStream<GenerationEvent, Error>`) left `MockInferenceBackend` and other test doubles still returning the old `String` stream signature, causing compilation failures in downstream test targets. All mocks in `BaseChatTestSupport` now return `GenerationEvent` streams. ([eff073a](https://github.com/roryford/BaseChatKit/commit/eff073ac763625982beda2819da54199532c6621))

## [0.3.0](https://github.com/roryford/BaseChatKit/compare/v0.2.22...v0.3.0) (2026-04-06)


### ⚠ BREAKING CHANGES

This release makes two foundational API changes that would be prohibitively expensive to ship after 1.0. Both are required to support multimodal messages, tool calling, and structured generation.

**Streaming API** — `InferenceBackend.generate()` now returns `AsyncThrowingStream<GenerationEvent, Error>` instead of `AsyncThrowingStream<String, Error>`. The new `GenerationEvent` enum carries `.token(String)`, `.toolCall(name:arguments:)`, `.usage(prompt:completion:)`, and `.done` cases. All backend conformers and stream consumers must update their `for try await` loops to switch on the event type. ([#167](https://github.com/roryford/BaseChatKit/issues/167), closes [#130](https://github.com/roryford/BaseChatKit/issues/130))

**Message content model** — `ChatMessage.content` is now a computed property that concatenates text parts from a new `contentParts: [MessagePart]` array. Writing to `content` still works (it replaces all parts with a single `.text`), so most consumer code is unaffected. However, direct SwiftData queries on the `content` column must use `contentPartsJSON` instead. A `BaseChatSchemaV2` migration automatically wraps existing content strings into `[.text(content)]`. ([#168](https://github.com/roryford/BaseChatKit/issues/168), closes [#131](https://github.com/roryford/BaseChatKit/issues/131))

### Features

**Tool calling and structured generation** — New `ToolProvider` protocol, `ToolCallingBackend` opt-in protocol, and `StructuredGenerationBackend` protocol with `generateStructured<T: Decodable>()`. `ClaudeBackend` handles Anthropic `tool_use` content blocks, `OpenAIBackend` handles OpenAI function-calling format. A `GrammarConstraint` type supports GBNF strings and JSON schema for constrained decoding. Tool call rounds are capped at 10 to prevent runaway loops. `InferenceService` and `ChatViewModel` wire tool providers through to conforming backends. ([#170](https://github.com/roryford/BaseChatKit/issues/170), closes [#55](https://github.com/roryford/BaseChatKit/issues/55))

## [0.2.22](https://github.com/roryford/BaseChatKit/compare/v0.2.21...v0.2.22) (2026-04-06)


### Bug Fixes

`BaseChatConfiguration.shared` and `CuratedModel.all` used `nonisolated(unsafe) static var` with a manual `NSLock`, which made it structurally possible to access the protected value without holding the lock. Both singletons now use `OSAllocatedUnfairLock`, which encapsulates the value inside the lock itself — unsynchronized access is a compile error rather than a discipline problem. ([#162](https://github.com/roryford/BaseChatKit/issues/162), closes [#156](https://github.com/roryford/BaseChatKit/issues/156))

MLX model downloads could fail silently when Hugging Face returned an HTML error page instead of a model snapshot, and the search filter allowed non-MLX model variants to appear in results. Downloads now validate response content types and snapshot structure before proceeding, and the search filter restricts results to MLX-compatible variants. ([#159](https://github.com/roryford/BaseChatKit/issues/159))

An audit of all 21 `@unchecked Sendable` conformances removed 8 that were unnecessary — redundant subclass declarations inherited from `SSECloudBackend`, `@MainActor`-isolated types that already satisfy `Sendable`, and test types with only immutable `Sendable` stored properties. The remaining 13 are legitimately needed for lock-guarded mutable state, C interop wrappers, and `@Observable` internals. ([#164](https://github.com/roryford/BaseChatKit/issues/164), closes [#150](https://github.com/roryford/BaseChatKit/issues/150))

## [0.2.21](https://github.com/roryford/BaseChatKit/compare/v0.2.20...v0.2.21) (2026-04-05)


### Bug Fixes

The `PinnedSessionDelegate` shipped with empty certificate pin sets for `api.anthropic.com` and `api.openai.com`. Although the delegate implemented fail-closed behavior, the missing pins meant TLS connections to these production hosts were always rejected — or, if pinning was bypassed, offered no MITM protection.

This release populates SPKI SHA-256 pins for the Google Trust Services WE1 intermediate CA and GTS Root R4 shared by both hosts. Intermediate/root pinning was chosen over leaf pinning because leaf certificates rotate every ~90 days, while intermediate CAs are stable across renewals. The chain validation logic was also updated to check all certificates in the TLS chain (leaf, intermediates, root) instead of only the leaf, which is required for intermediate-level pinning to work.

Pins are loaded automatically during `DefaultBackends.register(with:)` and respect any custom pins the host app has already configured — they will not be overwritten. Pin mismatch errors now log all seen SPKI hashes from the chain to aid rotation debugging. ([#157](https://github.com/roryford/BaseChatKit/issues/157))

## [0.2.20](https://github.com/roryford/BaseChatKit/compare/v0.2.19...v0.2.20) (2026-04-05)


### Features

* support MLX search and snapshot downloads ([#148](https://github.com/roryford/BaseChatKit/issues/148)) ([a9ae0c1](https://github.com/roryford/BaseChatKit/commit/a9ae0c124f9cbac0b687ff2252902d03976a08ce))

## [0.2.19](https://github.com/roryford/BaseChatKit/compare/v0.2.18...v0.2.19) (2026-04-05)


### Features

* add structured ChatError with recovery actions ([0c6c37e](https://github.com/roryford/BaseChatKit/commit/0c6c37ed8247fca779fc0a32cc9343816c654d30))


### Bug Fixes

* add Equatable to ChatError enums, preserve error context in surfaceError ([2752c70](https://github.com/roryford/BaseChatKit/commit/2752c70ea0fbe45e72c1d3c0ca4a4c99f8b1cd32))

## [0.2.18](https://github.com/roryford/BaseChatKit/compare/v0.2.17...v0.2.18) (2026-04-05)


### Bug Fixes

* reset isGenerating on synchronous backend throw, extend retry to all retryable errors ([6a9190f](https://github.com/roryford/BaseChatKit/commit/6a9190fd1a9c41ce46836440fa08ac9022868161))
* reset isGenerating on synchronous backend throw, extend retry to all retryable errors ([329294f](https://github.com/roryford/BaseChatKit/commit/329294fe07759eac3cb7884ea3117ce946cb1f01))
* update retry log message to reflect all retryable error types ([3351b6c](https://github.com/roryford/BaseChatKit/commit/3351b6ca266fcfcfc922c47a3f8ffe451593bee3))

## [0.2.17](https://github.com/roryford/BaseChatKit/compare/v0.2.16...v0.2.17) (2026-04-05)


### Features

* add backend capability API and host-facing settings surface ([#138](https://github.com/roryford/BaseChatKit/issues/138)) ([0b9affb](https://github.com/roryford/BaseChatKit/commit/0b9affb2957c10a007b56ac91abde731e86a4db5))

## [0.2.16](https://github.com/roryford/BaseChatKit/compare/v0.2.15...v0.2.16) (2026-04-05)


### Features

* add SwiftData VersionedSchema and MigrationPlan infrastructure ([#120](https://github.com/roryford/BaseChatKit/issues/120)) ([a065044](https://github.com/roryford/BaseChatKit/commit/a06504426b15b6a4384205cc879f4a937d25886f))
* extend BackendCapabilities with contextWindowSize and capability fields ([#125](https://github.com/roryford/BaseChatKit/issues/125)) ([5fe2038](https://github.com/roryford/BaseChatKit/commit/5fe2038357f698e496cc917ab88a70999ee859e4))

## [0.2.15](https://github.com/roryford/BaseChatKit/compare/v0.2.14...v0.2.15) (2026-04-05)


### Features

* add OpenAICompatibleBackend, OllamaBackend, and BonjourDiscoveryService for remote inference ([77360d7](https://github.com/roryford/BaseChatKit/commit/77360d7c5c1c9a95ca0280429ebc3f7b60412174))
* add PostGenerationTask hook to ChatViewModel ([5ad1837](https://github.com/roryford/BaseChatKit/commit/5ad183740622ce4c3673a64a45ecbe64e336bbf6))
* add PostGenerationTask hook to ChatViewModel ([ba1e38e](https://github.com/roryford/BaseChatKit/commit/ba1e38edf0a9e92b8351fbac5097f78ba9b3cb7f)), closes [#111](https://github.com/roryford/BaseChatKit/issues/111)
* add PromptSlotPosition enum replacing string-based slot positions ([1913a16](https://github.com/roryford/BaseChatKit/commit/1913a16d5b5e6216e789ec9ca6852804cd4f10dc))
* add PromptSlotPosition enum replacing string-based slot positions ([65b4bd4](https://github.com/roryford/BaseChatKit/commit/65b4bd4d12626782ab7f764c5fbd330be360a163))
* add remote inference backends (OpenAI-compatible, Ollama, KoboldCpp) ([85733a2](https://github.com/roryford/BaseChatKit/commit/85733a21a364b0c875ea210412dc8f8f39aea913))


### Bug Fixes

* address remaining PR 122 review issues ([989058e](https://github.com/roryford/BaseChatKit/commit/989058e4780f750a9601ec648547cd5104dfe98c))
* avoid sending self across actor boundary in post-generation error handler ([067c219](https://github.com/roryford/BaseChatKit/commit/067c2191c0c9b59545a243efb8a4263681768345))
* correct BonjourDiscovery re-probe, OllamaBackend UTF-8, save error handling, test cleanup ([bfa5bf7](https://github.com/roryford/BaseChatKit/commit/bfa5bf7db7941dac60daa6fa79b942961f834cd4))
* correct PromptSlotPosition sortIndex semantics and assembler sort stability ([ea7d0c9](https://github.com/roryford/BaseChatKit/commit/ea7d0c9b5c18a5500dd2a542fdb46a8bb71773f3))
* move backend loadModel off @MainActor to prevent UI blocking ([b553d83](https://github.com/roryford/BaseChatKit/commit/b553d8391f43bbf8d3388ea6fb1491aaea6d8c81))
* move backend loadModel off @MainActor to prevent UI blocking ([b553d83](https://github.com/roryford/BaseChatKit/commit/b553d8391f43bbf8d3388ea6fb1491aaea6d8c81))
* move backend loadModel off @MainActor to prevent UI blocking ([b0ae9ab](https://github.com/roryford/BaseChatKit/commit/b0ae9ab0677d767191d66914afa027fa390eab33)), closes [#100](https://github.com/roryford/BaseChatKit/issues/100)
* remove stale isRemote argument from BackendCapabilities call sites ([417d0e2](https://github.com/roryford/BaseChatKit/commit/417d0e28846d680af8082d332a6df65476a9e61e))
* use plain Task for post-generation hook, clear backgroundTaskError on new generation ([358630e](https://github.com/roryford/BaseChatKit/commit/358630e94838e10b2d1a26a0b7d560c09242610e))

## [0.2.14](https://github.com/roryford/BaseChatKit/compare/v0.2.13...v0.2.14) (2026-04-04)


### Bug Fixes

* harden model handoff lifecycle coordination ([fecf6f3](https://github.com/roryford/BaseChatKit/commit/fecf6f35610f5083babd6ce07d975e7e26b1a5a6))
* use UUID hostnames to eliminate MockURLProtocol cross-suite race ([#99](https://github.com/roryford/BaseChatKit/issues/99)) ([ed98813](https://github.com/roryford/BaseChatKit/commit/ed98813a0c1481d20d3f28a7ca8d8540510d358f))

## [0.2.13](https://github.com/roryford/BaseChatKit/compare/v0.2.12...v0.2.13) (2026-04-04)


### Bug Fixes

* avoid session restore selection clobber ([67a4194](https://github.com/roryford/BaseChatKit/commit/67a419467d8a2c881e9de5e28afeda36f35f678f))
* persist cloud endpoint selection and loading ([ef1d0d7](https://github.com/roryford/BaseChatKit/commit/ef1d0d7deaebbd01e482c581ffea40e940971439))
* persist cloud endpoint selection and loading ([c85097f](https://github.com/roryford/BaseChatKit/commit/c85097fdfa1a95c421449a32958ad024e37e6e83))

## [0.2.12](https://github.com/roryford/BaseChatKit/compare/v0.2.11...v0.2.12) (2026-04-04)


### Features

* add curated model presets to management sheet ([3573717](https://github.com/roryford/BaseChatKit/commit/3573717afbfaf0467bb424761c062461308cbc66))

## [0.2.11](https://github.com/roryford/BaseChatKit/compare/v0.2.10...v0.2.11) (2026-04-04)


### Bug Fixes

* correct macOS sheet layouts and add model selection E2E tests ([#90](https://github.com/roryford/BaseChatKit/issues/90)) ([19c127d](https://github.com/roryford/BaseChatKit/commit/19c127d6cdf0b2dd179bb35ae9cb4819438974ac))

## [0.2.10](https://github.com/roryford/BaseChatKit/compare/v0.2.9...v0.2.10) (2026-04-04)


### Features

* add pre-load memory gate to prevent OOM crashes ([#88](https://github.com/roryford/BaseChatKit/issues/88)) ([1cf37eb](https://github.com/roryford/BaseChatKit/commit/1cf37eb345787a5bbe265b8b47d27c4a82b7385e))

## [0.2.9](https://github.com/roryford/BaseChatKit/compare/v0.2.8...v0.2.9) (2026-04-03)


### Features

* extend BackendCapabilities and add activity indicators ([#85](https://github.com/roryford/BaseChatKit/issues/85)) ([ac0588d](https://github.com/roryford/BaseChatKit/commit/ac0588de88d52e55d231cd9e82179e28e4be5486))

## [0.2.8](https://github.com/roryford/BaseChatKit/compare/v0.2.7...v0.2.8) (2026-04-03)


### Bug Fixes

* address Copilot review comment on PR [#80](https://github.com/roryford/BaseChatKit/issues/80) ([906309d](https://github.com/roryford/BaseChatKit/commit/906309de7cc64dd4402be93ce18f148315e2b948))
* address Copilot review comments on PR [#75](https://github.com/roryford/BaseChatKit/issues/75) ([13dd499](https://github.com/roryford/BaseChatKit/commit/13dd499e65a42852dd2197260ce71ea68215fb84))
* address Copilot review comments on PR [#78](https://github.com/roryford/BaseChatKit/issues/78) ([15e1ecb](https://github.com/roryford/BaseChatKit/commit/15e1ecbecd18e15b59eb39a40f38b91fcedc0f20))
* address Copilot review comments on PR [#81](https://github.com/roryford/BaseChatKit/issues/81) ([1b28f2f](https://github.com/roryford/BaseChatKit/commit/1b28f2fa4f628a9493a6eaa62f1f8e5ebc872889))
* address Copilot review comments on PR [#82](https://github.com/roryford/BaseChatKit/issues/82) ([53f40ec](https://github.com/roryford/BaseChatKit/commit/53f40ec2473545e769ceb9cd6df2e1eb28bd3f89))
* address review findings in PR [#76](https://github.com/roryford/BaseChatKit/issues/76) ([17ffe65](https://github.com/roryford/BaseChatKit/commit/17ffe659ca7f9b843ef8ab100d0c2156da521141))
* address review findings in PR [#77](https://github.com/roryford/BaseChatKit/issues/77) ([3e12c10](https://github.com/roryford/BaseChatKit/commit/3e12c1053432376be8fc259d4afba4522283e8e3))
* address review findings in PR [#78](https://github.com/roryford/BaseChatKit/issues/78) ([04614e8](https://github.com/roryford/BaseChatKit/commit/04614e816eb686e0f9c81ca3000833ad50fc19bc))
* address review findings in PR [#80](https://github.com/roryford/BaseChatKit/issues/80) ([a8ff45e](https://github.com/roryford/BaseChatKit/commit/a8ff45eb64b677ed758f08b73c0339c764f7ac72))
* address review findings in PR [#81](https://github.com/roryford/BaseChatKit/issues/81) ([4dd66cd](https://github.com/roryford/BaseChatKit/commit/4dd66cd7b830e79f8f50530a63df247b2f114bce))
* address review findings in PR [#82](https://github.com/roryford/BaseChatKit/issues/82) ([7f7de44](https://github.com/roryford/BaseChatKit/commit/7f7de449015af9e5efd486e27b9490134ab59e91))
* convert E2E lifecycle tests to Swift Testing and fix review issues ([faf245c](https://github.com/roryford/BaseChatKit/commit/faf245c5e00054fb2971b75e1d5f5f563dcb2973))

## [0.2.7](https://github.com/roryford/BaseChatKit/compare/v0.2.6...v0.2.7) (2026-04-03)


### Features

* add max output token limit to generation pipeline ([#63](https://github.com/roryford/BaseChatKit/issues/63)) ([e4569c6](https://github.com/roryford/BaseChatKit/commit/e4569c6cabda6b33791c7dab7d0cdeaf55e2d00c))
* document and test stopGeneration() protocol contract ([#62](https://github.com/roryford/BaseChatKit/issues/62)) ([309e39c](https://github.com/roryford/BaseChatKit/commit/309e39c657fcb7efb4bf9dc70b7eb6574d9cdf6c))


### Bug Fixes

* reset FoundationBackend session after stop/cancel ([#61](https://github.com/roryford/BaseChatKit/issues/61)) ([055f232](https://github.com/roryford/BaseChatKit/commit/055f2327cae66d7c06d134d667984dc20cfbda82)), closes [#57](https://github.com/roryford/BaseChatKit/issues/57)
* stable reverse-scroll when prepending older messages ([#64](https://github.com/roryford/BaseChatKit/issues/64)) ([e858b6f](https://github.com/roryford/BaseChatKit/commit/e858b6fec50560d9c5528614d8d8e128c898292a))

## [0.2.6](https://github.com/roryford/BaseChatKit/compare/v0.2.5...v0.2.6) (2026-04-03)


### Features

* add focused example app scaffold with MinimalExample ([5db47a3](https://github.com/roryford/BaseChatKit/commit/5db47a3285d872c2bd6378673a02984743baf01a))
* add KoboldCpp backend and remote server discovery infrastructure ([d22cf42](https://github.com/roryford/BaseChatKit/commit/d22cf425805fab205edeba0c2a92271932a777ac))


### Bug Fixes

* replace deprecated configure(modelContext:) and remove phantom NarrationExample target ([0556fde](https://github.com/roryford/BaseChatKit/commit/0556fde31f648a471cda0bdd78219e02ebbe0f17))
* use GenerationConfig topK/typicalP and fix discovery stream race ([45cd524](https://github.com/roryford/BaseChatKit/commit/45cd524450906242178f29db647ce8130d8078cc))

## [0.2.5](https://github.com/roryford/BaseChatKit/compare/v0.2.4...v0.2.5) (2026-04-03)


### Performance Improvements

* throttle streamed token mutations in ChatViewModel ([#49](https://github.com/roryford/BaseChatKit/issues/49)) ([d57db57](https://github.com/roryford/BaseChatKit/commit/d57db57cd1557b5393398c5422a7321760c389fa))

## [0.2.4](https://github.com/roryford/BaseChatKit/compare/v0.2.3...v0.2.4) (2026-04-03)


### Features

* add RepetitionDetector and MacroExpander from an internal consumer app ([#50](https://github.com/roryford/BaseChatKit/issues/50)) ([311f9ae](https://github.com/roryford/BaseChatKit/commit/311f9ae974fdd48944a5d695e3770ad570747c70))
* migrate to Swift 6 language mode ([7704a77](https://github.com/roryford/BaseChatKit/commit/7704a7743e296a7f2e25eff64a53acc0da2e69cc))
* migrate to Swift 6 language mode ([8ce6dcc](https://github.com/roryford/BaseChatKit/commit/8ce6dccb9fcd2eb7bf804967b38ca7c4f0de41b1))


### Bug Fixes

* add local model import to model management ([69ef854](https://github.com/roryford/BaseChatKit/commit/69ef8545a570f73b021be94ace54cd706bea691a))
* add local model import to model management ([c32e497](https://github.com/roryford/BaseChatKit/commit/c32e4977c4261737894bb648305181f6a079e704))
* address Swift 6 test isolation and sendability ([2d3b1c3](https://github.com/roryford/BaseChatKit/commit/2d3b1c3eebb77005af54f36c9eeee277b3651db9))
* convert @MainActor test setUp/tearDown to async throws ([33d435c](https://github.com/roryford/BaseChatKit/commit/33d435c0ca45c1151ed5662028860b03dbec033d))
* replace [weak self] with [self] in TestSupport mock AsyncThrowingStream closures ([f332daf](https://github.com/roryford/BaseChatKit/commit/f332dafdf9b7ba194debf29d358dc1b02cbf33f1))
* resolve Swift 6 compile errors in MemoryPressureHandler and SettingsService ([e99e1db](https://github.com/roryford/BaseChatKit/commit/e99e1db11b9524a3d490d7ac336fa0cc2a1e01f6))
* revert SettingsService to [@unchecked](https://github.com/unchecked) Sendable ([0ce6684](https://github.com/roryford/BaseChatKit/commit/0ce6684b711992ebd887e2cf344daad01f7a7fdd))
* synchronize backend and global mutable state ([95bfbce](https://github.com/roryford/BaseChatKit/commit/95bfbce8de73ace6a3163bd8b96a140846425d72))

## [0.2.3](https://github.com/roryford/BaseChatKit/compare/v0.2.2...v0.2.3) (2026-04-01)


### Features

* harden security posture and expand CI smoke coverage ([#45](https://github.com/roryford/BaseChatKit/issues/45)) ([3101cb7](https://github.com/roryford/BaseChatKit/commit/3101cb739bc98f725a9b4a42da9a48a5c35af37b))


### Bug Fixes

* wire live model management services ([#41](https://github.com/roryford/BaseChatKit/issues/41)) ([063fe80](https://github.com/roryford/BaseChatKit/commit/063fe8004728006f5729a62572954ac4ddd428f2))

## [0.2.2](https://github.com/roryford/BaseChatKit/compare/v0.2.1...v0.2.2) (2026-03-31)


### Bug Fixes

* thread-safe pin store, CI-testable routing, Foundation probe audit, MLX docs ([#36](https://github.com/roryford/BaseChatKit/issues/36)) ([a83e42b](https://github.com/roryford/BaseChatKit/commit/a83e42bde14a85f579e922a12d3f1af92f0e000d))
* wire retry backoff into cloud backends and preserve partial Claude usage ([#34](https://github.com/roryford/BaseChatKit/issues/34)) ([679ad36](https://github.com/roryford/BaseChatKit/commit/679ad36579dba07ef8738d593c17090e408880e1))

## [0.2.1](https://github.com/roryford/BaseChatKit/compare/v0.2.0...v0.2.1) (2026-03-31)


### Features

* render markdown in assistant bubbles ([#31](https://github.com/roryford/BaseChatKit/issues/31)) ([dadc89e](https://github.com/roryford/BaseChatKit/commit/dadc89ed9d36b476c584c8296f657768a445e520))


### Bug Fixes

* move search field below tab picker and fix macOS tab switching in ModelManagementSheet ([#40](https://github.com/roryford/BaseChatKit/issues/40)) ([e54ad9f](https://github.com/roryford/BaseChatKit/commit/e54ad9f363578c16366dc1f2dbea8712de0ba367))

## [0.2.0](https://github.com/roryford/BaseChatKit/compare/v0.1.1...v0.2.0) (2026-03-30)


### ⚠ BREAKING CHANGES

* SessionManagerViewModel and ChatViewModel now require a ChatPersistenceProvider instead of accessing ModelContext directly. View models operate on ChatSessionRecord/ChatMessageRecord value types instead of SwiftData @Model objects. The deprecated configure(modelContext:) convenience is provided for migration.

### Features

* add ChatPersistenceProvider protocol to decouple from SwiftData ([1f26292](https://github.com/roryford/BaseChatKit/commit/1f2629281b414b8aa7d433e540d4597d0af58395)), closes [#4](https://github.com/roryford/BaseChatKit/issues/4)
* add Swift 6.1 package traits for selective backend compilation ([#22](https://github.com/roryford/BaseChatKit/issues/22)) ([be03548](https://github.com/roryford/BaseChatKit/commit/be0354874ad8ce87702dfc2c41b59fcb75f03f9c))


### Bug Fixes

* clarify hasFoundationModels checks OS version, not Apple Intelligence ([0f3314d](https://github.com/roryford/BaseChatKit/commit/0f3314def1a284595c2e45ed0ce726552d4da217))
* harden persistence error handling and state consistency ([a40bb5a](https://github.com/roryford/BaseChatKit/commit/a40bb5a9d5e5507b5bbe426e637673a7f309e50b))
* revert LlamaBackend lifecycle to NSLock — actor isolation unsafe in init/deinit ([ae141ae](https://github.com/roryford/BaseChatKit/commit/ae141ae348999e6ea6a5a4801bf734c3802c2e94))
* tighten SSE perf test expectation timeout from 10s to 5s ([fe4d57f](https://github.com/roryford/BaseChatKit/commit/fe4d57f8e095bc11f65e74ded1367f659ebdb71a))
* update perf test to use ChatMessageRecord after persistence refactor ([f16a8ab](https://github.com/roryford/BaseChatKit/commit/f16a8ab72796fa9ae7d2a37866eca0393ba4c00f))
* use updateMessage for edits and fix value-type test assertions ([a59dc4e](https://github.com/roryford/BaseChatKit/commit/a59dc4eafb7162d3811e8d61d77e9cd7bdbb90e9))

## 0.1.1 (2026-03-30)


### Bug Fixes

* use full=true instead of expand parameter for HuggingFace API ([cc7a131](https://github.com/roryford/BaseChatKit/commit/cc7a131dfd9c38baab1c2d3be80bc7936e629fd2))
