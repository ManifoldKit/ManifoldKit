# ManifoldKit — guide for AI coding assistants

This is the **canonical instruction file** for ManifoldKit, readable by any AI
coding assistant (Claude Code, Cursor, Copilot, codex, …). It serves two
audiences:

- **Part 1 — Using ManifoldKit** (consumers): the recipe-shaped surface for an
  assistant helping a human use ManifoldKit in their app — imports, bootstrap,
  the public API.
- **Part 2 — Contributing to ManifoldKit** (internal conventions): targets,
  dependency rules, testing, and the release/PR workflow for an assistant
  changing ManifoldKit itself.

`CLAUDE.md` is a stub that imports this file (`@AGENTS.md`) and adds only
Claude-harness-specific notes — never duplicate content between the two.

# Part 1 — Using ManifoldKit (consumers)

ManifoldKit is a Swift package. Install via SwiftPM:

```swift
.package(url: "https://github.com/ManifoldKit/ManifoldKit.git", from: "0.66.0") // x-release-please-version
```

> **Pre-1.0.** Minor versions can introduce breaking changes. For production,
> pin to a specific tag (`exact: "0.64.0"`) and read [CHANGELOG.md](CHANGELOG.md)
> before bumping. The `0.x` line stabilises pieces incrementally; `1.0.0` will
> be the freeze point.

## Imports

App code should `import ManifoldKit` — the umbrella product re-exports the
five most-imported modules in one line:

```swift
import ManifoldKit   // covers Inference, Runtime, PersistenceSwiftData, the backend families, UI
```

Specialised modules stay opt-in and are imported by name when you need them:

| Product | Import when you need… |
|---------|------------------------|
| **`ManifoldKit`** *(umbrella, the default)* | `ChatView`, `ChatViewModel`, `ManifoldBootstrap`, `quickStart(backends:)`, `InferenceService`, `BackendName` — the 80%-case surface. |
| `ManifoldUIModelManagement` | `ModelManagementSheet`, `APIConfigurationView`, model browser/download UI. Not in the umbrella because chat-only consumers can ship without 1,800+ LOC of management surface. |
| `ManifoldHuggingFace` *(optional)* | Hub search, browse, background downloads. Compiles unconditionally (the `HuggingFace` trait retired in v0.48). |
| `ManifoldVoice` *(optional)* | Speech I/O composer accessory. |
| `ManifoldMCP` *(optional)* | Model Context Protocol client + tool bridge. Compiles unconditionally (no trait since v0.48). |
| `ManifoldAppIntents` *(optional)* | AppIntent ↔ ToolDefinition bridge. |
| `ManifoldMLX` / `ManifoldLlama` *(companion packages)* | MLX / llama.cpp local inference — add `manifold-mlx` / `manifold-llama` as separate package dependencies and pass `MLXBackends.self` / `LlamaBackends.self` to `quickStart(backends:)` (v0.48 split). |

Contributors changing ManifoldKit internals can still import the individual products
(`ManifoldInference`, `ManifoldRuntime`, `ManifoldPersistenceSwiftData`, the backend
families `ManifoldFoundation`/`ManifoldOllama`/`ManifoldCloudSaaS`, `ManifoldUI`);
the umbrella is the consumer-facing surface.

The dependency graph is one-way: UI depends on Runtime depends on Inference;
backends depend on Inference directly. Never import a backend family
(`ManifoldFoundation`/`ManifoldOllama`/`ManifoldCloudSaaS`) from a view target —
CI lint rejects that edge.

## Bootstrap recipe (canonical hello-world)

The shipped `ManifoldBootstrap.build(...)` wires inference, persistence, the
conversation runtime, and the model container in the right order. Because it
is `async`, wire it from a `.task { }` on the launch view — **not** from
`App.init()`, which is synchronous and would deadlock:

