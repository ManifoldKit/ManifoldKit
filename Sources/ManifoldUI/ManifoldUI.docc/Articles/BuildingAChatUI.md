# Building a Chat UI

Compose ManifoldUI components into a multi-session chat application.

## Overview

This article shows the full layout pattern for an app with a sidebar session list and a main chat area, wired to the two primary view models: ``ChatViewModel`` and ``SessionManagerViewModel``.

### App scaffold

Create both view models at the app level and share the same `InferenceService` between them. ``SessionManagerViewModel`` only manages session metadata — it never touches inference directly. ``ChatViewModel`` drives all generation.

```swift
import ManifoldRuntime
import ManifoldInference
import ManifoldBackends
import ManifoldUI
import SwiftUI

@main
struct MyApp: App {
    let runtime: any ChatRuntimeBootstrap
    let inferenceService: InferenceService
    let chatVM: ChatViewModel
    let sessionVM: SessionManagerViewModel

    init() {
        let inferenceService = InferenceService()
        DefaultBackends.register(with: inferenceService)

        // AppRuntime lives in your app composition root. It may wrap the
        // shipped SwiftData bootstrap or your own SessionStore/MessageStore.
        let runtime = AppRuntime.make(inferenceService: inferenceService)
        self.runtime = runtime
        self.inferenceService = inferenceService

        let chatVM = ChatViewModel(inferenceService: inferenceService)
        chatVM.configure(runtime: runtime)
        chatVM.refreshModels()
        self.chatVM = chatVM

        let sessionVM = SessionManagerViewModel()
        sessionVM.configure(runtime: runtime)
        let initialSession = sessionVM.sessions.first ?? (try? sessionVM.createSession())
        if let initialSession {
            sessionVM.activeSession = initialSession
            chatVM.switchToSession(initialSession)
            chatVM.dispatchSelectedLoad()
        }
        self.sessionVM = sessionVM

        // Connect session title generation to InferenceService
        chatVM.onFirstMessage = { session, firstMessage in
            Task { @MainActor in
                await sessionVM.autoRenameSession(
                    session,
                    firstMessage: firstMessage,
                    inferenceService: inferenceService
                )
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(chatVM)
                .environment(sessionVM)
        }
    }
}
```

### Root layout with NavigationSplitView

```swift
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
            guard let newSession, chatVM.activeSession?.id != newSession.id else { return }
            chatVM.switchToSession(newSession)
            chatVM.dispatchSelectedLoad()
        }
    }
}
```

Both view models share the same runtime-backed ``SessionStore`` / ``MessageStore`` ports, so session records created by `SessionManagerViewModel` are immediately visible to `ChatViewModel`. The root view no longer has to late-bind persistence from `modelContext` on first appearance.

### Switching sessions

When the user selects a session in the sidebar, switch the active chat context:

```swift
struct SessionListView: View {
    @Environment(ChatViewModel.self) var chatVM
    @Environment(SessionManagerViewModel.self) var sessionVM

    var body: some View {
        List(sessionVM.sessions, selection: $sessionVM.activeSession) { session in
            SessionRowView(session: session)
        }
        .onChange(of: sessionVM.activeSession) { _, newSession in
            if let session = newSession {
                chatVM.switchToSession(session)
            }
        }
        .toolbar {
            Button("New Chat", systemImage: "square.and.pencil") {
                let session = try? sessionVM.createSession()
                if let session { chatVM.switchToSession(session) }
            }
        }
    }
}
```

### Customizing the model selection experience

``ChatViewModel`` exposes ``ChatViewModel/onFirstLaunch`` for apps that want to control the initial model selection flow — for example, showing an onboarding sheet instead of auto-selecting the Foundation model:

```swift
chatVM.onFirstLaunch = {
    showOnboardingSheet = true
}
```

When `onFirstLaunch` is `nil`, ManifoldKit auto-selects the Foundation model if ``ChatViewModel/foundationModelProvider`` returns `true`:

