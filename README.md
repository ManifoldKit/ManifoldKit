# BaseChatKit

A modular SwiftUI framework for building chat interfaces powered by local and cloud LLMs on Apple platforms.

BaseChatKit provides a complete, production-ready chat UI with pluggable inference backends, model management, and SwiftData persistence. Drop it into your app, register backends, and you have a working chat interface.

**Built for production failure modes.** BCK is designed around the things that go wrong between a working demo and an App Store release:

- **Streaming resilience** — cloud backends retry the initial connection with backoff on retryable errors and preserve already-yielded output if a later failure occurs.
- **Latest-wins model handoff** — racing model loads can't corrupt active state. If the user taps model A, then model B before A finishes, A is discarded and B wins deterministically.
- **Memory admission and pressure handling** — `ModelLoadPlan` estimates resident + KV memory before a load commits and returns an `allow`/`warn`/`deny` verdict; `InferenceService.denyPolicy` decides whether to fail fast, warn and proceed, or hand off to a custom hook. The drop-in `ChatViewModel` stops generation and unloads the model on critical memory pressure.
- **Mock backend for app-level testing** — `MockInferenceBackend` implements the full streaming contract so your app's tests can exercise BCK without loading a real model.
- **Certificate pinning with fail-closed defaults** — `api.openai.com` and `api.anthropic.com` fail closed if pin sets are missing or empty; custom hosts use platform trust by default or can be hardened to fail-closed via `BaseChatConfiguration.shared.customHostTrustPolicy = .requireExplicitPins`.

For the exact source-backed contract, see [docs/RELIABILITY.md](docs/RELIABILITY.md).
See [docs/SCOPE_DECISION.md](docs/SCOPE_DECISION.md) for the scoping rationale behind BCK 0.6.0.

## Demo


![BaseChatKit demo — chat conversation with streaming, session sidebar, and model browser](Example/Screenshots/demo.png)

## Features

- **Multiple inference backends** — GGUF (llama.cpp), MLX (Apple Silicon), Apple Foundation Models, OpenAI, Claude, Ollama, LM Studio, and custom OpenAI-compatible APIs
- **Vision-aware attachments** — `ChatInputBar` surfaces image attachments only when the active backend reports vision support; text-only backends fail fast on image parts instead of silently dropping them
- **Complete SwiftUI interface** — Chat view, session management, model browser, generation settings, export
- **HuggingFace integration** — Search, browse, and download models directly from the Hub (default-on trait)
- **Background downloads** — iOS background transfer support with progress tracking and GGUF/MLX validation
- **SwiftData persistence** — Chat sessions, messages, and API endpoint configuration
- **Context window management** — Automatic message trimming with token estimation
- **Memory pressure monitoring** — Auto-unloads models when the system is under pressure
- **Secure API key storage** — Keychain-backed with just-in-time retrieval; keys are read at request time and not stored as long-lived properties (they do exist in process memory as `String` for the duration of an HTTP request — see [docs/FIPS.md](docs/FIPS.md) §non-mitigations)
- **Certificate pinning** — Configurable SPKI hash pinning for cloud API connections

## Requirements

- Swift 5.9+
- iOS 18+ / macOS 15+
- Apple Foundation Models require iOS 26+ / macOS 26+

