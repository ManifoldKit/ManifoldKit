# Building a Chat UI

Compose ManifoldUI components into a multi-session chat application.

## Overview

This article shows the full layout pattern for an app with a sidebar session list and a main chat area, wired to the two primary view models: ``ChatViewModel`` and ``SessionManagerViewModel``.

The pattern below uses the shipped `ManifoldBootstrap` from `ManifoldPersistenceSwiftData`. `ManifoldBootstrap` conforms to ``ChatRuntimeBootstrap``, so the same value satisfies both view models' bootstrap-wiring entry points — no glue type required.

### The async bootstrap, briefly

`ManifoldBootstrap.build(...)` is the canonical way to construct a runtime. It is **async** and returns a `(progress:, task:)` tuple:

```swift,no-build
public static func build(
    configuration: ManifoldConfiguration,
    inferenceService: InferenceService? = nil,
    imageGenerationService: ImageGenerationService? = nil,
    diagnostics: DiagnosticsService = DiagnosticsService(),
    makeModelContainer: @MainActor @escaping () throws -> ModelContainer = { try ModelContainerFactory.makeContainer() }
) -> (progress: AsyncStream<RuntimeBootstrapMilestone>, task: Task<ManifoldBootstrap, any Error>)
```

The `progress` stream emits ``ManifoldPersistenceSwiftData/RuntimeBootstrapMilestone`` values (installingConfiguration → resolvingInferenceService → buildingModelContainer → wiringPersistence → complete). Apps that want a launch progress bar consume the stream; the simpler pattern below just drains it and awaits the task.

Because bootstrap is async, **wire it from `.task { }` on the root view, not `App.init()`**. `App.init()` is not an async context, and synchronously blocking on `Task.value` from the main actor will deadlock.

### App scaffold

Hold the bootstrap and view models in `@State` on the App, populate them inside `.task { }` on a launch view, then swap to the real chat UI when ready. This is the same shape used by `MinimalExample`.

```swift,no-build
import ManifoldRuntime
import ManifoldInference
import ManifoldPersistenceSwiftData
import ManifoldFoundation
import ManifoldOllama
import ManifoldCloudSaaS
import ManifoldUI
import SwiftData
import SwiftUI

@main
struct MyApp: App {
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
            // 1. Build the shipped bootstrap. The (progress, task) tuple lets
            //    callers observe milestones; here we just drain progress and
            //    await the task. Pass an explicit configuration in production
            //    so two ManifoldKit apps don't collide on the shared store
            //    path.
            let (progress, task) = ManifoldBootstrap.build(
                configuration: ManifoldConfiguration(
                    appName: "My Chat",
                    bundleIdentifier: "com.example.mychat"
                )
            )
            for await _ in progress { /* drain milestones */ }
            let bootstrap = try await task.value

            // 2. Register the compiled-in default backends against the
            //    bootstrap's shared InferenceService. `ManifoldBootstrap`
            //    constructs one for you; reuse it so both view models see
            //    the same backend registry.
            OllamaBackends.register(with: bootstrap.inferenceService)
            CloudSaaSBackends.register(with: bootstrap.inferenceService)
            FoundationBackends.register(with: bootstrap.inferenceService)
            // 3. Build the two view models. `ManifoldBootstrap` conforms to
            //    `ChatRuntimeBootstrap`, so the same value satisfies both
            //    `configure(bootstrap:)` calls below.
            let chatVM = ChatViewModel(
                inferenceService: bootstrap.inferenceService,
                conversationRuntime: bootstrap.conversationRuntime
            )
            chatVM.configure(bootstrap: bootstrap)
            chatVM.refreshModels()

            // 3a. Configure the session manager **and await its initial load**
            //     so `sessionVM.sessions` is populated before the next step
            //     inspects it. The plain `configure(bootstrap:)` overload
            //     kicks the load off as a fire-and-forget Task and returns
            //     immediately, which is the race that produced the
            //     duplicate-blank-session bug fixed in #1464. Use
            //     `configureAndLoad(bootstrap:)` from any bootstrap path that
            //     wants relaunch-safe restore — it awaits the first page so
            //     `sessions` is materially ready on return.
            let sessionVM = SessionManagerViewModel()
            await sessionVM.configureAndLoad(bootstrap: bootstrap)

            // 4. Wire automatic session-title generation from the first
            //    message of a new chat. `inferenceService` is shared.
            chatVM.onFirstMessage = { [inferenceService = bootstrap.inferenceService] session, firstMessage in
                Task { @MainActor in
                    await sessionVM.autoRenameSession(
                        session,
                        firstMessage: firstMessage,
                        inferenceService: inferenceService
                    )
                }
            }

            // 5. Restore (or create) an initial session so `ChatView`'s
            //    composer is enabled on first launch.
            //
            //    `selectInitialSession()` implements the relaunch-safe
            //    selection policy: prefer the previously active session,
            //    fall back to the most recent non-empty conversation, and
            //    only return `nil` when the store really is empty (#1464).
            //    The host decides whether to mint a blank session at that
            //    point — minting one *before* the restore probe is the
            //    naive pattern that produced repeated blank rows on
            //    relaunch.
            if let restored = await sessionVM.selectInitialSession() {
                sessionVM.activeSession = restored
                await chatVM.switchToSession(restored)
                chatVM.dispatchSelectedLoad()
            } else if let fresh = try? await sessionVM.createSession() {
                sessionVM.activeSession = fresh
                await chatVM.switchToSession(fresh)
                chatVM.dispatchSelectedLoad()
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

If you only need a single-session chat surface, prefer `ManifoldKit.quickStart()` — it collapses steps 1–5 above (minus the second view model) into one call. Drop into `ManifoldBootstrap.build(...)` directly when you need session management, a custom `InferenceService`, a custom model container, or progress-bar UI driven by ``ManifoldPersistenceSwiftData/RuntimeBootstrapMilestone``.

### Root layout with NavigationSplitView

```swift,no-build
struct RootView: View {
    @Environment(ChatViewModel.self) var chatVM
    @Environment(SessionManagerViewModel.self) var sessionVM

