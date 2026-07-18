# Naming the bootstrap milestone in your launch scene

Replace a bare spinner with ``BootstrapLoadingView`` so a slow first launch tells the user what's actually happening.

## Overview

`ManifoldBootstrap.build(configuration:)` is async and returns a `(progress:, task:)` tuple — the `progress` stream emits ``RuntimeBootstrapMilestone`` values (`installingConfiguration` → `resolvingInferenceService` → `buildingModelContainer` → `wiringPersistence` → `complete`) as bootstrap advances. The canonical launch-scene recipe (see `AGENTS.md`'s bootstrap recipe) drains that stream with `for await _ in progress { }` and shows a bare `ProgressView("Starting…")` for the whole span.

``BootstrapLoadingView`` is the drop-in replacement: capture each milestone into `@State` and hand it straight to the view — no translation layer, since it consumes ``RuntimeBootstrapMilestone`` directly.

```swift
import SwiftUI
import ManifoldKit

/// Renders the milestone-named loading screen for one bootstrap phase.
/// In a real launch scene this is the view shown in place of
/// `ProgressView("Starting…")` while `@State private var milestone`
/// tracks the live progress stream (see `start()` below).
@MainActor
func launchScreen(for milestone: RuntimeBootstrapMilestone) -> some View {
    BootstrapLoadingView(milestone: milestone)
}

@main
struct BootstrapLoadingScreenSnippet {
    @MainActor
    static func main() async throws {
        let (progress, task) = ManifoldBootstrap.build(
            configuration: ManifoldConfiguration(
                appName: "My Chat",
                bundleIdentifier: "com.example.mychat"
            )
        )
        // A real launch view holds the latest milestone in `@State` and
        // re-renders `launchScreen(for:)` on every iteration instead of
        // discarding it like this drain does.
        for await milestone in progress {
            _ = launchScreen(for: milestone)
        }
        _ = try await task.value
    }
}
```

A host's actual `App.body` wires this the same way as the plain-`ProgressView` recipe — only the launch view's content changes:

```swift,no-build
@State private var milestone: RuntimeBootstrapMilestone = .installingConfiguration

var body: some Scene {
    WindowGroup {
        if let bootstrap, let chatVM {
            // ... the real chat UI, unchanged ...
        } else {
            BootstrapLoadingView(milestone: milestone)
                .task {
                    let (progress, task) = ManifoldBootstrap.build(configuration: configuration)
                    for await m in progress { milestone = m }
                    bootstrap = try? await task.value
                }
        }
    }
}
```

``BootstrapLoadingView`` is `public` rather than `package` (unlike this refresh's other new state screens) precisely because it has no call site inside `ManifoldUI` itself — bootstrap always finishes before `ChatView` exists, so a host's own launch scene is the only place it can ever run.
