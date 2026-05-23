# ``ManifoldUI``

SwiftUI views and view models for building on-device and cloud-connected chat interfaces.

## Overview

ManifoldUI provides the view layer for ManifoldKit. It depends on ``ManifoldRuntime`` (the persistence-free orchestration target) and exposes cloud endpoint selection through SwiftData-free `APIEndpointRecord` values. SwiftData `APIEndpoint` rows are converted by the persistence adapters before reaching UI state. It has no knowledge of specific inference backends. Drop ``ChatView`` into your app and supply a ``ChatViewModel`` to get a fully-featured chat interface: streaming generation, model selection, and session management.

`ChatInputBar` automatically exposes image attachments only when the active backend's ``BackendCapabilities/supportsVision`` flag is `true`. If a host routes image-bearing history to a text-only backend anyway, the runtime fails fast rather than silently flattening the images away.

Turn-loop orchestration — send, regenerate, edit, cancel, and branch — lives in `ConversationRuntime` (in `ManifoldRuntime`). `ChatViewModel` forwards user actions to the runtime and renders its `ConversationEvent` stream; there is no second path.

### Minimum wiring

```swift,no-build
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
        self.sessionVM = sessionVM
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(chatVM)
                .environment(sessionVM)
                // `switchToSession` and `createSession` are async, so the
                // initial activation runs in `.task` rather than `App.init()`
                // (which is not an async context).
                .task {
                    let initial = sessionVM.sessions.first
                        ?? (try? await sessionVM.createSession())
                    if let initial {
                        await chatVM.switchToSession(initial)
                        chatVM.dispatchSelectedLoad()
                    }
                }
        }
    }
}
```

Then place ``ChatView`` in your view hierarchy:

```swift,no-build
struct ContentView: View {
    @Environment(ChatViewModel.self) var chatVM

    var body: some View {
        ChatView(showModelManagement: .constant(false))
    }
}
```

For a sidebar-based layout with multiple sessions, combine ``ChatView`` with ``SessionListView`` and ``SessionManagerViewModel``. See <doc:BuildingAChatUI> for the full pattern.

## Topics

### Getting Started

- <doc:BuildingAChatUI>

### View Models

- ``ChatViewModel``
- ``SessionManagerViewModel``

### Chat Views

- ``ChatView``
- ``ChatInputBar``
- ``MessageBubbleView``

### Settings

- ``GenerationSettingsView``

### Session Management

- ``SessionListView``

> Important: ``ModelManagementSheet``, ``ModelManagementViewModel``, and
> ``APIConfigurationView`` moved to the new `ManifoldUIModelManagement`
> product in v2.0. Add `import ManifoldUIModelManagement` to access them,
> or run `scripts/migrate-uimm-imports.sh` against your codebase.
