# ManifoldKit CLI / Headless Quickstart

A one-page tutorial for getting from "empty terminal" to "streaming tokens" without SwiftUI. If you're building a CLI, a server, an App Intents extension, a fuzz harness, or any non-SwiftUI consumer, start here.

> **macOS version matters for backend choice.** ManifoldKit officially supports macOS 15+ (its `n-1` floor), but the simplest documented backend — Apple Foundation Models — is macOS 26 / iOS 26 only. The table below maps backend → minimum platform so you don't pick one that won't run.
>
> | Backend           | Minimum platform              | Network? | Section            |
> |-------------------|-------------------------------|----------|--------------------|
> | Foundation Models | macOS 26 / iOS 26             | No       | [§1](#1-foundation-models-macos-26)         |
> | Local GGUF (Llama)| macOS 15 / iOS 18 (Apple Silicon) | No       | [§2](#2-local-gguf-via-the-llama-backend-macos-15)         |
> | Ollama / OpenAI / Anthropic | macOS 15 / iOS 18 | Yes      | [§3](#3-cloud--ollama-via-loadcloudbackend)         |
>
> If you're on macOS 15 and want a fully local model, skip directly to [§2](#2-local-gguf-via-the-llama-backend-macos-15). Foundation Models will not load.

Each section below is a complete, compile-tested example: a full `Package.swift` plus a full `main.swift`, ready to copy-paste into an empty directory and `swift run`.

> **Evaluating against a local checkout?** Swap the `.package(url:from:)` line in each section for `.package(name: "ManifoldKit", path: "/path/to/ManifoldKit")`. The `name:` argument is required — SwiftPM derives package identity from the last path component of `.package(path:)`, which breaks under non-default checkout paths (e.g. worktrees, custom directory names). `traits:` works on this form too — `.package(name: "ManifoldKit", path: "/path/to/ManifoldKit", traits: [.trait(name: "Ollama")])` for the §3 cloud snippet.

---

## Package dependency forms

The sections below each show the tagged-release form. Two alternate forms are worth knowing.

### Local-path form (local checkout, worktree, or monorepo)

```swift,no-build
dependencies: [
    // name: is required — SwiftPM derives identity from the last path component,
    // which breaks when the checkout directory is named differently from the package
    // (e.g. "ManifoldKit.worktrees/feat-foo", "vendor/mk", a bare git worktree path).
    .package(name: "ManifoldKit", path: "../ManifoldKit"),
],
```

> **The `name:` argument is not optional here.** Without it, `.package(path: "../ManifoldKit")` derives the package name from `"ManifoldKit"` (the last path component), which happens to work in a standard clone but silently breaks in worktrees and non-default directory names. Always pass `name: "ManifoldKit"` explicitly on local-path dependencies.

### Trait-selection form (opt in to specific backends)

ManifoldKit uses [SwiftPM package traits](https://github.com/apple/swift-evolution/blob/main/proposals/0394-swiftpm-expression-macros.md) to gate optional backends. The default trait set (`MLX`, `Llama`, `HuggingFace`) is suitable for most consumers, but you can opt in to additional traits — or limit to a subset — by passing `traits:`:

```swift,no-build
dependencies: [
    .package(
        url: "https://github.com/roryford/ManifoldKit.git",
        from: "0.41.0", // x-release-please-version
        traits: [
            .trait(name: "Ollama"),     // local Ollama server
            .trait(name: "CloudSaaS"),  // OpenAI / Anthropic
            // Omit "MLX" / "Llama" to skip those backends entirely
            // (saves compile time if you're cloud-only).
        ]
    ),
],
```

> **Both forms are composable.** A local-path dependency can specify traits too: `.package(name: "ManifoldKit", path: "../ManifoldKit", traits: [.trait(name: "Ollama")])`.

---

## 1. Foundation Models (macOS 26)

The smallest possible CLI. No model files to manage, no network calls, no API keys — Foundation Models ships with the OS on macOS 26 / iOS 26. If you're on a current Apple OS and your privacy / latency budget allows the on-device Apple model, this is the fastest path to a working binary.

**`Package.swift`:**

```swift
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ChatCLIFoundation",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "chat-cli-foundation", targets: ["ChatCLIFoundation"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/roryford/ManifoldKit.git",
            from: "0.41.0" // x-release-please-version
        ),
    ],
    targets: [
        .executableTarget(
            name: "ChatCLIFoundation",
            dependencies: [
                .product(name: "ManifoldInference", package: "ManifoldKit"),
                .product(name: "ManifoldBackends", package: "ManifoldKit"),
            ]
        ),
    ]
)
```

**`Sources/ChatCLIFoundation/main.swift`:**

```swift
import Foundation
import ManifoldInference
import ManifoldBackends

@main
@MainActor
struct ChatCLIFoundation {
    static func main() async throws {
        let inference = InferenceService()
        DefaultBackends.register(with: inference)

        // .builtInFoundation is a sentinel ModelInfo that targets Apple's
        // on-device Foundation Models. .cloud() is the matching ModelLoadPlan
        // shape for backends that don't load files off disk.
        try await inference.loadModel(from: .builtInFoundation, plan: .cloud())

        let stream = try inference.generate(messages: [("user", "Say hello in five words.")])
        for try await event in stream.events {
            if case .token(let text) = event {
                print(text, terminator: "")
                fflush(stdout)
            }
        }
        print("")
    }
}
```

Both `InferenceService.loadModel(...)` and `InferenceService.generate(...)` are `@MainActor`-isolated — that's why the example's enclosing scope is annotated `@MainActor`. The compiler will reject a non-`@MainActor` call site with a region-isolation error in Swift 6 mode. (SwiftUI consumers never notice because `App.body` is already on the main actor.)

---

## 2. Local GGUF via the Llama backend (macOS 15+)

This is the section that closes the "I'm on macOS 15 and want to evaluate ManifoldKit" gap. The Llama backend loads GGUF files via llama.cpp + Metal and runs on every supported platform.

**Get a model first.** Drop any GGUF file into `~/Documents/Models/`. SwiftUI hosts that use `ModelManagementSheet` discover both `~/Documents/Models` and the app-scoped Application Support directory — see [`docs/LOCAL-GGUF.md`](LOCAL-GGUF.md) for the full storage contract. Good starter picks:

- [`Llama-3.2-3B-Instruct-Q4_K_M.gguf`](https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF) — ~2 GB, instruction-tuned, no reasoning tokens — **the snippet below works with this model unchanged**
- [`Qwen3-0.6B-Q4_K_M.gguf`](https://huggingface.co/Qwen/Qwen3-0.6B-GGUF) — ~400 MB, fast, but emits `.thinkingToken` events before its final answer — see ["Reasoning models" below](#reasoning-models-thinking-tokens) before using
- Any other GGUF you've downloaded via HuggingFace, Ollama, or LM Studio

> **Known issue with Llama-3 family multi-turn**: tracked at [#1398](https://github.com/roryford/ManifoldKit/issues/1398) — long multi-turn conversations may produce ChatML control-token leakage and hallucinated turns. Single-turn use is unaffected.

**`Package.swift`:**

```swift
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ChatCLILlama",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "chat-cli-llama", targets: ["ChatCLILlama"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/roryford/ManifoldKit.git",
            from: "0.41.0" // x-release-please-version
        ),
    ],
    targets: [
        .executableTarget(
            name: "ChatCLILlama",
            dependencies: [
                .product(name: "ManifoldInference", package: "ManifoldKit"),
                .product(name: "ManifoldBackends", package: "ManifoldKit"),
            ]
        ),
    ]
)
```

**`Sources/ChatCLILlama/main.swift`:**

```swift
import Foundation
import ManifoldInference
import ManifoldBackends

@main
@MainActor
struct ChatCLILlama {
    static func main() async throws {
        // 1. Locate the GGUF on disk. Adjust to taste — or read it from argv.
        let modelURL = URL(fileURLWithPath: NSString(
            string: "~/Documents/Models/Llama-3.2-3B-Instruct-Q4_K_M.gguf"
        ).expandingTildeInPath)

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            FileHandle.standardError.write(Data(
                "Model not found at \(modelURL.path)\n".utf8
            ))
            exit(1)
        }

        // 2. ModelInfo(ggufURL:) is a failable factory. It validates GGUF
        // magic bytes and returns nil for files that aren't valid GGUFs.
        guard let model = ModelInfo(ggufURL: modelURL) else {
            FileHandle.standardError.write(Data(
                "Not a valid GGUF: \(modelURL.path)\n".utf8
            ))
            exit(1)
        }

        // 3. ModelLoadPlan.compute(...) figures out a safe load shape for the
        // host — context size clamped to available RAM, mmap vs in-memory,
        // KV-cache sizing. See the parameter notes below the snippet.
        let plan = ModelLoadPlan.compute(
            for: model,
            requestedContextSize: 2048,
            strategy: .mappable,
            environment: .init(
                availableMemoryBytes: { ProcessInfo.processInfo.physicalMemory },
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
            )
        )

        // 4. Standard service construction. DefaultBackends.register wires
        // the Llama backend (and every other compiled-in backend) into the
        // service's routing table.
        let inference = InferenceService()
        DefaultBackends.register(with: inference)

        try await inference.loadModel(from: model, plan: plan)

        // 5. Stream tokens. GenerationStream is NOT itself an AsyncSequence —
        // iterate `stream.events`.
        let stream = try inference.generate(
            messages: [("user", "Say hello in five words.")],
            systemPrompt: "You are a concise assistant.",
            temperature: 0.7,
            topP: 0.95,
            repeatPenalty: 1.1,
            maxOutputTokens: 256
        )

        for try await event in stream.events {
            if case .token(let text) = event {
                print(text, terminator: "")
                fflush(stdout)
            }
        }
        print("")

        // 6. Clean up. See "Cleaning up" below for the Llama-specific
        // teardown caveat — this Task.sleep is intentional.
        inference.unloadModel()
        try? await Task.sleep(nanoseconds: 500_000_000)
    }
}
```

### What `ModelLoadPlan.compute(...)` is doing

- **`for:`** — the `ModelInfo` you're loading. The plan reads `model.estimatedMemoryBytes` and `model.architecture` to size the KV cache and decide whether the model fits.
- **`requestedContextSize:`** — your *requested* context window in tokens. The planner clamps it down if RAM would be exhausted. `2048` is a safe starter; bump it for longer conversations. Set to `0` to ask for the model's natural maximum (clamped automatically).
- **`strategy: .mappable`** — matches llama.cpp's `mmap` behaviour. The weights are paged in from disk on demand instead of being copied into RSS up front. Use `.inMemory` only if you've explicitly disabled mmap and need every byte resident. For GGUF on Apple Silicon, `.mappable` is the right default.
- **`environment:`** — a snapshot of host memory the planner reasons about. The two closures let you mock available memory in tests; in production, `ProcessInfo.processInfo.physicalMemory` for both is fine. The planner will refuse to construct a plan it can't honour.

The plan is a *value type* — it makes no IO. Loading happens in `inference.loadModel(from:plan:)` on step 4.

### Why both a `ModelInfo` form and a `URL` form?

ManifoldKit has two `loadModel(from:)` shapes at different layers:

- **`InferenceService.loadModel(from: ModelInfo, plan:)`** — the consumer-facing call. Use this one.
- **`BackendProtocol.loadModel(from: URL, plan:)`** — the backend-protocol contract that custom backends implement. You'd only call this if you were building a brand-new backend.

The README's "Custom Backends" section documents the URL form because it's the protocol shape backend authors satisfy. Consumers call the `ModelInfo` form, and `ModelInfo(ggufURL:)` wraps the URL.

### Multi-turn conversations

`generate(messages:)` takes `[(role, content)]` and is stateless — the host owns the conversation history. Append the user's prompt before each call and the model's reply after each call:

```swift,no-build
var history: [(String, String)] = []

while let prompt = readLine() {
    history.append(("user", prompt))

    var reply = ""
    let stream = try inference.generate(messages: history, maxOutputTokens: 256)
    for try await event in stream.events {
        if case .token(let text) = event {
            print(text, terminator: "")
            fflush(stdout)
            reply += text
        }
    }
    print("")

    history.append(("assistant", reply))
}
```

Canonical role strings are `"user"`, `"assistant"`, and `"system"`. The `systemPrompt:` parameter on `generate(...)` is a convenience for the common case of one system message — when you pass it, ManifoldKit prepends a synthetic `("system", systemPrompt)` to the message array.

### Reasoning models (thinking tokens)

Some models — Qwen3, DeepSeek-R1, and similar — emit "thinking" content (reasoning steps) before their final answer. ManifoldKit surfaces these as a separate `GenerationEvent.thinkingToken(String)` case so the host can hide or render them as the UX demands. The §2 snippet above only handles `.token`, which means thinking output is silently dropped — that's fine for an instruct model but produces zero visible output for a reasoning model if its thinking block exhausts your `maxOutputTokens` budget.

If you need to support reasoning models, either render thinking content distinctly:

```swift,no-build
// Track whether we're currently inside a thinking block so the "[thinking] "
// prefix is emitted once per block (not once per token). Without this, every
// thinking token gets its own prefix: "[thinking] Okay[thinking] ,[thinking]  the…".
var inThinking = false
for try await event in stream.events {
    switch event {
    case .token(let text):
        if inThinking {
            FileHandle.standardError.write(Data("\n".utf8))
            inThinking = false
        }
        print(text, terminator: "")
    case .thinkingToken(let text):
        if !inThinking {
            // Render in a dim color, hide behind a fold, or skip entirely.
            FileHandle.standardError.write(Data("[thinking] ".utf8))
            inThinking = true
        }
        FileHandle.standardError.write(Data(text.utf8))
    default:
        break
    }
    fflush(stdout)
}
```

#### What events you'll see

The `switch` above only matches two cases — `.token` and `.thinkingToken` — and lets everything else fall through `default:`. That's deliberate: for a streaming-text CLI those are the only two events you have to render. But `GenerationEvent` has more cases, and once you build tool calling, usage reporting, or a progress UI you'll want to handle them explicitly. The full list (see [``GenerationEvent``](https://swiftpackageindex.com/roryford/ManifoldKit/main/documentation/manifoldinference/generationevent) on Swift Package Index for the rendered DocC page):

| Case                                                                  | Meaning                                                                                  |
|-----------------------------------------------------------------------|------------------------------------------------------------------------------------------|
| `.prefillProgress(nPast: Int, nTotal: Int, tokensPerSecond: Double)`  | Prompt-eval progress before the first generated token (Llama / MLX).                     |
| `.token(String)`                                                      | A fragment of generated text — usually one token. The thing you print.                   |
| `.usage(prompt: Int, completion: Int)`                                | Token usage reported by the backend (cloud backends only today).                         |
| `.toolCall(ToolCall)`                                                 | The model asked to call a tool. The host runs it and feeds back a `ToolResult`.          |
| `.toolCallStart(callId: String, name: String)`                        | Streaming providers only — beginning of a tool call whose arguments stream as deltas.    |
| `.toolCallArgumentsDelta(callId: String, textDelta: String)`          | JSON-arguments fragment for an in-flight streamed tool call.                             |
| `.thinkingToken(String)`                                              | A fragment of model reasoning (inside a thinking block).                                 |
| `.thinkingComplete`                                                   | Reasoning block closed; finalize any accumulated thinking content.                       |
| `.thinkingSignature(String)`                                          | Anthropic-only opaque signature attached to the most recent thinking block.              |
| `.toolLoopLimitReached(iterations: Int)`                              | Orchestrator stopped the tool-dispatch loop at `maxToolIterations`.                      |
| `.toolResult(ToolResult)`                                             | Result of a tool the orchestrator dispatched on your behalf.                             |
| `.kvCacheReuse(promptTokensReused: Int)`                              | Backend reused KV-cache prefix from the previous turn — that many tokens skipped decode. |
| `.diagnosticThrottle(reason: String)`                                 | Runtime paused generation (e.g. thermal pressure); surface this in your UI.              |
| `.toolDispatchStarted(callId: String, name: String, attempt: Int)`    | Orchestrator began handling a tool call — pin spinners / start timers here.              |
| `.toolDispatchCompleted(callId: String, durationMs: Int, errorKind: ToolResult.ErrorKind?)` | Orchestrator finished handling a tool call (success or failure).         |

Adding a case to `GenerationEvent` is source-breaking for exhaustive `switch` statements — that's why the snippets in this guide always include `default: break`. If you'd rather opt into the compiler warning when a new case lands, switch on `@unknown default:` instead.

…or use `maxThinkingTokens:` on `generate(...)` to cap how long the model can "think" before being forced to emit a final answer:

```swift,no-build
let stream = try inference.generate(
    messages: history,
    maxOutputTokens: 512,
    maxThinkingTokens: 128
)
```

If you're not sure whether your GGUF is a reasoning model, the simplest test is to run the §2 snippet against it: if you see no visible output, swap in the multi-handler `switch` shape above.

---

## 3. Cloud / Ollama via `loadCloudBackend(from:)`

For any HTTP-speaking provider — Ollama at `localhost:11434`, OpenAI, Anthropic, LM Studio, or a custom OpenAI-compatible endpoint — the entry point is `InferenceService.loadCloudBackend(from:)` with an `APIEndpointRecord` describing the endpoint.

> **Trait requirement.** Cloud backends are trait-gated. Add `Ollama` to your `traits:` for `localhost:11434`, or `CloudSaaS` for OpenAI / Claude. The default trait set (`MLX`, `Llama`, `HuggingFace`) does **not** include either. See [docs/FeatureMatrix.md](FeatureMatrix.md).

**`Package.swift`:**

```swift
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ChatCLICloud",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "chat-cli-cloud", targets: ["ChatCLICloud"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/roryford/ManifoldKit.git",
            from: "0.41.0", // x-release-please-version
            traits: [
                .trait(name: "Ollama"),     // for localhost:11434
                .trait(name: "CloudSaaS"),  // for OpenAI / Anthropic
            ]
        ),
    ],
    targets: [
        .executableTarget(
            name: "ChatCLICloud",
            dependencies: [
                .product(name: "ManifoldInference", package: "ManifoldKit"),
                .product(name: "ManifoldBackends", package: "ManifoldKit"),
            ]
        ),
    ]
)
```

> **Pick a model that's actually on your Ollama instance.** The snippet below requests `llama3.2`. If you don't already have that pulled, run `ollama list` and substitute one you do have — the cloud backend will surface Ollama's 404 verbatim if the model name is unknown, which reads like a ManifoldKit bug but isn't.

**`Sources/ChatCLICloud/main.swift`:**

```swift
import Foundation
import ManifoldInference
import ManifoldBackends

@main
@MainActor
struct ChatCLICloud {
    static func main() async throws {
        let inference = InferenceService()
        DefaultBackends.register(with: inference)

        // Point at a local Ollama instance. baseURL and modelName both default
        // off APIProvider.ollama, but pass them explicitly when you want a
        // non-default model or a non-default host.
        let endpoint = APIEndpointRecord(
            name: "Local Ollama",
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: "llama3.2" // swap for an entry from `ollama list`
        )

        try await inference.loadCloudBackend(from: endpoint)

        let stream = try inference.generate(messages: [("user", "Say hello in five words.")])
        for try await event in stream.events {
            if case .token(let text) = event {
                print(text, terminator: "")
                fflush(stdout)
            }
        }
        print("")
    }
}
```

The same shape works for every supported HTTP provider. Swap `.ollama` for `.openAI`, `.openAIResponses`, `.claude`, `.lmStudio`, or `.custom`:

- `.openAI` / `.openAIResponses` / `.claude` — `requiresAPIKey == true`. Store the key in Keychain under the endpoint's `keychainAccount` (defaults to the endpoint UUID). The bootstrap path in `ManifoldKit.quickStart()` wires Keychain lookup for you; CLI consumers manage their own storage.
- `.lmStudio` — same shape as `.openAI` against `localhost:1234`, no key required.
- `.custom` — pass your own `baseURL`. Speaks the OpenAI Chat Completions dialect.

---

## Cleaning up

`inference.unloadModel()` is synchronous and currently returns before llama.cpp's Metal device has drained its residency set. If you exit the process immediately after `unloadModel()`, `__cxa_finalize` may abort with:

```
ggml-metal-device.m: GGML_ASSERT([rsets->data count] == 0) failed
```

This is tracked at [#1394](https://github.com/roryford/ManifoldKit/issues/1394). Until it's fixed, give the Metal device a short window to drain before letting `main` return:

```swift,no-build
inference.unloadModel()
try? await Task.sleep(nanoseconds: 500_000_000) // workaround for #1394
```

500 ms is empirically sufficient on Apple Silicon and is harmless on backends that don't touch Metal. The workaround can be deleted once the upstream fix lands.

The Foundation Models and cloud backends are not affected — the teardown race is specific to the Llama / Metal stack.

---

## Where to go next

- [`docs/QUICKSTART.md`](QUICKSTART.md) — the SwiftUI hello-world and full `ManifoldKit.quickStart()` flow.
- [`docs/FeatureMatrix.md`](FeatureMatrix.md) — the full trait → backend → capability table.
- [`Example/Examples/MinimalExample`](../Example/Examples/MinimalExample) — runnable minimum-viable SwiftUI app.
- [README "Custom Backends"](../README.md#custom-backends) — implementing your own `BackendProtocol` conformance.
- [CONTRIBUTING.md](../CONTRIBUTING.md) — architecture invariants and how to add a backend.
