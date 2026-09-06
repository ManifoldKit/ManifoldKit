# AppIntents Integration

**Audience:** consumer
**Status:** living

Bridge an `AppIntent` into ManifoldKit's tool-calling pipeline so an inference backend can invoke it like any other registered tool. This is the entry point for surfacing existing Siri / App Shortcuts actions to the model.

The full reference — parameter-type coverage, the `Decodable` boilerplate AppIntents requires, enum handling, and approval policy — lives in the source-of-truth DocC article:

**[`Sources/ManifoldAppIntents/ManifoldAppIntents.docc/ManifoldAppIntents.md`](../Sources/ManifoldAppIntents/ManifoldAppIntents.docc/ManifoldAppIntents.md)**

This page is a thin pointer to it plus the package wiring.

## Module

`ManifoldAppIntents` is an opt-in module. It depends only on `ManifoldInference` (and AppIntents, which ships with the OS), so apps that don't need SwiftData persistence or the chat UI can adopt it with no transitive weight.

No trait required — the former `AppIntents` trait was retired in v0.48. Add the product explicitly to your target:

```swift
.package(
    url: "https://github.com/ManifoldKit/ManifoldKit.git",
    from: "0.77.0" // x-release-please-version
)
```

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "ManifoldAppIntents", package: "ManifoldKit"),
    .product(name: "ManifoldInference", package: "ManifoldKit"),
])
```

## Wiring

`AppIntentToolExecutor` wraps any `AppIntent` and exposes it through the `ToolExecutor` protocol. Register it into a `ToolRegistry`, then pass that registry to your `InferenceService`:

```swift,no-build
import ManifoldAppIntents
import ManifoldInference

let registry = ToolRegistry()
registry.register(AppIntentToolExecutor(AskManifoldDemoIntent.self))

let inference = InferenceService(toolRegistry: registry)
```

The model now sees the intent in its tool list (named from the intent type) and can invoke it whenever the conversation calls for it. The executor synthesises the JSON-Schema document from the intent's `@Parameter` properties, decodes the model's argument payload back into a fresh intent instance, calls `perform()`, and surfaces the `IntentResult` as a `ToolResult`.

## Availability and approval

`AppIntentToolExecutor` is annotated `@available(iOS 26, macOS 26, *)` — it ships alongside the on-device LLM-actuation features in the current AppIntents revision. Gate registration behind `if #available(iOS 26, macOS 26, *)` on apps with a lower deployment floor.

The executor requires per-call approval by default. For explicitly read-only intents, opt out with `approvalPolicy: .readOnlyAutoApprove`. See the DocC article for the `Decodable` conformance every bridged intent needs and the full parameter-type table.

## Where to go next

- [`docs/QUICKSTART-TOOLS.md`](QUICKSTART-TOOLS.md) — the general tool-calling guide: `ToolRegistry`, the local-model tool ceiling, approval gates, and streaming results.
- [`Sources/ManifoldAppIntents/ManifoldAppIntents.docc/ManifoldAppIntents.md`](../Sources/ManifoldAppIntents/ManifoldAppIntents.docc/ManifoldAppIntents.md) — the complete AppIntents bridge reference.