BaseChatKit follows an **n-1 platform policy**: the current Apple OS release
and the one immediately before it. When Apple ships a new major OS each
September, both minimums are bumped by one. See
[CLAUDE.md → Platform policy](CLAUDE.md#platform-policy) for the rationale.

## How BCK compares to AnyLanguageModel

AnyLanguageModel is HuggingFace's Swift package. It mirrors Apple's `FoundationModels` API and exposes many providers behind a single protocol, so code written against Apple's built-in model API can target cloud and open-source models with minimal changes.

BCK and AnyLanguageModel occupy adjacent niches. AnyLanguageModel optimizes for provider coverage and API familiarity — if you need "any LLM behind one protocol that looks like `FoundationModels`," it's the simpler choice. BCK optimizes for production reliability and drop-in chat UI — if you need "a chat framework that survives real failures and ships a working `ChatView` + `SessionListView` + `ModelManagementSheet` on day one," BCK is designed for that. The two aren't competing on the same axis; pick the one whose axis matches the problem you're solving.

## Architecture

BaseChatKit is split into five primary targets plus optional bridge modules:

```
BaseChatUI  ──────────>  BaseChatCore  ──────────>  BaseChatInference
(Views, ViewModels)      (SwiftData schema,         (Protocols, Models,
                          @Model types,              Services, Inference
                          persistence, export)       orchestration)
                                                             ↑
                         BaseChatMCP ────────────────────────┤
                         (MCP descriptors, client,           │
                          tool bridge)                       │
                                                             │
                          BaseChatBackends ──────────────────┘
                          (MLX, llama.cpp,
                           Foundation, Cloud)
```

- **BaseChatInference** — Inference orchestration. Protocols, models, and services for model loading, generation, context windows, prompt assembly, compression, tokenizers, and capability detection. No SwiftData. No ML dependencies. This is the integration point for custom backends and the minimum target for apps that bring their own persistence and UI.
- **BaseChatMCP** — Model Context Protocol client surface: descriptors, auth/transport types, connection lifecycle (`MCPClient`), and tool bridge (`MCPToolSource`) for registering MCP tools with `ToolRegistry`.
- **BaseChatCore** — SwiftData schema, `@Model` types (`ChatMessage`, `ChatSession`, `SamplerPreset`, `APIEndpoint`, `ModelBenchmarkCache`), `ModelContainerFactory`, `ChatPersistenceProvider`, and chat export. Depends on `BaseChatInference` but does not re-export it.
- **BaseChatBackends** — Concrete inference backend implementations. Depends on `BaseChatInference` (not `BaseChatCore`), so backends stay free of SwiftData. Pulls MLX, llama.cpp, and cloud APIs.
- **BaseChatUI** — SwiftUI views and view models. Depends on `BaseChatCore` (for persistence) and `BaseChatInference` (for inference orchestration).
- **BaseChatHuggingFace** *(trait: `HuggingFace`, default-on)* — HuggingFace Hub search plus background download / validation services.
- **BaseChatAnyLanguageModelBridge** *(trait: `AnyLanguageModel`, default-off)* — Thin `InferenceBackend` adapter over HuggingFace's `AnyLanguageModel`.
- **BaseChatVoice** — Optional speech-recognition / synthesis adapters and voice composer UI. Depends on `BaseChatUI` so hosts can opt in without adding a back-edge into the base chat surface.

## Quick Start

### 1. Add the package

```swift
.package(url: "https://github.com/roryford/BaseChatKit.git", from: "1.0.0")
```

Add the targets you need:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "BaseChatCore", package: "BaseChatKit"),
    .product(name: "BaseChatBackends", package: "BaseChatKit"),
    .product(name: "BaseChatUI", package: "BaseChatKit"),
])
```

### 2. Build modes

BaseChatKit ships four pre-blessed build profiles keyed by the network surface a binary exposes. Backends are gated behind Swift package traits so consumers in regulated or air-gapped environments can compile out everything that touches the network.

| Profile | Build command | Build profile at runtime | Remote providers compiled in |
|---------|---------------|--------------------------|-----------------------------|
| Default consumer app | `swift build` | `offline` | none |
| Regulated vertical (local-only, no networking) | `swift build --disable-default-traits --traits MLX,Llama` | `offline` | none |
| Self-hosted / private datacenter | `swift build --disable-default-traits --traits MLX,Llama,Ollama` | `selfHosted` | Ollama |
| SaaS-only | `swift build --disable-default-traits --traits MLX,Llama,CloudSaaS` | `saas` | Claude, OpenAI-compatible |
| Full / SaaS-enabled | `swift build --disable-default-traits --traits MLX,Llama,Ollama,CloudSaaS` | `full` | Ollama, Claude, OpenAI-compatible |

Pass the matching set as `traits:` on your `.package(...)` entry to lock the configuration in a consumer manifest:

```swift
.package(
    url: "https://github.com/roryford/BaseChatKit.git",
    from: "0.11.0",
    traits: [
        .trait(name: "MLX"),
        .trait(name: "Llama"),
        .trait(name: "Ollama"),       // remove for local-only builds
        .trait(name: "CloudSaaS"),    // add to enable Claude / OpenAI
    ]
)
```

`CloudSaaS` and `Ollama` are opt-in. `HuggingFace` is default-on for backwards compatibility; drop it from `traits:` (or start from `--disable-default-traits`) to remove the stock Hub browser/downloader from the build graph. `AnyLanguageModel` is also opt-in and only needed when you want the bridge target.

For example, a cloud-only consumer can keep the chat UI and local-model loaders out of the download path:

```swift
.package(
    url: "https://github.com/roryford/BaseChatKit.git",
    from: "1.0.0",
    traits: [
        .trait(name: "MLX"),
        .trait(name: "Llama"),
        .trait(name: "CloudSaaS"),
        // Omit HuggingFace to hide the stock download browser.
    ]
)
```

You can inspect the compiled contract at runtime without a custom shim:

```swift
import BaseChatInference

