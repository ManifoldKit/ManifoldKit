# ManifoldKit

A modular SwiftUI framework for building chat interfaces powered by local and cloud LLMs on Apple platforms.

ManifoldKit provides a complete, production-ready chat UI with pluggable inference backends, model management, and SwiftData persistence. Drop it into your app, register backends, and you have a working chat interface.

**Built for production failure modes.** ManifoldKit is designed around the things that go wrong between a working demo and an App Store release:

- **Streaming resilience** — cloud backends retry the initial connection with backoff on retryable errors and preserve already-yielded output if a later failure occurs.
- **Latest-wins model handoff** — racing model loads can't corrupt active state. If the user taps model A, then model B before A finishes, A is discarded and B wins deterministically.
- **Memory admission and pressure handling** — `ModelLoadPlan` estimates resident + KV memory before a load commits and returns an `allow`/`warn`/`deny` verdict; `InferenceService.denyPolicy` decides whether to fail fast, warn and proceed, or hand off to a custom hook. The drop-in `ChatViewModel` stops generation and unloads the model on critical memory pressure.
- **Mock backend for app-level testing** — `MockInferenceBackend` implements the full streaming contract so your app's tests can exercise ManifoldKit without loading a real model.
- **Certificate pinning with fail-closed defaults** — `api.openai.com` and `api.anthropic.com` fail closed if pin sets are missing or empty; custom hosts use platform trust by default or can be hardened to fail-closed via `ManifoldConfiguration.shared.customHostTrustPolicy = .requireExplicitPins`.

For the exact source-backed contract, see [docs/RELIABILITY.md](docs/RELIABILITY.md).
See [docs/SCOPE_DECISION.md](docs/SCOPE_DECISION.md) for the scoping rationale behind the 0.6.0 release.

## Demo


<p align="center">
  <img src="Example/Screenshots/demo-macos.png" alt="ManifoldKit on macOS — chat with streaming response and session sidebar" width="58%">
  <img src="Example/Screenshots/demo-ios.png" alt="ManifoldKit on iOS — chat conversation on iPhone" width="36%">
</p>

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

- **Swift 6.1+** (`swift-tools-version: 6.1` in your `Package.swift`) — required for `.macOS(.v26)` / `.iOS(.v26)` platform entries. Using an older tools version produces `'v26' is unavailable` errors from `PackageDescription`.
- iOS 18+ / macOS 15+
- Apple Foundation Models require iOS 26+ / macOS 26+

