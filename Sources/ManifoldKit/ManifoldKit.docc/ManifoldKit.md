# ``ManifoldKit``

The only open-source Swift package that bundles UI, turn-loop runtime,
persistence, and multi-backend inference into one drop-in chat product for Apple
platforms.

## Overview

Most AI-chat libraries hand you a single layer — a UI kit, an engine wrapper, or
a thin cloud client — and leave the rest as an exercise. `ManifoldKit` ships the
assembled product: import one umbrella module and you get a SwiftUI ``ChatView``,
the ``ConversationRuntime`` turn loop (send / regenerate / edit / cancel /
branch), SwiftData persistence, model download & management UI, and inference
backends spanning on-device (MLX, llama.cpp, Apple Foundation Models) and cloud
(OpenAI, Anthropic, Ollama, LAN) — all behind one ``InferenceBackend`` protocol.
Swapping engines is a config change, not a rewrite.

`import ManifoldKit` re-exports the 80%-case modules — the inference surface,
``ConversationRuntime``, persistence, the backends, and the chat UI. Specialised
modules stay explicit imports: `ManifoldMCP` (Model Context Protocol),
`ManifoldVoice` (speech I/O), `ManifoldUIModelManagement` (the model browser),
and `ManifoldAppIntents`.

### Hello World

Add the package, then drop this into your app entry point.
``ManifoldKit/quickStart(configuration:)`` builds the SwiftData container,
registers the compiled-in backends, and wires up a ``ChatViewModel`` in one call.
Errors surface as ``ManifoldKitError``.

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

> Important: The chat is inert until you select a model. `quickStart()` registers
> the compiled-in backends but loads none, so on first run the composer reads
> "No model loaded." Present `ModelManagementSheet` (from the opt-in
> `ManifoldUIModelManagement` module) bound to `showModelManagement`, or seed a
> model at launch.

> Warning: **The no-backend cliff.** With no backend registered — no backend
> trait enabled (`MLX`, `Llama`, `CloudSaaS`, `Ollama`, …) and no registrar
> passed via `quickStart(backends:)` — `quickStart()` compiles but throws
> ``ManifoldKitError`` `.noBackendsRegistered` at runtime: there is nothing to
> generate with. Enable a backend trait, or inject a backend package's
> registrar (e.g. `quickStart(backends: [LlamaBackends.self])`). A cloud-only
> registration with no configured endpoint launches but logs an actionable
> warning instead of throwing.

### The guided path

This reference ties the module catalogs together. For the prose walkthrough from
install to first token, follow the loose-markdown front door:

- **Start here:** [Why ManifoldKit](https://github.com/roryford/ManifoldKit/blob/main/docs/WHY-MANIFOLDKIT.md) · [docs index](https://github.com/roryford/ManifoldKit/blob/main/docs/README.md)
- **Getting started:** [QUICKSTART](https://github.com/roryford/ManifoldKit/blob/main/docs/QUICKSTART.md) → [Multi-session SwiftUI](https://github.com/roryford/ManifoldKit/blob/main/docs/SWIFTUI-MULTI-SESSION.md)
- **Branch points:** [CLI / server](https://github.com/roryford/ManifoldKit/blob/main/docs/QUICKSTART-CLI.md) · [Bring your own UI](https://github.com/roryford/ManifoldKit/blob/main/docs/QUICKSTART-BRING-YOUR-OWN-UI.md)
- **Add a capability:** [Tools](https://github.com/roryford/ManifoldKit/blob/main/docs/QUICKSTART-TOOLS.md) · [App Intents](https://github.com/roryford/ManifoldKit/blob/main/docs/QUICKSTART-APPINTENTS.md) · [RAG](https://github.com/roryford/ManifoldKit/blob/main/docs/QUICKSTART-RAG.md) · [Voice](https://github.com/roryford/ManifoldKit/blob/main/docs/QUICKSTART-VOICE.md) · [Image & video gen (manifold-mlx)](https://github.com/roryford/manifold-mlx)

## Topics

### Get Started

- ``ManifoldKit/quickStart(configuration:)``
- ``QuickStartResult``
- ``ManifoldConfiguration``
- ``ManifoldKitError``

### Build a Chat UI

- ``ChatView``
- ``ChatViewModel``

### Bring Your Own UI

- ``InferenceService``
- ``ConversationRuntime``
- ``ModelRegistry``

### Backends

Every engine sits behind one ``InferenceBackend`` protocol; ``DefaultBackends``
registers the ones compiled in for the active traits. The on-device families are
re-exported here. Cloud backends (OpenAI, Anthropic, Ollama, LAN) live in
`ManifoldOllama` / `ManifoldCloudSaaS` and are always compiled in since v0.48
(the `CloudSaaS` / `Ollama` traits were retired).

- ``InferenceBackend``
- ``DefaultBackends``
- ``MLXBackend``
- ``LlamaBackend``
- ``FoundationBackend``

### Persistence & Bootstrap

- ``ManifoldBootstrap``