let compiled = CompiledBackends.current

switch compiled.buildProfile {
case .offline:
    // Hide cloud endpoint settings.
    break
case .selfHosted, .saas, .full:
    break
}

if compiled.shouldPresentModelDownloads {
    // Show the stock download browser / local-model onboarding.
}

if compiled.localModelTypes.contains(.mlx) {
    // Surface MLX-specific copy.
}
```

If you already depend on `BaseChatBackends`, the same data is also available via `DefaultBackends.compiledBackends`.

`CompiledBackends.current` describes what's compiled into the binary based on SwiftPM traits — it answers "could this build ever support backend X?" `FrameworkCapabilityService.enabledBackends` describes what's actually been registered at runtime — "is backend X usable right now?" Gate UI affordances on `enabledBackends` unless you specifically need the compile-time view (e.g., to hide a download tab in a SaaS-only build).

### 2.1 Optional MCP traits

`BaseChatMCP` ships as its own module (`import BaseChatMCP`). Package traits expose MCP-specific configuration:

- `MCP` — explicit MCP opt-in marker for consumer manifests.
- `MCPBuiltinCatalog` — enables built-in `MCPCatalog` descriptors (`notion`, `linear`, `github`).

```swift
.package(
    url: "https://github.com/roryford/BaseChatKit.git",
    from: "1.0.0",
    traits: [
        .trait(name: "MCP"),
        .trait(name: "MCPBuiltinCatalog"), // optional: only if you use MCPCatalog
    ]
)
```

Quick checks:

```bash
swift test --filter BaseChatMCPTests --disable-default-traits
swift test --filter BaseChatMCPTests --disable-default-traits --traits MCPBuiltinCatalog
```

### 2.2 Optional voice

`BaseChatVoice` is an opt-in module for speech input/output. It plugs into
`ChatView` through the `composerAccessory:` seam, so `BaseChatUI` stays free of
audio-framework dependencies while hosts can mount a voice accessory above the
stock `ChatInputBar`.

```swift
 .package(
     url: "https://github.com/roryford/BaseChatKit.git",
     from: "1.0.0",
     traits: [
         .trait(name: "Voice"),
     ]
 )
```

```swift
import BaseChatUI
import BaseChatVoice

@State private var voice = VoiceConversationController(
    wakeWordDetector: AppleWakeWordDetector(wakeWords: ["hey base chat"])
)

ChatView(
    showModelManagement: $isModelManagementPresented,
    composerAccessory: { VoiceComposerAccessory(controller: voice) },
    apiConfiguration: { APIConfigurationView() }
)
```

Voice input requires `NSMicrophoneUsageDescription` and
`NSSpeechRecognitionUsageDescription` in the host app's `Info.plist`. The
default Apple speech transcriber returns a user-facing error on the simulator,
so validate the real capture flow on device or macOS hardware.

Wake-word support is phrase detection over the live Apple Speech transcript,
not background hotword monitoring while the app is idle. On iOS, the default
audio-session coordinator activates `.playAndRecord` / `.spokenAudio` with
`.defaultToSpeaker` and `.duckOthers` while capture is active, then deactivates
the session when recording stops. Apps with their own audio-session policy can
inject a custom transcriber or audio-session coordinator.

### 3. Create the runtime at app startup

```swift
import SwiftData
import BaseChatCore
import BaseChatInference
import BaseChatBackends
import BaseChatUI
import BaseChatUIModelManagement

