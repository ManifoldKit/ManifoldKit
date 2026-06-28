# AGENTS.md — ManifoldKit guide for AI coding assistants

This file is for AI coding assistants (Claude, Cursor, Copilot, …) helping a
human use **ManifoldKit** in their app. Contributors who need the
project's internal conventions read [`CLAUDE.md`](CLAUDE.md); this is the
shorter, recipe-shaped surface for *consumers*.

ManifoldKit is a Swift package. Install via SwiftPM:

```swift
.package(url: "https://github.com/ManifoldKit/ManifoldKit.git", from: "0.46.0")
```

> **Pre-1.0.** Minor versions can introduce breaking changes. For production,
> pin to a specific tag (`exact: "0.46.0"`) and read [CHANGELOG.md](CHANGELOG.md)
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
            // umbrella and `DefaultBackends` were retired in 1.0 (see
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
    from: "0.46.0",
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
    from: "0.48.0"
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
  [`CLAUDE.md` → Swift 6 concurrency gotchas item 5](CLAUDE.md#swift-6-concurrency-gotchas).)
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
  as the default pre-push gate; `CLAUDE.md` documents the full contributor workflow.
- For contributor-facing conventions (testing, traits, release process),
  see [CLAUDE.md](CLAUDE.md). For consumer-facing API, this file is enough.