```swift
import SwiftUI
import SwiftData
import ManifoldKit
import ManifoldUIModelManagement   // model browser/download UI is opt-in

@main
struct MyChatApp: App {
    @State private var bootstrap: ManifoldBootstrap?
    @State private var chatViewModel: ChatViewModel?
    @State private var sessionManager: SessionManagerViewModel?
    @State private var modelManagement = ModelManagementViewModel.live()
    @State private var startupError: Error?

    var body: some Scene {
        WindowGroup {
            if let bootstrap, let chatViewModel, let sessionManager {
                ContentView()
                    .environment(chatViewModel)
                    .environment(sessionManager)
                    .environment(modelManagement)
                    // .environment(\.endpointStore, ...) lets APIConfigurationView
                    // persist API keys without extra glue in the host.
                    .environment(\.endpointStore, bootstrap.endpointStore)
                    .modelContainer(bootstrap.modelContainer)
            } else if let startupError {
                ContentUnavailableView(
                    "Failed to start",
                    systemImage: "exclamationmark.triangle",
                    description: Text(String(describing: startupError))
                )
            } else {
                ProgressView("Starting…")
                    .task { await start() }
            }
        }
    }

    @MainActor
    private func start() async {
        do {
            let (progress, task) = ManifoldBootstrap.build(
                configuration: ManifoldConfiguration(
                    appName: "My Chat",
                    bundleIdentifier: "com.example.mychat"
                )
            )
            for await _ in progress { /* drain milestones or drive a progress bar */ }
            let bootstrap = try await task.value

            // Register the compiled-in default families. The `ManifoldBackends`
            // umbrella and `DefaultBackends` were retired in P7 (pre-1.0; see
            // docs/MIGRATION-shims-retired.md); `quickStart()` folds these for
            // you, the manual path registers them explicitly.
            OllamaBackends.register(with: bootstrap.inferenceService)
            CloudSaaSBackends.register(with: bootstrap.inferenceService)
            FoundationBackends.register(with: bootstrap.inferenceService)

            let vm = ChatViewModel(
                inferenceService: bootstrap.inferenceService,
                conversationRuntime: bootstrap.conversationRuntime
            )
            vm.configure(bootstrap: bootstrap)

            // Use configureAndLoad — not configure — so sessions are populated
            // before selectInitialSession() runs (#1464).
            let sessions = SessionManagerViewModel()
            await sessions.configureAndLoad(bootstrap: bootstrap)

            if let restored = await sessions.selectInitialSession() {
                sessions.activeSession = restored
                await vm.switchToSession(restored)
            } else if let fresh = try? await sessions.createSession() {
                sessions.activeSession = fresh
                await vm.switchToSession(fresh)
            }

            self.bootstrap = bootstrap
            self.chatViewModel = vm
            self.sessionManager = sessions
        } catch {
            self.startupError = error
        }
    }
}
```

The corresponding `ContentView` is small:

```swift
import SwiftUI
import ManifoldKit
import ManifoldUIModelManagement

struct ContentView: View {
    @Environment(ChatViewModel.self) private var vm
    @Environment(ModelManagementViewModel.self) private var mm
    @Environment(SessionManagerViewModel.self) private var sessionVM
    @State private var showModelManagement = false

    var body: some View {
        NavigationSplitView {
            SessionListView()
        } detail: {
            ChatView(
                showModelManagement: $showModelManagement,
                apiConfiguration: { APIConfigurationView() }
            )
            .sheet(isPresented: $showModelManagement) {
                ModelManagementSheet(modelRegistry: vm.modelRegistry)
                    .environment(mm)
            }
        }
        .onChange(of: sessionVM.activeSession) { _, newSession in
            guard let newSession,
                  vm.activeSession?.id != newSession.id else { return }
            Task { await vm.switchToSession(newSession) }
        }
    }
}
```

`Example/Examples/MinimalExample/` is the runnable version of this — keep it
open while you wire the real app.

> For a single-session surface without a sidebar, `ManifoldKit.quickStart()`
> collapses the `start()` method above into one call. See
> [`docs/QUICKSTART.md`](docs/QUICKSTART.md) for that path.
>
> For the complete end-to-end recipe (local SwiftPM path, Ollama seeding,
> `ManifoldUIModelManagement` optionality), see
> [`docs/SWIFTUI-MULTI-SESSION.md` § Full recipe](docs/SWIFTUI-MULTI-SESSION.md).

## Sending a message

The user-facing API is **`vm.sendMessage(_:)`** (NOT `vm.send(_:)` — that name
does not exist on `ChatViewModel`):

```swift
let reply = try await vm.sendMessage("hi")
print(reply.content)
```

For scripted drivers / integration tests, `sendMessage(_:)` returns the
completed `ChatMessage`. Polling `vm.lastTurnState` after the awaited call
inspects the same outcome:

```swift
await vm.sendMessage()                  // uses vm.inputText + draftAttachments
switch vm.lastTurnState {
case .completed(let record): /* use record */
case .failed(let err):       /* surface error */
case .idle, .generating:     /* unexpected */
}
```

`sendMessage(_:)` throws `SendMessageError` when a turn ends without producing a
message. Make sure a session is selected and a model is loaded first; the
method enforces both preconditions.

## Backend identity

`BackendName` is a Swift `enum: String` with six cases. Compare via the typed
accessor — never against raw string literals:

```swift
import ManifoldKit   // re-exports ManifoldInference

if vm.activeBackendName == BackendName.foundation.rawValue {
    // Foundation-specific copy
}
```

Available cases (canonical raw values shown):

| Case | Raw value (0.19+) | Legacy (0.18.x) |
|------|-------------------|-----------------|
| `.foundation` | `"foundation"` | `"Apple"` |
| `.ollama` | `"ollama"` | `"Ollama"` |
| `.claude` | `"claude"` | `"Claude"` |
| `.openAI` | `"openAI"` | `"OpenAI"` |
| `.mlx` | `"mlx"` | `"MLX"` |
| `.llama` | `"llama"` | `"llama.cpp"` |

`BackendName.parse(_:)` accepts both the canonical 0.19+ form and the legacy
0.18 strings, so apps reading already-persisted backend names off disk migrate
in place:

