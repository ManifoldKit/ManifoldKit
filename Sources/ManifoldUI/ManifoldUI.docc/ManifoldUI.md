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

    var body: some Scene {
        WindowGroup {
            if let bootstrap, let chatVM, let sessionVM {
                ContentView()
                    .environment(chatVM)
                    .environment(sessionVM)
                    .modelContainer(bootstrap.modelContainer)
            } else {
                ProgressView("Starting…").task { await start() }
            }
        }
    }

    @MainActor
    private func start() async {
        // `ManifoldBootstrap.build(...)` is async — drive it from `.task { }`
        // on the launch view, not `App.init()`. It returns a (progress, task)
        // tuple; consume the progress stream (or surface milestones to a
        // launch UI) and await the task.
        let (progress, task) = ManifoldBootstrap.build(
            configuration: ManifoldConfiguration(
                appName: "My Chat",
                bundleIdentifier: "com.example.mychat"
            )
        )
        for await _ in progress { }
        guard let bootstrap = try? await task.value else { return }
        OllamaBackends.register(with: bootstrap.inferenceService)
        CloudSaaSBackends.register(with: bootstrap.inferenceService)
        FoundationBackends.register(with: bootstrap.inferenceService)
        // `ManifoldBootstrap` conforms to `ChatRuntimeBootstrap`, so the same
        // value wires both view models.
        let chatVM = ChatViewModel(
            inferenceService: bootstrap.inferenceService,
            conversationRuntime: bootstrap.conversationRuntime
        )
        chatVM.configure(bootstrap: bootstrap)
        chatVM.refreshModels()

        let sessionVM = SessionManagerViewModel()
        await sessionVM.configureAndLoad(bootstrap: bootstrap)

        let initial = await sessionVM.selectInitialSession()
            ?? (try? await sessionVM.createSession())
        if let initial {
            sessionVM.activeSession = initial
            await chatVM.switchToSession(initial)
            chatVM.dispatchSelectedLoad()
        }

        self.bootstrap = bootstrap
        self.chatVM = chatVM
        self.sessionVM = sessionVM
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
- <doc:GenerationComponents>
- <doc:Theming>
- <doc:ComposerStyling>
- <doc:ThinkingBlockStyling>
- <doc:ToolInvocationStyling>
- <doc:SessionRowStyling>
- <doc:PartRendering>
- <doc:BootstrapLoadingScreen>

### View Models

- ``ChatViewModel``
- ``SessionManagerViewModel``

### Chat Views

- ``ChatView``
- ``ChatInputBar``
- ``MessageBubbleView``

### Generation

- ``PhotoAttachmentButton``
- ``ImageGenerationToolSource``
- ``VideoGenerationToolSource``

### Settings

- ``GenerationSettingsView``

### Session Management

- ``SessionListView``

### Runtime Contract

- ``ManifoldRuntime/ChatRuntimeBootstrap``

> Important: ``ModelManagementSheet``, ``ModelManagementViewModel``, and
> ``APIConfigurationView`` moved to the new `ManifoldUIModelManagement`
> product in v2.0. Add `import ManifoldUIModelManagement` to access them,
> or run `scripts/migrate-uimm-imports.sh` against your codebase.