```swift
chatVM.foundationModelProvider = { FoundationBackend.isAvailable }
```

### Adding post-generation tasks

Register background tasks that run after each response completes:

```swift
chatVM.postGenerationTasks = [
    AnalyticsLogger(),       // your PostGenerationTask conforming types
    LocalIndexUpdater()
]
```

Tasks run sequentially off `@MainActor`. Errors surface in ``ChatViewModel/backgroundTaskError`` but don't interrupt the session.

### Migrating from `configure(persistence:)`

Pre-runtime ManifoldKit apps often wired persistence from a root view's `.task` and called `chatViewModel.configure(persistence:)` once stores were available. A ``ChatRuntimeBootstrap`` collapses that into a single bootstrap value in `App.init()` while keeping ManifoldUI behind runtime ports.

**Before** — view-lifecycle late-binding:

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

**After** — runtime-driven bootstrap:

```swift
import SwiftUI
import ManifoldRuntime
import ManifoldInference
import ManifoldUI

@main
struct ModernApp: App {
    private let runtime: any ChatRuntimeBootstrap
    @State private var chatViewModel: ChatViewModel
    @State private var sessionManager: SessionManagerViewModel

    init() {
        let inferenceService = InferenceService()
        let runtime = AppRuntime.make(inferenceService: inferenceService)
        self.runtime = runtime

        let chatVM = ChatViewModel(inferenceService: inferenceService)
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
    }
}
```

Both view models must be configured from the runtime: `ChatViewModel.configure(runtime:)` wires persistence for chat sessions, and `SessionManagerViewModel.configure(runtime:)` wires persistence and diagnostics for the session list. Skipping the session-manager configuration leaves it on a nil-persistence path that fails on first save. Apps that buffered inbound payloads in `App.init()` for processing once persistence was wired should keep that pattern — the runtime makes persistence available before view rendering, so the buffer can drain immediately on first appearance.

Attach any persistence-specific scene modifiers from the app or persistence target. ManifoldUI only requires the runtime-port values exposed by ``ChatRuntimeBootstrap``.

Keep `configure(persistence:)` for adopters that provide custom ``SessionStore`` / ``MessageStore`` impls (e.g. an in-memory test fixture, or a non-SwiftData backing store) — construct ``ChatViewModel`` and ``SessionManagerViewModel`` directly and call `configure(persistence:)`. The shipped SwiftData bootstrap and custom stores both satisfy the same runtime-port boundary.

### Wiring `APIConfigurationView` from `ManifoldUIModelManagement`

`ChatView` accepts a `@ViewBuilder apiConfiguration:` closure that returns the host's API-key recovery sheet. The closure-injection pattern is **the canonical way** to mount `ManifoldUIModelManagement.APIConfigurationView` from a host that depends on both chat surfaces — and it is structural, not stylistic. Without it, `ManifoldUI` would have to import `ManifoldUIModelManagement` to reference the view directly, which would close a forbidden import cycle (the dependency edge runs UIModelManagement → UI, never the reverse). Closure injection lets the host module sit above both and pass the value down by name.

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
    }
}
```

Hosts that don't use `ManifoldUIModelManagement` (e.g. cloud-only builds or apps with their own settings UI) can use `ChatView(showModelManagement:)`; the `APIConfig == EmptyView` convenience initializer supplies the empty API sheet for them.

The closure is invoked at sheet/popover presentation time, not at `ChatView` init, so any `@Environment` or `@Bindable` lookups inside `APIConfigurationView` resolve against the live view tree rather than the value captured at construction.

## Next Steps

- See ``GenerationSettingsView`` to give users control over temperature and prompt templates
- See `ManifoldUIModelManagement.ModelManagementSheet` for the combined model selection, download, and storage UI (now in the peeled `ManifoldUIModelManagement` product — `import` it explicitly)
- See ``ManifoldConfiguration/Features`` to hide UI features that don't apply to your deployment