```swift
if let backend = BackendName.parse(persisted) {
    // 0.18 "Apple" and 0.19 "foundation" both map to .foundation here.
}
```

## Message types

There are three message-shaped types. Pick the right one:

| Type | Module | When to use |
|------|--------|-------------|
| `ChatMessage` (struct) | `ManifoldInference` | Transport / app code. The shape `sendMessage(_:)` returns. (`ChatMessageRecord` is a deprecated alias for this type.) |
| `ChatMessage` (`@Model`) | `ManifoldPersistenceSwiftData` | SwiftData row — owned by the persistence layer. Disambiguate with the full schema path when both are in scope. |
| `StructuredMessage` | `ManifoldInference` | Cloud-wire payload assembled by `InferenceService`. Internal — backends consume it. |

App code reads and writes `ChatMessage` (the struct). The persistence and wire types
are managed by ManifoldKit.

## Tool calling

Register an executor with `ToolRegistry`, then thread the registry's
`definitions` into `GenerationConfig.tools`:

```swift
let registry = ToolRegistry()
registry.register(MyWeatherTool())

let (_, stream) = try inferenceService.enqueue(
    messages: history,
    tools: registry.definitions
)
```

### `@ToolSchema` macro requires `--traits Macros`

The `@ToolSchema` macro synthesises `static var jsonSchema` on a `Decodable`
struct. **It is gated behind the `Macros` SwiftPM trait, default-off**, because
the macro plugin pulls swift-syntax (~647 source files) into the build. Opt in
on every consumer:

```swift
.package(
    url: "https://github.com/ManifoldKit/ManifoldKit.git",
    from: "0.66.0", // x-release-please-version
    traits: [.trait(name: "Macros")]
)
```

```swift
@ToolSchema
struct WeatherArguments: Decodable, Sendable {
    /// City name
    let city: String
}

let tool = ToolDefinition(
    name: "get_weather",
    description: "Returns weather for a city.",
    parameters: WeatherArguments.jsonSchema
)
```

### Manual `JSONSchemaValue` (no Macros trait)

Without `--traits Macros`, declare the parameter schema by hand. `JSONSchemaValue`
is a recursive enum (`.string`, `.number`, `.bool`, `.null`, `.array`, `.object`):

```swift
let tool = ToolDefinition(
    name: "get_weather",
    description: "Returns weather for a city.",
    parameters: .object([
        "type": .string("object"),
        "properties": .object([
            "city": .object([
                "type": .string("string"),
                "description": .string("City name")
            ])
        ]),
        "required": .array([.string("city")])
    ])
)
```

**Local backend ceiling:** local instruct models (3B–8B) degrade past ~5 tools
per request. Curate per call. Cloud backends handle 20+ tools fine.

## Cloud backend setup

Cloud endpoints (OpenAI, Claude, Ollama, LM Studio, custom) flow through
`APIEndpointRecord` values. The 5-step canonical flow:

```swift
import ManifoldInference

// 1. Build the record.
let endpoint = APIEndpointRecord(
    name: "My OpenAI",
    provider: .openAI,
    baseURL: "https://api.openai.com",
    modelName: "gpt-4o-mini"
)

// 2. Store the API key in the Keychain (throws on failure).
try KeychainService.store(key: "sk-...", account: endpoint.keychainAccount)

// 3. Persist the endpoint via the runtime's EndpointStore.
try await runtime.endpointStore.insertEndpoint(endpoint)

// 4. Route the chat view model to the new backend.
await vm.loadCloudEndpoint(endpoint)

// 5. Send.
let reply = try await vm.sendMessage("hello")
```

Cloud backends are always compiled in since v0.48 (the `CloudSaaS` /
`Ollama` traits were retired) — no trait flags needed:

```swift
.package(
    url: "https://github.com/ManifoldKit/ManifoldKit.git",
    from: "0.66.0" // x-release-please-version
)
```

`KeychainService.store` / `.delete` and the `APIEndpoint.setAPIKey` /
`.deleteAPIKey` helpers throw `KeychainError` on failure — never use the legacy
`Bool`-returning shape.

## Common LLM hallucinations to avoid

These are the four mistakes most assistants make against ManifoldKit. Don't write any
of them:

1. **The umbrella module is `ManifoldKit`** (added in 0.19). Reach for
   `import ManifoldKit` first — it covers Inference, Runtime,
   PersistenceSwiftData, Backends, and UI. Specialised modules
   (`ManifoldUIModelManagement`, `ManifoldMCP`, `ManifoldVoice`, …) stay
   explicit imports.
2. **The send method is `vm.sendMessage(_:)`, NOT `vm.send(_:)`.**
   `ChatViewModel.send` does not exist. Use `try await vm.sendMessage("hi")`
   for scripted use, or set `vm.inputText` and call `await vm.sendMessage()`.