@main
struct MyApp: App {
    private let runtime: BaseChatRuntime
    @State private var chatViewModel: ChatViewModel
    @State private var sessionManager: SessionManagerViewModel
    @State private var modelManagement: ModelManagementViewModel

    init() {
        let runtime = try! BaseChatRuntime(
            configuration: BaseChatConfiguration(
                appName: "My Chat App",
                bundleIdentifier: "com.example.mychatapp"
            )
        )
        self.runtime = runtime

        DefaultBackends.register(with: runtime.inferenceService)

        let vm = ChatViewModel(inferenceService: runtime.inferenceService)
        vm.foundationModelProvider = {
            if #available(iOS 26, macOS 26, *) {
                return FoundationBackend.isAvailable
            }
            return false
        }
        vm.configure(runtime: runtime)
        vm.refreshModels()
        _chatViewModel = State(initialValue: vm)

        let sessionManager = SessionManagerViewModel()
        sessionManager.configure(runtime: runtime)

        let initialSession = sessionManager.sessions.first ?? (try? sessionManager.createSession())
        if let initialSession {
            sessionManager.activeSession = initialSession
            vm.switchToSession(initialSession)
            vm.dispatchSelectedLoad()
        }

        _sessionManager = State(initialValue: sessionManager)

        _modelManagement = State(initialValue: ModelManagementViewModel.live())
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(chatViewModel)
                .environment(modelManagement)
                .environment(sessionManager)
        }
        .modelContainer(runtime.modelContainer)
    }
}
```

### 4. Wire up the UI

```swift
struct ContentView: View {
    @Environment(ChatViewModel.self) private var viewModel
    @Environment(SessionManagerViewModel.self) private var sessionManager

    var body: some View {
        NavigationSplitView {
            SessionListView()
        } detail: {
            ChatView(
                showModelManagement: .constant(false),
                apiConfiguration: { APIConfigurationView() }
            )
        }
        .onChange(of: sessionManager.activeSession) { _, session in
            guard let session, viewModel.activeSession?.id != session.id else { return }
            viewModel.switchToSession(session)
            viewModel.dispatchSelectedLoad()
        }
    }
}
```

### Migrating from `configure(persistence:)`

Pre-runtime BaseChatKit apps wired persistence by reading
`@Environment(\.modelContext)` from a root view's `.task` or `.onAppear` and
calling `chatViewModel.configure(persistence: SwiftDataPersistenceProvider(...))`
once the SwiftData container was attached. The runtime collapses that into a
single bootstrap call.

**Before** — late-binding from a view lifecycle:

```swift
import SwiftUI
import SwiftData
import BaseChatCore
import BaseChatInference
import BaseChatUI

@main
struct LegacyApp: App {
    @State private var chatViewModel = ChatViewModel()
    let modelContainer: ModelContainer

    init() {
        modelContainer = try! ModelContainer(for: ChatSessionRecord.self, ChatMessageRecord.self)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(chatViewModel)
                .task {
                    let provider = SwiftDataPersistenceProvider(modelContext: modelContainer.mainContext)
                    chatViewModel.configure(persistence: provider)
                }
        }
        .modelContainer(modelContainer)
    }
}
```

**After** — runtime-driven bootstrap in `App.init()`:

```swift
import SwiftUI
import SwiftData
import BaseChatCore
import BaseChatInference
import BaseChatUI

@main
struct ModernApp: App {
    private let runtime: BaseChatRuntime
    @State private var chatViewModel: ChatViewModel
    @State private var sessionManager: SessionManagerViewModel

