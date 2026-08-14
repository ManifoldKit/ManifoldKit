# Building a Multi-Session SwiftUI Chat App

**Audience:** consumer
**Status:** living

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
import SwiftData
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

**Model loading.** Sessions restore automatically; **a usable model depends on
the path.** What `quickStart()` does before it returns (see
`Sources/ManifoldKit/QuickStart.swift`):

| Goal | What `quickStart()` does | What the host must still do |
|------|--------------------------|-----------------------------|
| **Apple Foundation Models** (macOS 26 / iOS 26+, `FoundationBackend.isAvailable`) | Wires `foundationModelProvider`, runs the **Foundation-first** `defaultSelectionPolicy`, then **dispatches** a load | Observe `modelLoadState` before the first send (dispatch is fire-and-forget — #2222). No extra host call on the happy path. |
| **Local GGUF / MLX** already on disk (and companion registrar passed) | Same policy falls through to the first compatible on-disk model, then dispatches | Companion package + weights; see §4 |
| **Relaunch** with a cloud/LAN endpoint already in the store (and no local model selected) | Selects the first stored endpoint and dispatches a load | Observe `modelLoadState`; no second `loadSelectedEndpoint()` for selection |
| **First launch** seeding Ollama / OpenAI / Claude *after* `quickStart` returns | Nothing for that endpoint (it did not exist yet) | `setAvailableEndpoints` + `selectedEndpoint` + **awaited** `loadSelectedEndpoint()` — see [QUICKSTART.md → Seeding an Ollama endpoint](QUICKSTART.md#seeding-an-ollama-endpoint) |
| **Manual `ManifoldBootstrap.build` path** | Does **not** run the selection policy or auto-select endpoints | Host must do Foundation (§4) or the cloud triad (§4 / §6) on **every** cold start |

``switchToSession(_:)`` re-dispatches load for the session's remembered
model/endpoint when the user picks a different sidebar row, so the
`onChange` handler above does not need an extra `dispatchSelectedLoad()`.

>
> **"Dispatches" is not "awaits" (#2222).** Every one of those dispatches —
> `quickStart()`'s own selection, ``switchToSession(_:)``'s restore, the
> `onChange` handler — calls the fire-and-forget `dispatchSelectedLoad()`.
> `quickStart()` (and `switchToSession(_:)`) can therefore return, and the
> view can appear, while the backend is still connecting: `isModelLoaded` is
> not guaranteed `true` on the first observation, and a `sendMessage(_:)`
> that races the in-flight load throws the distinguishable
> `SendMessageError.modelLoading` rather than the ambiguous
> `.noModelLoaded`. Bind chat-surface "ready" state to
> `chatVM.modelLoadState` (`.idle` / `.loading` / `.loaded` / `.failed(error)`)
> instead of inferring it from `isModelLoaded` alone — it's the one property
> that distinguishes "still loading" from "loaded" from "failed with a real
> `Error`".
>
> **Older QUICKSTART prose said Foundation was "not auto-selected by
> `quickStart()`".** That is stale relative to current `quickStart` (it wires
> the provider + Foundation-first policy + `dispatchSelectedLoad`). Explicit
> `loadFoundationModelIfAvailable()` remains the right tool for the **manual**
> bootstrap path and for re-enabling Foundation after session churn (§4).

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

```swift,no-build
let (progress, task) = ManifoldBootstrap.build(
    configuration: ManifoldConfiguration(
        appName: "My Chat",
        bundleIdentifier: "com.example.mychat"
    )
)
for await _ in progress { /* drain milestones or drive a progress bar */ }
let bootstrap = try await task.value
// Register the compiled-in default families. (The `ManifoldBackends`
// umbrella and `DefaultBackends` were retired in P7 (pre-1.0; see
// docs/MIGRATION-shims-retired.md).) `quickStart()` folds these for you;
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

`FoundationBackends.register(with:)` installs `FoundationBackend` when the
OS version qualifies. On the **`quickStart()` path**, that is enough: the
facade wires `foundationModelProvider`, Foundation-first-selects when
`FoundationBackend.isAvailable`, and dispatches a load (see §2).

On the **manual bootstrap path** (this section's `chatVM`), Foundation is
**not** auto-selected. Two explicit wiring steps are required:

1. Set `foundationModelProvider` so the view model can probe availability.
2. Call `loadFoundationModelIfAvailable()` to select Foundation **and**
   `dispatchSelectedLoad()`.

```swift,no-build
#if canImport(FoundationModels)
if #available(macOS 26, iOS 26, *) {
    chatVM.foundationModelProvider = { FoundationBackend.isAvailable }
    chatVM.loadFoundationModelIfAvailable()
}
#endif
```

Do **not** substitute `autoSelectFirstRunModel()` for step 2 unless your
UI also dispatches a load on selection change — that helper only sets
`selectedModel` (and is first-launch-flag gated); it deliberately does not
load (avoids a double-load race with view `onChange` handlers).

Without those two steps on the manual path, `availableModels` will not
contain the Foundation entry and the chat surface will show "Welcome —
Download a model to get started" even on a supported OS. Set
``ChatViewModel/onFirstLaunch`` if you want to show an onboarding sheet
instead of auto-loading.

> **Session churn caveat.** After `createSession()` / `switchToSession` under
> Foundation, `isModelLoaded` can report `true` while `sendMessage` still fails
> with `InferenceError.inferenceFailure("No model loaded")` (DX walkthrough
> 2026-07-25). Prefer `modelLoadState`, and re-call
> `loadFoundationModelIfAvailable()` after minting a new session if generation
> fails with that error.

### Local GGUF (llama.cpp) and MLX

Local models need the matching companion backend package —
[manifold-llama](https://github.com/ManifoldKit/manifold-llama) for GGUF,
[manifold-mlx](https://github.com/ManifoldKit/manifold-mlx) for MLX — registered
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
``ManifoldUIModelManagement.APIConfigurationView`` via
`ChatView(showModelManagement:).chatAPIConfiguration { APIConfigurationView() }`
to give users the endpoint editor. Hosts that pre-configure endpoints in code
(e.g. for an internal demo) can skip the UI entirely and write directly to
`bootstrap.endpointStore`.

**Inserting a record is not enough to generate.** After the store write you
must also bind the chat view model and load:

```swift,no-build:fragment; builds on identifiers defined in earlier blocks
chatVM.setAvailableEndpoints([endpoint])   // or the full fetched list
chatVM.selectedEndpoint = endpoint
await chatVM.loadSelectedEndpoint()        // await on first seed; see #2222
```

- On the **`quickStart()` path**, that triad is required only when you seed
  *after* `quickStart` returns (first launch). On relaunch, `quickStart`
  re-selects the first stored endpoint and dispatches a load for you.
- On the **manual `ManifoldBootstrap.build` path**, there is **no** equivalent
  auto-select. You must run the triad (or at least re-select +
  `loadSelectedEndpoint()`) on **every** cold start — first launch *and*
  relaunch — or the sidebar comes back populated while the composer stays
  inert (`selectedEndpoint == nil` / `isModelLoaded == false`). Section 6's
  full recipe does this.

## 5. When `ManifoldUIModelManagement` is required

`ManifoldUIModelManagement` is the **separate, explicitly imported**
product that hosts the model browser, downloader, storage UI, and API
endpoint editor. The dependency edge runs `ManifoldUIModelManagement →
ManifoldUI` (never the reverse), which is why these views — and the
``.environment(\.endpointStore, …)`` key used by `APIConfigurationView` —
are not visible from `import ManifoldKit` / `ManifoldUI` alone. Without
`import ManifoldUIModelManagement`, the compiler reports
`EnvironmentValues has no member 'endpointStore'`.

Mount it via closure injection on `ChatView`:

```swift,no-build
import ManifoldUI
import ManifoldUIModelManagement

struct RootView: View {
    @State private var showModelManagement = false

    var body: some View {
        ChatView(showModelManagement: $showModelManagement)
            .chatAPIConfiguration { APIConfigurationView() }
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
use `ChatView(showModelManagement:)` with no `.chatAPIConfiguration(_:)`
modifier — `ChatView` defaults to an empty sheet.

## 6. Full recipe: explicit bootstrap + multi-session UI + APIConfigurationView + Ollama

This section gives the single end-to-end example that previously had to be
stitched together from `QUICKSTART.md`, `AGENTS.md`, and the DocC article.
It covers:

- **Manual `ManifoldBootstrap.build(...)` bootstrap** from a `.task { }` (async, no deadlock).
- **`SessionManagerViewModel` wired with `configureAndLoad`** (relaunch-safe restore).
- **`.environment(\.endpointStore, bootstrap.endpointStore)` injection** — requires `import ManifoldUIModelManagement` (the env key lives there, not in the umbrella).
- **Ollama endpoint pre-seeded *and loaded*** — insert alone is not enough; the recipe binds `selectedEndpoint` and awaits `loadSelectedEndpoint()` on every cold start (manual path has no `quickStart`-style auto-select).
- **`ManifoldUIModelManagement`** mounted via closure injection (optional for the model browser; required for the env-key / `APIConfigurationView` lines).

### Package dependency

Tagged release:

```swift
// Package.swift — the cloud backends (Ollama, OpenAI, Anthropic, LM Studio)
// always compile since v0.48; no traits needed.
.package(
    url: "https://github.com/ManifoldKit/ManifoldKit.git",
    from: "0.76.0" // x-release-please-version
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
import SwiftData                 // required for `.modelContainer` type-checking
import ManifoldKit
// Required for `.environment(\.endpointStore, …)`, `APIConfigurationView`,
// and `ModelManagementSheet` — the env key is NOT on the ManifoldKit umbrella.
import ManifoldUIModelManagement

@main
struct MyChatApp: App {
    @State private var bootstrap: ManifoldBootstrap?
    @State private var chatVM: ChatViewModel?
    @State private var sessionVM: SessionManagerViewModel?
    @State private var startupError: Error?
    // Named-milestone loading (2026 UI refresh, `BootstrapLoadingScreen.md`)
    // — tells the user what's actually happening on a slow first launch,
    // instead of a bare "Starting…" spinner.
    @State private var milestone: RuntimeBootstrapMilestone = .installingConfiguration

    var body: some Scene {
        WindowGroup {
            if let bootstrap, let chatVM, let sessionVM {
                RootView()
                    .environment(chatVM)
                    .environment(sessionVM)
                    // Inject the endpoint store so APIConfigurationView can
                    // persist API keys without any extra glue in the host.
                    // (Requires `import ManifoldUIModelManagement` above.)
                    .environment(\.endpointStore, bootstrap.endpointStore)
                    .modelContainer(bootstrap.modelContainer)
            } else if let startupError {
                ContentUnavailableView(
                    "Failed to start",
                    systemImage: "exclamationmark.triangle",
                    description: Text(String(describing: startupError))
                )
            } else {
                BootstrapLoadingView(milestone: milestone)
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
            for await m in progress { milestone = m }
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

            // 1) Restore or create the initial session *before* host selection.
            // `switchToSession` applies the session's persisted model/endpoint
            // IDs (and clears both when the session has none — typical for a
            // brand-new session). Selecting Ollama *before* this call is wiped.
            // Order mirrors `quickStart()` (session → select if still nil → load).
            if let restored = await sessionVM.selectInitialSession() {
                sessionVM.activeSession = restored
                await chatVM.switchToSession(restored)
            } else if let fresh = try? await sessionVM.createSession() {
                sessionVM.activeSession = fresh
                await chatVM.switchToSession(fresh)
            }

            // 2) Endpoint → model load (manual path, every cold start).
            // Unlike quickStart() relaunch, manual bootstrap does NOT auto-select
            // the first stored cloud endpoint. Insert alone leaves the composer
            // inert. Only bind when *both* model and endpoint are still nil so
            // a restored Foundation/local selection is not clobbered by Ollama.
            var endpoints = try await bootstrap.endpointStore.fetchEndpoints()
            if endpoints.isEmpty {
                let ollama = APIEndpointRecord(
                    name: "Local Ollama",
                    provider: .ollama,
                    // paste a tag from `ollama list` — the host may not have
                    // whatever default the docs last used
                    modelName: "llama3.1:8b"
                )
                try await bootstrap.endpointStore.insertEndpoint(ollama)
                endpoints = try await bootstrap.endpointStore.fetchEndpoints()
            }
            chatVM.setAvailableEndpoints(endpoints)
            if chatVM.selectedModel == nil, chatVM.selectedEndpoint == nil {
                chatVM.selectedEndpoint = endpoints.first
            }
            if chatVM.selectedEndpoint != nil {
                await chatVM.loadSelectedEndpoint()
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
            // and ManifoldUIModelManagement. Omit .chatAPIConfiguration(_:)
            // entirely if your app doesn't surface an API key editor.
            ChatView(showModelManagement: $showModelManagement)
                .chatAPIConfiguration { APIConfigurationView() }
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
> and the `.chatAPIConfiguration(_:)` modifier entirely — `ChatView` defaults
> to an empty API sheet.

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