3. **Backend identity comparisons go through `BackendName.<case>.rawValue`**
   (e.g. `vm.activeBackendName == BackendName.foundation.rawValue`). The raw
   values flipped from `"Apple"`/`"Ollama"`/`"llama.cpp"` to lowercase
   canonical (`"foundation"`/`"ollama"`/`"llama"`) in 0.19 — code that
   hardcoded the legacy strings breaks. Use `BackendName.parse(_:)` when
   reading already-persisted strings off disk.
4. **Local model loading goes through
   `ModelManagementViewModel.dispatchSelectedLoad()`** — there is no shortcut
   like `vm.loadModel(url:)` or `vm.loadModel(from:)`. Foundation Models are
   the exception: call `vm.loadFoundationModelIfAvailable()` directly.

## Trait gotchas

Since v0.48 there are **no default traits** — plain `swift build` is the full
core build, and the heavy local backends moved to companion packages. What's
left:

- **`Macros` trait (default-off)** — required for `@ToolSchema`. See above.
- **`Server` trait (default-off)** — gates the `manifold-server` executable and
  its Hummingbird dependency tree.
- **MLX / llama.cpp are packages, not traits** — add
  `https://github.com/ManifoldKit/manifold-mlx` / `…/manifold-llama` as separate
  `.package(...)` dependencies and pass their registrars to
  `quickStart(backends:)`. A `traits: ["MLX"]` / `["Llama"]` array now
  hard-errors at resolve time — see docs/MIGRATION-0.48.md.
- **Everything else compiles unconditionally** (cloud, MCP, Voice, Tools,
  AppIntents, Skills, HuggingFace) — opt in by linking/importing the product.

## Concurrency

ManifoldKit is Swift-concurrency-native. The rules:

- **`@Observable` + `@MainActor` everywhere.** The view models are `@Observable`
  (Swift Observation), not Combine `ObservableObject`. Store them in `@State`
  and pass via `.environment(_)`; read with `@Environment(Type.self)`.