    init() {
        let runtime = try! BaseChatRuntime(
            configuration: BaseChatConfiguration(
                appName: "My App",
                bundleIdentifier: "com.example.myapp"
            )
        )
        self.runtime = runtime

        let chatVM = ChatViewModel(inferenceService: runtime.inferenceService)
        chatVM.configure(runtime: runtime)
        _chatViewModel = State(initialValue: chatVM)

        let sessionVM = SessionManagerViewModel()
        sessionVM.configure(runtime: runtime)
        _sessionManager = State(initialValue: sessionVM)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(chatViewModel)
                .environment(sessionManager)
        }
        .modelContainer(runtime.modelContainer)
    }
}
```

Both view models must be configured from the runtime. `ChatViewModel.configure(runtime:)` wires the persistence provider used by chat sessions; `SessionManagerViewModel.configure(runtime:)` wires both persistence and diagnostics for the session list. Skipping the session-manager configuration leaves it on a nil-persistence path that fails on first save. See the MinimalExample app for the canonical wiring.

#### What still works unchanged

`@Query` and `@Environment(\.modelContext)` continue to work in your views: the
`runtime.modelContainer` is attached to the scene with the standard
`.modelContainer(_:)` modifier, so SwiftData wiring downstream of that scene
behaves exactly as it did before.

#### Buffering payloads during cold launch

Apps that buffer an inbound payload during cold launch (Share Extension, App
Intent, deep link) and then drain it once persistence is available should keep
that pattern. The runtime makes persistence available *before* view rendering,
so the buffer can drain immediately on first appearance — no `if persistence ==
nil` race needed in `.task`.

#### Multiple `ModelContainer`s

Apps using a second `ModelContainer` for non-chat data (analytics caches,
extension state, bookmarks) should continue to construct that container
independently and attach it to the scene with a separate `.modelContainer(_:)`
modifier:

```swift
import SwiftData

var body: some Scene {
    WindowGroup {
        RootView()
            .environment(chatViewModel)
    }
    .modelContainer(runtime.modelContainer)
    .modelContainer(analyticsContainer)
}
```

The runtime owns only the chat schema; non-chat schemas stay yours.

#### When to keep `configure(persistence:)`

Keep `configure(persistence:)` for adopters that provide a custom
``ChatPersistenceProvider`` (e.g. an in-memory test fixture, or a non-SwiftData
backing store). Construct ``ChatViewModel`` and ``SessionManagerViewModel``
directly and call `configure(persistence:)` — `BaseChatRuntime` is the
SwiftData-backed bootstrap and does not yet support custom providers.

## Supported Model Types

| Type | Backend | Format | Source |
|------|---------|--------|--------|
| GGUF | `LlamaBackend` (llama.cpp) | Single `.gguf` file | HuggingFace, local |
| MLX | `MLXBackend` (mlx-swift) | Directory with `config.json` + `.safetensors` | HuggingFace, local |
| Foundation | `FoundationBackend` | Built-in (no download) | Apple Intelligence |
| OpenAI | `OpenAIBackend` | Cloud API | api.openai.com |
| Claude | `ClaudeBackend` | Cloud API | api.anthropic.com |
| Ollama | `OpenAIBackend` | Local API | localhost:11434 |
| LM Studio | `OpenAIBackend` | Local API | localhost:1234 |

## Key Types

### View Models

| Type | Purpose |
|------|---------|
| `ChatViewModel` | Central chat controller — messages, generation, model loading, settings |
| `SessionManagerViewModel` | Chat session CRUD and selection |
| `ModelManagementViewModel` | HuggingFace search, downloads, local model management |

### Services

| Type | Purpose |
|------|---------|
| `InferenceService` | Backend orchestrator — selects and delegates to the right backend |
| `BaseChatRuntime` | Preferred bootstrap surface — installs configuration, builds SwiftData persistence, and holds shared services |
| `BackgroundDownloadManager` | Background model downloads with progress and validation (`BaseChatHuggingFace`) |
| `ModelStorageService` | Local model file discovery and storage paths |
| `DeviceCapabilityService` | RAM/chipset queries for model size recommendations |
| `KeychainService` | Secure API key storage |
| `ContextWindowManager` | Token estimation and message trimming |
| `HuggingFaceService` | HuggingFace Hub API (search, model info, download URLs) (`BaseChatHuggingFace`) |

### Views

| View | Purpose |
|------|---------|
| `ChatView` | Main chat interface with message list and input bar |
| `SessionListView` | Sidebar session list with rename/delete |
| `GenerationSettingsView` | Temperature, top-p, system prompt, prompt template |
| `APIConfigurationView` | Cloud API endpoint management |
| `ModelManagementSheet` | Combined model browser + storage management |

### Protocols

| Protocol | Purpose |
|----------|---------|
| `InferenceBackend` | Common interface for all inference engines |
| `SSEPayloadHandler` | Interprets SSE JSON payloads for cloud API streaming |
| `ConversationHistoryReceiver` | Passes multi-turn history to cloud backends |
| `TokenUsageProvider` | Reports token usage from cloud API responses |
| `HuggingFaceServiceProtocol` | Abstraction for HuggingFace Hub operations |

## Tool Calling

Register tools with `ToolRegistry` and pass `toolRegistry.definitions` as `GenerationConfig.tools` when enqueueing a request:

```swift
let registry = ToolRegistry()
registry.register(MyWeatherTool())
registry.register(MySearchTool())