    var body: some View {
        NavigationSplitView {
            SessionListView()
        } detail: {
            ChatView(showModelManagement: .constant(false))
        }
        // `switchToSession(_:)` is async — the `onChange` closure itself is
        // synchronous, so wrap the hop in a Task. Capturing `chatVM` /
        // `sessionVM` from the @Environment is safe because Task inherits
        // the @MainActor context.
        .onChange(of: sessionVM.activeSession) { _, newSession in
            guard let newSession, chatVM.activeSession?.id != newSession.id else { return }
            Task {
                await chatVM.switchToSession(newSession)
                chatVM.dispatchSelectedLoad()
            }
        }
    }
}
```

Both view models share the same runtime-backed composite persistence handle `bootstrap.persistenceStores`, typed as `any SessionStore & MessageStore`, so session records created by `SessionManagerViewModel` are immediately visible to `ChatViewModel`. Call the store methods directly on that value — there is no `.sessionStore` / `.messageStore` pair to drill into:

```swift
import ManifoldKit

@main
struct PersistenceStoresExample {
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
        let session = ChatSession(title: "Seeded Session")
        try await stores.insertSession(session)
        _ = try await stores.fetchMessages(for: session.id)
    }
}
```

The root view no longer has to late-bind persistence from `modelContext` on first appearance.

### Switching sessions

When the user selects a session in the sidebar, switch the active chat context:

```swift,no-build
struct SessionListView: View {
    @Environment(ChatViewModel.self) var chatVM
    @Environment(SessionManagerViewModel.self) var sessionVM

    var body: some View {
        List(sessionVM.sessions, selection: $sessionVM.activeSession) { session in
            SessionRowView(session: session)
        }
        .onChange(of: sessionVM.activeSession) { _, newSession in
            if let session = newSession {
                Task { await chatVM.switchToSession(session) }
            }
        }
        .toolbar {
            Button("New Chat", systemImage: "square.and.pencil") {
                // Both calls are async; the button action closure is not.
                Task {
                    if let session = try? await sessionVM.createSession() {
                        await chatVM.switchToSession(session)
                    }
                }
            }
        }
    }
}
```

### Customizing the model selection experience

``ChatViewModel`` exposes ``ChatViewModel/onFirstLaunch`` for apps that want to control the initial model selection flow — for example, showing an onboarding sheet instead of auto-selecting the Foundation model:

```swift,no-build
chatVM.onFirstLaunch = {
    showOnboardingSheet = true
}
```

When `onFirstLaunch` is `nil`, ManifoldKit auto-selects the Foundation model if ``ChatViewModel/foundationModelProvider`` returns `true`:

```swift,no-build
chatVM.foundationModelProvider = { FoundationBackend.isAvailable }
```

### Adding post-generation tasks

Register background tasks that run after each response completes:

```swift,no-build
chatVM.postGenerationTasks = [
    AnalyticsLogger(),       // your PostGenerationTask conforming types
    LocalIndexUpdater()
]
```

Tasks run sequentially off `@MainActor`. Errors surface in ``ChatViewModel/backgroundTaskError`` but don't interrupt the session.

### Migrating from `configure(persistence:)`

Pre-runtime ManifoldKit apps often wired persistence from a root view's `.task` and called `chatViewModel.configure(persistence:)` once stores were available. Today the bootstrap value carries persistence, the endpoint store, diagnostics, and (optionally) the image-generation runtime — a single `configure(bootstrap:)` call wires all of them.

**Before** — view-lifecycle late-binding with hand-rolled stores:

```swift,no-build
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

**After** — runtime-driven bootstrap via `ManifoldBootstrap.build(...)`:

```swift,no-build
import SwiftUI
import SwiftData
import ManifoldInference
import ManifoldRuntime
import ManifoldPersistenceSwiftData
import ManifoldFoundation
import ManifoldOllama
import ManifoldCloudSaaS
import ManifoldUI

@main
struct ModernApp: App {
    @State private var bootstrap: ManifoldBootstrap?
    @State private var chatViewModel: ChatViewModel?
    @State private var sessionManager: SessionManagerViewModel?

    var body: some Scene {
        WindowGroup {
            if let bootstrap, let chatViewModel, let sessionManager {
                RootView()
                    .environment(chatViewModel)
                    .environment(sessionManager)
                    .modelContainer(bootstrap.modelContainer)
            } else {
                ProgressView("Starting…")
                    .task { await start() }
            }
        }
    }

    @MainActor
    private func start() async {
        let (progress, task) = ManifoldBootstrap.build(
            configuration: ManifoldConfiguration(
                appName: "Modern Chat",
                bundleIdentifier: "com.example.modern"
            )
        )
        for await _ in progress { }
        guard let bootstrap = try? await task.value else { return }
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
        }

        self.bootstrap = bootstrap
        self.chatViewModel = chatVM
        self.sessionManager = sessionVM
    }
}
```

Both view models must be configured from the bootstrap: ``ChatViewModel/configure(bootstrap:)`` wires persistence, the endpoint store, and (when present) the image-generation runtime. `SessionManagerViewModel.configureAndLoad(bootstrap:)` wires the same persistence plus diagnostics **and awaits the initial session-list load** before returning. Skipping the session-manager configuration leaves it on a nil-persistence path that fails on first save; using the non-awaiting `configure(bootstrap:)` overload from a relaunch-aware host produces the duplicate-blank-session race described in #1464.

### Relaunch / restore guarantees

After ``SessionManagerViewModel/configureAndLoad(bootstrap:)`` returns, `sessions` reflects the first persisted page. Calling ``SessionManagerViewModel/selectInitialSession()`` returns the session the host should restore as `activeSession`, preferring (in order) the previously active session, the most recent non-empty conversation, and finally the most recent session in the list. It returns `nil` only when no sessions exist — at which point the host decides whether to mint a fresh blank session. Assigning the returned record (or any subsequent user selection) to `activeSession` automatically persists it as the new last-active session for the next relaunch. No custom polling or wait heuristics are required.

Keep ``ChatViewModel/configure(persistence:)`` for adopters that provide custom ``SessionStore`` / ``MessageStore`` impls (e.g. an in-memory test fixture, or a non-SwiftData backing store) — construct ``ChatViewModel`` and ``SessionManagerViewModel`` directly and call `configure(persistence:)`. The shipped SwiftData bootstrap and custom stores both satisfy the same runtime-port boundary.

### Wiring `APIConfigurationView` from `ManifoldUIModelManagement`

`ChatView` accepts a host-supplied API-key recovery sheet via the `.chatAPIConfiguration(_:)` modifier, a `@ViewBuilder` closure. The closure-injection pattern is **the canonical way** to mount `ManifoldUIModelManagement.APIConfigurationView` from a host that depends on both chat surfaces — and it is structural, not stylistic. Without it, `ManifoldUI` would have to import `ManifoldUIModelManagement` to reference the view directly, which would close a forbidden import cycle (the dependency edge runs UIModelManagement → UI, never the reverse). Closure injection lets the host module sit above both and pass the value down by name.

```swift,no-build
import ManifoldUI
import ManifoldUIModelManagement

struct RootView: View {
    @State private var showModelManagement = false

    var body: some View {
        ChatView(showModelManagement: $showModelManagement)
            .chatAPIConfiguration { APIConfigurationView() }
    }
}
```

Set `.environment(\.endpointStore, bootstrap.endpointStore)` on `ChatView` or
an ancestor. `ChatView` explicitly carries that custom environment value into
the API-configuration sheet/popover content, so `APIConfigurationView` can
read and write the bootstrap store.

Hosts that don't use `ManifoldUIModelManagement` (e.g. cloud-only builds or apps with their own settings UI) can use `ChatView(showModelManagement:)` with no `.chatAPIConfiguration(_:)` modifier; `ChatView` supplies an empty API sheet for them.

**LAST-WINS:** applying `.chatAPIConfiguration(_:)` more than once replaces the previous closure entirely — there is no merging. The closure is invoked at sheet/popover presentation time, not when the modifier is applied, so any `@Environment` or `@Bindable` lookups inside `APIConfigurationView` resolve against the live view tree rather than the value captured at construction. `ChatView` forwards its `endpointStore` value explicitly because custom environment keys do not reliably inherit across this presentation boundary.

## Next Steps

- See [`docs/SWIFTUI-MULTI-SESSION.md`](../../../../docs/SWIFTUI-MULTI-SESSION.md) for the single canonical guide to multi-session UI, relaunch restore, `APIConfigurationView`, local SwiftPM path, and a complete end-to-end recipe covering everything in one place.
- See ``GenerationSettingsView`` to give users control over temperature and prompt templates
- See `ManifoldUIModelManagement.ModelManagementSheet` for the combined model selection, download, and storage UI (now in the peeled `ManifoldUIModelManagement` product — `import` it explicitly)
- See ``ManifoldConfiguration/Features`` to hide UI features that don't apply to your deployment
