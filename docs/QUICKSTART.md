# ManifoldKit Quickstart

A one-page tutorial for getting from "empty SwiftUI project" to "working chat UI" in under five minutes. If you already have a working bootstrap, jump to [Customizing backends](#customizing-backends) or [Customizing storage](#customizing-storage).

## Prerequisites

- Xcode 16+ on macOS, or Swift 6.2+ toolchain (`swift-tools-version: 6.2` is required for `.macOS(.v26)` / `.iOS(.v26)` platform entries).
- A SwiftUI app target on iOS 18+ / macOS 15+ (Apple Foundation Models require iOS 26+ / macOS 26+).
- Familiarity with SwiftUI's `App` protocol and `@State`. No prior knowledge of MLX, llama.cpp, MCP, or any specific backend is assumed.

## Install

Add ManifoldKit to your `Package.swift` (or Xcode's *Package Dependencies*):

```swift
.package(
    url: "https://github.com/roryford/ManifoldKit.git",
    from: "0.31.0" // x-release-please-version
)
```

Then depend on the `ManifoldKit` umbrella product from your app target:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "ManifoldKit", package: "ManifoldKit"),
])
```

The umbrella re-exports `ManifoldRuntime`, `ManifoldPersistenceSwiftData`, `ManifoldBackends`, `ManifoldUI`, and `ManifoldInference` so one `import ManifoldKit` covers the common surface.

## Hello World

`ManifoldKit.quickStart()` builds the SwiftData container, registers the compiled-in backends, and wires up a `ChatViewModel` in one async call. Errors normalise to [`ManifoldKitError`](../Sources/ManifoldInference/ManifoldKitError.swift).

```swift
import SwiftUI
import SwiftData
import ManifoldKit
import ManifoldUI

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

Run the app. On macOS or iOS 26+, the Apple Foundation Models backend is available immediately; for other backends, see [Customizing backends](#customizing-backends).

## Customizing backends

`quickStart()` registers every backend that's compiled into your build (gated by SwiftPM traits). To control which backends ship, pass a `traits:` array on your `.package(...)` dependency:

```swift
.package(
    url: "https://github.com/roryford/ManifoldKit.git",
    from: "0.31.0", // x-release-please-version
    traits: [
        .trait(name: "MLX"),           // default-on
        .trait(name: "Llama"),         // default-on
        .trait(name: "CloudSaaS"),     // opt-in: OpenAI, Claude
        .trait(name: "Ollama"),        // opt-in: localhost:11434
    ]
)
```

Common profiles:

| Use case | Traits |
|----------|--------|
| Default consumer app | leave defaults (`MLX`, `Llama`, `HuggingFace`) |
| App Store-lean (Foundation Models only) | `["FoundationOnly"]` — see [docs/AppStoreSubmission.md](AppStoreSubmission.md) |
| SaaS-only | `["CloudSaaS"]` (drop MLX/Llama if you don't need local models) |
| Self-hosted / private datacenter | `["MLX", "Llama", "Ollama"]` |
| Full | `["MLX", "Llama", "Ollama", "CloudSaaS"]` |

See [`docs/FeatureMatrix.md`](FeatureMatrix.md) for the full trait → capability table.

### Bring your own UI

If you don't want `ChatView` and prefer your own SwiftUI surface, skip `quickStart()` and depend on just `ManifoldInference` plus the backends you want. Construct an `InferenceService` directly, register the compiled backends, and stream `GenerationEvent.token` into your transcript:

```swift,no-build
import ManifoldInference
import ManifoldBackends

let inference = InferenceService()
DefaultBackends.register(with: inference)

try await inference.loadModel(from: .builtInFoundation, plan: .cloud())

let stream = try inference.generate(messages: [("user", "Hello")])
for try await event in stream.events {
    if case .token(let text) = event { print(text, terminator: "") }
}
```

This keeps SwiftData, `ManifoldRuntime`, and `ManifoldUI` out of your app graph entirely.

## Customizing storage

`ManifoldKit.quickStart(configuration:)` accepts a `ManifoldConfiguration`. Override the bundle identifier so two ManifoldKit-based apps on the same machine don't collide on the shared SwiftData store path:

```swift,no-build
result = try await ManifoldKit.quickStart(
    configuration: ManifoldConfiguration(
        appName: "My Chat App",
        bundleIdentifier: "com.example.mychatapp"
    )
)
```

If you need a custom `ModelContainer` (e.g. for testing, or to attach a second schema), drop down to `ManifoldBootstrap.build(...)` directly — `quickStart()` is the no-decisions-required path. The model container produced by either route attaches to your scene with the standard `.modelContainer(_:)` modifier, so `@Query` and `@Environment(\.modelContext)` work in your views unchanged.

## Error handling

Every public throws from the bootstrap path normalises to [`ManifoldKitError`](../Sources/ManifoldInference/ManifoldKitError.swift). Catch it once at the call site and read `errorDescription` for a user-facing string:

```swift,no-build
do {
    result = try await ManifoldKit.quickStart()
} catch let e as ManifoldKitError {
    // Already normalised — show e.errorDescription
    error = e
} catch {
    // Belt-and-braces for anything that escapes the normaliser
    error = .from(error)
}
```

`ManifoldKitError` wraps the underlying cause so logs can still surface the original `URLError` / SwiftData error if you need it for diagnostics.

## Where to go next

- [`docs/FeatureMatrix.md`](FeatureMatrix.md) — full trait → backend → capability table.
- [`Example/Examples/MinimalExample`](../Example/Examples/MinimalExample) — runnable minimum-viable app.
- [`Example/Advanced`](../Example/Advanced) — full reference app with sessions, model management, and a custom composer accessory.
- [CONTRIBUTING.md](../CONTRIBUTING.md) — architecture invariants and how to add a backend.
- [CLAUDE.md](../CLAUDE.md) — target layout, dependency rules, and platform policy.
