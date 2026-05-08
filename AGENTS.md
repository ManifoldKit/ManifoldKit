# AGENTS.md — BaseChatKit guide for AI coding assistants

This file is for AI coding assistants (Claude, Cursor, Copilot, …) helping a
human use **BaseChatKit (BCK)** in their app. Contributors who need the
project's internal conventions read [`CLAUDE.md`](CLAUDE.md); this is the
shorter, recipe-shaped surface for *consumers*.

BCK is a Swift package. Install via SwiftPM:

```swift
.package(url: "https://github.com/roryford/BaseChatKit.git", from: "0.18.0")
```

> **Pre-1.0.** Minor versions can introduce breaking changes. For production,
> pin to a specific tag (`exact: "0.18.0"`) and read [CHANGELOG.md](CHANGELOG.md)
> before bumping. The `0.x` line stabilises pieces incrementally; `1.0.0` will
> be the freeze point.

## Imports

There is **no `BaseChatKit` umbrella module** — every dependency is imported by
its product name. (An umbrella product is planned for 0.19.) The eight products
a typical consumer wires up:

| Product | Import when you need… |
|---------|------------------------|
| `BaseChatInference` | Backend protocols, `InferenceService`, `ModelInfo`, `GenerationEvent`, tool types. |
| `BaseChatRuntime` | Storage-neutral ports (`EndpointStore`, `SamplerPresetStore`), use cases, `ConversationRuntime`. |
| `BaseChatPersistenceSwiftData` | The shipped SwiftData stack: `BaseChatBootstrap`, `@Model` types, container factory. |
| `BaseChatBackends` | Concrete backends (MLX, llama.cpp, Foundation, OpenAI, Claude, Ollama). `DefaultBackends.register(with:)`. |
| `BaseChatUI` | `ChatView`, `SessionListView`, `ChatViewModel`, `SessionManagerViewModel`. |
| `BaseChatUIModelManagement` | `ModelManagementSheet`, `APIConfigurationView`, model browser/download UI. |
| `BaseChatHuggingFace` *(optional, `HuggingFace` trait, default-on)* | Hub search, browse, background downloads. |
| `BaseChatVoice` *(optional, `Voice` trait)* | Speech I/O composer accessory. |
| `BaseChatMCP` *(optional, `MCP` trait)* | Model Context Protocol client + tool bridge. |

The dependency graph is one-way: UI depends on Runtime depends on Inference;
backends depend on Inference directly. Never import `BaseChatBackends` from a
view target — CI lint rejects that edge.

## Bootstrap recipe (canonical hello-world)

The shipped `BaseChatBootstrap` wires inference, persistence, the conversation
runtime, and the model container in the right order. Drop this in
`@main App.init()`:

```swift
import SwiftUI
import SwiftData
import BaseChatPersistenceSwiftData
import BaseChatInference
import BaseChatUI
import BaseChatUIModelManagement
import BaseChatBackends

@main
struct MyChatApp: App {
    private let runtime: BaseChatBootstrap
    @State private var chatViewModel: ChatViewModel
    @State private var sessionManager: SessionManagerViewModel
    @State private var modelManagement: ModelManagementViewModel

    init() {
        let runtime = try! BaseChatBootstrap(
            configuration: BaseChatConfiguration(
                appName: "My Chat",
                bundleIdentifier: "com.example.mychat"
            )
        )
        self.runtime = runtime

        DefaultBackends.register(with: runtime.inferenceService)

        let vm = ChatViewModel(
            inferenceService: runtime.inferenceService,
            conversationRuntime: runtime.conversationRuntime
        )
        vm.foundationModelProvider = {
            if #available(iOS 26, macOS 26, *) {
                return FoundationBackend.isAvailable
            }
            return false
        }
        vm.configure(runtime: runtime)
        _chatViewModel = State(initialValue: vm)

        let sessions = SessionManagerViewModel()
        sessions.configure(runtime: runtime)
        _sessionManager = State(initialValue: sessions)

        _modelManagement = State(initialValue: ModelManagementViewModel.live())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(chatViewModel)
                .environment(sessionManager)
                .environment(modelManagement)
                .environment(\.endpointStore, runtime.endpointStore)
        }
        .modelContainer(runtime.modelContainer)
    }
}
```

The corresponding `ContentView` is small:

```swift
import SwiftUI
import BaseChatUI
import BaseChatUIModelManagement

struct ContentView: View {
    @Environment(ChatViewModel.self) private var vm
    @Environment(ModelManagementViewModel.self) private var mm
    @State private var showModelManagement = false

    var body: some View {
        NavigationStack {
            ChatView(
                showModelManagement: $showModelManagement,
                apiConfiguration: { APIConfigurationView() }
            )
            .sheet(isPresented: $showModelManagement) {
                ModelManagementSheet(modelRegistry: vm.modelRegistry)
                    .environment(mm)
            }
        }
    }
}
```

`Example/Examples/MinimalExample/` is the runnable version of this — keep it
open while you wire the real app.

## Sending a message

The user-facing API is **`vm.sendMessage(_:)`** (NOT `vm.send(_:)` — that name
does not exist on `ChatViewModel`):

```swift
let reply = try await vm.sendMessage("hi")
print(reply.content)
```

