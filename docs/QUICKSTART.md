# ManifoldKit Quickstart

**Audience:** consumer
**Status:** living

A one-page tutorial for getting from "empty SwiftUI project" to "working chat UI" in under five minutes. If you already have a working bootstrap, jump to [Customizing backends](#customizing-backends) or [Customizing storage](#customizing-storage).

> If you're building a CLI, headless service, or non-SwiftUI app, see [`QUICKSTART-CLI.md`](QUICKSTART-CLI.md) — it has compile-tested `Package.swift` + `main.swift` examples for Foundation Models, local GGUF via Llama, and Ollama / OpenAI-compatible cloud endpoints.

## Prerequisites

- Xcode 16+ on macOS, or Swift 6.1+ toolchain. ManifoldKit's own `Package.swift` declares `// swift-tools-version: 6.1` and platforms `.iOS(.v18)` / `.macOS(.v15)`; consumer packages should match (or go higher) to avoid SwiftPM version-resolution churn.
- **If your app's own manifest declares `.macOS(.v26)` / `.iOS(.v26)`**, use `// swift-tools-version: 6.2` (or newer) in *that* package — those platform enum cases were introduced in PackageDescription 6.2; under 6.1 the manifest fails with `'v26' is unavailable`. ManifoldKit itself stays on 6.1 / macOS 15 floor; only the consumer targeting the new OS need bump. CLI recipes that target Foundation on macOS 26 already use 6.2 — see [`QUICKSTART-CLI.md`](QUICKSTART-CLI.md) §1.
- A SwiftUI app target on iOS 18+ / macOS 15+ (Apple Foundation Models require iOS 26+ / macOS 26+). Prefer an **Xcode app target** (or a real `.app` bundle) for SwiftUI hosts — a bare SwiftPM `executableTarget` `@main App` often fails to activate a window or lacks a bundle identifier, which complicates screenshots and TCC.
- Familiarity with SwiftUI's `App` protocol and `@State`. No prior knowledge of MLX, llama.cpp, MCP, or any specific backend is assumed.

## Install

Add ManifoldKit to your `Package.swift` (or Xcode's *Package Dependencies*):

```swift
.package(
    url: "https://github.com/ManifoldKit/ManifoldKit.git",
    from: "0.76.1" // x-release-please-version
)
```

Then depend on the `ManifoldKit` umbrella product from your app target:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "ManifoldKit", package: "ManifoldKit"),
])
```

The umbrella re-exports `ManifoldRuntime`, `ManifoldPersistenceSwiftData`, the backend families (`ManifoldFoundation`, `ManifoldOllama`, `ManifoldCloudSaaS`, `ManifoldCloudCore`), `ManifoldUI`, and `ManifoldInference` so one `import ManifoldKit` covers the common surface.

## Hello World

`ManifoldKit.quickStart()` builds the SwiftData container, registers the compiled-in backends, and wires up a `ChatViewModel` in one async call — a wired runtime in one call, then one more step (model selection) for a live chat. Errors normalise to [`ManifoldKitError`](../Sources/ManifoldModelCatalog/ManifoldKitError.swift).

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

Run the app. `quickStart()` compiles, launches, and renders a usable composer. On macOS 26 / iOS 26 with Apple Intelligence available it also **Foundation-first-selects and dispatches a load** before returning (see [What "available immediately" actually means](#what-available-immediately-actually-means)). On older OSes or when Foundation is unavailable, seed a starter model / cloud endpoint — [First-launch backend selection](#first-launch-backend-selection).

## Required Info.plist keys for ChatView

`ChatView`'s composer ships permission-gated controls. The microphone button is the critical one: on iOS, recording invokes `AVAudioSession`, which **hard-crashes the host process (SIGABRT)** the moment it runs while `NSMicrophoneUsageDescription` is missing from your app's `Info.plist` — the crash happens before any framework `try`/`catch` can run, so it is unrecoverable. Declare the key for every capability you keep enabled:

| Capability | Composer control | Info.plist key |
|------------|------------------|----------------|
| Microphone (record audio messages, iOS) | mic button in `ChatView` (on by default) | `NSMicrophoneUsageDescription` — **required**; the button is auto-hidden when it's missing (see below) |
| Photo attachment (iOS) | `VisionInputButton` / `PhotoAttachmentButton` composer accessories | `NSPhotoLibraryUsageDescription` — recommended for App Store review; the built-in picker is `PhotosPicker` (PHPicker, out-of-process) so it does **not** crash without it |

**Microphone defense in depth.** ManifoldKit also hides the mic button automatically when `NSMicrophoneUsageDescription` is absent, so a forgotten key degrades to a no-op rather than a crash. You still need the key for the button to appear. The photo-library accessories are *not* gated on their key (PHPicker doesn't require it) — they appear whenever `showImageAttachment` is on and the backend supports vision.

**No backend can hear the recording yet.** The mic button records a voice note and stages it as an attachment, but no backend in this package encodes `.audio` message parts for a model to consume — `ChatViewModel.sendMessage()` aborts the send and surfaces a configuration error rather than silently dropping it, so the user isn't left thinking their voice note was sent. Real audio-attachment encoding for capable backends is tracked in [#2353](https://github.com/ManifoldKit/ManifoldKit/issues/2353). This is unrelated to `ManifoldVoice`'s speech-to-text composer accessory, which transcribes to text before sending and works today.

**Turning controls off entirely.** Set the matching `ManifoldConfiguration.Features` flag to `false` at startup — the control is removed from the view tree:

```swift,no-build
ManifoldConfiguration.shared.features = .init(
    showAudioInput: false,       // remove the mic button (no NSMicrophoneUsageDescription needed)
    showImageAttachment: false   // remove image-attachment controls (paperclip + photo accessories)
)
```

Both flags default to `true`, so existing apps keep today's composer; opt out only where you don't want the capability.

> [!IMPORTANT]
> **The backend cliff: no registered backend → a *runtime* throw, not a compile error.** If **zero** inference backends are registered when you call it, `ManifoldKit.quickStart()` throws [`ManifoldKitError.noBackendsRegistered`](../Sources/ManifoldModelCatalog/ManifoldKitError.swift) — it compiles fine, then fails at launch. This is deliberate: it surfaces the real cause at the assembly boundary instead of a confusing "No model loaded" on the first turn. Since v0.48 the cloud backends (Ollama, OpenAI, Claude) always compile, so a `quickStart()` build always has cloud support — the throw only fires if nothing was *registered* (e.g. you bypassed `quickStart()` and registered no backend yourself). For **local** inference add a companion package — [manifold-llama](https://github.com/ManifoldKit/manifold-llama) (GGUF) or [manifold-mlx](https://github.com/ManifoldKit/manifold-mlx) (MLX) — and pass its registrar to `quickStart(backends:)`; on iOS 26 / macOS 26+ the built-in Foundation Models backend is available with no extra package. See [Customizing backends](#customizing-backends).

> **Session bootstrap.** `quickStart()` auto-creates an initial empty `ChatSession` and activates it on first launch when the persistent store has no sessions yet, so `ChatView`'s composer is enabled the moment the view appears. On subsequent launches the most-recent existing session is selected. Hosts that need finer control over the initial session (custom title, system prompt, restoring from a deep link) can drop down to `ManifoldBootstrap.build(...)` directly and seed through the canonical composite accessor `bootstrap.persistenceStores` before constructing the view model — `quickStart()` only auto-creates when the store is *empty*, so seeding one session first opts out cleanly. The full session-management surface (list sidebar, create/delete/rename) lives on `SessionManagerViewModel` — see the [Building a Chat UI](../Sources/ManifoldUI/ManifoldUI.docc/Articles/BuildingAChatUI.md) DocC article for the worked example.

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
        try await stores.insertSession(ChatSession(title: "Inbox"))
    }
}
```

