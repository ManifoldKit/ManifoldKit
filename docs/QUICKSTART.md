# ManifoldKit Quickstart

A one-page tutorial for getting from "empty SwiftUI project" to "working chat UI" in under five minutes. If you already have a working bootstrap, jump to [Customizing backends](#customizing-backends) or [Customizing storage](#customizing-storage).

> If you're building a CLI, headless service, or non-SwiftUI app, see [`QUICKSTART-CLI.md`](QUICKSTART-CLI.md) — it has compile-tested `Package.swift` + `main.swift` examples for Foundation Models, local GGUF via Llama, and Ollama / OpenAI-compatible cloud endpoints.

## Prerequisites

- Xcode 16+ on macOS, or Swift 6.1+ toolchain. ManifoldKit's own `Package.swift` declares `// swift-tools-version: 6.1` and platforms `.iOS(.v18)` / `.macOS(.v15)`; consumer packages should match (or go higher) to avoid SwiftPM version-resolution churn.
- A SwiftUI app target on iOS 18+ / macOS 15+ (Apple Foundation Models require iOS 26+ / macOS 26+).
- Familiarity with SwiftUI's `App` protocol and `@State`. No prior knowledge of MLX, llama.cpp, MCP, or any specific backend is assumed.

## Install

Add ManifoldKit to your `Package.swift` (or Xcode's *Package Dependencies*):

```swift
.package(
    url: "https://github.com/roryford/ManifoldKit.git",
    from: "0.43.0" // x-release-please-version
)
```

Then depend on the `ManifoldKit` umbrella product from your app target:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "ManifoldKit", package: "ManifoldKit"),
])
```

The umbrella re-exports `ManifoldRuntime`, `ManifoldPersistenceSwiftData`, `ManifoldBackends`, `ManifoldUI`, and `ManifoldInference` so one `import ManifoldKit` covers the common surface.

## Hello World

`ManifoldKit.quickStart()` builds the SwiftData container, registers the compiled-in backends, and wires up a `ChatViewModel` in one async call. Errors normalise to [`ManifoldKitError`](../Sources/ManifoldInference/ManifoldKitError.swift).

```swift
import SwiftUI
import SwiftData
import ManifoldKit

@main
struct MyChatApp: App {
    @State private var result: QuickStartResult?
    @State private var error: ManifoldKitError?
    @State private var showModelManagement = false

    var body: some Scene {
        WindowGroup {
            if let result {
                ChatView(showModelManagement: $showModelManagement)
                    .environment(result.viewModel)
                    .modelContainer(result.bootstrap.modelContainer)
            } else if let error {
                ContentUnavailableView("Failed to start", systemImage: "exclamationmark.triangle", description: Text(error.errorDescription ?? ""))
            } else {
                ProgressView().task {
                    do { result = try await ManifoldKit.quickStart() }
                    catch let e as ManifoldKitError { error = e }
                    catch { self.error = .from(error) }
                }
            }
        }
    }
}
```

Run the app. `quickStart()` will compile, launch, and render a usable composer — but the chat will be inert until a backend is selected. See [First-launch backend selection](#first-launch-backend-selection) for the next step.

> **Session bootstrap.** `quickStart()` auto-creates an initial empty `ChatSessionRecord` and activates it on first launch when the persistent store has no sessions yet, so `ChatView`'s composer is enabled the moment the view appears. On subsequent launches the most-recent existing session is selected. Hosts that need finer control over the initial session (custom title, system prompt, restoring from a deep link) can drop down to `ManifoldBootstrap.build(...)` directly and seed through the canonical composite accessor `bootstrap.persistenceStores` before constructing the view model — `quickStart()` only auto-creates when the store is *empty*, so seeding one session first opts out cleanly. The full session-management surface (list sidebar, create/delete/rename) lives on `SessionManagerViewModel` — see the [Building a Chat UI](../Sources/ManifoldUI/ManifoldUI.docc/Articles/BuildingAChatUI.md) DocC article for the worked example.

```swift
import ManifoldKit