For scripted drivers / integration tests, `sendMessage(_:)` returns the
completed `ChatMessageRecord`. Polling `vm.lastTurnState` after the awaited call
inspects the same outcome:

```swift
await vm.sendMessage()                  // uses vm.inputText + draftAttachments
switch vm.lastTurnState {
case .completed(let record): /* use record */
case .failed(let err):       /* surface error */
case .idle, .generating:     /* unexpected */
}
```

`sendMessage(_:)` throws `NoResponseError` when a turn ends without producing a
message. Make sure a session is selected and a model is loaded first; the
method enforces both preconditions.

## Backend identity

Use the typed constants in `BackendName`. Do not compare against raw strings:

```swift
import BaseChatInference

if vm.activeBackendName == BackendName.foundation {
    // Foundation-specific copy
}
```

Available constants today (raw values shown for reference, but **don't compare
against them directly** — write `BackendName.foundation`, not `"Apple"`):

| Constant | Raw value |
|----------|-----------|
| `.foundation` | `"Apple"` |
| `.ollama` | `"Ollama"` |
| `.claude` | `"Claude"` |
| `.openAI` | `"OpenAI"` |
| `.mlx` | `"MLX"` |
| `.llama` | `"llama.cpp"` |

The 0.19 release converts `BackendName` to a true Swift `enum` (raw values
become lowercase: `.foundation == "foundation"`). The typed accessor pattern
above is forward-compatible — code that hardcodes `"Apple"` will break.

## Message types

There are three message-shaped types. Pick the right one:

| Type | Module | When to use |
|------|--------|-------------|
| `ChatMessageRecord` | `BaseChatInference` | Transport / app code. The shape `sendMessage(_:)` returns. |
| `ChatMessage` (`@Model`) | `BaseChatPersistenceSwiftData` | SwiftData row — owned by the persistence layer. |
| `StructuredMessage` | `BaseChatInference` | Cloud-wire payload assembled by `InferenceService`. Internal — backends consume it. |

App code reads and writes `ChatMessageRecord`. The persistence and wire types
are managed by BCK.

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
    url: "https://github.com/roryford/BaseChatKit.git",
    from: "0.18.0",
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
import BaseChatInference

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

Cloud backends require **`--traits CloudSaaS`** (default-off):

```swift
.package(
    url: "https://github.com/roryford/BaseChatKit.git",
    from: "0.18.0",
    traits: [
        .trait(name: "MLX"),
        .trait(name: "Llama"),
        .trait(name: "CloudSaaS"),
    ]
)
```

`KeychainService.store` / `.delete` and the `APIEndpoint.setAPIKey` /
`.deleteAPIKey` helpers throw `KeychainError` on failure — never use the legacy
`Bool`-returning shape.

## Common LLM hallucinations to avoid

These are the four mistakes most assistants make against BCK. Don't write any
of them:

1. **There is NO `BaseChatKit` umbrella module.** `import BaseChatKit` does not
   compile. Import the specific products you need
   (`BaseChatPersistenceSwiftData`, `BaseChatUI`, `BaseChatBackends`, …). An
   umbrella product is on the 0.19 roadmap.
2. **The send method is `vm.sendMessage(_:)`, NOT `vm.send(_:)`.**
   `ChatViewModel.send` does not exist. Use `try await vm.sendMessage("hi")`
   for scripted use, or set `vm.inputText` and call `await vm.sendMessage()`.
3. **Backend identity is `BackendName.foundation` (typed), NOT a raw string
   `"foundation"` or `"Apple"`.** The raw values are an implementation detail
   that 0.19 will change.
4. **Local model loading goes through
   `ModelManagementViewModel.dispatchSelectedLoad()`** — there is no shortcut
   like `vm.loadModel(url:)` or `vm.loadModel(from:)`. Foundation Models are
   the exception: call `vm.loadFoundationModelIfAvailable()` directly.

## Trait gotchas

BCK uses SwiftPM traits aggressively to keep dependency graphs small. The ones
that bite consumers:

- **`Macros` (default-off)** — required for `@ToolSchema`. See above.
- **`MLX` (default-on)** — pulls mlx-swift; large checkout. Drop on cloud-only
  builds. Apple Silicon only at runtime.
- **`Llama` (default-on)** — pulls llama.cpp xcframework (~200 MB). Drop on
  Foundation-Models-only or cloud-only builds.
- **`HuggingFace` (default-on)** — Hub browser/downloader. Drop if you don't
  ship a model picker.
- **`CloudSaaS` (default-off)** — required for OpenAI / Claude. Off in regulated
  builds.
- **`Ollama` (default-off)** — required for `OllamaBackend`. Self-hosted only.
- **`MCPBuiltinCatalog` (default-off)** — required for the built-in MCP catalog
  (`notion`, `linear`, `github` descriptors).
- **`Voice` (default-off)** — required for `BaseChatVoice` speech I/O.

When you `--disable-default-traits`, you must explicitly add the ones you want
back. The "default consumer app" build is `swift build` with no flags —
`MLX,Llama,HuggingFace`.

## Concurrency

BCK is Swift-concurrency-native. The rules:

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
  (`Sources/BaseChatUI/BaseChatUI.docc/`).
- For contributor-facing conventions (testing, traits, release process),
  see [CLAUDE.md](CLAUDE.md). For consumer-facing API, this file is enough.
