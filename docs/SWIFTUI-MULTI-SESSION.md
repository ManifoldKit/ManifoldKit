# Building a Multi-Session SwiftUI Chat App

The canonical guide for SwiftUI hosts that want a sidebar of chats, a chat
detail view, persisted history, and turnkey relaunch restore. For **multi-session
SwiftUI use** this is the single source of truth: it consolidates the
session-management guidance that adopters previously had to stitch together from
fragments across [`docs/QUICKSTART.md`](QUICKSTART.md),
[`BuildingAChatUI.md`](../Sources/ManifoldUI/ManifoldUI.docc/Articles/BuildingAChatUI.md),
[`Example/Examples/MinimalExample/`](../Example/Examples/MinimalExample), and the
README quickstart. Those remain the canonical sources for what they each cover
(the README/QUICKSTART Hello World is still the one-call starting point);
`QUICKSTART.md` defers here for the session sidebar / restore recipe rather than
duplicating it.

If you only need a single-session chat surface, stop here and read
[`docs/QUICKSTART.md`](QUICKSTART.md) — it covers the one-call
`ManifoldKit.quickStart()` path and the simplest `ChatView` placement.

## 1. Pick the recommended path

Two real bootstrap shapes ship today. Pick the one that matches the level
of control your app needs:

| You want… | Path | When to use |
|-----------|------|-------------|
| Defaults — bootstrap, persistence, backends, restored session, all wired in one call | **`ManifoldKit.quickStart(configuration:)`** | Default for new apps. Single-session, multi-session, or sidebar-style hosts that don't need a custom `InferenceService` or a launch progress bar. |
| Control — own `InferenceService`, custom model container, custom backend mix, or a launch progress UI | **Manual `ManifoldBootstrap.build(...)` bootstrap** | Apps with bespoke launch UI, alternate model containers (encrypted, app-group), or non-default backend registries. |

The two paths share the **same view models**. The only difference is whether
ManifoldKit does the bootstrap dance for you, or your app drives it itself.
The relaunch / restore guarantees in section 5 apply to both.

## 2. The recommended default path — `ManifoldKit.quickStart`

```swift
import SwiftUI
import ManifoldKit            // umbrella: ManifoldInference + ManifoldRuntime
                              // + ManifoldPersistenceSwiftData + the backend
                              // families (Foundation/Ollama/CloudSaaS) + ManifoldUI

@main
struct MyChatApp: App {
    @State private var kit: QuickStartResult?
    @State private var startupError: Error?

    var body: some Scene {
        WindowGroup {
            if let kit {
                RootView()
                    .environment(kit.viewModel)
                    .environment(kit.sessionManager)
                    .modelContainer(kit.bootstrap.modelContainer)
            } else if let startupError {
                ContentUnavailableView(
                    "Failed to start",
                    systemImage: "exclamationmark.triangle",
                    description: Text(String(describing: startupError))
                )
            } else {
                ProgressView("Starting…")
                    .task {
                        do {
                            kit = try await ManifoldKit.quickStart(
                                configuration: .init(
                                    appName: "My Chat",
                                    bundleIdentifier: "com.example.mychat"
                                )
                            )
                        } catch {
                            startupError = error
                        }
                    }
            }
        }
    }
}

struct RootView: View {
    @Environment(ChatViewModel.self) var chatVM
    @Environment(SessionManagerViewModel.self) var sessionVM

    var body: some View {
        NavigationSplitView {
            SessionListView()
        } detail: {
            ChatView(showModelManagement: .constant(false))
        }
        .onChange(of: sessionVM.activeSession) { _, newSession in
            guard let newSession,
                  chatVM.activeSession?.id != newSession.id else { return }
            Task { await chatVM.switchToSession(newSession) }
        }
    }
}
```

That's the whole app. `quickStart` builds the bootstrap, registers the
compiled-in default backends, configures both view models, **awaits the
initial session-list load**, and selects the previously active session (or
mints a fresh one if the store is empty). On every subsequent relaunch the
sidebar comes back populated and the previously open chat is already
selected — no host-side wait/restore heuristic required.