@main
struct SeedSessionExample {
    @MainActor
    static func main() async throws {
        let (progress, task) = ManifoldBootstrap.build(
            configuration: ManifoldConfiguration(
                appName: "My Chat",
                bundleIdentifier: "com.example.mychat"
            )
        )
        for await _ in progress { }
        let bootstrap = try await task.value

        let stores: any SessionStore & MessageStore = bootstrap.persistenceStores
        try await stores.insertSession(ChatSessionRecord(title: "Inbox"))
    }
}
```

`persistenceStores` is the `SessionStore & MessageStore` handle itself — call `insertSession(_:)`, `fetchSessions()`, or `fetchMessages(for:)` on it directly. There is no `.sessionStore` / `.messageStore` sub-property pair to drill into.

## First-launch backend selection

`quickStart()` registers every compiled-in backend with the inference service, but **it does not pick one for you**. The composer is enabled (a session exists), but no model is loaded — `ChatViewModel.isModelLoaded` is `false`, the composer placeholder reads "No model loaded", and the empty-state surfaces a "Select Model" button that flips the `showModelManagement` binding (see [`showModelManagement` binding](#showmodelmanagement-binding) below — by itself the binding doesn't present anything).

This section shows the three documented paths to get a model loaded on first launch.

### What "available immediately" actually means

On macOS 26 / iOS 26, the Apple Foundation Models backend is *registered* by `DefaultBackends.register(with:)` — but it is **not auto-selected by `quickStart()`**. `ChatViewModel` needs two extra inputs before Foundation Models appears in `availableModels`:

1. A provider closure that reports availability — `foundationModelProvider = { FoundationBackend.isAvailable }`.
2. An explicit `loadFoundationModelIfAvailable()` call (or `autoSelectFirstRunModel()`, which is gated on a first-launch `UserDefaults` flag).

Without those, `availableModels` won't contain the Foundation entry and `ChatView`'s welcome state will read "Welcome — Download a model to get started" even though the OS ships with one. (Tracked as A2-F1 in the iter-1 walkthrough.)

### Seeding Foundation Models

Add this to the `Hello World` example so the moment `result` is non-nil, you also probe Foundation availability and dispatch a load. The probe is OS-gated; the rest of `quickStart()`'s flow runs unchanged on older OSes.

```swift,no-build
import SwiftUI
import SwiftData
import ManifoldKit
#if canImport(ManifoldFoundation)
import ManifoldFoundation
#endif

@main
struct MyChatApp: App {
    @State private var result: QuickStartResult?
    @State private var showModelManagement = false

    var body: some Scene {
        WindowGroup {
            if let result {
                ChatView(showModelManagement: $showModelManagement)
                    .environment(result.viewModel)
                    .modelContainer(result.bootstrap.modelContainer)
                    .task {
                        #if canImport(ManifoldFoundation)
                        if #available(macOS 26, iOS 26, *) {
                            result.viewModel.foundationModelProvider = { FoundationBackend.isAvailable }
                            result.viewModel.loadFoundationModelIfAvailable()
                        }
                        #endif
                    }
            } else {
                ProgressView().task {
                    result = try? await ManifoldKit.quickStart()
                }
            }
        }
    }
}
```

`loadFoundationModelIfAvailable()` is a no-op when the provider returns `false` or when no Foundation entry exists in `availableModels`, so it's safe to call unconditionally on supported OSes.

### Seeding an Ollama endpoint

For cloud / LAN backends (Ollama, OpenAI Chat Completions, OpenAI Responses, Anthropic Claude), the host inserts an `APIEndpointRecord` into the endpoint store *before* the view appears. `quickStart()` exposes the store on `result.bootstrap.endpointStore`; `ChatViewModel.refreshAvailableEndpointsFromStore()` is wired up automatically and will pick up the new endpoint. If you want a seeded endpoint to be live immediately (single-endpoint apps, scripted demos, kiosk flows), also set `selectedEndpoint` and call `loadSelectedEndpoint()` before exposing the view model.

⚠️ Ollama is gated behind the `Ollama` SwiftPM trait — see [Customizing backends](#customizing-backends) for the manifest snippet. Without that trait, no Ollama backend is registered for the seeded endpoint.

```swift,no-build
import SwiftUI
import ManifoldKit
import ManifoldInference

@main
struct MyChatApp: App {
    @State private var result: QuickStartResult?
    @State private var showModelManagement = false