- **No Combine, no `@Published`, no callback pyramids.** Async/await throughout.
- **Never use `Task.detached` from a `@MainActor` class.** It captures mutable
  state without inheriting actor isolation. Use `Task { … }` and let the callee
  hop off-actor itself. (Swift 6 doesn't always warn on this — see
  [Part 2 → Swift 6 concurrency gotchas item 5](#swift-6-concurrency-gotchas).)
- **Don't block in `deinit` under `@MainActor` ownership.** Async cleanup hops
  to a `Task.detached` after capturing the resource strongly.
- **Streams are `AsyncThrowingStream<GenerationEvent, Error>`.** Consume with
  `for try await event in stream { … }`. The wrapper alias is `GenerationStream`.

## When in doubt

- Read the relevant source under `Sources/`. The public surface is small.
- The `Example/Examples/MinimalExample/` app is the canonical runnable wiring.
- DocC catalogs live alongside the modules
  (`Sources/ManifoldUI/ManifoldUI.docc/`).
- Contributors changing ManifoldKit internals should use `scripts/test.sh --profile local`
  as the default pre-push gate; **Part 2** below documents the full contributor workflow.
- For contributor-facing conventions (testing, traits, release process), see
  **Part 2 — Contributing to ManifoldKit** below. For consumer-facing API, Part 1 is enough.

# Part 2 — Contributing to ManifoldKit (internal conventions)
## Targets

No target in this repo has heavy ML dependencies — the MLX and llama.cpp families live in companion packages since v0.48 (see "Companion packages" below).

### Core / leaf modules (no SwiftData)

| Target | Role |
|--------|------|
| `ManifoldNetworking` | Leaf networking primitives (P1a #1608): `NetworkActivity` observability funnel, `PrivateIPClassifier`. Pure Foundation, zero upward deps. |
| `ManifoldSecrets` | Leaf security primitives (P1b #1609): `KeychainService`, `SecureEnclaveKeyManager`, `SecureBytes`. Pure Security framework, zero upward deps. |
| `ManifoldHardware` | Leaf device-capability + GGUF primitives (P1c #1610): device probing, memory-pressure broadcasting, GGUF parsing, load-plan logic. Also the physical home of the tool-calling value types (`ToolDefinition`/`ToolCall`/`ToolResult`/`ToolChoice`/`JSONSchemaValue`) and `BackendCapabilities` — re-exported through `ManifoldContract` via `@_exported import` (see `ManifoldContractLeafExports.swift`); physical relocation to Contract was ruled out (2026-07 API review) because `StructuredOutputStrategy`/`PromptTemplate`/`GenerationCapabilityRequirement` consume them here load-bearingly, which would cycle. Per the API-review posture, the SwiftPM products are the API — module placement is internal topology. Zero deps. |
| `ManifoldModelCatalog` | Model discovery/catalog/benchmark + image/video-gen records (P1d #1611): `ModelInfo`, `ModelManifest`, `ModelCatalog`, `ModelStorageService`, `DiagnosticsService`, `SettingsService`, `ModelBenchmarkRunner`. Depends on `ManifoldHardware`, `ManifoldNetworking`, `ManifoldSecrets`. |
| `ManifoldContract` | The Contract kernel (P2a #1719): backend protocols (`InferenceBackend`, `EmbeddingBackend`), value/stream types (`GenerationConfig`, `GenerationEvent`, `Message`, streaming transforms), plus `ToolDefinition`/`ToolCall`/`ToolResult` re-exported from `ManifoldHardware` (see that row). Depends on `ManifoldHardware` + `ManifoldModelCatalog` (`@_exported import`s both). Must NOT depend on `ManifoldInference` — `ManifoldContractNoEngineDependencyTests` is the tripwire. |

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

**Companion packages (v0.48, PR C2 / #1749):** the heavy local-inference families live outside this repo. [`ManifoldKit/manifold-mlx`](https://github.com/ManifoldKit/manifold-mlx) hosts the MLX backend family (text inference, diffusion/image gen, video gen, vendored FluxSwift/StableDiffusion, MLX integration tests); [`ManifoldKit/manifold-llama`](https://github.com/ManifoldKit/manifold-llama) hosts the llama.cpp/GGUF family. Module names stay `ManifoldMLX` / `ManifoldLlama`. Consumers add the companion `.package(...)` and pass registrars: `try await ManifoldKit.quickStart(backends: [LlamaBackends.self])`. Their conventions, hardware constraints, and test docs live in those repos. Building a new companion package? See [docs/COMPANION-BACKENDS.md](docs/COMPANION-BACKENDS.md).

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
| `manifold-tools` | CLI executable for running tool-call validation scenarios from `ManifoldTools`. Links `ManifoldOllama` + `ManifoldCloudSaaS` directly (the now-retired `ManifoldBackends` umbrella was deliberately never used here — #982 dual-llama Xcode-scheme hazard). |
| `ManifoldTelemetryOTLP` | OTLP/HTTP trace exporter (added #2070). Optional product — not re-exported by the `ManifoldKit` umbrella; consumers add it explicitly and pass an `OTLPTraceSink` to a backend's `traceSink` property. |

### Test support targets

| Target | Role |
|--------|------|
| `ManifoldTestSupport` | Shared mocks and fakes (`MockInferenceBackend`, `CharTokenizer`, etc.). No XCTest dependency (see `ManifoldContractTestSupport`). Published as a `.library` product so companion backend packages (manifold-mlx / manifold-llama, #1749) can reuse the mocks. |
| `ManifoldContractTestSupport` | XCTest-dependent protocol contract mixins. Kept separate from `ManifoldTestSupport` so `fuzz-chat` can depend on the latter without pulling XCTest into a non-test binary (PR #1409). |
| `ManifoldBackendTestKit` | Importable backend contract-check machinery (`BackendContractChecks`, backend contract mixins, `FixtureComparator`, local-backend contract runner). Published as a `.library` product for companion backend packages. Links XCTest — same #1409 constraint as `ManifoldContractTestSupport`: never depend on it from an executable target (audit-enforced). Contract suites that use the capability-claims registry must NOT run under `swift test --parallel` (process-global registry — see its DocC catalog). |

### Umbrella

| Target | Role |
|--------|------|
| `ManifoldKit` | Umbrella re-export so app code can `import ManifoldKit` instead of stitching together 4–6 imports. Re-exports `ManifoldInference` + `ManifoldRuntime` + `ManifoldPersistenceSwiftData` + the backend families (`ManifoldFoundation` / `ManifoldOllama` / `ManifoldCloudSaaS` / `ManifoldCloudCore`) + `ManifoldUI` + `ManifoldSkills` + `ManifoldHuggingFace` (the `quickStart(seed:)` background-download path). `ManifoldModelCatalog` is deliberately *not* a direct edge — no file in `Sources/ManifoldKit/` imports it; consumers reach it transitively via `ManifoldInference`'s `@_exported import`. Specialised modules (UIModelManagement, MCP, Voice, AppIntents, …) stay explicit imports. |

**Dependency rules:** Never import any backend family target (`ManifoldFoundation` / `ManifoldOllama` / `ManifoldCloudSaaS`) from UI; never import `ManifoldUIModelManagement` from `ManifoldUI` (CI lint enforces this). `ManifoldUIModelManagement` depends on `ManifoldUI` — cycle dissolved by closure-injecting `APIConfigurationView` via `@ViewBuilder` parameter.

**Backend family deps (post-P2a #1719, post-v0.48 C2, post-P7 #1837):** `ManifoldOllama` and `ManifoldCloudSaaS` compile against `ManifoldContract` + `ManifoldCloudCore` without touching the engine directly; `ManifoldFoundation` compiles against `ManifoldContract` + `ManifoldInference` (its `FoundationBackends` registrar, relocated here in P7, needs the engine). `ManifoldCloudCore` depends on `ManifoldInference` + `ManifoldRuntime` (the latter for `DefaultWebSearchRuntime`'s `WebSearchRuntime` port conformance — an un-gated library→library edge; see Package.swift comment). `ManifoldMCP` depends on `ManifoldInference` (uses `ToolExecutor`, `ToolRegistry`). All backend-family edges are unconditional — the trait-gated consumer→family edges died with the v0.48 trait retirement. The companion-package families (`ManifoldMLX`, `ManifoldLlama`) depend on this package's `ManifoldInference` from their own repos.

The `ManifoldKit` umbrella re-exports the always-compiled families (Foundation + cloud) directly — the `ManifoldBackends` re-export shim was retired in P7 (#1837), so `import ManifoldBackends` no longer compiles (see docs/MIGRATION-shims-retired.md). `ManifoldMCP` (including the `MCPCatalog` descriptors) compiles unconditionally — the `MCP` and `MCPBuiltinCatalog` traits were retired in v0.48. The `ManifoldAnyLanguageModel` bridge is its own always-compiled product (PR A5) — never re-exported by the umbrella or `ManifoldKit`; consumers import it explicitly.

**Trait roster (post-C2):** there are **no default traits** — plain `swift build` is the full core build. Surviving opt-in traits: `Server`, `Macros`; WWDC stubs `SystemAIProviderExtension`, `CoreAI`. Everything else was retired across the v0.48 train: `MCP`, `MCPBuiltinCatalog`, `Voice`, `Tools`, `AppIntents`, `Skills`, `Ollama`, `CloudSaaS`, `AnyLanguageModel` (A-series), then `MLX`, `Llama`, `HuggingFace`, `Fuzz`, `FoundationOnly` (PR C2). See docs/MIGRATION-0.48.md.

## Running tests

Use `scripts/test.sh` — it runs configured suites and prints an honest summary. There are no default traits since v0.48 — plain `swift test` covers the full core surface (`--disable-default-traits` is obsolete). Key flags:
- `--skip-update` — skips per-invocation git-remote contact (drop only if you edited Package.swift; a brand-new dependency commit fails `--skip-update` lanes with "unable to read tree", so drop the flag on the first run after adding a dep)
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
7. **Unlocked `nonisolated(unsafe) static var` test-injection seams are not safe by default.** A bare `nonisolated(unsafe) static var` used to let tests inject a mock resolver/hook (e.g. `_resolverForTesting`, a warning hook) is read on the real code path and written by test setup/teardown — with no lock, that's a live cross-thread race under `swift test --parallel`, not just a style nit. Wrong: `nonisolated(unsafe) static var _resolverForTesting: ((String) async -> [String]?)? = nil`. Right: keep the property name (so call sites don't change) but back it with a lock-guarded private storage var, e.g. `private static let overrideLock = NSLock()` + `nonisolated(unsafe) private static var _resolverForTesting_storage: (...)? = nil` + a computed `static var _resolverForTesting` whose `get`/`set` both go through `overrideLock.withLock { ... }` (mirrors `MCPSSRFPolicy`), or `OSAllocatedUnfairLock<T?>` for a single hook (mirrors `CloudImageEncoding._encodeHook`). `UnlockedNonisolatedUnsafeTestSeamAuditTest` is the tripwire; genuinely write-once-before-any-reader flags (documented boot-time config) are the only allowlisted exception.

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

See [docs/HARDWARE-TOOLCHAIN.md](docs/HARDWARE-TOOLCHAIN.md) for the full cross-repo consolidation (process-global `llama_backend_init`, the #982 dual-llama hazard, Swift Testing/XCTest process separation, toolchain ceiling, CI runner shape).

## Tooling

| Script | Purpose |
|--------|---------|
| `scripts/test.sh` | Runs configured Swift test suites and prints an honest summary. |
| `scripts/example-ui-tests.sh` | `build-for-testing` / `test-without-building` for Example app XCUITests. |
| `scripts/clean-leaked-test-artifacts.sh` | Removes test fixtures that leaked into `~/Documents/Models/`. |
| `scripts/clean-build.sh` | Full `.build` wipe + `swift package resolve`. Use when builds fail with "XCFramework Info.plist not found" or other `workspace-state.json` desync errors after changing the trait set. |
| `scripts/fuzz.sh` | Runs the ManifoldFuzz harness (default: 5 min against Ollama). CI cadence: **weekly only** (`.github/workflows/fuzz-weekly.yml`, `workflow_dispatch`). PR / nightly / hosted-heartbeat tiers were retired 2026-05 — once a backend is mature the fuzzer goes quiet for months, so per-PR + nightly CI minutes did not pay off. Run `scripts/fuzz.sh` locally (and consider temporarily reintroducing a higher cadence) when adding a new backend or model family. |
| `scripts/test-ios-simulator.sh` | Runs `ModelContainerFileProtectionTests` on an iOS Simulator via xcodebuild. Required because `NSFileProtection*` is an iOS-only kernel feature skipped by the macOS `swift test` lane. |
| `scripts/local-integration-sweep.sh` | Repeatable real-model integration + perf sweep across core (Ollama E2E) + manifold-llama (5-family GBNF conformance) + manifold-mlx (text/vision/benchmark) on local Apple Silicon. Run by hand (not scheduled) the nights you want real-hardware signal CI can't produce. See [docs/QA-PRACTICES.md § 5](docs/QA-PRACTICES.md). |

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

CI runs on macOS runners. The repo is public, so standard-runner minutes are free — the cost of a red or redundant run is **latency**: GitHub caps concurrent macOS jobs org-wide, and one `ci.yml` run fans out up to 5 macOS jobs, so every wasted run delays other queued work (including parallel sessions' PRs). Test locally first.

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

Workflow: check out the release branch via its worktree, rewrite CHANGELOG.md, amend + force-push, then merge through the queue: `gh pr merge <N> --squash --auto` (same rule as feature PRs — no `--admin`, no `gh api` direct merge; the queue validates the release commit against current main and the post-merge CI run self-skips).

**Pre-bump demo-app gate (mandatory before merging the release PR):** run `scripts/demo-apps-build.sh` — it builds both example apps (Advanced iOS, Minimal iOS + macOS) and must be green. The demos consume ManifoldKit by local path, so package drift (retired traits, renamed modules, iOS-unavailable symbols pulled in via the `ManifoldKit` umbrella) breaks them while `swift test` stays green — `swift test` builds for macOS only, so iOS-only API unavailability is invisible to it. This gate is **release-time, not per-PR**: demo breakage is rare and the xcodebuild runs are slow, so paying for them once per release (not per PR) is the right trade. Do not bump the version if it fails.

`README.md` install-pin examples (`from: "x.y.z"`) are bumped automatically by Release Please via the `extra-files` entry in `release-please-config.json` — do not update them manually between releases.

`changelog-lint` accepts: `^### ` (Prisma subheading) or `^\*\*[^*]+\*\* — ` (legacy bold+em-dash). Rejects any unrewritten `* lowercase` Release Please bullet.

## PR workflow

All changes go through PRs — direct pushes to `main` are blocked.

1. Branch off `main`, commit with conventional commits
2. `gh pr create --title "feat: ..." --body "..."`
3. Report the PR URL
4. Merge through the **merge queue**: `gh pr merge <N> --squash --auto` (queues the PR once required checks pass; the queue batches up to 5 PRs per validation run against the true merged tree). Never `--admin` and never `gh api`-direct merges — bypassing the queue skips pre-merge validation of the merged state AND forfeits ci.yml's `already-validated` post-merge skip, so main pays a redundant full CI run.

CI must pass all suites before merge. `ManifoldBackendsTests` covers the cloud/Foundation/mock surface — the MLX/Llama backend suites run in the companion repos' CI.

### Draft-PR review loop (mandatory for non-trivial PRs)

Every **non-trivial** PR goes through an adversarial review-and-fix loop **on a draft PR, before CI runs**. CI is gated to skip draft PRs (`ci.yml`/`readme-snippets.yml`/`cold-start-human.yml`/`build-modes.yml` guard the run on `draft == false`, with `ready_for_review` in the trigger types), so the draft is a **zero-CI staging area** and marking ready is the single, deliberate CI trigger. This keeps green-but-wrong code — and its re-run latency tax — off CI. Run the loop by hand (some harnesses automate it — e.g. Claude Code's `/ship` skill; see CLAUDE.md):

1. **Implement** in an isolated worktree off `origin/main` (never the current branch). Open a **draft** PR the moment it compiles (protect work early).
2. **Review** — dispatch an independent, skeptical reviewer against the diff: correctness, the premise/assumptions, scope discipline, conventions, and *is the feature actually live or inert* (the #2064 lesson — a read path with no writer is dead code).
3. **Fix** — apply findings, push to the same branch (still draft).
4. **Local gate — the FULL affected test targets, not `--filter <featureSuite>`.** Cross-cutting audits (`TestSuiteSilentSkipAuditTest`, `SilentCatchAuditTest`, schema/codegen/snapshot guards) live *outside* feature suites, so a filtered run goes green while CI goes red (exactly how #2064's `try? XCTUnwrap` reached CI). Run the affected target(s) whole, plus the audit suites by name. For added test files, `grep -rnE 'try\? (XCTUnwrap|XCTSkip)' Tests/` must come back clean.
5. **Mark ready** (`gh pr ready`) **only when review-clean and the local gate is green** — that flip is what triggers CI.

**Non-trivial** = touches **2+ files** OR adds/changes **behavior or logic**. Trivial single-file mechanical edits (typo, version bump, comment/doc-only, pure rename) skip the loop and go straight to a normal PR. When in doubt, run the loop.

## Issue & PR hygiene

CI is macOS-only, and the repo is **public — standard GitHub-hosted runners (including `macos-15`) cost nothing**. The budget is **latency, not dollars**: GitHub caps concurrent macOS jobs org-wide (~5), one `ci.yml` run fans out up to 5 macOS jobs, and the satellite PR workflows (`cold-start-human`, `readme-snippets`, `build-modes`) add more — so a single readied PR can saturate the cap, and wasted runs queue *behind each other and every other session's work*. Each run still pays an ~8-min cold `swift build` floor before any test executes. Caching is two-tiered (see the `actions/cache` step in `.github/actions/setup-swift-ci`): compiled **own-module** artifacts (`.build/debug`) are deliberately *not* cached — SwiftPM embeds paths in module fingerprints, so restored objects go stale on miss; tried and reverted twice (#961/#1045 → #1036, ~13% worse). But SwiftPM **dependency** material *is* cached and live — `.build/artifacts` + `.build/checkouts`/`.build/repositories` save the artifact-download and clone phases. The residual floor is local-module + test compile and test execution, neither cacheable. The dominant latency lever is therefore **run count and macOS job fan-out**, not per-run speed. Recent baseline: 145 PRs merged in 14 days across ~411 `ci.yml` runs (270 `pull_request`, 111 `push`, 30 `merge_group`; ~22% of concluded ready-PR runs were red). **The merge queue is LIVE** (batch ≤5, 5-min accumulation window, ALLGREEN, squash): `gh pr merge --squash --auto` routes a merge through it, which validates the true merged tree pre-merge and lets the push-to-main CI run self-skip via ci.yml's `already-validated` guard. An `--admin` merge bypasses both — every admin merge buys a redundant ~11-min post-merge run.

- **Batch toward an interior optimum, not "bigger is always better."** Two run-count reducers already ship and are doing real work: the `concurrency:` block in `ci.yml` (`cancel-in-progress: true`) collapses superseded in-flight runs — keyed on the PR number for `pull_request` (force-push collapse) and, since #1871, on `github.ref` for `push` so a *burst of rapid merges to main collapses to one CI run on the newest commit* (intermediate merges lose per-commit post-merge signal; nightly is the backstop); and `dorny/paths-filter@v4` (the `changes` job in `ci.yml`) skips jobs whose inputs didn't change. So the marginal cost of a *small, well-scoped* PR is already lower than the raw 384-runs figure implies — over-batching is no longer free. Prefer fewer, larger units of work, **but split when a diff exceeds ~40 changed files or ~800 net non-generated lines**: past that, review quality and conflict/revert risk dominate the saved cold-compile run. The target is the EOQ interior optimum, not maximal batch size.
- **Already-pulled CI-cost levers (don't re-investigate these).** Pulled June 2026 — verify before re-opening:
  - **Doc-snippet gate batching (#1870).** `scripts/extract-snippets-test.sh` (run by `readme-snippets.yml`) compiles every snippet in ONE SwiftPM package with one executable target per snippet + a single `swift build`, so the heavy ManifoldKit umbrella links once instead of once-per-snippet: ~17 min → ~2.5 min. A non-zero aggregate exit falls through to compile-only per-target attribution (`swift build --target`) — the gate validates compilation, not linking. **The CI runners ship Bash 3.2** (no `declare -A`); test shell-script edits under `/bin/bash`, not your dev bash.
  - **Redundant push gates dropped (#1870).** `readme-snippets.yml` and `cold-start-human.yml` run on `pull_request` only; their `push:` triggers were removed. `nightly-slow-tests.yml`'s `doc-gates` job runs both scripts as the 24h post-merge backstop.
  - **Docs left as-is.** `docs.yml`'s `pages` concurrency group (`cancel-in-progress: false`) already collapses a merge burst to ~2 builds (GitHub cancels previously-*pending* runs in the group). Flipping to `cancel-in-progress: true` reclaims only the one in-flight build and risks cancelling a publish mid-deploy — deliberately not done.
- **No phased feature splits.** Ship a feature as one PR, not P0→P5 (Glass Box shipped as 8 separate PRs of ≤8 files each = 8 cold-compile runs for one feature). If it's too big to review at once, stack it behind a draft and merge the stack as one — do not open a CI-triggering PR per phase.
- **Don't open issues for follow-ups, phases, or "while I'm here" cleanups.** The tracker is for real bugs and feature asks with external visibility. Use code comments for cross-session notes. Default to no when considering opening an issue.
- **One feature = one PR across all backends.** Don't fan out per-backend (past storms hit 15–24 PRs/day). Ship as one PR with a backend checklist in the body.
- **Tests and docs ship in the feature PR**, not as follow-ups.
- **Single-file PRs are a smell.** Batch them. (19% of the last 14 days' PRs touched one file.)
- **Kill the re-run tax.** ~Half of CI compute is failed attempts. Run the full `scripts/test.sh --profile local` gate before *every* push — CI is the last check, not the iteration loop. A red run costs a full ~8-min cold compile *and* holds macOS concurrency slots that every other queued job — yours and other sessions' — waits behind.
- **Tracking issues**: use one issue with a checklist for multi-PR work. Existing umbrellas: #753 (tool calling), #754 (demo-picker test matrix), #755 (fuzz harness v2). Add to these rather than creating new ones in the same area.
