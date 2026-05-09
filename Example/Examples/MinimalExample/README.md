# Minimal Example

The simplest possible ManifoldKit app. Demonstrates the bare minimum setup:

- Create a `ManifoldBootstrap` at startup
- Register backends with `DefaultBackends.register(with:)`
- Configure a `ChatViewModel` and `SessionManagerViewModel` from the runtime
- Present `ChatView` with environment wiring

## Running

1. Open `ManifoldExamples.xcodeproj` in Xcode
2. Select the **MinimalExample** scheme
3. Build and run on iOS Simulator or Mac

## What to Look At

- `MinimalExampleApp.swift` — app entry point and runtime assembly
- `MinimalContentView.swift` — wraps `ChatView` with the thinnest possible shell

## Next Steps

See the other examples for specific features (narration, remote backends, tool calling, RAG).
