# Minimal Example

The smallest possible ManifoldKit app — one call to bootstrap, one view.

```swift
import SwiftUI
import ManifoldKit
import ManifoldUI

@main
struct MinimalExampleApp: App {
    @State private var result: QuickStartResult?
    @State private var error: ManifoldKitError?
    @State private var showModelManagement = false

    var body: some Scene {
        WindowGroup {
            if let result {
                NavigationStack {
                    ChatView(showModelManagement: $showModelManagement)
                }
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

`ManifoldKit.quickStart()` builds the SwiftData container, registers the
compiled-in backends, and wires up a `ChatViewModel`. On first launch (no
persisted sessions) it auto-creates an initial empty session and activates
it, so `ChatView`'s composer is enabled the moment the view appears. Errors
surface as `ManifoldKitError` — see `MinimalExampleApp.swift` for the
explicit handling shape.

## Running

1. From `Example/Examples/`, run `xcodegen` (if you haven't already).
2. Open `ManifoldExamples.xcodeproj` in Xcode.
3. Pick the **MinimalExample** scheme and run on Mac or an iOS simulator.

## What to look at next

- `Sources/ManifoldKit/QuickStart.swift` — what `quickStart()` actually does.
- `Example/Advanced/` — the advanced reference app (sessions, model
  management, custom composer accessories, etc.).
- Drop down to `ManifoldBootstrap.build(...)` directly if you need a custom
  inference service, model container, or non-default backend mix.
