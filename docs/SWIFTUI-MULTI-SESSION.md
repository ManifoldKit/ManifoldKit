# Building a Multi-Session SwiftUI Chat App

The canonical guide for SwiftUI hosts that want a sidebar of chats, a chat
detail view, persisted history, and turnkey relaunch restore. This document
supersedes the per-doc fragments adopters previously had to stitch together
(`docs/QUICKSTART.md`, `BuildingAChatUI.md`, `Example/Examples/MinimalExample/`,
the README quickstart) for SwiftUI multi-session use.

If you only need a single-session chat surface, stop here and read
`docs/QUICKSTART.md` — it covers the one-call `ManifoldKit.quickStart()` path
and the simplest `ChatView` placement.

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
                              // + ManifoldPersistenceSwiftData + ManifoldBackends + ManifoldUI

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
DefaultBackends.register(with: bootstrap.inferenceService)

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

No additional steps. `DefaultBackends.register(with:)` installs
`FoundationBackend` automatically when the OS version qualifies. The chat
view model auto-selects the Foundation model on first launch via
``ChatViewModel/foundationModelProvider``; override it (or set
``ChatViewModel/onFirstLaunch``) if you want to show an onboarding sheet
instead.

### Local GGUF (llama.cpp) and MLX

Local models need a downloaded weights file before the chat surface can
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

## 6. Persistence and relaunch guarantees

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

## 7. Common pitfalls

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
- **Forgetting `DefaultBackends.register(with: bootstrap.inferenceService)`.**
  Without it, no backend will satisfy a generation request and the
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