    var body: some Scene {
        WindowGroup {
            if let result {
                ChatView(showModelManagement: $showModelManagement)
                    .environment(result.viewModel)
                    .modelContainer(result.bootstrap.modelContainer)
            } else {
                ProgressView().task {
                    do {
                        let r = try await ManifoldKit.quickStart()
                        let existing = try await r.bootstrap.endpointStore.fetchEndpoints()
                        if existing.isEmpty {
                            // Seed a default Ollama endpoint pointing at localhost:11434.
                            // `defaultBaseURL` / `defaultModelName` come from `APIProvider`.
                            let ollama = APIEndpointRecord(
                                name: "Local Ollama",
                                provider: .ollama,
                                modelName: "llama3.2:3b"  // any model you've `ollama pull`-ed
                            )
                            try await r.bootstrap.endpointStore.insertEndpoint(ollama)
                            r.viewModel.setAvailableEndpoints([ollama])
                            r.viewModel.selectedEndpoint = ollama
                            await r.viewModel.loadSelectedEndpoint()
                        }
                        result = r
                    } catch {
                        // Show ContentUnavailableView, log, etc.
                    }
                }
            }
        }
    }
}
```

Cloud SaaS providers (OpenAI, Anthropic) follow the same pattern but additionally need an API key written to the keychain under `keychainAccount`; the `ManifoldUIModelManagement` `APIConfigurationView` handles that wiring, or you can write the key yourself before inserting the record. If your app presents its own endpoint picker instead of preloading one, bind the choice to `selectedEndpoint` and call `dispatchSelectedLoad()` from the selection-change handler, mirroring the local-model flow.

### `showModelManagement` binding

`ChatView(showModelManagement: $flag)` accepts a `Binding<Bool>` but **does not present any sheet itself** — `ChatView` only *writes* `true` to the binding when the user taps an empty-state "Select Model" / "Browse" button. The host attaches a `.sheet(isPresented:)` modifier to whatever model-management surface they want.

The canonical surface is `ModelManagementSheet` from the **`ManifoldUIModelManagement`** product (a non-default, opt-in module — add `.product(name: "ManifoldUIModelManagement", package: "ManifoldKit")` to your target's dependencies). It needs a `ModelManagementViewModel` in the SwiftUI environment; construct it with `.live()` for production:

```swift,no-build
import SwiftUI
import ManifoldKit
import ManifoldUIModelManagement

@main
struct MyChatApp: App {
    @State private var result: QuickStartResult?
    @State private var showModelManagement = false
    @State private var managementVM = ModelManagementViewModel.live()

    var body: some Scene {
        WindowGroup {
            if let result {
                ChatView(showModelManagement: $showModelManagement)
                    .environment(result.viewModel)
                    .environment(managementVM)
                    .modelContainer(result.bootstrap.modelContainer)
                    .sheet(isPresented: $showModelManagement) {
                        ModelManagementSheet(modelRegistry: result.viewModel.modelRegistry)
                            .environment(managementVM)
                    }
            } else {
                ProgressView().task {
                    result = try? await ManifoldKit.quickStart()
                }
            }
        }
    }
}
```

If you don't want the full model-management UI (e.g. cloud-only apps that seed an endpoint at launch as shown above), leave the `.sheet` modifier off and the binding will simply toggle a value nothing observes. The `Select Model` / `Browse` buttons then become harmless no-ops; consider hiding the empty-state hint with a custom empty-state view (see `ChatView.init(showModelManagement:emptyState:apiConfiguration:)`).

## Customizing backends

`quickStart()` registers every backend that's compiled into your build (gated by SwiftPM traits). To control which backends ship, pass a `traits:` array on your `.package(...)` dependency:

```swift
.package(
    url: "https://github.com/roryford/ManifoldKit.git",
    from: "0.43.0", // x-release-please-version
    traits: [
        .trait(name: "MLX"),           // default-on
        .trait(name: "Llama"),         // default-on
        .trait(name: "CloudSaaS"),     // opt-in: OpenAI, Claude
        .trait(name: "Ollama"),        // opt-in: localhost:11434
    ]
)
```

Common profiles:

| Use case | Traits |
|----------|--------|
| Default consumer app | leave defaults (`MLX`, `Llama`, `HuggingFace`) |
| App Store-lean (Foundation Models only) | `["FoundationOnly"]` — see [docs/AppStoreSubmission.md](AppStoreSubmission.md) |
| SaaS-only | `["CloudSaaS"]` (drop MLX/Llama if you don't need local models) |
| Self-hosted / private datacenter | `["MLX", "Llama", "Ollama"]` |
| Full | `["MLX", "Llama", "Ollama", "CloudSaaS"]` |

See [`docs/FeatureMatrix.md`](FeatureMatrix.md) for the full trait → capability table.

### Bring your own UI

If you don't want `ChatView` and prefer your own SwiftUI surface, skip `quickStart()` and depend on just `ManifoldInference` plus the backends you want. Construct an `InferenceService` directly, register the compiled backends, and stream `GenerationEvent.token` into your transcript:

```swift
import ManifoldInference
import ManifoldBackends

