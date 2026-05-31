# ``ManifoldPersistenceSwiftData``

ManifoldKit's shipped SwiftData adapter — concrete schema, container factory, port conformances, and the ``ManifoldBootstrap`` one-call wire-up for typical apps.

## Overview

`ManifoldPersistenceSwiftData` is the default storage tier for ManifoldKit. It provides:

- **`@Model` types** — `ChatSession`, `ChatMessage`, `APIEndpoint`, `SamplerPreset`, `Agent`, and the versioned schemas in `Schema/` (currently `ManifoldSchemaV9`) plus the matching `ManifoldMigrationPlan`.
- **Adapter conformances** — `SwiftDataPersistenceProvider` implements both ``MessageStore`` and ``SessionStore``; `SwiftDataEndpointStore`, `SwiftDataSamplerPresetStore`, `SwiftDataBenchmarkCache`, `SwiftDataUsageStore`, and `SwiftDataDocumentStore` cover the remaining ports.
- **``ModelContainerFactory``** — builds per-app on-disk or in-memory `ModelContainer`s, applies the configured `NSFileProtection` class on iOS, and prevents two ManifoldKit apps on the same machine from sharing a SwiftData store.
- **``ManifoldBootstrap``** — the one-call entry point that installs ``ManifoldConfiguration/shared``, builds the inference service, container, persistence adapters, and a pre-wired ``ConversationRuntime`` in a fixed safe order.

This module is layered above ``ManifoldRuntime``: it provides concrete impls of the port protocols defined there. Backend family targets do not depend on it.

## When to use this module

- **You want the shortest path to a working ManifoldKit app.** ``ManifoldBootstrap`` wires every port in the right order so you do not have to.
- **You are happy with SwiftData as your persistence backend.** No reason not to be — SwiftData is the platform default and ManifoldKit's schema migrations are versioned.
- **You want at-rest data protection on iOS.** ``ModelContainerFactory`` applies the protection class from ``ManifoldConfiguration/fileProtectionClass`` to the store and its `-shm` / `-wal` sidecars.

## When not to use this module

- **You ship your own SwiftData stack.** Skip ``ManifoldBootstrap`` and conform your own adapter to ``MessageStore`` / ``SessionStore`` directly. The "use this with your own SwiftData stack" pattern below shows the shape.
- **You are not using SwiftData at all.** Implement the ``ManifoldRuntime`` ports against whatever storage you have — Core Data, GRDB, a remote API, an in-memory fake for tests. `ManifoldPersistenceSwiftData` is one impl of the ports, not the only one.
- **You are writing a backend target.** Backends never see persistence.

## The 3–5 most-used types

### One-call bootstrap with ``ManifoldBootstrap``

The synchronous initialiser builds the full stack in the right order and exposes every wired service as a property. ``ManifoldBootstrap/conversationRuntime`` is pre-composed against the SwiftData ports so ``ChatViewModel/configure(runtime:)`` can adopt it directly:

```swift,no-build
import ManifoldInference
import ManifoldPersistenceSwiftData
import ManifoldRuntime

// Set your bundle identifier so the per-app store URL is unique. The default
// `com.manifoldkit` is intentionally invalid: two apps using the framework
// default would collide on a shared SwiftData store.
ManifoldConfiguration.shared = ManifoldConfiguration(bundleIdentifier: "com.example.MyApp")

let bootstrap = try ManifoldBootstrap(
    configuration: .shared
)

// `bootstrap.conversationRuntime` is already wired against the SwiftData
// `MessageStore` / `SessionStore` / `UsageStore` and the resolved
// `InferenceService`. Pass it into ChatViewModel (or drive it directly).
```

### Incognito (in-memory) sessions with ``ManifoldBootstrap/makeInMemory(configuration:inferenceService:ragConfiguration:)``

For sessions where conversation history must never touch disk — Incognito mode, SwiftUI Previews, or test scaffolding — use the `makeInMemory` factory. It returns a fully-wired bootstrap backed by an ephemeral SwiftData container; all data is discarded when the instance is deallocated:

```swift,no-build
let incognito = try ManifoldBootstrap.makeInMemory(
    configuration: ManifoldConfiguration(bundleIdentifier: "com.example.MyApp"),
    inferenceService: myInferenceService
)
// incognito.isInMemory == true
// Pass to ChatViewModel exactly like a regular bootstrap — no API difference.
```