ManifoldKit follows an **n-1 platform policy**: the current Apple OS release
and the one immediately before it. When Apple ships a new major OS each
September, both minimums are bumped by one. See
[CLAUDE.md → Platform policy](CLAUDE.md#platform-policy) for the rationale.

## How ManifoldKit compares to AnyLanguageModel

AnyLanguageModel is HuggingFace's Swift package. It mirrors Apple's `FoundationModels` API and exposes many providers behind a single protocol, so code written against Apple's built-in model API can target cloud and open-source models with minimal changes.

ManifoldKit and AnyLanguageModel occupy adjacent niches. AnyLanguageModel optimizes for provider coverage and API familiarity — if you need "any LLM behind one protocol that looks like `FoundationModels`," it's the simpler choice. ManifoldKit optimizes for production reliability and drop-in chat UI — if you need "a chat framework that survives real failures and ships a working `ChatView` + `SessionListView` + `ModelManagementSheet` on day one," ManifoldKit is designed for that. The two aren't competing on the same axis; pick the one whose axis matches the problem you're solving.

## Architecture

ManifoldKit ships **14 libraries**, **2 executables**, and **1 macro plugin**. The
core runtime stack is six libraries; the rest are optional sibling modules and
test-only targets gated behind SwiftPM traits.

The diagram below shows the dependency graph for the targets a typical adopter
cares about. Arrows point from a consumer toward its dependency:

```
ManifoldVoice              ManifoldUIModelManagement
(Voice trait)              (model browser + endpoint UI)
        │                          │
        └────────► ManifoldUI ◄────┘
                       │
                       ▼
            ManifoldPersistenceSwiftData
            (SwiftData schema, ManifoldBootstrap)
                       │
                       ▼
                 ManifoldRuntime
                 (Ports, use cases, ConversationRuntime)
                       │
                       ▼
                ManifoldInference  ◄─── ManifoldBackends
                (Protocols, services)   (MLX, llama.cpp,
                       ▲                 Foundation, Cloud)
                       │
                ManifoldMCP
                (MCP descriptors, client, tool bridge)
```

`ManifoldBackends` and `ManifoldMCP` depend on `ManifoldInference` **directly**,
not via `ManifoldRuntime` — that keeps both modules free of SwiftData so
host apps can wire backends or MCP into a non-SwiftData runtime.

### Core runtime targets

- **ManifoldInference** — Inference orchestration. Protocols, models, and services for model loading, generation, context windows, prompt assembly, compression, tokenizers, and capability detection. No SwiftData. No ML dependencies. This is the integration point for custom backends and the minimum target for apps that bring their own persistence and UI.
- **ManifoldMCP** — Model Context Protocol client surface: descriptors, auth/transport types, connection lifecycle (`MCPClient`), and tool bridge (`MCPToolSource`) for registering MCP tools with `ToolRegistry`. Depends on `ManifoldInference` directly.
- **ManifoldRuntime** — Persistence-agnostic ports (`EndpointStore`, `SamplerPresetStore`, `BenchmarkCache`), use cases (`PromptContextPipeline`, `ChatExportService`, `SessionListService`), session-list orchestration, `ConversationEvent` observability, and the shared turn loop `ConversationRuntime`. No SwiftData, no SwiftUI, no Observation — apps that bring their own persistence stop here and supply their own adapters.
- **ManifoldPersistenceSwiftData** — SwiftData schema, `@Model` types (`ChatMessage`, `ChatSession`, `SamplerPreset`, `APIEndpoint`, `ModelBenchmarkCache`), `ModelContainerFactory`, adapter implementations of the runtime ports, and the full-stack `ManifoldBootstrap` entry point.
- **ManifoldBackends** — Concrete inference backend implementations. Depends on `ManifoldInference` (not `ManifoldRuntime` or `ManifoldPersistenceSwiftData`), so backends stay free of SwiftData. Pulls MLX, llama.cpp, and cloud APIs.
- **ManifoldUI** — SwiftUI chat views and view models. Depends on `ManifoldRuntime` and `ManifoldInference`. Stays a chat-only consumer surface — never imports `ManifoldBackends` or `ManifoldUIModelManagement`. Cloud endpoint state crosses the UI boundary as SwiftData-free `APIEndpointRecord` values supplied by an `EndpointStore`.

### Optional sibling modules

- **ManifoldUIModelManagement** — Model browser, download UI, storage management, and cloud-endpoint editors (`APIConfigurationView`). Depends on `ManifoldUI`. The reverse edge is broken by closure-injecting `APIConfigurationView` via a `@ViewBuilder apiConfiguration:` parameter on `ChatView` — see [Building a Chat UI](Sources/ManifoldUI/ManifoldUI.docc/Articles/BuildingAChatUI.md) for the canonical wiring.
- **ManifoldHuggingFace** *(trait: `HuggingFace`, default-on)* — HuggingFace Hub search plus background download / validation services.
- **ManifoldAnyLanguageModelBridge** *(trait: `AnyLanguageModel`, default-off)* — Thin `InferenceBackend` adapter over HuggingFace's `AnyLanguageModel`.
- **ManifoldVoice** *(trait: `Voice`, default-off)* — Optional speech-recognition / synthesis adapters and voice composer UI. Depends on `ManifoldUI` so hosts can opt in without adding a back-edge into the base chat surface.
- **ManifoldServer** *(trait: `Server`, default-off, executable)* — OpenAI-compatible HTTP server executable for exposing a selected `ManifoldInference` backend over `/v1/chat/completions`. Validates unsupported request capabilities before dispatch and returns clear `invalid_request_error` responses with `unsupported_capability` codes. Trait-gated; add `--traits Server` to `swift run`/`swift build`/`swift test` commands.
- **ManifoldTools** *(trait: `Tools`, default-off)* + **`manifold-tools`** executable — End-to-end tool-calling validation harness and CLI for exercising `ToolRegistry` against real backends.
- **ManifoldAppIntents** *(trait: `AppIntents`, default-off)* — Bridge between Apple `AppIntent` types and ManifoldKit's `ToolDefinition`, so iOS/macOS app intents can be exposed as tools to the inference layer.
- **ManifoldFuzz** *(trait: `Fuzz`, default-off)* + **`fuzz-chat`** executable — Fuzzing harness that drives real backends with adversarial inputs. Run via `scripts/fuzz.sh`.
- **`@ToolSchema` macro** *(trait: `Macros`, default-off)* — `ManifoldMacrosPlugin` synthesises `static var jsonSchema` on `Decodable` tool-argument structs. The plugin and its `swift-syntax` dependency (~647 source files) are gated behind the `Macros` trait so default builds skip the swift-syntax compile cost. Add `--traits Macros` to `swift build`/`swift test` invocations that use `@ToolSchema`.

### Test-only targets

`ManifoldTestSupport` ships shared mocks and fakes (`MockInferenceBackend`,
`CharTokenizer`, `makeInMemoryContainer`, etc.) for app-level testing.
`ManifoldMLXIntegrationTests` runs real MLX model E2E tests under Xcode (Metal
shaders unavailable to `swift test`); see `scripts/test-mlx-integration.sh`.

### Turn-loop orchestration

`ConversationRuntime` (`Sources/ManifoldRuntime/Services/ConversationRuntime.swift`)
is the **single turn loop** for chat. It owns `send`, `regenerate`, `edit`,
`cancel`, and `branch` — there is no alternative path. Host apps get a
configured `ConversationRuntime` from `ManifoldBootstrap` (exposed as
`bootstrap.conversationRuntime`) and forward user actions to it via
`ChatViewModel.configure(runtime:)` or `ChatViewModel.configure(conversationRuntime:)`.
Custom adopters wiring their own runtime stack should still route every user
turn through `ConversationRuntime` rather than calling `InferenceService`
directly — anything else regresses cancellation, regenerate semantics, and
session-touch observability. See
[CONTRIBUTING.md → Architecture invariants](CONTRIBUTING.md#architecture-invariants)
for the full list of dependency rules the lint enforces.

## Quick Start

### 1. Add the package

```swift
.package(url: "https://github.com/roryford/ManifoldKit.git", from: "0.26.0")
```

Most apps add a single product — the `ManifoldKit` umbrella, which re-exports
the runtime, persistence, backends, UI, and inference surface in one import:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "ManifoldKit", package: "ManifoldKit"),
])
```

Use the individual products (`ManifoldRuntime`, `ManifoldPersistenceSwiftData`,
`ManifoldBackends`, `ManifoldUI`, …) when you need finer-grained dependency
control — for example, a UI-only target that doesn't link `ManifoldBackends`.
Specialised modules (`ManifoldUIModelManagement`, `ManifoldMCP`, `ManifoldVoice`,
`ManifoldHuggingFace`, `ManifoldAppIntents`) stay opt-in: add them explicitly
when you need that surface, since they're not in the umbrella.

### 2. Build modes

ManifoldKit ships four pre-blessed build profiles keyed by the network surface a binary exposes. Backends are gated behind Swift package traits so consumers in regulated or air-gapped environments can compile out everything that touches the network.

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
    url: "https://github.com/roryford/ManifoldKit.git",
    from: "0.26.0",
    traits: [
        .trait(name: "MLX"),
        .trait(name: "Llama"),
        .trait(name: "Ollama"),       // remove for local-only builds
        .trait(name: "CloudSaaS"),    // add to enable Claude / OpenAI
    ]
)
```