@main
struct BYOExample {
    static func main() async throws {
        let inference = InferenceService()
        DefaultBackends.register(with: inference)

        try await inference.loadModel(from: .builtInFoundation, plan: .cloud())

        let stream = try inference.generate(messages: [("user", "Hello")])
        for try await event in stream.events {
            if case .token(let text) = event { print(text, terminator: "") }
        }
    }
}
```

This keeps SwiftData, `ManifoldRuntime`, and `ManifoldUI` out of your app graph entirely.

> **Lighter-weight than full BYO-UI:** if you only need to restyle bubbles, change brand colors, or override how *some* messages render, you don't have to rebuild the message list. Keep `ChatView` and reach for the in-framework theming seams instead — `.chatTheme(_:)` for tokens, `.messageBubbleStyle(_:)` for bubble chrome, and `.chatMessageRenderer(_:)` (with a `params.defaultMessageView()` fallback) for per-message overrides. See the **Theming the Chat UI** DocC article. Drop to full BYO-UI only when you need to replace the transcript, scroll-anchoring, and composer wholesale.

## Customizing storage

`ManifoldKit.quickStart(configuration:)` accepts a `ManifoldConfiguration`. Override the bundle identifier so two ManifoldKit-based apps on the same machine don't collide on the shared SwiftData store path:

```swift,no-build
result = try await ManifoldKit.quickStart(
    configuration: ManifoldConfiguration(
        appName: "My Chat App",
        bundleIdentifier: "com.example.mychatapp"
    )
)
```

If you need a custom `ModelContainer` (e.g. for testing, or to attach a second schema), drop down to `ManifoldBootstrap.build(...)` directly — `quickStart()` is the no-decisions-required path. The model container produced by either route attaches to your scene with the standard `.modelContainer(_:)` modifier, so `@Query` and `@Environment(\.modelContext)` work in your views unchanged.

## Error handling

Every public throws from the bootstrap path normalises to [`ManifoldKitError`](../Sources/ManifoldInference/ManifoldKitError.swift). Catch it once at the call site and read `errorDescription` for a user-facing string:

```swift,no-build
do {
    result = try await ManifoldKit.quickStart()
} catch let e as ManifoldKitError {
    // Already normalised — show e.errorDescription
    error = e
} catch {
    // Belt-and-braces for anything that escapes the normaliser
    error = .from(error)
}
```

`ManifoldKitError` wraps the underlying cause so logs can still surface the original `URLError` / SwiftData error if you need it for diagnostics.

## Where to go next

- [`docs/SWIFTUI-MULTI-SESSION.md`](SWIFTUI-MULTI-SESSION.md) — **ready to add a session sidebar?** Start here. Covers multi-session UI, relaunch restore, `APIConfigurationView`, and a complete end-to-end recipe that replaces piecemeal fragments from multiple docs.
- [`docs/FeatureMatrix.md`](FeatureMatrix.md) — full trait → backend → capability table.
- [`Example/Examples/MinimalExample`](../Example/Examples/MinimalExample) — runnable minimum-viable app.
- [`Example/Advanced`](../Example/Advanced) — full reference app with sessions, model management, and a custom composer accessory.
- [CONTRIBUTING.md](../CONTRIBUTING.md) — architecture invariants and how to add a backend.
- [CLAUDE.md](../CLAUDE.md) — target layout, dependency rules, and platform policy.