`persistenceStores` is the `SessionStore & MessageStore` handle itself — call `insertSession(_:)`, `fetchSessions()`, or `fetchMessages(for:)` on it directly. There is no `.sessionStore` / `.messageStore` sub-property pair to drill into.

## First-launch backend selection

`quickStart()` registers every compiled-in backend, then runs a selection policy and **dispatches** a load when something is selectable:

1. **Foundation-first** when Apple Intelligence is available (macOS 26 / iOS 26+).
2. Else the first **on-disk local model** a registered companion backend can load.
3. Else the first **stored cloud/LAN endpoint** (relaunch path when endpoints already exist).

When none of those apply, the composer is enabled (a session exists) but inert — `isModelLoaded` is `false`, the placeholder reads "No model loaded", and the empty-state "Select Model" button flips `showModelManagement` (see [`showModelManagement` binding](#showmodelmanagement-binding) — by itself the binding doesn't present anything).

This section covers the paths that fill that gap on first launch (starter seed download, post-return Ollama seed, manual Foundation re-enable). To react to the user's choice or populate your own discovery list, see the `ModelRegistry.onSelectionChanged` / `foundationModelProvider` and `CuratedModel.all` rows in [Host configuration seams](#host-configuration-seams).

### Seeding a starter model (recommended for local-first apps)

The curated starter is a GGUF, so add the `manifold-llama` companion package and pass `backends: [LlamaBackends.self]`. ManifoldKit downloads Qwen3-0.6B-Instruct Q4\_K\_M (~484 MB) before returning, runs the selection policy, and dispatches the load before returning. Without the registrar the seed is deliberately skipped and no model loads (see `QuickStartSeed`).

That dispatch is fire-and-forget (`dispatchSelectedLoad()`), so the load is typically still in flight when `quickStart()` returns and the view appears — `ChatViewModel.isModelLoaded` is not guaranteed `true` on the first observation. Read `viewModel.modelLoadState` (`.idle` / `.loading` / `.loaded` / `.failed(error)`) to drive an accurate "starting up" indicator instead of assuming the composer is immediately live (#2222).

```swift,no-build
import SwiftUI
import ManifoldKit
import ManifoldLlama

@main
struct MyChatApp: App {
    @State private var result: QuickStartResult?
    @State private var error: ManifoldKitError?
    @State private var downloadProgress: Double = 0

    var body: some Scene {
        WindowGroup {
            if let result {
                ChatView()
                    .environment(result.viewModel)
                    .modelContainer(result.bootstrap.modelContainer)
            } else if let error {
                ContentUnavailableView(
                    "Failed to start",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error.errorDescription ?? "")
                )
            } else {
                VStack {
                    ProgressView("Downloading starter model…", value: downloadProgress)
                        .padding()
                    Text("\(Int(downloadProgress * 100))%")
                        .foregroundStyle(.secondary)
                }
                .task {
                    do {
                        result = try await ManifoldKit.quickStart(
                            backends: [LlamaBackends.self],
                            seed: .recommendedSmallModel { progress in
                                downloadProgress = progress
                            }
                        )
                    }
                    catch let e as ManifoldKitError { error = e }
                    catch { self.error = .from(error) }
                }
            }
        }
    }
}
```

**Seed skip conditions.** The seed is skipped silently when any of the following is true — the app still launches, just with the "No model loaded" empty state instead:

| Condition | Outcome |
|-----------|---------|
| Foundation Models available (iOS/macOS 26+) | Skip — zero-cost built-in model wins |
| A local GGUF or MLX model is already on disk | Skip — never downloads redundantly |
| No registered backend can load GGUF models | Skip — logged as `quickStart(seed:): no registered backend can load gguf models — seed skipped` |
| Network failure during the download | Skip silently — app launches in empty state |

**Backend requirement.** The downloaded model is a GGUF, so the seed needs the GGUF backend at runtime: add the [manifold-llama](https://github.com/ManifoldKit/manifold-llama) companion package and pass `backends: [LlamaBackends.self]` (as in the README's optional GGUF starter). Without it the seed logs and skips — never an error. The download machinery itself (`ManifoldHuggingFace`) is always compiled since v0.48.

### What "available immediately" actually means

On macOS 26 / iOS 26, when Apple Intelligence is available, **`quickStart()` already Foundation-first-selects and dispatches a load** before it returns:

1. Wires `foundationModelProvider = { FoundationBackend.isAvailable }` on the view model's registry.
2. Runs `defaultSelectionPolicy` (Foundation first, then first compatible on-disk model).
3. Calls fire-and-forget `dispatchSelectedLoad()` when something was selected.

You do **not** need a second host-side `loadFoundationModelIfAvailable()` for the default `quickStart` → `ChatView` path. What you *do* need is to treat "dispatched" as not "loaded" (#2222): observe `viewModel.modelLoadState` (or tolerate `SendMessageError.modelLoading` and retry) before assuming the first turn can complete.

If no Foundation / on-disk / stored-endpoint model is selected, `ChatView`'s welcome state will still read "Welcome — Download a model to get started" — seed a cloud endpoint (below) or a companion local model in that case.

### Seeding Foundation Models (manual bootstrap / re-enable)

Use the explicit two-step when you are **not** on `quickStart()` (manual `ManifoldBootstrap.build`), or when you need to **re-select Foundation after session churn** (create/switch can leave `isModelLoaded` stale relative to the engine — re-call after minting a session if `sendMessage` fails with "No model loaded"):

```swift,no-build
// Gate on FoundationModels (the Apple framework), not ManifoldFoundation —
// the ManifoldFoundation module always compiles; FoundationBackend only exists
// when FoundationModels is present (matches QuickStart.swift).
#if canImport(FoundationModels)
if #available(macOS 26, iOS 26, *) {
    chatVM.foundationModelProvider = { FoundationBackend.isAvailable }
    chatVM.loadFoundationModelIfAvailable()  // select + dispatchSelectedLoad
}
#endif
```

`loadFoundationModelIfAvailable()` is a no-op when the provider returns `false` or when no Foundation entry exists in `availableModels`. Prefer it over `autoSelectFirstRunModel()` when you need a load — the latter only *selects* Foundation (first-launch flag gated) and expects a view-layer `onChange` / `dispatchSelectedLoad` to actually load.

### Seeding an Ollama endpoint

For cloud / LAN backends (Ollama, OpenAI Chat Completions, OpenAI Responses, Anthropic Claude), the host inserts an `APIEndpointRecord` into the endpoint store *before* the view appears. `quickStart()` exposes the store on `result.bootstrap.endpointStore`; `ChatViewModel.refreshAvailableEndpointsFromStore()` is wired up automatically and will pick up the new endpoint.

On **relaunch**, when the endpoint is already in the store, `quickStart()` selects the first configured endpoint and dispatches a load before returning — no extra `loadSelectedEndpoint()` call is required. That dispatch (`dispatchSelectedLoad()`) is fire-and-forget, though: the load is commonly still in flight when `quickStart()` returns, so don't treat `isModelLoaded == true` or a completed `sendMessage(_:)` as guaranteed on the first frame. Observe `viewModel.modelLoadState` for the `.loading` → `.loaded` / `.failed(error)` transition, or catch `SendMessageError.modelLoading` from a `sendMessage(_:)` call that raced the load and retry once it resolves (#2222). On **first launch**, when you seed the endpoint *after* `quickStart()` returns (the snippet below), you still need one explicit, **awaited** `loadSelectedEndpoint()` so the first session is live before the view appears — awaiting it (unlike the fire-and-forget dispatch above) does block until the load actually completes or fails.

Ollama support is always compiled in since v0.48 (the `Ollama` trait was retired) — the seeded endpoint is the only configuration step.

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
                                modelName: "llama3.1:8b"  // paste a tag from `ollama list`
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

If you don't want the full model-management UI (e.g. cloud-only apps that seed an endpoint at launch as shown above), leave the `.sheet` modifier off and the binding will simply toggle a value nothing observes. The `Select Model` / `Browse` buttons then become harmless no-ops; consider hiding the empty-state hint with a custom empty-state view (see `ChatView.chatEmptyState(_:)`).

## Customizing backends

`quickStart()` registers every backend compiled into your build. Core always ships the cloud backends (Ollama, OpenAI, Claude, LM Studio / custom endpoints) and the Apple Foundation Models bridge (active on iOS 26 / macOS 26+). The heavy local backends ship as **companion packages** since v0.48 — add the package and pass its registrar to `quickStart(backends:)`:

```swift,no-build
// Package.swift
.package(
    url: "https://github.com/ManifoldKit/ManifoldKit.git",
    from: "0.76.1" // x-release-please-version
),
.package(url: "https://github.com/ManifoldKit/manifold-llama.git", from: "0.2.14"),  // GGUF / llama.cpp
.package(url: "https://github.com/ManifoldKit/manifold-mlx.git", from: "0.2.13"),    // MLX (+ image gen)

// target dependencies:
"ManifoldKit",
.product(name: "ManifoldLlama", package: "manifold-llama"),
.product(name: "ManifoldMLX", package: "manifold-mlx"),
```

```swift,no-build
import ManifoldKit
import ManifoldLlama   // from manifold-llama
import ManifoldMLX     // from manifold-mlx

result = try await ManifoldKit.quickStart(
    backends: [LlamaBackends.self, MLXBackends.self]
)
```

> **Argument order:** the combined overload is `quickStart(backends:configuration:seed:)` — `backends:` comes **first**, then the optional `configuration:`. So to pass both, write `quickStart(backends: [...], configuration: myConfig)`. (The no-arg and `configuration:`-only forms shown elsewhere in this guide are separate overloads.)

(Xcode consumers: File ▸ Add Package Dependencies… ▸ enter the companion URL ▸ tick the product for your app target — no manifest editing.)

> [!IMPORTANT]
> **MLX needs a colocated `mlx.metallib` — automatic under Xcode, gated on the Metal Toolchain under `swift run`.** mlx-swift loads a precompiled `mlx.metallib` at GPU init and aborts with `MLX error: Failed to load the default metallib` if none sits next to the binary. A normal SwiftUI `.app` (the path this page describes) is an Xcode build, which produces and bundles it automatically — nothing to do. Under a bare-SwiftPM `swift build` / `swift run`, `manifold-mlx`'s `MLXMetallibPlugin` compiles it and `MLXMetallibStaging` colocates it — **provided the Metal Toolchain component is installed** (`xcodebuild -downloadComponent MetalToolchain`); without it the build still succeeds but emits no metallib and MLX aborts at model load. See [QUICKSTART-IMAGE-GEN.md → §5](QUICKSTART-IMAGE-GEN.md#5-the-metallib-requirement) for the full story, or use the GGUF/Llama backend for a toolchain-free `swift run` CLI (`manifold-llama` has no Metal step).

Common profiles:

| Use case | Packages |
|----------|----------|
| Default consumer app | ManifoldKit + manifold-llama (GGUF starter-seed path) |
| Full local inference | ManifoldKit + manifold-llama + manifold-mlx |
| App Store-lean (Foundation Models + cloud only) | ManifoldKit alone — core has no heavy ML dependencies; see [docs/AppStoreSubmission.md](AppStoreSubmission.md) |
| Cloud-only (no local models) | ManifoldKit alone — cloud is always compiled in |

See [`docs/FeatureMatrix.md`](FeatureMatrix.md) for the full capability table and [docs/MIGRATION-0.48.md](MIGRATION-0.48.md) if you're migrating from a trait-based 0.47 setup.

### Local-only (privacy / on-device) runtime

`quickStart()` and `quickStart(backends:)` always fold in the compiled-in cloud families (Ollama + SaaS) — convenient for most apps, but wrong for a privacy/on-device app that must never reach a cloud provider. Two opt-outs:

```swift,no-build
import ManifoldKit
import ManifoldLlama   // manifold-llama companion package

// Convenience: on-device Foundation Models + your local backends, no cloud.
let kit = try await ManifoldKit.localOnly(backends: [LlamaBackends.self])

// Or the general primitive — register ONLY the registrars you name:
let kit2 = try await ManifoldKit.quickStart(
    backends: [LlamaBackends.self],
    includeDefaultBackends: false   // cloud families are NOT registered
)
```

The value-typed front door has the matching `LLM.localOnly(from:backends:)`.

> [!IMPORTANT]
> **This is registration-level exclusion, not link-level.** `localOnly` / `includeDefaultBackends: false` guarantee no cloud backend can be *selected or dispatched* — but the cloud code is still compiled and linked through the `ManifoldKit` umbrella. For true link-time exclusion (e.g. a FIPS posture, or proving the binary contains no networking symbols) depend on the individual products instead of the umbrella — see [`docs/FIPS.md`](FIPS.md).

On iOS 26 / macOS 26+, `localOnly()` with no `backends` still yields a working chat via Apple Foundation Models. On older OSes, pass a companion local registrar (`[LlamaBackends.self]` / `[MLXBackends.self]`) — with no registrar that can serve the OS, `localOnly()` throws `ManifoldKitError.noBackendsRegistered` at bootstrap rather than launching a chat with no selectable model. To also stop accidental network egress at runtime (e.g. from a misconfigured custom endpoint), flip the `URLSessionProvider.networkDisabled` kill-switch — see [Host configuration seams](#host-configuration-seams) below.

### Foundation-only quickstart (no cloud, no companion packages)

Apple Foundation Models ship in core — no companion package to add, no Ollama/OpenAI/Anthropic wiring to reason about. If your app only ever targets the on-device model, register just that one family instead of the compiled-in default of "cloud + Foundation":

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
                    do {
                        // Below the Foundation Models floor this registrar yields
                        // no usable backend and quickStart throws
                        // .noBackendsRegistered — gate the call (or add a
                        // fallback registrar for older OSes; see note below).
                        guard #available(iOS 26, macOS 26, *) else {
                            error = .noBackendsRegistered
                            return
                        }
                        result = try await ManifoldKit.quickStart(
                            backends: [FoundationBackends.self],
                            includeDefaultBackends: false
                        )
                    }
                    catch let e as ManifoldKitError { error = e }
                    catch { self.error = .from(error) }
                }
            }
        }
    }
}
```

`FoundationBackends` is re-exported by the `ManifoldKit` umbrella (`@_exported import` — see `Sources/ManifoldKit/Exports.swift`), so no extra product or import is needed beyond `ManifoldKit` itself. This is the same registration-level exclusion as `localOnly()` above, just spelled out with the general `quickStart(backends:includeDefaultBackends:)` primitive and an explicit registrar list of one.

On iOS 18–25 / macOS 15–25 the snippet *compiles and links* fine, but the unguarded `quickStart` call **throws `ManifoldKitError.noBackendsRegistered`**: below the Foundation Models floor `FoundationBackends` registers a factory that can never produce a usable backend, and `quickStart` fails fast rather than launching a chat that can never generate. A Foundation-only app must therefore gate the call with `#available(iOS 26, macOS 26, *)` (as the snippet does) or include a fallback registrar for older OSes — a companion local registrar (`LlamaBackends.self` / `MLXBackends.self`) or the compiled-in cloud families. See the [compatibility matrix](../README.md#compatibility-matrix) in the README. Headless (non-SwiftUI) consumers get an even leaner dependency set — just `ManifoldInference` + `ManifoldFoundation`, no `ManifoldKit` umbrella at all — via [`QUICKSTART-CLI.md` §1](QUICKSTART-CLI.md#1-foundation-models-macos-26).