`CloudSaaS` and `Ollama` are opt-in. `HuggingFace` is default-on for backwards compatibility; drop it from `traits:` (or start from `--disable-default-traits`) to remove the stock Hub browser/downloader from the build graph. `AnyLanguageModel` is also opt-in and only needed when you want the bridge target.

> **Note on `--disable-default-traits`:** this flag applies to the package where it is passed. If your consumer package declares no traits of its own, SwiftPM will error with `"Disabled default traits by command-line trait configuration on package 'X' that declares no traits"`. Use the flag when building ManifoldKit directly or when your package declares its own traits; otherwise control the ManifoldKit trait set via the `traits:` array in your `Package.swift` dependency declaration.

**Foundation Models only (App Store-lean build)**

If your app targets Apple's built-in Foundation model exclusively (iOS 26+ /
macOS 26+), use the `FoundationOnly` trait. This excludes MLX (~100 MB
checkout) and LlamaSwift (~563 MB xcframework), keeping the ManifoldKit overhead
under 5 MB — enforced by the `foundation-only-build` CI gate. Recommended
for indie iOS / macOS apps that ship through the App Store and only need
Apple Foundation Models.

```swift
.package(
    url: "https://github.com/roryford/ManifoldKit.git",
    from: "0.26.0",
    traits: ["FoundationOnly"]   // overrides the MLX/Llama/HuggingFace defaults
)
```

The `FoundationOnly` trait is mutually exclusive with `MLX`, `Llama`, and
`HuggingFace` — when you pass `traits: ["FoundationOnly"]`, SwiftPM treats
that as the full enabled-trait set and the heavy defaults drop out. See
[`docs/AppStoreSubmission.md`](docs/AppStoreSubmission.md) for the full
submission checklist (encryption export, privacy manifest, ATS, bundle
sizes per profile).

Equivalent legacy form (still supported, before the named trait existed):

