# ``BaseChatUI``

SwiftUI views and view models for building on-device and cloud-connected chat interfaces.

## Overview

BaseChatUI provides the view layer for BaseChatKit. It depends only on ``BaseChatCore`` — it has no knowledge of specific inference backends. Drop ``ChatView`` into your app and supply a ``ChatViewModel`` to get a fully-featured chat interface: streaming generation, model selection, and session management.

### Minimum wiring

```swift
import BaseChatCore
import BaseChatInference
import BaseChatBackends
import BaseChatUI
import SwiftData
import SwiftUI

@main
struct MyApp: App {
    let runtime: BaseChatRuntime
    let chatVM: ChatViewModel

    init() {
        let runtime = try! BaseChatRuntime(
            configuration: BaseChatConfiguration(
                appName: "MyApp",
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "com.example.myapp"
            )
        )
        self.runtime = runtime

        DefaultBackends.register(with: runtime.inferenceService)

        let chatVM = ChatViewModel(inferenceService: runtime.inferenceService)
        chatVM.configure(runtime: runtime)
        chatVM.refreshModels()

        let sessionVM = SessionManagerViewModel()
        sessionVM.configure(runtime: runtime)
        if let session = sessionVM.sessions.first ?? (try? sessionVM.createSession()) {
            chatVM.switchToSession(session)
            chatVM.dispatchSelectedLoad()
        }

        self.chatVM = chatVM
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(chatVM)
        }
        .modelContainer(runtime.modelContainer)
    }
}
```

Then place ``ChatView`` in your view hierarchy:

```swift
struct ContentView: View {
    @Environment(ChatViewModel.self) var chatVM

    var body: some View {
        ChatView(
            showModelManagement: .constant(false),
            apiConfiguration: { EmptyView() }
        )
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
> ``APIConfigurationView`` moved to the new `BaseChatUIModelManagement`
> product in v2.0. Add `import BaseChatUIModelManagement` to access them,
> or run `scripts/migrate-uimm-imports.sh` against your codebase.