**Model loading.** `quickStart()` also dispatches a load for whichever
backend it selected: the built-in policy's local model (Foundation-first,
then first on-disk GGUF), a per-session model/endpoint restored by
``switchToSession(_:)``, or — when no local model is available — the first
configured cloud endpoint in the endpoint store. You do **not** need a
separate `loadSelectedEndpoint()` / `dispatchSelectedLoad()` call after
`quickStart()` returns on relaunch. ``switchToSession(_:)`` performs the
same dispatch when the user picks a different sidebar row, so the
`onChange` handler above does not need an extra `dispatchSelectedLoad()`
either.

> **First-launch Ollama seeding.** If you insert an endpoint *after*
> `quickStart()` returns (the pattern in [QUICKSTART.md → Seeding an Ollama
> endpoint](QUICKSTART.md#seeding-an-ollama-endpoint)), you still need one
> explicit `loadSelectedEndpoint()` on that first run — the endpoint did not
> exist in the store when `quickStart()` ran. Every subsequent relaunch
> picks it up automatically.

## 3. When to use the manual bootstrap path

Drop down to `ManifoldBootstrap.build(...)` when you need:

- A launch progress bar driven by
  ``ManifoldPersistenceSwiftData/RuntimeBootstrapMilestone``
- A custom ``InferenceService`` (custom retry strategy, custom URLSession,
  observability hooks)
- A custom model container (e.g. encrypted store, app-group container)
- A non-default backend mix (omit one of the families, register a custom
  backend)

The full manual scaffold lives in the
[``BuildingAChatUI``](../Sources/ManifoldUI/ManifoldUI.docc/Articles/BuildingAChatUI.md)
DocC article. Two rules are non-obvious enough to call out here:

1. **Use `await sessionVM.configureAndLoad(bootstrap: bootstrap)`**, not the
   fire-and-forget `configure(bootstrap:)` overload. The latter schedules
   the first session-list fetch as a detached `Task` and returns
   immediately, so reading `sessionVM.sessions` on the next line still
   sees the empty initial state. That race produced the duplicate-blank-
   session bug reported in #1464.
2. **Call `await sessionVM.selectInitialSession()` before deciding whether
   to mint a fresh session.** It returns the session the host should
   restore (previously active → most recent non-empty → first), or `nil`
   when the store really is empty. Minting a `"New Chat"` row pre-restore
   is the naive pattern that produced repeated blank rows on relaunch.

A minimal manual bootstrap that does both:

```swift
let (progress, task) = ManifoldBootstrap.build(
    configuration: ManifoldConfiguration(
        appName: "My Chat",
        bundleIdentifier: "com.example.mychat"
    )
)
for await _ in progress { /* drain milestones or drive a progress bar */ }
let bootstrap = try await task.value
// Register the compiled-in default families. (The `ManifoldBackends`
// umbrella and `DefaultBackends` were retired in 1.0 — see
// docs/MIGRATION-shims-retired.md.) `quickStart()` folds these for you;
// the manual path registers them explicitly.
OllamaBackends.register(with: bootstrap.inferenceService)
CloudSaaSBackends.register(with: bootstrap.inferenceService)
FoundationBackends.register(with: bootstrap.inferenceService)

let chatVM = ChatViewModel(
    inferenceService: bootstrap.inferenceService,
    conversationRuntime: bootstrap.conversationRuntime
)
chatVM.configure(bootstrap: bootstrap)

let sessionVM = SessionManagerViewModel()
await sessionVM.configureAndLoad(bootstrap: bootstrap)

if let restored = await sessionVM.selectInitialSession() {
    sessionVM.activeSession = restored
    await chatVM.switchToSession(restored)
} else if let fresh = try? await sessionVM.createSession() {
    sessionVM.activeSession = fresh
    await chatVM.switchToSession(fresh)
}
```

## 4. Backend-specific startup steps

The bootstrap above wires the view models for **any** backend. The
backend-specific work is per-family and lives outside the SwiftUI surface
proper.

### Foundation (on-device, iOS 26 / macOS 26+)

`FoundationBackends.register(with:)` installs `FoundationBackend`
automatically when the OS version qualifies, but **Foundation is not
auto-selected**. Two explicit wiring steps are required before the chat
view model will treat it as an available model:

1. Set `foundationModelProvider` so the view model can probe availability.
2. Call `loadFoundationModelIfAvailable()` (or `autoSelectFirstRunModel()`,
   which is gated on a first-launch `UserDefaults` flag) to trigger the
   actual load.

```swift
#if canImport(ManifoldFoundation)
if #available(macOS 26, iOS 26, *) {
    chatVM.foundationModelProvider = { FoundationBackend.isAvailable }
    chatVM.loadFoundationModelIfAvailable()
}
#endif
```

Without those two steps, `availableModels` will not contain the Foundation
entry and the chat surface will show "Welcome — Download a model to get
started" even on a supported OS. Set ``ChatViewModel/onFirstLaunch`` if you
want to show an onboarding sheet instead of auto-loading.

### Local GGUF (llama.cpp) and MLX

Local models need the matching companion backend package —
[manifold-llama](https://github.com/roryford/manifold-llama) for GGUF,
[manifold-mlx](https://github.com/roryford/manifold-mlx) for MLX — registered
via `quickStart(backends:)` (or `LlamaBackends.register(with:)` on a manual
bootstrap), plus a downloaded weights file before the chat surface can
generate. Use ``ManifoldUIModelManagement`` (a separate product) to give
users a model browser, downloader, and storage UI. See
``ManifoldUIModelManagement.ModelManagementSheet`` for the canonical sheet.

> Note: the discovery story for sideloaded GGUFs from `~/Documents/Models`
> versus the app-scoped Application Support directory is being tightened in
> a separate workstream (#1468). This guide does not try to re-document
> those rules.

### Ollama, OpenAI, Anthropic (cloud)

Cloud backends need at least one configured ``APIEndpointRecord`` before
the user can pick a model. Mount
``ManifoldUIModelManagement.APIConfigurationView`` from your
`ChatView(showModelManagement:apiConfiguration:)` to give users the
endpoint editor. Hosts that pre-configure endpoints in code (e.g. for an
internal demo) can skip the UI entirely and write directly to
`bootstrap.endpointStore`.

## 5. When `ManifoldUIModelManagement` is required

`ManifoldUIModelManagement` is the **separate, explicitly imported**
product that hosts the model browser, downloader, storage UI, and API
endpoint editor. The dependency edge runs `ManifoldUIModelManagement →
ManifoldUI` (never the reverse), which is why these views are not visible
from `ManifoldUI` alone.

Mount it via closure injection on `ChatView`:

```swift
import ManifoldUI
import ManifoldUIModelManagement

struct RootView: View {
    @State private var showModelManagement = false

    var body: some View {
        ChatView(
            showModelManagement: $showModelManagement,
            apiConfiguration: { APIConfigurationView() }
        )
        .sheet(isPresented: $showModelManagement) {
            ModelManagementSheet()
        }
    }
}
```

You need to import `ManifoldUIModelManagement` when your app surfaces:

- a model browser / downloader UI for local GGUF or MLX weights
- an API endpoint editor for cloud backends
- the combined model-management sheet (``ModelManagementSheet``)

Cloud-only apps that pre-configure endpoints in code, or apps that build
their own settings UI, can skip `ManifoldUIModelManagement` entirely and
use `ChatView(showModelManagement:)` — the `APIConfig == EmptyView`
convenience initializer supplies an empty sheet.

## 6. Full recipe: explicit bootstrap + multi-session UI + APIConfigurationView + Ollama

This section gives the single end-to-end example that previously had to be
stitched together from `QUICKSTART.md`, `AGENTS.md`, and the DocC article.
It covers:

- **Manual `ManifoldBootstrap.build(...)` bootstrap** from a `.task { }` (async, no deadlock).
- **`SessionManagerViewModel` wired with `configureAndLoad`** (relaunch-safe restore).
- **`.environment(\.endpointStore, bootstrap.endpointStore)` injection** — required for `APIConfigurationView` to save keys.
- **Ollama endpoint pre-seeded in code** — the same pattern applies to any cloud provider.
- **`ManifoldUIModelManagement`** mounted via closure injection (optional).

### Package dependency

Tagged release:

```swift
// Package.swift — the cloud backends (Ollama, OpenAI, Anthropic, LM Studio)
// always compile since v0.48; no traits needed.
.package(
    url: "https://github.com/roryford/ManifoldKit.git",
    from: "0.59.0" // x-release-please-version
)
```

Local SwiftPM path (development / monorepo):

```swift
.package(
    name: "ManifoldKit",
    path: "../ManifoldKit"      // adjust to your checkout
)
```

Target dependencies (add what you need):

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "ManifoldKit", package: "ManifoldKit"),
    // Optional — only when surfacing model browser / endpoint editor UI:
    .product(name: "ManifoldUIModelManagement", package: "ManifoldKit"),
])
```

### App entry point

```swift,no-build
import SwiftUI
import ManifoldKit
import ManifoldUIModelManagement   // optional — omit if you don't want the model browser

@main
struct MyChatApp: App {
    @State private var bootstrap: ManifoldBootstrap?
    @State private var chatVM: ChatViewModel?
    @State private var sessionVM: SessionManagerViewModel?
    @State private var startupError: Error?

    var body: some Scene {
        WindowGroup {
            if let bootstrap, let chatVM, let sessionVM {
                RootView()
                    .environment(chatVM)
                    .environment(sessionVM)
                    // Inject the endpoint store so APIConfigurationView can
                    // persist API keys without any extra glue in the host.
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
            for await _ in progress { /* drain or drive a progress bar */ }
            let bootstrap = try await task.value

            // The retired `DefaultBackends` fold is now an explicit per-family
            // registration (see docs/MIGRATION-shims-retired.md).
            OllamaBackends.register(with: bootstrap.inferenceService)
            CloudSaaSBackends.register(with: bootstrap.inferenceService)
            FoundationBackends.register(with: bootstrap.inferenceService)

            let chatVM = ChatViewModel(
                inferenceService: bootstrap.inferenceService,
                conversationRuntime: bootstrap.conversationRuntime
            )
            chatVM.configure(bootstrap: bootstrap)

            // Use configureAndLoad — not configure — so sessions are
            // populated before selectInitialSession() runs (#1464).
            let sessionVM = SessionManagerViewModel()
            await sessionVM.configureAndLoad(bootstrap: bootstrap)

            // Pre-seed an Ollama endpoint if none exist yet.
            let existing = try await bootstrap.endpointStore.fetchEndpoints()
            if existing.isEmpty {
                let ollama = APIEndpointRecord(
                    name: "Local Ollama",
                    provider: .ollama,
                    modelName: "llama3.2:3b"
                )
                try await bootstrap.endpointStore.insertEndpoint(ollama)
            }

            // Restore or create the initial session.
            if let restored = await sessionVM.selectInitialSession() {
                sessionVM.activeSession = restored
                await chatVM.switchToSession(restored)
            } else if let fresh = try? await sessionVM.createSession() {
                sessionVM.activeSession = fresh
                await chatVM.switchToSession(fresh)
            }

            self.bootstrap = bootstrap
            self.chatVM = chatVM
            self.sessionVM = sessionVM
        } catch {
            self.startupError = error
        }
    }
}
```

### Root view with sidebar + APIConfigurationView

```swift,no-build
import SwiftUI
import ManifoldKit
import ManifoldUIModelManagement

struct RootView: View {
    @Environment(ChatViewModel.self) var chatVM
    @Environment(SessionManagerViewModel.self) var sessionVM
    @State private var showModelManagement = false

    var body: some View {
        NavigationSplitView {
            SessionListView()
        } detail: {
            // Pass APIConfigurationView via closure injection — this is the
            // structural pattern that avoids an import cycle between ManifoldUI
            // and ManifoldUIModelManagement. Omit apiConfiguration: entirely
            // if your app doesn't surface an API key editor.
            ChatView(
                showModelManagement: $showModelManagement,
                apiConfiguration: { APIConfigurationView() }
            )
            .sheet(isPresented: $showModelManagement) {
                ModelManagementSheet(modelRegistry: chatVM.modelRegistry)
            }
        }
        .onChange(of: sessionVM.activeSession) { _, newSession in
            guard let newSession,
                  chatVM.activeSession?.id != newSession.id else { return }
            Task { await chatVM.switchToSession(newSession) }
        }
    }
}
```

> **`ManifoldUIModelManagement` is optional.** Import it only when your
> app surfaces a model browser, model downloader, or API endpoint editor UI.
> Cloud-only apps that pre-seed endpoints in code (like the `start()` snippet
> above), or apps that build their own settings UI, can omit the import
> entirely and use `ChatView(showModelManagement:)` — the convenience
> initializer supplies an empty API sheet.

## 7. Persistence and relaunch guarantees

With either bootstrap path, ManifoldKit gives you the following without
any custom host code:

- **Sessions persist across launches.** Every created session, message, and
  pinned/agent state is written to a SwiftData store under the
  configuration's bundle identifier.
- **`sessions` is populated when `configureAndLoad(bootstrap:)` (or
  `quickStart`) returns.** No polling, no `Task.sleep`, no
  `withTimeout` heuristics required.
- **`selectInitialSession()` returns the right session to restore.**
  Preference order: previously active → most recent non-empty → first in
  the list. Returns `nil` only when the store is empty.
- **Assigning to `sessionVM.activeSession` persists the choice.** The next
  cold start will restore the same session. This works for user
  selections in the sidebar and for `selectInitialSession()`'s return
  value alike.

Things the host is **still** responsible for:

- Deciding whether to mint a fresh `"New Chat"` when
  `selectInitialSession()` returns `nil`. The manual scaffold above shows
  the recommended shape. `quickStart` does this for you.
- Wiring `sessionVM.activeSession` → `chatVM.switchToSession(_:)` (the
  `onChange` snippet in section 2 covers the common case).
- Calling `chatVM.refreshModels()` after backend changes (e.g. after a
  download finishes or an endpoint is added).

## 8. Common pitfalls

- **Calling `SessionManagerViewModel.configure(bootstrap:)` (non-`await`
  overload) and then reading `sessions` on the next line.** The load is
  fire-and-forget. Use `configureAndLoad(bootstrap:)` for relaunch-safe
  flows.
- **Minting a `"New Chat"` row before `selectInitialSession()`.** This is
  the pattern that produced "the sidebar gained a blank row on every
  relaunch" in #1464. Always restore first, then mint only if restore
  returned `nil`.
- **Wiring persistence late from `.task` on the root view.** Pre-runtime
  hosts did this; the bootstrap path makes it unnecessary. Configure the
  view models once during startup and pass them through `.environment`.
- **Forgetting to register backends on the manual path** — i.e. the
  `OllamaBackends`/`CloudSaaSBackends`/`FoundationBackends` `register(with:)`
  calls. Without them, no backend will satisfy a generation request and the
  composer's send button will appear inert. `quickStart` registers
  defaults for you.

## Related

- ``ManifoldKit.quickStart(configuration:)`` — one-call facade
- ``BuildingAChatUI`` (DocC) — full manual scaffold walkthrough
- ``ManifoldUIModelManagement.ModelManagementSheet`` — combined model
  selection / download / storage UI
- ``ManifoldConfiguration/Features`` — feature flags for hiding UI that
  doesn't apply to your deployment
- #1464 — the multi-session relaunch / restore fix this guide reflects
- #1465 — the issue requesting this canonical guide