```swift
.package(
    url: "https://github.com/roryford/ManifoldKit.git",
    from: "0.26.0",
    traits: []   // disables MLX, Llama, HuggingFace defaults
)
```

Then at app launch:

```swift
if #available(macOS 26, iOS 26, *) {
    vm.foundationModelProvider = { FoundationBackend.isAvailable }
    vm.loadFoundationModelIfAvailable()
}
```

No `--disable-default-traits` flag is needed in your `swift build` command — the trait array already communicates your intent to SPM.

For example, a cloud-only consumer can keep the chat UI and local-model loaders out of the download path:

```swift
.package(
    url: "https://github.com/roryford/ManifoldKit.git",
    from: "0.26.0",
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
import ManifoldInference

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

If you already depend on `ManifoldBackends`, the same data is also available via `DefaultBackends.compiledBackends`.

`CompiledBackends.current` describes what's compiled into the binary based on SwiftPM traits — it answers "could this build ever support backend X?" `FrameworkCapabilityService.enabledBackends` describes what's actually been registered at runtime — "is backend X usable right now?" Gate UI affordances on `enabledBackends` unless you specifically need the compile-time view (e.g., to hide a download tab in a SaaS-only build).

### 2.1 Optional MCP traits

`ManifoldMCP` ships as its own module (`import ManifoldMCP`). Package traits expose MCP-specific configuration:

- `MCP` — explicit MCP opt-in marker for consumer manifests.
- `MCPBuiltinCatalog` — enables built-in `MCPCatalog` descriptors (`notion`, `linear`, `github`).

```swift
.package(
    url: "https://github.com/roryford/ManifoldKit.git",
    from: "0.26.0",
    traits: [
        .trait(name: "MCP"),
        .trait(name: "MCPBuiltinCatalog"), // optional: only if you use MCPCatalog
    ]
)
```

Quick checks:

```bash
scripts/test.sh --filter ManifoldMCPTests --disable-default-traits --traits MCP --skip-update
scripts/test.sh --filter ManifoldMCPTests --disable-default-traits --traits MCP,MCPBuiltinCatalog --skip-update
```

### 2.2 ManifoldServer

`ManifoldServer` runs an OpenAI-compatible local HTTP surface backed by ManifoldKit inference. The server target and its `Hummingbird` dependency are trait-gated behind `Server` (default-off), so add `--traits Server` to every build/run/test command:

```bash
swift build --product ManifoldServer --disable-default-traits --traits Server,Ollama
swift run --disable-default-traits --traits Server,Ollama ManifoldServer -- \
  --backend ollama --model llama3.2 --host 127.0.0.1 --port 8080 \
  --api-key local-dev --cors-origin http://localhost:3000 --metrics
```

Point OpenAI-compatible clients at `http://127.0.0.1:8080/v1` and send `Authorization: Bearer local-dev`. The server exposes `GET /health`, `GET /v1/models`, `POST /v1/chat/completions`, streaming SSE when `stream: true`, and `GET /metrics` when `--metrics` is enabled. CORS is disabled by default; use `--cors-origin <origin>` for a single trusted browser origin or `--unsafe-cors` only for local development.

Backend availability follows SwiftPM traits: MLX requires `--traits MLX` plus `--model-path` or `--model`, llama.cpp requires `--traits Llama` plus a GGUF `--model-path`, Ollama requires `--traits Ollama`, and Apple Foundation Models require macOS/iOS 26 at runtime. Cloud SaaS loading is intentionally not implemented in the v1 server.

### 2.3 Optional voice

`ManifoldVoice` is an opt-in module for speech input/output. It plugs into
`ChatView` through the `composerAccessory:` seam, so `ManifoldUI` stays free of
audio-framework dependencies while hosts can mount a voice accessory above the
stock `ChatInputBar`.

```swift
 .package(
     url: "https://github.com/roryford/ManifoldKit.git",
     from: "0.26.0",
     traits: [
         .trait(name: "Voice"),
     ]
 )
```