## Host configuration seams

ManifoldKit exposes a number of powerful extension points that most apps never need — but which are easy to miss because they live deep in the module graph rather than on the `quickStart` surface. The table below is the discoverable index; each is public today.

| Seam | File | What it does | One-line example |
|------|------|--------------|------------------|
| `CuratedModel.all` | [`Sources/ManifoldHardware/CuratedModel.swift`](../Sources/ManifoldHardware/CuratedModel.swift) | Host-owned curated model list shown in discovery UI (empty by default; thread-safe public setter). | `CuratedModel.all = [myQwenEntry, myLlamaEntry]` |
| `ModelRegistry.onSelectionChanged` | [`Sources/ManifoldInference/Services/ModelRegistry.swift`](../Sources/ManifoldInference/Services/ModelRegistry.swift) | Callback fired whenever the selected model changes — persist the choice, update UI, log. | `registry.onSelectionChanged = { model in save(model?.id) }` |
| `ModelRegistry.foundationModelProvider` | [`Sources/ManifoldInference/Services/ModelRegistry.swift`](../Sources/ManifoldInference/Services/ModelRegistry.swift) | Closure reporting Apple Foundation availability so `refresh()` prepends the built-in model (`quickStart` wires this on 26+). | `registry.foundationModelProvider = { FoundationBackend.isAvailable }` |
| `ConversationRuntimeOptions` | [`Sources/ManifoldRuntime/Services/ConversationRuntimeOptions.swift`](../Sources/ManifoldRuntime/Services/ConversationRuntimeOptions.swift) | Injection points threaded through `ManifoldBootstrap`: custom compression/history providers, generation hooks, per-turn context, an auxiliary model. | `var o = ConversationRuntimeOptions(); o.compressionPolicy = MyPolicy()` |
| `PinnedSessionDelegate.pinnedHosts` | [`Sources/ManifoldCloudCore/PinnedSessionDelegate.swift`](../Sources/ManifoldCloudCore/PinnedSessionDelegate.swift) | TLS certificate/public-key pinning per host — set before any network request. | `PinnedSessionDelegate.pinnedHosts = ["api.example.com": [spkiHash]]` |
| `URLSessionProvider.networkDisabled` | [`Sources/ManifoldCloudCore/URLSessionProvider.swift`](../Sources/ManifoldCloudCore/URLSessionProvider.swift) | Global runtime kill-switch — cloud sessions throw `CloudBackendError.networkDisabled` instead of issuing requests. Pairs with `localOnly`. | `URLSessionProvider.networkDisabled = true` |
| `ChatViewModel.onFirstMessage` | [`Sources/ManifoldUI/ViewModels/ChatViewModel.swift`](../Sources/ManifoldUI/ViewModels/ChatViewModel.swift) | Fired after the first user message in a session (`quickStart` uses it for auto-titling; replace to AI-title). | `vm.onFirstMessage = { session, text in await retitle(session, text) }` |
| `ChatViewModel.onSessionBranched` | [`Sources/ManifoldUI/ViewModels/ChatViewModel.swift`](../Sources/ManifoldUI/ViewModels/ChatViewModel.swift) | Fired when a session is branched (edit/regenerate fork) with the new session id (`quickStart` wires this to reload sessions and switch both `sessionManager.activeSession` and `viewModel`'s own active session to the branch — replace to customize the navigation). | `vm.onSessionBranched = { newID in await reload(newID) }` |
| `ChatViewModel.onFirstLaunch` | [`Sources/ManifoldUI/ViewModels/ChatViewModel.swift`](../Sources/ManifoldUI/ViewModels/ChatViewModel.swift) | Replaces the default first-run behaviour (invoked by `autoSelectFirstRunModel()`; skips default Foundation auto-selection) — present onboarding, choose your own first model. | `vm.onFirstLaunch = { showOnboarding = true }` |
| `ChatViewModel.onUpgradeHintTriggered` | [`Sources/ManifoldUI/ViewModels/ChatViewModel.swift`](../Sources/ManifoldUI/ViewModels/ChatViewModel.swift) | Fired when the upgrade hint is first shown (e.g. suggesting a local model for longer context) — override the default banner with your own nudge. | `vm.onUpgradeHintTriggered = { showUpgradeSheet = true }` |

> See also [Customizing backends](#customizing-backends) for the curated-model and backend-registration seams, and [First-launch backend selection](#first-launch-backend-selection) for the model-selection flow that `onSelectionChanged` / `foundationModelProvider` plug into.

### M5 Neural Accelerator (macOS 26.2+)

MLX inference on M5 or later hardware with macOS 26.2 or later delivers a 3.3–4× TTFT
speedup via Neural Accelerator dedicated matrix-multiplication hardware. The acceleration
is **automatic** — no configuration needed. All M5 variants (including MacBook Air) are
supported.

Use `NeuralAcceleratorProbe.availability` from `ManifoldHardware` to surface this in
your app UI.

```swift
import ManifoldHardware

#if os(macOS)
if case .available = NeuralAcceleratorProbe.availability {
    // Surface "Running on M5 with Neural Accelerator — ~4× faster first-token" in your UI.
}
#endif
```

> **macOS 26.2 status:** macOS 26.2 was in beta as of June 2026. Check Apple's release
> notes for the stable availability date.

*Source: [Apple ML Research, June 2026](https://machinelearning.apple.com/research/exploring-llms-mlx-m5)*

### Bring your own UI

If you don't want `ChatView` and prefer your own SwiftUI surface, skip `quickStart()`, depend on just `ManifoldInference` plus the backends you want, construct an `InferenceService` directly, register the compiled backends, and stream `GenerationEvent.token` into your own transcript. This keeps SwiftData, `ManifoldRuntime`, and `ManifoldUI` out of your app graph entirely.

The full walkthrough — package wiring, the minimal headless example, a SwiftUI view model that streams tokens, and the complete `GenerationEvent` surface — is the canonical, single-source guide at **[`QUICKSTART-BRING-YOUR-OWN-UI.md`](QUICKSTART-BRING-YOUR-OWN-UI.md)**.

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

Every public throws from the bootstrap path normalises to [`ManifoldKitError`](../Sources/ManifoldModelCatalog/ManifoldKitError.swift). Catch it once at the call site and read `errorDescription` for a user-facing string:

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
- [`docs/FeatureMatrix.md`](FeatureMatrix.md) — full backend → capability table.
- [`Example/Examples/MinimalExample`](../Example/Examples/MinimalExample) — runnable minimum-viable app.
- [`Example/Advanced`](../Example/Advanced) — full reference app with sessions, model management, and a custom composer accessory.
- [CONTRIBUTING.md](../CONTRIBUTING.md) — architecture invariants and how to add a backend.
- [CLAUDE.md](../CLAUDE.md) — target layout, dependency rules, and platform policy.