let (_, stream) = try inferenceService.enqueue(
    messages: history,
    tools: registry.definitions
)
```

**Local backend tool ceiling:** Local instruct models (3B–8B) degrade sharply when given more than ~5 tool definitions per request — the model may ignore later tools, hallucinate names, or misroute calls. For cloud backends (OpenAI, Anthropic, large Ollama models) 20+ tools is fine. When targeting a local backend, curate tools per request via `GenerationConfig.tools` and keep definitions at or below 5 per call.

## MCP Quick Start

```swift
import BaseChatInference
import BaseChatMCP

let client = MCPClient()
let source = try await client.connect(descriptor)
await source.register(in: registry)
```

For a complete walkthrough (descriptor setup, lifecycle, and built-in catalog), see `Sources/BaseChatMCP/BaseChatMCP.docc/Articles/MCPGettingStarted.md`.

## Custom Backends

Implement `InferenceBackend` and register it:

```swift
class MyBackend: InferenceBackend, @unchecked Sendable {
    var isModelLoaded = false
    var isGenerating = false
    var capabilities: BackendCapabilities { /* ... */ }

    func loadModel(from url: URL, contextSize: Int32) async throws { /* ... */ }
    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig)
        throws -> AsyncThrowingStream<GenerationEvent, Error> { /* ... */ }
    func stopGeneration() { /* ... */ }
    func unloadModel() { /* ... */ }
}

// Register
inferenceService.registerBackendFactory { modelType in
    switch modelType {
    case .gguf: return MyBackend()
    default: return nil
    }
}
```

## Curated Model Recommendations

Provide device-appropriate model suggestions:

```swift
CuratedModel.all = [
    CuratedModel(
        id: "my-model",
        displayName: "My Model (Q4)",
        fileName: "my-model-q4.gguf",
        repoID: "myorg/my-model-GGUF",
        modelType: .gguf,
        approximateSizeBytes: 4_000_000_000,
        recommendedFor: [.medium, .large, .xlarge],
        contextSize: 4096,
        promptTemplate: .chatML,
        description: "A great model"
    ),
]
```

Recommendations are filtered by `DeviceCapabilityService.recommendedModelSize()` based on available RAM.

## Cloud API Configuration

Cloud endpoints are persisted via SwiftData. Users configure them through `APIConfigurationView`, or you can create them programmatically:

```swift
let endpoint = APIEndpoint(
    name: "My OpenAI",
    provider: .openAI,
    baseURL: "https://api.openai.com",
    modelName: "gpt-4o-mini"
)
do {
    try endpoint.setAPIKey("sk-...")  // Stored in Keychain
} catch {
    // Surface `error.localizedDescription` in your settings UI — it already
    // maps known Keychain statuses (locked device, missing entitlement, etc.)
    // to a short user-facing sentence and appends the raw OSStatus for logs.
}
```

### Migrating from `Bool`-returning Keychain APIs

`KeychainService.store` / `.delete` and `APIEndpoint.setAPIKey` / `.deleteAPIKey`
used to return `Bool` and virtually no caller checked the result. They now
throw a typed `KeychainError` so failures can't be silently discarded.

```swift
// Before
if !KeychainService.store(key: key, account: id) { /* usually ignored */ }
endpoint.setAPIKey("sk-...")
endpoint.deleteAPIKey()