```swift
import ManifoldUI
import ManifoldVoice

@State private var voice = VoiceConversationController(
    wakeWordDetector: AppleWakeWordDetector(wakeWords: ["hey base chat"])
)

ChatView(
    showModelManagement: $isModelManagementPresented,
    composerAccessory: { VoiceComposerAccessory(controller: voice) }
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

### 2.4 Trait reference

The full list of SwiftPM traits, derived from `Package.swift`. Defaults
(`MLX`, `Llama`, `HuggingFace`) are enabled when callers don't pass
`--disable-default-traits` or a custom `traits:` array.

| Trait | Default? | Gates / pulls in |
|-------|----------|-------------------|
| `MLX` | Yes | `MLXBackend` (Apple Silicon, mlx-swift xcframework). |
| `Llama` | Yes | `LlamaBackend` (GGUF via mattt/llama.swift xcframework). |
| `HuggingFace` | Yes | `ManifoldHuggingFace` Hub search, browse, and background download/validation. |
| `Ollama` | No | `OllamaBackend` (self-hosted HTTP at `localhost:11434` or custom host). |
| `CloudSaaS` | No | `OpenAIBackend`, `ClaudeBackend`, and any third-party SaaS code paths. |
| `MCP` | No | `ManifoldMCP` opt-in marker for consumer manifests. |
| `MCPBuiltinCatalog` | No | Built-in `MCPCatalog` descriptors (`notion`, `linear`, `github`). |
| `AnyLanguageModel` | No | `ManifoldAnyLanguageModelBridge` adapter over HuggingFace's `AnyLanguageModel`. |
| `Voice` | No | `ManifoldVoice` speech I/O adapters and voice composer accessory. |
| `Tools` | No | `ManifoldTools` tool-calling validation harness and `manifold-tools` CLI. |
| `AppIntents` | No | `ManifoldAppIntents` AppIntent ↔ ToolDefinition bridge. |
| `Server` | No | `ManifoldServer` executable + Hummingbird HTTP dependency. |
| `Macros` | No | `ManifoldMacrosPlugin` (`@ToolSchema`) + swift-syntax (~647 source files). |
| `Fuzz` | No | Real backends in `fuzz-chat` for `scripts/fuzz.sh`. Not needed for `swift test`. |
| `FoundationOnly` | No | App Store-lean marker. Overrides `MLX`/`Llama`/`HuggingFace` defaults; pulls no heavy dependencies. See [`docs/AppStoreSubmission.md`](docs/AppStoreSubmission.md). |

`Package.swift` is the authoritative source — add `--list-traits` to a
`swift package` invocation if you suspect this table has drifted.

### 2.5 Bring your own UI

If you want host-owned SwiftUI views instead of `ChatView`, depend only on
`ManifoldInference` plus the backends you want. This keeps SwiftData,
`ManifoldRuntime`, `ManifoldUI`, and model-management UI out of your app graph.

```swift
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "MyChatApp",
    platforms: [.iOS(.v18), .macOS(.v15)],
    dependencies: [
        .package(
            url: "https://github.com/roryford/ManifoldKit.git",
            from: "0.26.0",
            traits: [
                .trait(name: "MLX"),
                .trait(name: "Llama"),
                // Add CloudSaaS or Ollama only if your UI exposes those providers.
            ]
        )
    ],
    targets: [
        .target(
            name: "MyChatApp",
            dependencies: [
                .product(name: "ManifoldInference", package: "ManifoldKit"),
                .product(name: "ManifoldBackends", package: "ManifoldKit"),
            ]
        )
    ]
)
```

Own the observable state in your app, register the compiled backends once, load a
`ModelInfo`, and stream `GenerationEvent.token` values into your transcript:

```swift
import Observation
import SwiftUI
import ManifoldInference
import ManifoldBackends

@MainActor
@Observable
final class HostChatStore {
    var transcript: [(role: String, content: String)] = []
    var draft = ""
    var errorMessage: String?

    private let inference = InferenceService()

    init() {
        DefaultBackends.register(with: inference)
    }