Check ``ManifoldBootstrap/isInMemory`` to surface the ephemeral badge in your UI (for example the Architect view's Incognito indicator).

### Splash-screen progress with ``ManifoldBootstrap/build(configuration:inferenceService:imageGenerationService:diagnostics:sessionToolSources:hookRegistry:makeModelContainer:)``

For apps that want a launch progress UI, the static `build(configuration:)` factory returns an `AsyncStream<RuntimeBootstrapMilestone>` you can iterate on the main actor while bootstrap runs concurrently:

```swift,no-build
let (milestones, runtimeTask) = ManifoldBootstrap.build(configuration: .shared)

Task { @MainActor in
    for await milestone in milestones {
        splashProgress = milestone.fractionComplete
    }
}

let bootstrap = try await runtimeTask.value
```

### Build a `ModelContainer` directly with ``ModelContainerFactory``

Use the factory instead of constructing `ModelContainer` by hand so the current schema, migration plan, and platform-specific file protection are applied uniformly:

```swift,no-build
import ManifoldPersistenceSwiftData
import SwiftData

// On-disk store at <Application Support>/<bundleIdentifier>/store.sqlite
let container = try ModelContainerFactory.makeContainer()

// In-memory store for tests / previews
let inMemory = try ModelContainerFactory.makeInMemoryContainer()
```

### "I have my own SwiftData stack already"

If your app already owns a `ModelContainer` (sharing schemas with non-ManifoldKit features, custom directory, CloudKit syncing, etc.), pass it in via `makeModelContainer:`. ``ManifoldBootstrap`` will not own the container lifecycle — it will use the one you give it, but every adapter will share the same `mainContext`:

```swift,no-build
let bootstrap = try ManifoldBootstrap(
    configuration: .shared,
    makeModelContainer: {
        // Your existing container — possibly with a merged schema that
        // includes both your app's models and ManifoldKit's.
        try ModelContainer(
            for: Schema([
                ChatSession.self, ChatMessage.self, APIEndpoint.self,
                SamplerPreset.self, Agent.self,
                MyAppModel.self
            ]),
            migrationPlan: ManifoldMigrationPlan.self,
            configurations: [ModelConfiguration(url: myStoreURL)]
        )
    }
)
```

### "I want only some of the ports, not all of them"

Skip ``ManifoldBootstrap`` and adopt the adapters you want individually. The four standalone stores (`SwiftDataEndpointStore`, `SwiftDataSamplerPresetStore`, `SwiftDataBenchmarkCache`, `SwiftDataUsageStore`) all take a `ModelContext` and conform to their respective ports — mix and match with custom impls of the rest:

```swift,no-build
let container = try ModelContainerFactory.makeContainer()
let context = container.mainContext

// SwiftData for endpoints + samplers, custom store for messages/sessions.
let endpointStore = SwiftDataEndpointStore(modelContext: context)
let samplerPresetStore = SwiftDataSamplerPresetStore(modelContext: context)

let runtime = ConversationRuntime(
    messageStore: myCustomMessageStore,
    sessionStore: myCustomSessionStore,
    inferenceService: InferenceService()
)
```

## Beyond chat

The schema and adapters are deliberately split so non-chat use cases can opt in to the pieces they need:

- ``SwiftDataUsageStore`` records per-turn token counts; an analytics or cost-dashboard surface can read aggregates without touching messages.
- ``SwiftDataBenchmarkCache`` persists model-capability tier results — useful for any app that benchmarks local models, not just chat.
- ``SwiftDataDocumentStore`` is the RAG document index; image-generation and agent flows that ingest user files re-use it.

## Topics

### Bootstrap

- ``ManifoldBootstrap``
- ``RAGConfiguration``

### Container factory

- ``ModelContainerFactory``

### Schema

- ``ManifoldSchemaV9``
- ``ManifoldMigrationPlan``

### Adapters

- ``SwiftDataPersistenceProvider``
- ``SwiftDataEndpointStore``
- ``SwiftDataSamplerPresetStore``
- ``SwiftDataBenchmarkCache``
- ``SwiftDataUsageStore``
- ``SwiftDataDocumentStore``
- ``FlatFileVectorStore``
