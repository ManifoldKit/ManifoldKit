# ManifoldKit CLI / Headless Quickstart

**Audience:** consumer
**Status:** living

A one-page tutorial for getting from "empty terminal" to "streaming tokens" without SwiftUI. If you're building a CLI, a server, an App Intents extension, a fuzz harness, or any non-SwiftUI consumer, start here.

> **macOS version matters for backend choice.** ManifoldKit officially supports macOS 15+ (its `n-1` floor), but the simplest documented backend — Apple Foundation Models — is macOS 26 / iOS 26 only. The table below maps backend → minimum platform so you don't pick one that won't run.
>
> | Backend           | Minimum platform              | Network? | Section            |
> |-------------------|-------------------------------|----------|--------------------|
> | Foundation Models | macOS 26 / iOS 26             | No       | [§1](#1-foundation-models-macos-26)         |
> | Local GGUF (Llama)| macOS 15 / iOS 18 (Apple Silicon) | No       | [§2](#2-local-gguf-via-the-llama-backend-macos-15)         |
> | Ollama / OpenAI / Anthropic | macOS 15 / iOS 18 | Yes      | [§3](#3-cloud--ollama-via-loadendpointbackendfrom) / [§3b REPL](#3b-interactive-repl-stdin-loop) |
> | MLX (Apple Silicon) | macOS 15 / iOS 18 — **Xcode `.app` only, not `swift run`** | No | [§4](#4-mlx-via-the-manifold-mlx-companion-apple-silicon) |
>
> If you're on macOS 15 and want a fully local model, skip directly to [§2](#2-local-gguf-via-the-llama-backend-macos-15). Foundation Models will not load.

Sections §1–§3b are complete, compile-tested examples: a full `Package.swift` plus a full `main.swift`, ready to copy-paste into an empty directory and `swift run`. §3 is a one-shot smoke test; [§3b](#3b-interactive-repl-stdin-loop) is the multi-turn REPL most CLIs actually want. §4 (MLX) is the exception — from a bare `swift run` it generates only when the **Metal Toolchain** component is installed (otherwise MLX aborts at model load); see the callout in that section.

> **First build is slow — that's the whole package graph resolving, not your target.** Depending on ManifoldKit pulls its full dependency closure (~15 packages: NIO, swift-syntax, huggingface, and more) at `swift package resolve`, even for the Foundation-only path in §1 that links none of them. Expect a multi-minute first `swift build`; subsequent builds are incremental and fast. Slimming your target's product list (as §1 does) trims *compile/link* time but not the one-time resolve.

> **Evaluating against a local checkout?** Swap the `.package(url:from:)` line in each section for `.package(name: "ManifoldKit", path: "/path/to/ManifoldKit")`. The `name:` argument is required — SwiftPM derives package identity from the last path component of `.package(path:)`, which breaks under non-default checkout paths (e.g. worktrees, custom directory names).

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

### Companion-package form (local GGUF / MLX backends)

Since v0.48 the heavy local backends ship as companion packages — core ManifoldKit compiles with no MLX or llama.cpp checkout at all, and the cloud + Foundation backends are always compiled in. To add local inference, depend on the companion package(s) alongside core:

```swift,no-build
dependencies: [
    .package(
        url: "https://github.com/ManifoldKit/ManifoldKit.git",
        from: "0.76.1" // x-release-please-version
    ),
    .package(url: "https://github.com/ManifoldKit/manifold-llama.git", from: "0.2.14"),  // GGUF
    // .package(url: "https://github.com/ManifoldKit/manifold-mlx.git", from: "0.2.13"), // MLX
],
```

then add `.product(name: "ManifoldLlama", package: "manifold-llama")` (or `ManifoldMLX`) to your target and register the backend with `LlamaBackends.register(with: inference)` after the default registrars — §2 below shows the full shape. See [MIGRATION-0.48.md](MIGRATION-0.48.md) if you're coming from a trait-based 0.47 setup.

### Granular vs umbrella imports for CLI targets

Most examples below depend on four core products — `ManifoldInference`, `ManifoldFoundation`, `ManifoldOllama`, and `ManifoldCloudSaaS` — and import them individually. That keeps a headless executable from linking `ManifoldUI` and `ManifoldPersistenceSwiftData`, which the `ManifoldKit` umbrella also re-exports. Link only the families you actually register: [§1](#1-foundation-models-macos-26) (Foundation-only) slims to two products, while §3 keeps all four so the same manifest works when you swap `.ollama` for `.openAI` or `.claude`.

If you'd rather match the SwiftUI quickstarts and take the umbrella import, swap the target dependencies for a single product and write one import:

```
// Package.swift target dependencies:
.product(name: "ManifoldKit", package: "ManifoldKit"),

// main.swift:
import ManifoldKit   // re-exports Inference + Foundation + Ollama + CloudSaaS
```

The registrar calls (`OllamaBackends.register(with:)`, etc.) are unchanged — you still register only the backends you intend to use. Trade-off: the umbrella pulls the UI and persistence modules even when your binary never touches them.

---

## 1. Foundation Models (macOS 26)

The smallest possible CLI. No model files to manage, no network calls, no API keys — Foundation Models ships with the OS on macOS 26 / iOS 26. If you're on a current Apple OS and your privacy / latency budget allows the on-device Apple model, this is the fastest path to a working binary.

**`Package.swift`:**

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ChatCLIFoundation",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "chat-cli-foundation", targets: ["ChatCLIFoundation"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/ManifoldKit/ManifoldKit.git",
            from: "0.76.1" // x-release-please-version
        ),
    ],
    targets: [
        .executableTarget(
            name: "ChatCLIFoundation",
            dependencies: [
                // Foundation-only is the leanest path: just the engine plus the
                // Foundation family. Add ManifoldOllama / ManifoldCloudSaaS (see
                // §3) only when you also want to reach an HTTP provider.
                .product(name: "ManifoldInference", package: "ManifoldKit"),
                .product(name: "ManifoldFoundation", package: "ManifoldKit"),
            ]
        ),
    ]
)
```

**`Sources/ChatCLIFoundation/main.swift`:**

```swift
import Foundation
import ManifoldInference
import ManifoldFoundation
@main
@MainActor
struct ChatCLIFoundation {
    static func main() async throws {
        let inference = InferenceService()
        // Register only the family you use. A Foundation-only CLI needs just
        // this one call — §3 adds OllamaBackends / CloudSaaSBackends for HTTP
        // providers, and each registrar is independent.
        FoundationBackends.register(with: inference)
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

> **Want a multi-turn REPL, not a one-shot?** The `readLine()` loop in [§3b](#3b-interactive-repl-stdin-loop) drops straight onto this Foundation setup — keep the two imports and single `FoundationBackends.register(with:)` above, then drop §3b's `APIEndpointRecord` construction and its `loadEndpointBackend(...)` call, replacing them with the `loadModel(from: .builtInFoundation, plan: .cloud())` line shown here. The stdin loop itself is unchanged.

---

## 2. Local GGUF via the Llama backend (macOS 15+)

This is the section that closes the "I'm on macOS 15 and want to evaluate ManifoldKit" gap. The Llama backend loads GGUF files via llama.cpp + Metal and runs on every supported platform. Since v0.48 it ships in the [`manifold-llama`](https://github.com/ManifoldKit/manifold-llama) companion package, so this example adds two `.package(...)` lines instead of one (which is why these snippets are not compile-checked against a core-only checkout).

**Get a model first.** Drop any GGUF file into `~/Documents/Models/`. SwiftUI hosts that use `ModelManagementSheet` discover both `~/Documents/Models` and the app-scoped Application Support directory — see [`docs/LOCAL-GGUF.md`](LOCAL-GGUF.md) for the full storage contract. Good starter picks:

- [`Llama-3.2-3B-Instruct-Q4_K_M.gguf`](https://huggingface.co/bartowski/Llama-3.2-3B-Instruct-GGUF) — ~2 GB, instruction-tuned, no reasoning tokens — **the snippet below works with this model unchanged**
- [`Phi-3.5-mini-instruct-Q4_K_M.gguf`](https://huggingface.co/bartowski/Phi-3.5-mini-instruct-GGUF) — ~2.2 GB, plain instruct, no reasoning or tool-call tokens — another safe default for a naive REPL
- [`Qwen_Qwen3-0.6B-Q4_K_M.gguf`](https://huggingface.co/bartowski/Qwen_Qwen3-0.6B-GGUF) — ~484 MB, fast, but emits `.thinkingToken` events before its final answer — see ["Reasoning models" below](#reasoning-models-thinking-tokens) before using — same repo `QuickStartSeed.recommendedSmallModel()` downloads
- Any other GGUF you've downloaded via HuggingFace, Ollama, or LM Studio

> **Pick a plain instruct model for a first REPL.** The bare `if case .token` snippet below assumes conversational prose. Two model families surprise a naive host: **reasoning models** (Qwen3, DeepSeek-R1) emit `.thinkingToken` before their answer (see ["Reasoning models" below](#reasoning-models-thinking-tokens)), and **tool-tuned or larger instruct builds** (e.g. Llama-3.1-8B-Instruct) can emit tool-call JSON — `{"name": "...", "parameters": {...}}` — as plain text even when you pass no tools, because that behavior is baked into their chat template. That JSON is the model's template, not a ManifoldKit bug. If you see JSON or reasoning where you expected prose, swap in a plain instruct model like the Llama-3.2-3B or Phi-3.5 above before reaching for tool handling.

> **Llama-3 multi-turn:** Real Jinja chat templates (v0.54+, [#1898](https://github.com/ManifoldKit/ManifoldKit/issues/1898)) fixed the ChatML control-token leakage reported in [#1398](https://github.com/ManifoldKit/ManifoldKit/issues/1398). Still smoke-test long multi-turn sessions in your CLI — any regression is tracked at #1398.

> **First-run stderr noise (Llama / Metal):** The first generation on a fresh build can emit thousands of `ggml_metal_library_compile_pipeline` lines on stderr while Metal kernels compile. That is llama.cpp logging, not model output — subsequent runs are much quieter. There is no consumer-facing silence knob yet ([#1399](https://github.com/ManifoldKit/ManifoldKit/issues/1399)).

**`Package.swift`:**

```swift,no-build
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
            url: "https://github.com/ManifoldKit/ManifoldKit.git",
            from: "0.76.1" // x-release-please-version
        ),
        // The GGUF backend lives in the manifold-llama companion package (v0.48).
        .package(url: "https://github.com/ManifoldKit/manifold-llama.git", from: "0.2.14"),
    ],
    targets: [
        .executableTarget(
            name: "ChatCLILlama",
            dependencies: [
                .product(name: "ManifoldInference", package: "ManifoldKit"),
                .product(name: "ManifoldFoundation", package: "ManifoldKit"),
                .product(name: "ManifoldOllama", package: "ManifoldKit"),
                .product(name: "ManifoldCloudSaaS", package: "ManifoldKit"),
                .product(name: "ManifoldLlama", package: "manifold-llama"),
            ]
        ),
    ]
)
```

**`Sources/ChatCLILlama/main.swift`:**

```swift,no-build
import Foundation
import ManifoldInference
import ManifoldFoundation
import ManifoldOllama
import ManifoldCloudSaaS
import ManifoldLlama   // from manifold-llama

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

        // 4. Standard service construction. The default registrars wire
        // the compiled-in core backends (cloud + Foundation); the companion
        // Llama registrar adds GGUF routing on top.
        let inference = InferenceService()
        OllamaBackends.register(with: inference)
        CloudSaaSBackends.register(with: inference)
        FoundationBackends.register(with: inference)
        LlamaBackends.register(with: inference)

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

The `switch` above only matches two cases — `.token` and `.thinkingToken` — and lets everything else fall through `default:`. That's deliberate: for a streaming-text CLI those are the only two events you have to render. But `GenerationEvent` has more cases, and once you build tool calling, usage reporting, or a progress UI you'll want to handle them explicitly. The full list (see [``GenerationEvent``](https://swiftpackageindex.com/ManifoldKit/ManifoldKit/main/documentation/manifoldinference/generationevent) on Swift Package Index for the rendered DocC page):

| Case                                                                  | Meaning                                                                                  |
|-----------------------------------------------------------------------|------------------------------------------------------------------------------------------|
| `.prefillProgress(tokensProcessed: Int, tokensTotal: Int, tokensPerSecond: Double)` | Prompt-eval progress before the first generated token (Llama / MLX).          |
| `.token(String)`                                                      | A fragment of generated text — usually one token. The thing you print.                   |
| `.usage(TokenUsage)`                                                  | Token usage reported by the backend (`promptTokens` / `completionTokens`, cloud backends only today). |
| `.toolCall(ToolCall)`                                                 | The model asked to call a tool. The host runs it and feeds back a `ToolResult`.          |
| `.toolCallStart(callId: String, name: String)`                        | Streaming providers only — beginning of a tool call whose arguments stream as deltas.    |
| `.toolCallArgumentsDelta(callId: String, textDelta: String)`          | JSON-arguments fragment for an in-flight streamed tool call.                             |
| `.thinkingToken(String)`                                              | A fragment of model reasoning (inside a thinking block).                                 |
| `.thinkingCompleted`                                                   | Reasoning block closed; finalize any accumulated thinking content.                       |
| `.thinkingSignature(String)`                                          | Anthropic-only opaque signature attached to the most recent thinking block.              |
| `.toolIterationLimitExceeded(iterations: Int)`                              | Orchestrator stopped the tool-dispatch loop at `maxToolIterations`.                      |
| `.toolResult(ToolResult)`                                             | Result of a tool the orchestrator dispatched on your behalf.                             |
| `.kvCacheReuse(promptTokensReused: Int)`                              | Backend reused KV-cache prefix from the previous turn — that many tokens skipped decode. |
| `.throttleDiagnostic(reason: String)`                                 | Runtime paused generation (e.g. thermal pressure); surface this in your UI.              |
| `.toolDispatchStarted(callId: String, name: String, attempt: Int)`    | Orchestrator began handling a tool call — pin spinners / start timers here.              |
| `.toolDispatchCompleted(callId: String, durationMilliseconds: Int, errorKind: ToolResult.ErrorKind?)` | Orchestrator finished handling a tool call (success or failure).         |

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

## 3. Cloud / Ollama via `loadEndpointBackend(from:)`

For any HTTP-speaking provider — Ollama at `localhost:11434`, OpenAI, Anthropic, LM Studio, or a custom OpenAI-compatible endpoint — the entry point is `InferenceService.loadEndpointBackend(from:)` with an `APIEndpointRecord` describing the endpoint.

> **No trait required.** Cloud backends (Ollama, OpenAI, Claude, LM Studio, custom endpoints) always compile since v0.48 — the former `Ollama`/`CloudSaaS` traits are retired. See [docs/FeatureMatrix.md](FeatureMatrix.md).

> **Ollama-only evaluators:** The full `Package.swift` below links every compiled-in backend family so the same manifest works when you swap `.ollama` for `.openAI` or `.claude`. If you only need local Ollama, slim the target to `ManifoldInference` + `ManifoldOllama`, import only those two modules, and call `OllamaBackends.register(with:)` — see [`manifold-tools`](../Sources/manifold-tools/main.swift) for the in-repo shape.

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
            url: "https://github.com/ManifoldKit/ManifoldKit.git",
            from: "0.76.1" // x-release-please-version
        ),
    ],
    targets: [
        .executableTarget(
            name: "ChatCLICloud",
            dependencies: [
                .product(name: "ManifoldInference", package: "ManifoldKit"),
                .product(name: "ManifoldFoundation", package: "ManifoldKit"),
                .product(name: "ManifoldOllama", package: "ManifoldKit"),
                .product(name: "ManifoldCloudSaaS", package: "ManifoldKit"),
            ]
        ),
    ]
)
```

> **Pick a model that's actually on your Ollama instance.** Run `ollama list` and paste a tag you already have into `modelName:` below — the cloud backend surfaces Ollama's 404 verbatim when the name is unknown, which reads like a ManifoldKit bug but isn't.

**`Sources/ChatCLICloud/main.swift`:**

```swift
import Foundation
import ManifoldInference
import ManifoldFoundation
import ManifoldOllama
import ManifoldCloudSaaS
@main
@MainActor
struct ChatCLICloud {
    static func main() async throws {
        let inference = InferenceService()
        OllamaBackends.register(with: inference)
        CloudSaaSBackends.register(with: inference)
        FoundationBackends.register(with: inference)

        let modelName = ProcessInfo.processInfo.environment["OLLAMA_MODEL"] ?? "llama3.1:8b"
        let endpoint = APIEndpointRecord(
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: modelName // paste a tag from `ollama list`, or set OLLAMA_MODEL
        )

        try await inference.loadEndpointBackend(from: endpoint)

        let stream = try inference.generate(messages: [("user", "Say hello in five words.")])

        // Reasoning-tuned models (Qwen3, DeepSeek-R1, etc.) emit `.thinkingToken`
        // events before — or instead of — `.token` events. A bare `if case .token`
        // pattern drops all thinking content silently, producing zero stdout output
        // when pointed at one of these models. Route thinking tokens to stderr so
        // they don't pollute piped output; response tokens go to stdout as normal.
        // If you see nothing on stdout, check stderr for thinking content — that
        // confirms the model is responding but its response is reasoning-only.
        // Generation errors surface as thrown errors from the async sequence itself,
        // not as a GenerationEvent case — the outer `try` handles them.
        for try await event in stream.events {
            switch event {
            case .token(let text):
                print(text, terminator: "")
                fflush(stdout)
            case .thinkingToken(let text):
                FileHandle.standardError.write(Data(text.utf8))
            default:
                break
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

### 3b. Interactive REPL (stdin loop)

§3 above is a one-shot smoke test. Most terminal chat tools need a loop: read a line from stdin, stream the reply, append both sides to history, repeat until Ctrl-D. The snippet below is the §3 Ollama wiring plus the multi-turn loop from [§2](#multi-turn-conversations) — same `Package.swift` as §3, different `main.swift`.

> **Stdout vs stderr in headless apps.** Route generated `.token` text to **stdout** so pipes and scripts capture only model output. Put status lines ("Loading…", "Ready.", prompt labels) and `.thinkingToken` content on **stderr** so they don't pollute `session.log` captures. Run the built binary directly (`.build/debug/chat-cli-cloud`) when you need a clean transcript — `swift run` prefixes build noise.

Reuse the §3 `Package.swift` unchanged (product name `chat-cli-cloud`, target `ChatCLICloud`).

**`Sources/ChatCLICloud/main.swift`:**

```swift
import Foundation
import ManifoldInference
import ManifoldFoundation
import ManifoldOllama
import ManifoldCloudSaaS

@main
@MainActor
struct ChatCLICloud {
    static func main() async throws {
        let inference = InferenceService()
        OllamaBackends.register(with: inference)
        CloudSaaSBackends.register(with: inference)
        FoundationBackends.register(with: inference)

        let modelName = ProcessInfo.processInfo.environment["OLLAMA_MODEL"] ?? "llama3.1:8b"
        let endpoint = APIEndpointRecord(
            provider: .ollama,
            baseURL: "http://localhost:11434",
            modelName: modelName
        )

        fputs("Loading Ollama model \(endpoint.modelName)…\n", stderr)
        try await inference.loadEndpointBackend(from: endpoint)
        fputs("Ready. Type a prompt and press Enter (Ctrl-D to exit).\n\n", stderr)

        var history: [(String, String)] = []

        while true {
            fputs("user: ", stderr)
            guard let line = readLine() else { break }

            let prompt = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !prompt.isEmpty else { continue }

            history.append(("user", prompt))
            fputs("assistant: ", stderr)

            var reply = ""
            let stream = try inference.generate(messages: history, maxOutputTokens: 512)
            for try await event in stream.events {
                switch event {
                case .token(let text):
                    print(text, terminator: "")
                    fflush(stdout)
                    reply += text
                case .thinkingToken(let text):
                    // thinking tokens are internal reasoning; exclude from conversational history
                    FileHandle.standardError.write(Data(text.utf8))
                default:
                    break
                }
            }
            print("")
            fputs("\n", stderr)

            guard !reply.isEmpty else {
                history.removeLast()
                continue
            }
            history.append(("assistant", reply))
        }

        fputs("Goodbye.\n", stderr)
    }
}
```

The same `readLine()` loop works for §1 (Foundation) and §2 (GGUF) — swap the load call and keep the event-handling `switch` shape.

---

## 4. MLX via the `manifold-mlx` companion (Apple Silicon)

MLX is ManifoldKit's fastest local backend on Apple Silicon (and the only one with on-device image generation). It ships in the [`manifold-mlx`](https://github.com/ManifoldKit/manifold-mlx) companion package.

> [!IMPORTANT]
> **MLX from a plain `swift run` CLI needs the Metal Toolchain component.** mlx-swift loads a precompiled `mlx.metallib` at GPU init; `manifold-mlx`'s `MLXMetallibPlugin` compiles it during `swift build` and `MLXMetallibStaging` colocates it next to the binary — **but only when the Metal Toolchain component is installed** (`xcodebuild -downloadComponent MetalToolchain`, or Xcode ▸ Settings ▸ Components). Without it the build still succeeds but emits no metallib, so MLX aborts at model load with `MLX error: Failed to load the default metallib`. Discovery, classification, registration, and the load *plan* all work regardless — only the GPU load (model load onward) needs the metallib.
>
> **So:** for the simplest headless CLI, the **GGUF/Llama backend (§2)** needs no Metal setup at all. To run MLX from `swift run`, install the Metal Toolchain component (above); otherwise build the target with `xcodebuild`, or reach for MLX from a **SwiftUI / Xcode app** (see [QUICKSTART.md → Customizing backends](QUICKSTART.md#customizing-backends)). The recipe below is the wiring either path uses.

**Get an MLX model first.** MLX loads a *directory* (`config.json` + `*.safetensors`), not a single file — point HuggingFace at an `mlx-community` repo and drop it under the auto-discovered `~/Documents/Models/`:

```sh
hf download mlx-community/Qwen2.5-0.5B-Instruct-4bit \
  --local-dir ~/Documents/Models/mlx-community/Qwen2.5-0.5B-Instruct-4bit
```

**`Package.swift`** (companion-package form — see [§ Package dependency forms](#package-dependency-forms); use the local-path form for both core and companion if evaluating against a local checkout, to avoid SwiftPM's `Conflicting identity for manifoldkit` warning):

```swift,no-build
// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ChatCLIMLX",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "chat-cli-mlx", targets: ["ChatCLIMLX"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/ManifoldKit/ManifoldKit.git",
            from: "0.76.1" // x-release-please-version
        ),
        // The MLX backend lives in the manifold-mlx companion package (v0.48).
        .package(url: "https://github.com/ManifoldKit/manifold-mlx.git", from: "0.2.13"),
    ],
    targets: [
        .executableTarget(
            name: "ChatCLIMLX",
            dependencies: [
                .product(name: "ManifoldInference", package: "ManifoldKit"),
                .product(name: "ManifoldModelCatalog", package: "ManifoldKit"),
                .product(name: "ManifoldMLX", package: "manifold-mlx"),
            ]
        ),
    ]
)
```

**`Sources/ChatCLIMLX/main.swift`:** MLX has no `ModelInfo(mlxURL:)` factory (unlike GGUF's `ModelInfo(ggufURL:)`) — the documented way to turn an on-disk MLX directory into a loadable `ModelInfo` is **storage discovery**, which classifies each model by type:

```swift,no-build
import Foundation
import ManifoldInference
import ManifoldModelCatalog
import ManifoldMLX // from manifold-mlx
@main
@MainActor
struct ChatCLIMLX {
    static func main() async throws {
        let inference = InferenceService()
        MLXBackends.register(with: inference)

        // No ModelInfo(mlxURL:) — discover the MLX directory under
        // ~/Documents/Models and pick the first .mlx model. discoverModels()
        // is synchronous (no await).
        let models = ModelStorageService().discoverModels()
        guard let mlxModel = models.first(where: { $0.modelType == .mlx }) else {
            FileHandle.standardError.write(Data("No MLX model found under ~/Documents/Models. Run the `hf download` above.\n".utf8))
            return
        }

        let plan = ModelLoadPlan.compute(
            for: mlxModel,
            requestedContextSize: 2048,
            strategy: .mappable
        )
        // NOTE: under plain `swift run` this load throws the metallib error
        // described in the callout above unless the Metal Toolchain component is
        // installed (or you build the target via xcodebuild / an .app).
        try await inference.loadModel(from: mlxModel, plan: plan)

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

`quickStart(backends: [MLXBackends.self])` is the one-liner equivalent of the manual `MLXBackends.register(with:)` above when you're in a SwiftUI / bootstrap context — see [QUICKSTART.md → Customizing backends](QUICKSTART.md#customizing-backends).

---

## Cleaning up

`inference.unloadModel()` is synchronous and currently returns before llama.cpp's Metal device has drained its residency set. If you exit the process immediately after `unloadModel()`, `__cxa_finalize` may abort with:

```
ggml-metal-device.m: GGML_ASSERT([rsets->data count] == 0) failed
```

This is tracked at [#1394](https://github.com/ManifoldKit/ManifoldKit/issues/1394). Until it's fixed, give the Metal device a short window to drain before letting `main` return:

```swift,no-build
inference.unloadModel()
try? await Task.sleep(nanoseconds: 500_000_000) // workaround for #1394
```

500 ms is empirically sufficient on Apple Silicon and is harmless on backends that don't touch Metal. The workaround can be deleted once the upstream fix lands.

The Foundation Models and cloud backends are not affected — the teardown race is specific to the Llama / Metal stack.

---

## Where to go next

- [`docs/QUICKSTART.md`](QUICKSTART.md) — the SwiftUI hello-world and full `ManifoldKit.quickStart()` flow.
- [`docs/FeatureMatrix.md`](FeatureMatrix.md) — the full backend → capability table.
- [`Example/Examples/MinimalExample`](../Example/Examples/MinimalExample) — runnable minimum-viable SwiftUI app.
- [README "Custom Backends"](../README.md#custom-backends) — implementing your own `BackendProtocol` conformance.
- [CONTRIBUTING.md](../CONTRIBUTING.md) — architecture invariants and how to add a backend.