    func loadFoundationIfAvailable() async {
        guard #available(iOS 26, macOS 26, *), FoundationBackend.isAvailable else { return }

        do {
            try await inference.loadModel(from: .builtInFoundation, plan: .cloud())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func send() async {
        let prompt = draft
        draft = ""
        transcript.append(("user", prompt))
        transcript.append(("assistant", ""))

        do {
            let stream = try inference.generate(messages: transcript)
            for try await event in stream {
                if case .token(let text) = event {
                    transcript[transcript.count - 1].content += text
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct HostChatView: View {
    @State private var store = HostChatStore()

    var body: some View {
        VStack {
            List(store.transcript, id: \.content) { message in
                Text("\(message.role): \(message.content)")
            }
            TextField("Message", text: $store.draft)
                .onSubmit { Task { await store.send() } }
        }
        .task { await store.loadFoundationIfAvailable() }
    }
}
```

ManifoldKit's view models and services use Swift Observation (`@Observable`),
not Combine `ObservableObject`. In SwiftUI, store them in `@State` and inject
them with `.environment(value)`, then read them with `@Environment(Type.self)`.
Use `ObservableObject` only in a host-owned adapter when you must bridge to
legacy Combine-based views.

### 3. Create the runtime at app startup

With the `ManifoldKit` umbrella, `import ManifoldKit` covers
`ManifoldRuntime`, `ManifoldPersistenceSwiftData`, `ManifoldBackends`,
`ManifoldUI`, and `ManifoldInference` in one line:

```swift
import SwiftUI
import SwiftData
import ManifoldKit
import ManifoldUIModelManagement   // model browser/download UI is opt-in

@main
struct MyApp: App {
    private let runtime: ManifoldBootstrap
    @State private var chatViewModel: ChatViewModel
    @State private var sessionManager: SessionManagerViewModel
    @State private var modelManagement: ModelManagementViewModel

    init() {
        let runtime = try! ManifoldBootstrap(
            configuration: ManifoldConfiguration(
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

Apps that need finer-grained dependency control can swap the umbrella for the
individual product imports (`import ManifoldRuntime`, `import ManifoldPersistenceSwiftData`,
`import ManifoldInference`, `import ManifoldBackends`, `import ManifoldUI`).
The umbrella exists so most consumers don't need to.

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

Pre-runtime ManifoldKit apps often wired persistence from a root view's `.task`
or `.onAppear` and called `chatViewModel.configure(persistence:)` once stores
were available. A runtime bootstrap collapses that into one value created in
`App.init()` while keeping ManifoldUI behind runtime ports.

**Before** — late-binding from a view lifecycle:

```swift
import SwiftUI
import ManifoldInference
import ManifoldRuntime
import ManifoldUI

@main
struct LegacyApp: App {
    @State private var chatViewModel = ChatViewModel()
    private let stores = AppStores.open()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(chatViewModel)
                .task {
                    chatViewModel.configure(persistence: stores)
                }
        }
    }
}
```

**After** — runtime-driven bootstrap in `App.init()`:

```swift
import SwiftUI
import SwiftData
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldInference
import ManifoldUI

@main
struct ModernApp: App {
    private let runtime: ManifoldBootstrap
    @State private var chatViewModel: ChatViewModel
    @State private var sessionManager: SessionManagerViewModel

    init() {
        let runtime = try! ManifoldBootstrap(
            configuration: ManifoldConfiguration(
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

Both view models must be configured from the runtime. `ChatViewModel.configure(runtime:)` wires chat persistence, endpoint loading, and the shared `ConversationRuntime`; `SessionManagerViewModel.configure(runtime:)` wires persistence and diagnostics for the session list. Skipping the session-manager configuration leaves it on a nil-persistence path that fails on first save. See the MinimalExample app for the canonical wiring.

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

Keep `configure(persistence:)` for adopters that provide custom
`SessionStore` / `MessageStore` implementations (e.g. an in-memory test fixture
or a non-SwiftData backing store). Construct `ChatViewModel` and
`SessionManagerViewModel` directly and call `configure(persistence:)`, or wrap
the stores in your own `ChatRuntimeBootstrap` when you also want runtime
endpoint and diagnostics wiring.

## Supported Model Types

| Type | Backend | Format | Source | Image input |
|------|---------|--------|--------|-------------|
| GGUF | `LlamaBackend` (llama.cpp) | Single `.gguf` file | HuggingFace, local | Not yet; tracked in [#416](https://github.com/roryford/ManifoldKit/issues/416) |
| MLX | `MLXBackend` (mlx-swift) | Directory with `config.json` + `.safetensors` | HuggingFace, local | Vision models only |
| Foundation | `FoundationBackend` | `ModelInfo.builtInFoundation` (built-in, no download) | Apple Intelligence | No public FoundationModels image-input API yet |
| OpenAI | `OpenAIBackend` | Cloud API | api.openai.com | Vision-capable models |
| Claude | `ClaudeBackend` | Cloud API | api.anthropic.com | Vision-capable models |
| Ollama | `OpenAIBackend` | Local API | localhost:11434 | Vision-capable OpenAI-compatible models |
| LM Studio | `OpenAIBackend` | Local API | localhost:1234 | Vision-capable OpenAI-compatible models |

### Model storage scoping

`ModelStorageService()` stores and discovers local models under
`<Application Support>/<ManifoldConfiguration.shared.bundleIdentifier>/<modelsDirectoryName>`
by default. This keeps multiple ManifoldKit-based apps on the same machine from
seeing each other's downloaded models. Hosts that intentionally share a model
pool can opt in by passing an explicit directory, for example
`ModelStorageService(baseDirectory: sharedModelsDirectory)`.

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
| `ManifoldBootstrap` | SwiftData-backed bootstrap — installs configuration, builds persistence adapters, and holds shared services |
| `ConversationRuntime` | Single turn loop for send/regenerate/edit/cancel/branch, with `ConversationEvent` hooks for token usage and recoverable session-touch failures |
| `BackgroundDownloadManager` | Background model downloads with progress and validation (`ManifoldHuggingFace`) |
| `ModelStorageService` | Local model file discovery and storage paths |
| `DeviceCapabilityService` | RAM/chipset queries for model size recommendations |
| `KeychainService` | Secure API key storage |
| `ContextWindowManager` | Token estimation and message trimming |
| `HuggingFaceService` | HuggingFace Hub API (search, model info, download URLs) (`ManifoldHuggingFace`) |

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
| `EndpointStore` | Storage-neutral CRUD for cloud endpoint `APIEndpointRecord` values |
| `HuggingFaceServiceProtocol` | Abstraction for HuggingFace Hub operations |

## Tool Calling

> [!WARNING]
> The `@ToolSchema` macro is gated behind the `Macros` SwiftPM trait (default-off,
> see `Package.swift`). Default builds skip swift-syntax (~647 source files) and
> `@ToolSchema` is invisible. To use the macro, opt in with `--traits Macros` (or
> add `.trait(name: "Macros")` to the `traits:` array on your `.package(...)`
> entry). Without the trait, declare `JSONSchemaValue` by hand on
> `ToolDefinition.parameters`.

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
import ManifoldInference
import ManifoldMCP

let client = MCPClient()
let source = try await client.connect(descriptor)
await source.register(in: registry)
```

For a complete walkthrough (descriptor setup, lifecycle, and built-in catalog), see `Sources/ManifoldMCP/ManifoldMCP.docc/Articles/MCPGettingStarted.md`.

## Custom Backends

Implement `InferenceBackend` and register it. The protocol takes a precomputed
`ModelLoadPlan` so the caller's memory-admission verdict and effective context
size flow through to the backend instead of being recomputed:

```swift
class MyBackend: InferenceBackend, @unchecked Sendable {
    var isModelLoaded = false
    var isGenerating = false
    var capabilities: BackendCapabilities { /* ... */ }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws { /* ... */ }
    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig)
        throws -> GenerationStream { /* ... */ }
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

`plan.effectiveContextSize` carries the resolved context window and `plan.verdict`
is one of `.allow` / `.warn` / `.deny`. Callers must check the verdict before
invoking `loadModel`; conformers may rely on that precondition.

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

Cloud endpoints flow through storage-neutral `APIEndpointRecord` values.
`APIConfigurationView` persists records through the runtime's `EndpointStore`;
the shipped SwiftData bootstrap converts those records to `APIEndpoint` rows in
its adapter. You can create records programmatically through the same port:

```swift
let endpoint = APIEndpointRecord(
    name: "My OpenAI",
    provider: .openAI,
    baseURL: "https://api.openai.com",
    modelName: "gpt-4o-mini"
)
do {
    try KeychainService.store(key: "sk-...", account: endpoint.keychainAccount)
    try await runtime.endpointStore.insertEndpoint(endpoint)
} catch {
    // Surface `error.localizedDescription` in your settings UI — it already
    // maps known Keychain statuses (locked device, missing entitlement, etc.)
    // to a short user-facing sentence and appends the raw OSStatus for logs.
}
```

### Migrating from `Bool`-returning Keychain APIs

`KeychainService.store` / `.delete` and the SwiftData `APIEndpoint.setAPIKey` /
`.deleteAPIKey` helpers used to return `Bool` and virtually no caller checked
the result. They now throw a typed `KeychainError` so failures can't be silently
discarded.

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

GGUF models require explicit chat formatting. ManifoldKit includes templates for:

- **ChatML** — `<|im_start|>user\n...<|im_end|>`
- **Llama 3** — `<|start_header_id|>user<|end_header_id|>\n\n...<|eot_id|>`
- **Mistral** — `[INST] ... [/INST]`
- **Alpaca** — `### Instruction:\n...\n### Response:`
- **Gemma** — `<start_of_turn>user\n...<end_of_turn>`
- **Phi** — `<|user|>\n...<|end|>`

Templates auto-detect from GGUF metadata when available. User content is sanitised to strip special tokens and prevent prompt injection.

## Security

See [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) for the full threat model, what ManifoldKit protects against, what remains your responsibility, and how to tune for stricter environments. A quick summary:

- API keys stored in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`
- Keys read just-in-time from Keychain rather than cached as long-lived properties; during an in-flight `URLSession` request the key bytes do exist in process memory as a Swift `String` and are not zeroized after use (see [docs/FIPS.md](docs/FIPS.md) §non-mitigations)
- Certificate pinning support via `PinnedSessionDelegate` — configure `pinnedHosts` with SPKI SHA-256 hashes; `api.openai.com` and `api.anthropic.com` fail closed if pin sets are missing/empty; custom hosts use platform trust by default or can be set to fail-closed via `ManifoldConfiguration.shared.customHostTrustPolicy = .requireExplicitPins`
- HTTPS enforced for non-localhost endpoints
- User content sanitised in prompt templates to prevent injection
- Sensitive data uses `privacy: .private` in os.Logger calls
- Error response bodies filtered before logging

For regulated-deployment evaluation (healthcare, federal-adjacent, finance),
see [docs/FIPS.md](docs/FIPS.md) — the honest answer to "are your cryptographic
primitives FIPS 140-3 validated?", with a complete inventory of the crypto
primitives ManifoldKit invokes and where the validation boundary actually sits.

## Binary Dependencies

`ManifoldBackends` includes two pre-built binary xcframeworks:

- **llama.swift** — wraps a pre-built llama.cpp xcframework. The binary is not compiled from source as part of your project. If you require a source-verified build, follow the [llama.swift build instructions](https://github.com/mattt/llama.swift) to compile your own xcframework.
- **mlx-swift** — Apple's MLX framework ships as a pre-built xcframework from [ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift). Source builds are supported via that upstream repo.

Both dependencies are pinned to specific tagged releases in `Package.swift`. Review `Package.resolved` to verify the exact versions in use.

## Troubleshooting

### "XCFramework Info.plist not found" or "workspace-state.json desync"

This typically happens after changing the active trait set (e.g. switching from the default MLX/Llama traits to traits-disabled, or vice versa). SwiftPM caches binary-target paths in `.build/workspace-state.json` and does not automatically re-resolve stale paths on subsequent builds. A partial cleanup like `rm -rf .build/artifacts/` is insufficient.

Run the recovery script:

```bash
scripts/clean-build.sh
```

This removes the entire `.build` directory and runs `swift package resolve` before your next build.

### Stale "No such module 'ManifoldPersistenceSwiftData'" in the editor

SourceKit can retain stale module-not-found diagnostics from a previous trait-set build even while `swift build` succeeds cleanly. The editor's index does not flush automatically when the trait set changes.

**Workaround:** restart the SourceKit language server. In Xcode: *Product → Clean Build Folder*, then reopen the file. In VS Code with Swift extension: run "Swift: Restart SourceKit-LSP" from the command palette (⇧⌘P). The false diagnostic disappears after the language server re-indexes with the current trait set.

If restarting the language server is insufficient, run `scripts/clean-build.sh` and reopen the project.

For non-destructive investigation, see `docs/SOURCEKIT_DIAGNOSTICS.md` and run:

```bash
scripts/sourcekit-stale-module-diagnostics.sh
```

## Example App

See the `Example/` directory for a complete demo app showing integration patterns.

```bash
cd Example
open ManifoldDemo.xcodeproj
```

## Migrating from BaseChatKit

This package was renamed from `BaseChatKit` to `ManifoldKit` in v0.20. The old GitHub URL `github.com/roryford/BaseChatKit` redirects to `roryford/ManifoldKit`, but for clarity:

- Update SPM dependencies: `.package(url: "https://github.com/roryford/ManifoldKit.git", from: "0.26.0")`
- Update imports: `import BaseChatKit` → `import ManifoldKit` (and similarly for sub-modules — `BaseChatInference` → `ManifoldInference`, etc.)
- Renamed public types: `BaseChatBootstrap` → `ManifoldBootstrap`, `BaseChatConfiguration` → `ManifoldConfiguration`, `BaseChatSchemaV3/4/5` → `ManifoldSchemaV3/4/5`, `BaseChatMigrationPlan` → `ManifoldMigrationPlan`, `BaseChatBackgroundTaskIdentifiers` → `ManifoldBackgroundTaskIdentifiers`
- **BREAKING — local SwiftData stores reset.** SwiftData persists fully-qualified `@Model` type names; renaming the schema namespace orphans existing on-disk stores. Apps upgrading from 0.19.x will create fresh databases on first launch. We chose this clean break over preserving data with `@Model.originalName` because v0.20 is pre-1.0.
- Cache directories `~/Library/Caches/BaseChatKit/` and `~/Library/Application Support/BaseChatKit/` are also orphaned; users get fresh state.
- Background-task identifiers `com.basechatkit.background.*` → `com.manifoldkit.background.*` — apps must update `BGTaskSchedulerPermittedIdentifiers` in Info.plist.

## License

MIT License. See [LICENSE](LICENSE) for details.
