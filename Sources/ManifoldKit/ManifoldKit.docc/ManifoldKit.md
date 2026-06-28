# ``ManifoldKit``

The only open-source Swift package that bundles UI, turn-loop runtime,
persistence, and multi-backend inference into one drop-in chat product for Apple
platforms.

## Overview

Most AI-chat libraries hand you a single layer — a UI kit, an engine wrapper, or
a thin cloud client — and leave the rest as an exercise. `ManifoldKit` ships the
assembled product: import one umbrella module and you get a SwiftUI `ChatView`,
the `ConversationRuntime` turn loop (send / regenerate / edit / cancel /
branch), SwiftData persistence, model download & management UI, and inference
backends spanning on-device (MLX, llama.cpp, Apple Foundation Models) and cloud
(OpenAI, Anthropic, Ollama, LAN) — all behind one `InferenceBackend` protocol.
Swapping engines is a config change, not a rewrite.

`import ManifoldKit` re-exports the 80%-case modules — the inference surface,
`ConversationRuntime`, persistence, the backends, and the chat UI. Specialised
modules stay explicit imports: `ManifoldMCP` (Model Context Protocol),
`ManifoldVoice` (speech I/O), `ManifoldUIModelManagement` (the model browser),
and `ManifoldAppIntents`.

### Hello World

Add the package, then drop this into your app entry point.
``ManifoldKit/quickStart(configuration:)`` builds the SwiftData container,
registers the compiled-in backends, and wires up a `ChatViewModel` in one call.
Errors surface as `ManifoldKitError`.

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

> Warning: **The no-backend cliff.** With no backend registered — no companion
> backend package linked (`manifold-mlx`, `manifold-llama`, …) and no registrar
> passed via `quickStart(backends:)` — `quickStart()` compiles but throws
> `ManifoldKitError` `.noBackendsRegistered` at runtime: there is nothing to
> generate with. Add a companion package and inject its registrar (e.g.
> `quickStart(backends: [LlamaBackends.self])`). The cloud and Foundation
> families compile in unconditionally, so a cloud-only setup with no configured
> endpoint launches but logs an actionable warning instead of throwing.

### The guided path

This reference ties the module catalogs together. For the prose walkthrough from
install to first token, follow the loose-markdown front door:

- **Start here:** [Why ManifoldKit](https://github.com/ManifoldKit/ManifoldKit/blob/main/docs/WHY-MANIFOLDKIT.md) · [docs index](https://github.com/ManifoldKit/ManifoldKit/blob/main/docs/README.md)
- **Getting started:** [QUICKSTART](https://github.com/ManifoldKit/ManifoldKit/blob/main/docs/QUICKSTART.md) → [Multi-session SwiftUI](https://github.com/ManifoldKit/ManifoldKit/blob/main/docs/SWIFTUI-MULTI-SESSION.md)
- **Branch points:** [CLI / server](https://github.com/ManifoldKit/ManifoldKit/blob/main/docs/QUICKSTART-CLI.md) · [Bring your own UI](https://github.com/ManifoldKit/ManifoldKit/blob/main/docs/QUICKSTART-BRING-YOUR-OWN-UI.md)
- **Add a capability:** [Tools](https://github.com/ManifoldKit/ManifoldKit/blob/main/docs/QUICKSTART-TOOLS.md) · [App Intents](https://github.com/ManifoldKit/ManifoldKit/blob/main/docs/QUICKSTART-APPINTENTS.md) · [RAG](https://github.com/ManifoldKit/ManifoldKit/blob/main/docs/QUICKSTART-RAG.md) · [Voice](https://github.com/ManifoldKit/ManifoldKit/blob/main/docs/QUICKSTART-VOICE.md) · [Image & video gen (manifold-mlx)](https://github.com/ManifoldKit/manifold-mlx)

### The assembled surface

`import ManifoldKit` re-exports these types from their home modules. This site is
built as combined documentation, so the curated entry points below link straight
to each type's home-module page — follow any link, or the navigation sidebar, for
the full per-module reference:

- **Chat UI** (`ManifoldUI`): ``/ManifoldUI/ChatView``, ``/ManifoldUI/ChatViewModel``.
- **Bring your own UI** (`ManifoldInference` / `ManifoldRuntime`):
  ``/ManifoldInference/InferenceService``, ``/ManifoldRuntime/ConversationRuntime``,
  ``/ManifoldInference/ModelRegistry``.
- **Backends** (`ManifoldContract` + families): every engine sits behind one
  ``/ManifoldContract/InferenceBackend`` protocol. The cloud (OpenAI, Anthropic,
  Ollama, LAN) and Apple ``/ManifoldFoundation/FoundationBackend`` families compile
  in unconditionally; the on-device MLX and llama.cpp families ship as companion
  packages (`manifold-mlx`, `manifold-llama`) since v0.48 and are wired in by
  passing their registrars to ``ManifoldKit/quickStart(backends:configuration:seed:)``.
- **Persistence & bootstrap** (`ManifoldPersistenceSwiftData`):
  ``/ManifoldPersistenceSwiftData/ManifoldBootstrap``, configured by
  ``/ManifoldModelCatalog/ManifoldConfiguration``.

## Topics

### Get Started

- ``ManifoldKit/quickStart(configuration:)``
- ``ManifoldKit/quickStart(configuration:seed:)``
- ``ManifoldKit/quickStart(backends:configuration:seed:)``
- ``QuickStartResult``
- ``QuickStartSeed``
- ``/ManifoldModelCatalog/ManifoldConfiguration``
- ``/ManifoldModelCatalog/ManifoldKitError``

### Build a Chat UI

- ``/ManifoldUI/ChatView``
- ``/ManifoldUI/ChatViewModel``

### Bring Your Own UI

- ``/ManifoldInference/InferenceService``
- ``/ManifoldRuntime/ConversationRuntime``
- ``/ManifoldInference/ModelRegistry``

### Backends

Every engine sits behind one ``/ManifoldContract/InferenceBackend`` protocol; the
default registrars (`OllamaBackends`, `CloudSaaSBackends`, `FoundationBackends`,
exposed as `ManifoldKit.defaultBackendRegistrars`) register the Foundation and
cloud backends compiled into core. Cloud backends (OpenAI, Anthropic, Ollama, LAN)
live in `ManifoldOllama` / `ManifoldCloudSaaS` and are always compiled in since
v0.48 (the `CloudSaaS` / `Ollama` traits were retired). The local MLX and
llama.cpp families ship in the `manifold-mlx` / `manifold-llama` companion
packages since v0.48 — add the package and pass its registrar to
`quickStart(backends:)`.

- ``/ManifoldContract/InferenceBackend``
- ``/ManifoldFoundation/FoundationBackend``

### Persistence & Bootstrap

- ``/ManifoldPersistenceSwiftData/ManifoldBootstrap``
