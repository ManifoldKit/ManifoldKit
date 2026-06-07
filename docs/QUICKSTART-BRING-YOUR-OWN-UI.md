# Bring Your Own UI

Use ManifoldKit's inference layer with a fully custom SwiftUI interface — no `ChatView`, no `ManifoldBootstrap`, no SwiftData. This path suits evaluation, embedding inference into an existing app, or building a bespoke chat surface where the framework's transcript, scroll-anchoring, and composer are not wanted.

> Only restyling bubbles or overriding how *some* messages render? You do not need this. Keep `ChatView` and use the in-framework theming seams — `.chatTheme(_:)`, `.messageBubbleStyle(_:)`, and `.chatMessageRenderer(_:)`. See the [Theming the Chat UI](../Sources/ManifoldUI/ManifoldUI.docc/Articles/Theming.md) DocC article. Drop to full BYO-UI only when you need to replace the transcript, scroll-anchoring, and composer wholesale.

## What you depend on

Skip the `ManifoldKit` umbrella and depend on `ManifoldInference` plus the backends you want:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "ManifoldInference", package: "ManifoldKit"),
    .product(name: "ManifoldBackends", package: "ManifoldKit"),
])
```

This keeps SwiftData, `ManifoldRuntime`, and `ManifoldUI` out of your app graph entirely. The backends you get are gated by SwiftPM traits — see [QUICKSTART.md → Customizing backends](QUICKSTART.md#customizing-backends).

## Minimal headless example

Construct an `InferenceService`, register the compiled-in backends, load a model, and stream `GenerationEvent.token` values.

> **Prerequisite for this snippet:** `.builtInFoundation` is the only backend that needs no model file and no server, so it makes the shortest first-token demo — but it exists only on macOS 26 / iOS 26 **with Apple Intelligence enabled**. On older OSes (or a Mac without Apple Intelligence) it is not registered and the load throws. The snippet guards the OS at compile/runtime; if it logs the fallback message on your machine, load a local GGUF (`loadModel(from:plan:)` with a file URL) or a cloud endpoint (`loadEndpointBackend(from:)`, shown below) instead.

```swift
import ManifoldInference
import ManifoldBackends

@main
struct BYOExample {
    static func main() async throws {
        let inference = InferenceService()
        DefaultBackends.register(with: inference)

        // `.builtInFoundation` is the zero-file, zero-server choice, but Apple
        // Intelligence only exists on macOS 26 / iOS 26. Guard availability so
        // the demo degrades with a clear message instead of an opaque throw.
        guard #available(macOS 26, iOS 26, *) else {
            print("""
            Apple Intelligence (.builtInFoundation) needs macOS 26 / iOS 26 with \
            Apple Intelligence enabled. Load a local GGUF via loadModel(from:plan:) \
            with a file URL, or a cloud endpoint via loadEndpointBackend(from:) — \
            see "Cloud and local endpoints" below.
            """)
            return
        }

        try await inference.loadModel(from: .builtInFoundation, plan: .cloud())

        let stream = try inference.generate(messages: [("user", "Hello")])
        for try await event in stream.events {
            if case .token(let text) = event { print(text, terminator: "") }
        }
    }
}
```

`InferenceService` is `@MainActor @Observable`. `DefaultBackends.register(with:)` registers every backend compiled into your build and returns the count, so you can fail fast on an empty service. `loadModel(from:plan:)` takes a precomputed `ModelLoadPlan`; `.cloud()` is the factory for endpoint-backed and OS-provided models. `generate(messages:)` returns a `GenerationStream` whose `events` property is an `AsyncThrowingStream<GenerationEvent, Error>`.

## Wiring it into SwiftUI

Hold the `InferenceService` in an `@Observable @MainActor` model and append streamed tokens to a published transcript. The view binds to that state like any other SwiftUI state.

```swift,no-build
import SwiftUI
import ManifoldInference
import ManifoldBackends

@Observable
@MainActor
final class CustomChatModel {
    var transcript: [(role: String, content: String)] = []
    var streamingReply = ""
    var isGenerating = false

    private let inference = InferenceService()

    func bootstrap() async throws {
        DefaultBackends.register(with: inference)
        try await inference.loadModel(from: .builtInFoundation, plan: .cloud())
    }

    func send(_ prompt: String) async {
        transcript.append((role: "user", content: prompt))
        streamingReply = ""
        isGenerating = true
        defer { isGenerating = false }

        do {
            let stream = try inference.generate(messages: transcript)
            for try await event in stream.events {
                if case .token(let text) = event { streamingReply += text }
            }
            transcript.append((role: "assistant", content: streamingReply))
            streamingReply = ""
        } catch {
            transcript.append((role: "assistant", content: "Error: \(error.localizedDescription)"))
        }
    }
}

struct CustomChatView: View {
    @State private var model = CustomChatModel()
    @State private var draft = ""

    var body: some View {
        VStack {
            ScrollView {
                ForEach(Array(model.transcript.enumerated()), id: \.offset) { _, message in
                    Text("\(message.role): \(message.content)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !model.streamingReply.isEmpty {
                    Text("assistant: \(model.streamingReply)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack {
                TextField("Message", text: $draft)
                Button("Send") {
                    let prompt = draft
                    draft = ""
                    Task { await model.send(prompt) }
                }
                .disabled(model.isGenerating)
            }
            .padding()
        }
        .task {
            do { try await model.bootstrap() }
            catch { /* surface a load failure in your UI */ }
        }
    }
}
```

## Beyond tokens

`GenerationEvent` carries more than `.token`. The cases you will most likely switch on:

| Case | Meaning |
|------|---------|
| `.token(String)` | A content chunk. Append to the visible reply. |
| `.thinkingToken(String)` | A reasoning/thinking chunk (models that emit a separate thinking channel). Render separately or drop. |
| `.toolCall(ToolCall)` | The model asked to invoke a tool. See [QUICKSTART-TOOLS.md](QUICKSTART-TOOLS.md). |
| `.usage(prompt:completion:)` | Token accounting for the turn. |

The full case list lives in [`Sources/ManifoldInference/Models/GenerationEvent.swift`](../Sources/ManifoldInference/Models/GenerationEvent.swift). The enum is non-frozen, so an exhaustive `switch` should keep a `default` branch.

## Cloud and local endpoints

For an Ollama, OpenAI-compatible, or Anthropic endpoint, build an `APIEndpointRecord` and call `loadEndpointBackend(from:)` instead of `loadModel(from:plan:)`. Cloud SaaS providers additionally require an API key in the keychain. The endpoint construction is the same shape shown in [QUICKSTART.md → Seeding an Ollama endpoint](QUICKSTART.md#seeding-an-ollama-endpoint); only the load call differs in the BYO path (you call it on your own `InferenceService`, not through `quickStart()`).

## Where to go next

- [`docs/QUICKSTART-TOOLS.md`](QUICKSTART-TOOLS.md) — register tools and handle `.toolCall` events.
- [`docs/QUICKSTART-CLI.md`](QUICKSTART-CLI.md) — compile-tested `Package.swift` + `main.swift` for Foundation Models, local GGUF, and Ollama / OpenAI endpoints.
- [`docs/FeatureMatrix.md`](FeatureMatrix.md) — full trait → backend → capability table.
- [`docs/QUICKSTART.md`](QUICKSTART.md) — the full-stack `quickStart()` path if you decide you want `ChatView` after all.