// After
try KeychainService.store(key: key, account: id)
try endpoint.setAPIKey("sk-...")
try endpoint.deleteAPIKey()

// Cleanup paths where "already gone" is fine stay terse
try? endpoint.deleteAPIKey()
```

Deleting a non-existent item is still non-throwing (`errSecItemNotFound` is
treated as success), so `tearDown` / `deinit` cleanup can keep its `try?`
idiom. For programmatic recovery, `KeychainError.osStatus` exposes the raw
code and `localizedDescription` is already user-friendly — there is no need
to pattern-match the enum for UI purposes.

## Prompt Templates

GGUF models require explicit chat formatting. BaseChatKit includes templates for:

- **ChatML** — `<|im_start|>user\n...<|im_end|>`
- **Llama 3** — `<|start_header_id|>user<|end_header_id|>\n\n...<|eot_id|>`
- **Mistral** — `[INST] ... [/INST]`
- **Alpaca** — `### Instruction:\n...\n### Response:`
- **Gemma** — `<start_of_turn>user\n...<end_of_turn>`
- **Phi** — `<|user|>\n...<|end|>`

Templates auto-detect from GGUF metadata when available. User content is sanitised to strip special tokens and prevent prompt injection.

## Security

See the [Security Model](Sources/BaseChatCore/BaseChatCore.docc/Articles/SecurityModel.md) DocC article for the full threat model, what BCK protects against, what remains your responsibility, and how to tune for stricter environments. A quick summary:

- API keys stored in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- Keys read just-in-time from Keychain rather than cached as long-lived properties; during an in-flight `URLSession` request the key bytes do exist in process memory as a Swift `String` and are not zeroized after use (see [docs/FIPS.md](docs/FIPS.md) §non-mitigations)
- Certificate pinning support via `PinnedSessionDelegate` — configure `pinnedHosts` with SPKI SHA-256 hashes; `api.openai.com` and `api.anthropic.com` fail closed if pin sets are missing/empty; custom hosts use platform trust by default or can be set to fail-closed via `BaseChatConfiguration.shared.customHostTrustPolicy = .requireExplicitPins`
- HTTPS enforced for non-localhost endpoints
- User content sanitised in prompt templates to prevent injection
- Sensitive data uses `privacy: .private` in os.Logger calls
- Error response bodies filtered before logging

For regulated-deployment evaluation (healthcare, federal-adjacent, finance),
see [docs/FIPS.md](docs/FIPS.md) — the honest answer to "are your cryptographic
primitives FIPS 140-3 validated?", with a complete inventory of the crypto
primitives BCK invokes and where the validation boundary actually sits.

## Binary Dependencies

`BaseChatBackends` includes two pre-built binary xcframeworks:

- **llama.swift** — wraps a pre-built llama.cpp xcframework. The binary is not compiled from source as part of your project. If you require a source-verified build, follow the [llama.swift build instructions](https://github.com/mattt/llama.swift) to compile your own xcframework.
- **mlx-swift** — Apple's MLX framework ships as a pre-built xcframework from [ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift). Source builds are supported via that upstream repo.

Both dependencies are pinned to specific tagged releases in `Package.swift`. Review `Package.resolved` to verify the exact versions in use.

## Example App

See the `Example/` directory for a complete demo app showing integration patterns.

```bash
cd Example
open BaseChatDemo.xcodeproj
```

## License

MIT License. See [LICENSE](LICENSE) for details.
