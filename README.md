# ManifoldKit

[![CI](https://github.com/ManifoldKit/ManifoldKit/actions/workflows/ci.yml/badge.svg)](https://github.com/ManifoldKit/ManifoldKit/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/ManifoldKit/ManifoldKit?sort=semver)](https://github.com/ManifoldKit/ManifoldKit/releases/latest)
[![License: MIT](https://img.shields.io/github/license/ManifoldKit/ManifoldKit)](LICENSE)
[![Swift 6.1+](https://img.shields.io/badge/Swift-6.1%2B-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2018%2B%20%7C%20macOS%2015%2B-blue)](#requirements)
[![SwiftPM](https://img.shields.io/badge/SwiftPM-compatible-brightgreen?logo=swift&logoColor=white)](#install)
[![Documentation](https://img.shields.io/badge/Docs-DocC-blue?logo=swift&logoColor=white)](https://docs.manifoldkit.com/documentation/manifoldkit/)

The only open-source Swift package that bundles UI, turn-loop runtime, persistence, and multi-backend inference into one drop-in chat product for Apple platforms.

![ManifoldKit assembled full-stack hero — one import gives you the SwiftUI ChatView, the ConversationRuntime turn loop, SwiftData persistence, and the in-core backends; ManifoldUIModelManagement is an explicit import for model-browser UI; the manifold-mlx and manifold-llama companion packages add on-device MLX and llama.cpp/GGUF](docs/images/product/layer-cake-hero.png)

**New here?** Start with **[Why ManifoldKit — and how it's built to last](docs/WHY-MANIFOLDKIT.md)** for the honest "what it solves and why trust it" narrative, or jump to the [docs index](docs/README.md) for the full guided path from install to first token. Prefer rendered API reference? The full **[DocC documentation site](https://docs.manifoldkit.com/documentation/manifoldkit/)** ties every module's reference together under one navigable root.

ManifoldKit is a full-stack, multi-backend AI chat framework for iOS 18+ / macOS 15+. Import one umbrella package and you get a SwiftUI `ChatView`, the `ConversationRuntime` turn loop (send / regenerate / edit / cancel / branch), SwiftData persistence, and the in-core inference backends (Apple Foundation Models, OpenAI, Anthropic, Ollama / LAN) — all behind one `InferenceBackend` protocol. Model browser / download UI is the opt-in `ManifoldUIModelManagement` product; on-device MLX and llama.cpp ship as the `manifold-mlx` / `manifold-llama` companion packages. Competitors ship a single layer; ManifoldKit ships the assembled product and the wiring between layers. It survives real failures — streaming retries, latest-wins model handoff, memory admission, certificate pinning, and a mock backend for app-level testing. See [docs/RELIABILITY.md](docs/RELIABILITY.md) for the source-backed contract, or [docs/POSITIONING.md](docs/POSITIONING.md) for the full "why ManifoldKit vs. the field" rationale.

## Hello World

Add **ManifoldKit** (core), then drop this into your app entry point. `ManifoldKit.quickStart()` builds the SwiftData container and registers the compiled-in backends. On devices with an available Foundation Model, a stored local model that a registered backend can load, or a saved endpoint it selects that model; otherwise, configure a backend or use the optional GGUF starter below. Errors surface as [`ManifoldKitError`](Sources/ManifoldModelCatalog/ManifoldKitError.swift).

```text
.package(url: "https://github.com/ManifoldKit/ManifoldKit.git", from: "0.77.0"), // x-release-please-version
// target dependencies: "ManifoldKit"
```

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
                    do {
                        result = try await ManifoldKit.quickStart()
                    }
                    catch let e as ManifoldKitError { error = e }
                    catch { self.error = .from(error) }
                }
            }
        }
    }
}
```

#### Optional: on-device GGUF starter

Want the on-device GGUF starter model instead of relying on Foundation Models / a manually-loaded backend? Add the **manifold-llama** companion package and pass its registrar — otherwise `quickStart` logs and skips the GGUF seed, because no registered backend can load it:

```swift,no-build:pulls in the manifold-llama companion package, which is a separate SwiftPM dependency the snippet harness (core-only) does not resolve
// + .package(url: "https://github.com/ManifoldKit/manifold-llama.git", from: "0.2.14")
// + target dependency: .product(name: "ManifoldLlama", package: "manifold-llama")
import ManifoldLlama

result = try await ManifoldKit.quickStart(
    backends: [LlamaBackends.self],
    seed: .recommendedSmallModel()
)
```

#### One-shot response

Already have a `QuickStartResult` with a loaded model and just want one reply as a `String`? `respond(to:)` sends the message, drives the turn, and returns the assistant's text — no `inputText`/observation plumbing:

```swift
import ManifoldKit

func oneShot(using kit: QuickStartResult) async throws -> String {
    return try await kit.respond(to: "Explain monads in one sentence.")
}
```

> **About `seed:`** — with the `manifold-llama` companion's `LlamaBackends` registrar, `.recommendedSmallModel()` downloads Qwen3-0.6B (~484 MB) in the background before returning, so the composer is generating the moment the view appears. Without that registrar the GGUF seed is skipped. The download is also skipped when a model is already available (Foundation on iOS/macOS 26+, or a local model on disk), and it accepts a `{ progress in … }` closure for a progress indicator.
>
> **No starter download?** `quickStart` registers the backends but loads none when no Foundation Model, compatible stored local model, or saved endpoint is available, so on first run the composer reads "No model loaded" and the empty-state **Select Model** button only flips `showModelManagement` — nothing is presented until you attach a sheet to that binding. Fastest route: present `ModelManagementSheet` (from the opt-in `ManifoldUIModelManagement` module) with `.sheet(isPresented: $showModelManagement)`, or pass the `LlamaBackends` registrar with `seed:`. Step-by-step: [First-launch backend selection](docs/QUICKSTART.md#first-launch-backend-selection).

#### Value-typed front door: `LLM`

Want the LLM.swift feel — construct a value, call `.respond(to:)`? `LLM(from:template:backends:)` wraps the same `quickStart` plumbing in a value type. `backends:` is a **required** parameter (no default — explicit registrars over implicit ones, see [docs/API-DESIGN.md](docs/API-DESIGN.md)); pass a registrar that can load the seed type:

```swift,no-build:uses the manifold-llama companion package, which is not linked by the core-only snippet harness
import ManifoldKit
import ManifoldLlama

func twoLine() async throws -> String {
    let llm = try await LLM(
        from: .recommendedSmallModel(),
        backends: [LlamaBackends.self]
    )
    return try await llm.respond(to: "Explain monads in one sentence.")
}
```

> **Local models need a companion registrar.** `ManifoldKit.defaultBackendRegistrars` covers cloud (Ollama / OpenAI / Anthropic) and Apple Foundation Models. For an on-device model, add the `manifold-llama` (GGUF) or `manifold-mlx` package and pass its registrar instead — `backends: [LlamaBackends.self]` — plus the matching `import`. Pass an optional `template: ChatTemplate` to override formatting for built-in (enum) templates.

See [docs/QUICKSTART.md](docs/QUICKSTART.md) for backend selection and configuration.
Building a multi-session SwiftUI app with a sidebar, persisted chats, and relaunch restore? See [docs/SWIFTUI-MULTI-SESSION.md](docs/SWIFTUI-MULTI-SESSION.md) — the canonical end-to-end guide.
Building a CLI, server, or non-SwiftUI consumer? See [docs/QUICKSTART-CLI.md](docs/QUICKSTART-CLI.md) — compile-tested Foundation Models, local GGUF, and Ollama / OpenAI examples.
Running ManifoldKit as a standalone OpenAI-compatible server (for Cursor, Continue, or any OpenAI SDK)? Install via `brew tap manifoldkit/manifoldkit https://github.com/ManifoldKit/ManifoldKit.git && brew install manifold-server` and see [docs/QUICKSTART-SERVER.md](docs/QUICKSTART-SERVER.md).
Want the inference layer with a fully custom SwiftUI UI (no `ChatView`)? See [docs/QUICKSTART-BRING-YOUR-OWN-UI.md](docs/QUICKSTART-BRING-YOUR-OWN-UI.md).
Registering tools the model can call? See [docs/QUICKSTART-TOOLS.md](docs/QUICKSTART-TOOLS.md) — `ToolRegistry`, the local-model tool ceiling, approval gates, and streaming results.
Exposing an `AppIntent` to the model? See [docs/QUICKSTART-APPINTENTS.md](docs/QUICKSTART-APPINTENTS.md).
Full runnable: [`Example/Examples/MinimalExample`](Example/Examples/MinimalExample).

## Where each backend lives

As of v0.48 the heavy on-device backends ship as **companion packages** so a
core-only app never resolves llama.cpp or mlx-swift (SwiftPM traits gate
link, not fetch — see
[docs/TRAIT-COSTS.md](docs/TRAIT-COSTS.md#faq-why-not-keep-the-glue-in-core-and-only-externalize-the-engines)).
Module names are stable — only the `.package(…)` line differs. Migrating from
a trait-based 0.47 setup? **[docs/MIGRATION-0.48.md](docs/MIGRATION-0.48.md)**
is the error-message-indexed guide.

| You want | Module to import | Package |
|---|---|---|
| MLX on-device inference (+ image gen) | `ManifoldMLX` | [`ManifoldKit/manifold-mlx`](https://github.com/ManifoldKit/manifold-mlx) |
| llama.cpp / GGUF on-device inference | `ManifoldLlama` | [`ManifoldKit/manifold-llama`](https://github.com/ManifoldKit/manifold-llama) |
| Apple Foundation Models (iOS/macOS 26+) | `ManifoldKit` umbrella (or `ManifoldFoundation`) | ManifoldKit (core) |
| OpenAI / Anthropic / LM Studio / custom endpoints | `ManifoldKit` umbrella (or `ManifoldCloudSaaS`) | ManifoldKit (core) |
| Ollama / LAN | `ManifoldKit` umbrella (or `ManifoldOllama`) | ManifoldKit (core) |
| xAI, Groq, Mistral, OpenRouter — incl. Gemini models via OpenRouter (OpenAI-compatible endpoint) | `ManifoldKit` umbrella (or `ManifoldCloudSaaS`), `APIProvider.custom` + `OpenAIBackend` | ManifoldKit (core) |
| MCP client / host | `ManifoldMCP` / `ManifoldMCPHost` | ManifoldKit (core) |

Companion backends register through `quickStart(backends: [MLXBackends.self, LlamaBackends.self])` (or `MLXBackends.register(with:)` on a hand-assembled service). The `manifold-mlx` / `manifold-llama` packages tag 0.1.0 alongside the core v0.48.0 release.

Building a new backend companion package? See [docs/COMPANION-BACKENDS.md](docs/COMPANION-BACKENDS.md) for the product/contract-adoption/release-lifecycle guide, and [docs/HARDWARE-TOOLCHAIN.md](docs/HARDWARE-TOOLCHAIN.md) for the cross-repo hardware/CI constraints.

## Why ManifoldKit

**Full-stack altitude.** Import one umbrella package and ship a multi-backend chat app: SwiftUI `ChatView`, the `ConversationRuntime` turn loop, SwiftData persistence, and the in-core backends — already wired together. Model browser UI is the opt-in `ManifoldUIModelManagement` product; MLX / llama.cpp are companion packages. Most alternatives hand you one layer (a UI kit, an engine wrapper, or a thin cloud client) and leave the rest as an exercise. Here the integration is the product.

**Backend portability.** MLX, llama.cpp/GGUF, Apple Foundation Models, and cloud (OpenAI Chat + Responses, Anthropic, Ollama, LAN, and any OpenAI-compatible endpoint — xAI, Groq, Mistral, OpenRouter via `APIProvider.custom`, including Gemini models through OpenRouter) all sit behind one `InferenceBackend` protocol. Streaming, tool calling, thinking/reasoning tokens, RAG, and structured output behave identically across every backend, so swapping engines is a config change, not a rewrite. See [How ManifoldKit compares to AnyLanguageModel](#how-manifoldkit-compares-to-anylanguagemodel).

**n-1 OS reach — everything above the model layer.** At WWDC 2026 Apple opened the Foundation Models framework to any LLM provider via the `LanguageModel` protocol, with first-party Claude (`anthropics/ClaudeForFoundationModels`, beta) and Gemini (via Firebase, preview) packages arriving on top. That validates the multi-backend idea — and commoditizes it: model *access* is becoming a platform primitive. But it all lands on the newest OS only — Foundation Models itself is iOS 26+ / macOS 26+, and the opened provider layer is iOS 27+ (in beta now) — while ManifoldKit already serves the iOS 18 / macOS 15 installed base those APIs can't reach, wrapping Foundation Models as just one more backend behind `InferenceBackend`. ManifoldKit's value was never the abstraction; it's everything above the model layer: the turn loop, persistence, MCP client+server, tool approval, and RAG. The companion-package split means one codebase yields either an App-Store-lean build with no heavy ML dependencies at all (core only — just don't add the companion packages) or the full local + cloud + RAG + voice stack. The historical `SystemAIProviderExtension` and `CoreAI` traits remain no-op manifest stubs; [the Xcode 27 investigation](docs/wwdc-2026-trait-stubs.md) records the real `LanguageModelExecutor` seam and why it is not wired through those traits. See [AGENTS.md → Platform policy](AGENTS.md#platform-policy).

**Reliability and security as product.** TLS pinning, SSRF and DNS-rebind guards, a throwing Keychain, a documented [threat model](docs/THREAT_MODEL.md), a fuzz harness, 6,500+ tests, capability-routed structured output, human-in-the-loop tool approval (`ToolApprovalGate`), and cost/metrics observability ship in the box. These are the things that go wrong between the demo and App Store review — see [docs/RELIABILITY.md](docs/RELIABILITY.md) for the implementation-backed guarantees.

ManifoldKit is **decomposable, not monolithic**: 28 libraries across a layered module graph. Take just the engine ([CLI / server path](docs/QUICKSTART-CLI.md)), just the UI (bring-your-own-runtime), or the whole stack — the umbrella is a convenience, not a requirement.

### Drop in `ChatView`, or compose the primitives

`ChatView` is a complete reference integration, not the only door in. `ManifoldUI` ships as composable pieces you can assemble into a custom layout while still driving the same `ChatViewModel` / `ConversationRuntime` (`SessionListView` and `SessionManagerViewModel` are also in the [Key Types](#key-types) table below):

- **Message rendering** — `MessageBubbleView`, the `MessageBubbleStyle` protocol (with `PlainMessageBubbleStyle`, `IMessageMessageBubbleStyle`, `CardMessageBubbleStyle` built in), `StreamingCursorView`, `ToolInvocationView`, `CitationsView`.
- **Input** — `ChatInputBar`, `VisionInputButton` (cross-platform), `PhotoAttachmentButton` (**iOS only** — prefer `VisionInputButton` for a codebase that also targets macOS).
- **Session chrome** — `SessionListView`, `SessionRowView`, backed by `SessionManagerViewModel`; `ContextIndicatorView`, `MemoryIndicatorView`, `ModelLoadingIndicatorView`, `TypingIndicatorView`.
- **Pickers & sheets** — `PersonaPickerView`, `SamplerPresetPickerView`, `VoicePickerView`, `ChatExportSheet`, `SessionExportSheet`.

Bring your own layout and swap in only the pieces you need — a custom message list with `MessageBubbleView` and a bespoke input bar is a valid integration, not an unsupported one.

## What's already in the box

Table-stakes capabilities that ship today (verified in source):

- **Token streaming** across every backend (`GenerationStream` / `GenerationEvent`).
- **Multi-provider abstraction** — one `InferenceBackend` protocol, local + cloud.
- **Tool / function calling** with a per-request tool ceiling guide for local models.
- **Tool-call evaluation & conformance** — score how reliably a model calls tools (incl. a bundled BFCL AST track) via the `manifold-tools` CLI and `ConformanceScorer`, plus a bootstrap-exposed, SwiftData-backed `ToolCallConformanceCache` port for persisting verdicts. See [Beyond chat](#beyond-chat).
- **Structured / typed output**, capability-routed by `StructuredOutputRouter` across GBNF, Foundation guided-generation, JSON-Schema, and JSON-prompting.
- **Reasoning / thinking tokens** surfaced as first-class events.
- **MCP client *and* server** ([ManifoldMCP](Sources/ManifoldMCP) + the `Server` trait).
- **On-device RAG with citations** — a full document subsystem (parse `.txt`/`.md`/`.pdf` → chunk → embed → retrieve), wired into the turn loop, with an optional cross-encoder rerank stage (`Reranker` port — on-device `LlamaReranker`, or cloud `CloudReranker` for Cohere / Jina) and a Document Library UI. See [docs/QUICKSTART-RAG.md](docs/QUICKSTART-RAG.md).
- **Embeddings & semantic search** — `EmbeddingBackend` protocol with on-device `NLEmbeddingBackend` (Apple NaturalLanguage, no companion package) and an OpenAI-compatible `/v1/embeddings` server endpoint.
- **Human-in-the-loop tool approval** via `ToolApprovalGate`.
- **Metrics + cost estimation** for observability.
- **On-device image generation** — `FluxDiffusionBackend` (FLUX.1 Schnell) and `MLXDiffusionBackend` (SDXL Turbo), via the [`manifold-mlx`](https://github.com/ManifoldKit/manifold-mlx) companion package.

**Status:** ManifoldKit is pre-1.0; breaking changes can land between minor versions. Deferred reliability features (e.g. mid-stream resume) are tracked in [docs/RELIABILITY.md](docs/RELIABILITY.md).

**Dev-tool products** — `ManifoldTools`, `ManifoldTestSupport`, `ManifoldPersistenceTestSupport`, and `ManifoldBackendTestKit` — are semver-exempt and may break in any minor release. Each provides published APIs for real external consumers (eval repo, companion packages, local apps) and every break receives a migration note, but they are not bound to the core stability promise: they are developer tooling, and linking one means accepting the looser promise. See [docs/API-DESIGN.md § 7](docs/API-DESIGN.md#7-semver-exempt-products) for the complete policy and consumer list.

**Maturity tiers.** Not every product carries the same stability promise. [docs/PRODUCTION-READINESS.md](docs/PRODUCTION-READINESS.md) is the normative page assigning every published product — Core guarantee, Supported first-party integration, Experimental, or Labs — so you know what you can build on today vs. what may move under you.

## Beyond chat

The same backend, model-management, persistence, and download infrastructure that powers the chat UI is reusable for non-chat consumers. The framing is "chat-first" because that's the most complete reference integration, but the public surface explicitly supports:

- **On-device image generation** — `FluxDiffusionBackend` (FLUX.1 Schnell, 1024×1024 in 4 steps) and `MLXDiffusionBackend` (SDXL Turbo) conform to `ImageGenerationBackend` and stream `ImageGenerationEvent`s exactly like text inference streams `GenerationEvent`. The diffusion backends ship in the [`manifold-mlx`](https://github.com/ManifoldKit/manifold-mlx) companion package; the `ImageGenerationBackend` protocol and records stay in core. See [docs/QUICKSTART-IMAGE-GEN.md](docs/QUICKSTART-IMAGE-GEN.md) for the end-to-end walkthrough (download → load → generate).
- **Cloud video generation** — Any cloud service that conforms to `VideoGenerationBackend` wires into `VideoGenerationService` and `VideoGenerationRuntime`, which persist the result via `MessageStore` and expose real-time progress through `ChatViewModel.videoGenerationProgress`. The same `ManifoldBootstrap` init that accepts an `imageGenerationService` also accepts a `videoGenerationService`, so adding video is one extra parameter:

  ```swift,no-build
  let backend = MyVideoBackend()
  backend.configure(baseURL: videoAPIURL, tokenProvider: tokenProvider, modelName: "my-video-model")
  let service = VideoGenerationService(backend: backend)
  let kit = try ManifoldBootstrap(
      configuration: config,
      videoGenerationService: service
  )
  // Trigger a generation from anywhere you hold the view model:
  try await kit.viewModel.generateVideo(
      prompt: "a sun rising over mountains",
      config: VideoGenerationConfig(duration: 5, aspectRatio: VideoGenerationConfig.AspectRatio.landscape)
  )
  ```

  The full walkthrough lives with the generation backends in the [`manifold-mlx`](https://github.com/ManifoldKit/manifold-mlx) companion package docs; the `VideoGenerationBackend` protocol, `VideoGenerationService`, and persistence wiring above are core.
- **Standalone speech-to-text / text-to-speech** — `ManifoldVoice` wraps Apple `Speech` + `AVFoundation` behind a chat-agnostic `VoiceConversationController` that anything (image-gen prompt fields, search bars, CLI dictation) can drive. See [docs/QUICKSTART-VOICE.md](docs/QUICKSTART-VOICE.md).
- **On-device embeddings, semantic search & RAG** — the `EmbeddingBackend` protocol with on-device `NLEmbeddingBackend` (Apple NaturalLanguage, zero extra dependencies) powers a complete retrieval subsystem: `RAGService.ingest(url:)` parses (`.txt`/`.md`/`.pdf`), chunks, embeds into a flat-file vector index, and retrieves the top passages before each turn (semantic when an embedding backend is loaded, keyword-fallback otherwise) — with inline `Citation`s in `ChatView`, an optional cross-encoder rerank, and a Document Library UI (`DocumentLibrarySheet`). Opt in via `ManifoldBootstrap(ragConfiguration:)`. The same `EmbeddingBackend` surface backs the OpenAI-compatible `/v1/embeddings` server endpoint. See [docs/QUICKSTART-RAG.md](docs/QUICKSTART-RAG.md) and [docs/RAG-TUNING.md](docs/RAG-TUNING.md).
- **Tool-call evaluation & conformance** — measure how well a model actually calls tools before shipping. The `manifold-tools` CLI drives a bundled **BFCL** (Berkeley Function-Calling Leaderboard) AST slice against a live backend (`manifold-tools bfcl --model … --category simple`), and `ConformanceScorer` / `MatrixRenderer` (in the `ManifoldTools` library) render a deterministic conformance matrix you can gate on. A bootstrap-exposed, SwiftData-backed `ToolCallConformanceCache` port is available for persisting per-model verdicts — the seam a host needs to avoid re-running the eval — though no built-in UI consumes it yet. The CLI lives at [`Sources/manifold-tools`](Sources/manifold-tools) and the scoring library at [`Sources/ManifoldTools`](Sources/ManifoldTools) (run `swift run manifold-tools bfcl --help`).
- **CLI / server / non-SwiftUI consumers** — backends, model management, and persistence work without `ChatView`. See [docs/QUICKSTART-CLI.md](docs/QUICKSTART-CLI.md).

## Feature Matrix

Capabilities scope by **which products and companion packages you link**, not by traits. The full capability table is generated from `Sources/ManifoldKit/FeatureMatrix.swift` and rendered to [docs/FeatureMatrix.md](docs/FeatureMatrix.md).

v0.48 retires the trait architecture in favour of library products. There are **no default traits** — plain `swift build` is the full core build. The surviving opt-in traits are `Server` and `Macros` (genuine build-cost levers: Hummingbird and swift-syntax respectively) plus the forward-declared WWDC stubs (`SystemAIProviderExtension`, `CoreAI`). Everything else is retired: `MCP`, `MCPBuiltinCatalog`, `Voice`, `Tools`, `AppIntents`, `Skills`, `Ollama`, `CloudSaaS`, and `AnyLanguageModel` became always-compiled modules or explicit products, and the local-backend traits (`MLX`, `Llama`, `HuggingFace`, `Fuzz`, `FoundationOnly`) died with the companion-package split — MLX and llama.cpp now arrive by adding [`manifold-mlx`](https://github.com/ManifoldKit/manifold-mlx) / [`manifold-llama`](https://github.com/ManifoldKit/manifold-llama). See [docs/MIGRATION-0.48.md](docs/MIGRATION-0.48.md) for the full mapping and [docs/QUICKSTART.md → Customizing backends](docs/QUICKSTART.md#customizing-backends) for install steps.

For a quantified breakdown of what the remaining opt-in traits (`Server`, `Macros`) cost in binary size and dependency weight — heavy ML is companion-optional since v0.48 — see [docs/TRAIT-COSTS.md](docs/TRAIT-COSTS.md).

## ManifoldKit vs. the field

Most Swift AI projects are excellent at one layer. ManifoldKit's claim is narrow and checkable: it's the only open-source *package* that fills every column.

| Project / category | Chat UI | Turn-loop runtime | Persistence | Multi-backend local + cloud | Reusable as a package |
|---|---|---|---|---|---|
| **ManifoldKit** | ✅ | ✅ | ✅ | ✅ | ✅ |
| UI-only kits (Exyte/Chat, MessageKit, SwiftyChat) | ✅ | ❌ | ❌ | ❌ | ✅ |
| Engine-only (LocalLLMClient, AnyLanguageModel, swift-transformers, LLM.swift) | ❌ | ❌ | ❌ | partial¹ | ✅ |
| Ecosystem-bound (SpeziLLM — Stanford Spezi) | ❌ | partial | ❌ | partial² | ✅ (requires Spezi) |
| Thin cloud clients (MacPaw/OpenAI, SwiftAnthropic) | ❌ | ❌ | ❌ | ❌ (one provider) | ✅ |
| Apple Foundation Models (+ opened provider layer, WWDC26) | ❌ | ❌ | ❌ | ✅ via `LanguageModel` (iOS 27+ only, beta) | ✅ |
| Cross-platform (Cactus) | ❌ (engine/bindings, no chat-UI kit) | ❌ | ❌ | ✅ (hosted-service cloud fallback) | ✅ (Swift binding less mature) |
| Full-stack apps (fullmoon, Enchanted) | ✅ | ✅ | ✅ | partial | ❌ (fork, not a package) |

¹ LocalLLMClient is the closest multi-engine analog (multiple local engines behind one interface) but ships no UI, persistence, or cloud backends, and is explicitly labelled experimental (tool calling and multimodal included). ² SpeziLLMFog adds mDNS-discovered local-network inference ManifoldKit doesn't have.

Each row is genuinely strong at its own layer — a UI kit renders beautiful bubbles, a cloud client is a clean SDK, Foundation Models is free and on-device. The point isn't that they're weak; it's that assembling them into a shipping chat product is the work ManifoldKit already did. Apple validated the category at WWDC 2026 by opening Foundation Models to third-party providers — which raises the value of everything *above* the model layer, not below it. Cross-language demand for that "above" layer is proven (React's assistant-ui has ~11k stars; Vercel ships a chatbot template) — there is still no Swift equivalent until this one. Full rationale in [docs/POSITIONING.md](docs/POSITIONING.md).

## Install

```swift
.package(
    url: "https://github.com/ManifoldKit/ManifoldKit.git",
    from: "0.77.0" // x-release-please-version
)
```

Most apps add a single product — the `ManifoldKit` umbrella — which re-exports the runtime, persistence, backends, UI, and inference surface in one import:

```swift
.target(name: "MyApp", dependencies: [
    .product(name: "ManifoldKit", package: "ManifoldKit"),
])
```

Specialised modules (`ManifoldUIModelManagement`, `ManifoldMCP`, `ManifoldVoice`, `ManifoldHuggingFace`, `ManifoldAppIntents`) stay opt-in — add them explicitly when you need that surface. `ManifoldVoice` in particular is usable outside chat: it wraps Apple `Speech` / `AVFoundation` behind a chat-agnostic `VoiceConversationController`, so anything from an image-gen prompt field to a CLI dictation tool can drive it. See [docs/QUICKSTART-VOICE.md](docs/QUICKSTART-VOICE.md) for the standalone STT path; the chat composer accessory is the *other* consumer of the same controller. For finer-grained dependency control (e.g. a UI-only target that doesn't link a backend family), depend on the individual products instead. See [docs/QUICKSTART.md](docs/QUICKSTART.md) for backend selection and the bring-your-own-UI path.

## Requirements

- **Swift 6.1+** (`swift-tools-version: 6.1` in this package's `Package.swift`)
- If your app's own manifest declares `.macOS(.v26)` / `.iOS(.v26)`, use **Swift 6.2+** there — those platform entries were introduced in PackageDescription 6.2.
- iOS 18+ / macOS 15+
- Apple Foundation Models require iOS 26+ / macOS 26+

ManifoldKit follows an **n-1 platform policy**: the current Apple OS release and the one immediately before it. When Apple ships a new major OS each September, both minimums bump by one. See [AGENTS.md → Platform policy](AGENTS.md#platform-policy) for the rationale.

### Compatibility matrix

Most of the surface builds and runs down to the package floor (iOS 18 / macOS 15). A few modules and symbols carry a higher floor because they wrap OS-26-only frameworks — they still **compile and link** fine on older deployment targets; only *using* the gated symbol requires an OS check.

| Module / symbol | Min iOS | Min macOS | Notes |
|---|---|---|---|
| Package floor (`ManifoldKit`, `ManifoldInference`, `ManifoldRuntime`, `ManifoldUI`, …) | 18 | 15 | The n-1 baseline everything below is measured against. |
| `ManifoldFoundation` / `FoundationBackend` | 26 | 26 | Re-exported by the `ManifoldKit` umbrella, so apps targeting iOS 18–25 / macOS 15–25 link it fine — but `FoundationBackends.register(with:)` registers a factory that yields no usable backend below the floor, and `quickStart` with *only* this registrar throws `ManifoldKitError.noBackendsRegistered` on iOS 18–25 / macOS 15–25. Guard usage with `if #available(iOS 26, macOS 26, *)`. |
| `ManifoldAppIntents` — `AppIntentToolExecutor` (the ToolExecutor bridge) | 26 | 26 | Separate opt-in product (not re-exported by the umbrella). Gate registration behind `#available(iOS 26, macOS 26, *)`. |
| `ManifoldAppIntents` — `AskManifoldIntent` / `AskManifoldHandler` | 18 | 15 | Same opt-in product as above, but the sample intent and its handler protocol only need the package floor. |

## Demo

<p align="center">
  <img src="Example/Screenshots/demo-macos.png" alt="ManifoldKit on macOS — chat with streaming response and session sidebar" width="58%">
  <img src="Example/Screenshots/demo-ios.png" alt="ManifoldKit on iOS — chat conversation on iPhone" width="36%">
</p>

Start with [`Example/Examples/MinimalExample`](Example/Examples/MinimalExample) if you're new — it's the canonical Hello World. The full-featured reference app lives at [`Example/Advanced`](Example/Advanced) (sessions, model management, custom composer accessories); open it once the minimal example makes sense.

## Architecture

ManifoldKit ships **28 libraries**, **3 executables**, and **1 macro plugin**. The core runtime stack is six libraries; the rest are optional sibling modules you link explicitly. The MLX and llama.cpp backend families live in the [`manifold-mlx`](https://github.com/ManifoldKit/manifold-mlx) and [`manifold-llama`](https://github.com/ManifoldKit/manifold-llama) companion packages.

```
ManifoldVoice              ManifoldUIModelManagement
(speech I/O)               (model browser + endpoint UI)
        │                          │
        └────────► ManifoldUI ◄────┘
                       │
                       ▼
            ManifoldPersistenceSwiftData
            (SwiftData schema, ManifoldBootstrap)
                       │
                       ▼
                 ManifoldRuntime
                 (Ports, use cases, ConversationRuntime)
                       │
                       ▼
                ManifoldInference  ◄─── backend families
                (Protocols, services)   (ManifoldFoundation,
                       ▲                 ManifoldOllama,
                       │                 ManifoldCloudSaaS; MLX /
                       │                 llama.cpp via companions)
                       │
                ManifoldMCP
                (MCP descriptors, client, tool bridge)
```

The backend families (`ManifoldFoundation` / `ManifoldOllama` / `ManifoldCloudSaaS`) and `ManifoldMCP` depend on `ManifoldInference` **directly**, not via `ManifoldRuntime` — that keeps them free of SwiftData so host apps can wire backends or MCP into a non-SwiftData runtime. The full target list lives in [AGENTS.md → Targets](AGENTS.md#targets).

### Turn-loop orchestration

`ConversationRuntime` (`Sources/ManifoldRuntime/Services/ConversationRuntime.swift`) is the **single turn loop** for chat. It owns all turn-flow operations — send, regenerate, edit, cancel, and branch — dispatched through `processTurn(TurnInput(...))` with the corresponding `TurnKind` case. There is no alternative path. Host apps get a configured runtime from `ManifoldBootstrap` (exposed as `bootstrap.conversationRuntime`) and forward user actions to it. See [CONTRIBUTING.md → Architecture invariants](CONTRIBUTING.md#architecture-invariants) for the full list of dependency rules the lint enforces.

## Supported Model Types

| Type | Backend | Format | Source | Image input |
|------|---------|--------|--------|-------------|
| GGUF | `LlamaBackend` (llama.cpp, via [`manifold-llama`](https://github.com/ManifoldKit/manifold-llama)) | Single `.gguf` file | HuggingFace, local | Not yet; tracked in [#416](https://github.com/ManifoldKit/ManifoldKit/issues/416) |
| MLX | `MLXBackend` (mlx-swift, via [`manifold-mlx`](https://github.com/ManifoldKit/manifold-mlx)) | Directory with `config.json` + `.safetensors` | HuggingFace, local | Vision models only |
| Foundation | `FoundationBackend` | `ModelInfo.builtInFoundation` (built-in, no download) | Apple Intelligence | No public FoundationModels image-input API yet |
| OpenAI | `OpenAIBackend` | Cloud API | api.openai.com | Vision-capable models |
| Claude | `ClaudeBackend` | Cloud API | api.anthropic.com | Vision-capable models |
| Ollama | `OpenAIBackend` | Local API | localhost:11434 | Vision-capable OpenAI-compatible models |
| LM Studio | `OpenAIBackend` | Local API | localhost:1234 | Vision-capable OpenAI-compatible models |

### Model storage scoping

`ModelStorageService()` stores and discovers local models under `<Application Support>/<ManifoldConfiguration.shared.bundleIdentifier>/<modelsDirectoryName>` by default. This keeps multiple ManifoldKit-based apps on the same machine from seeing each other's downloaded models. Hosts that intentionally share a model pool can opt in by passing `ModelStorageService(baseDirectory: sharedModelsDirectory)`.

Discovery additionally surfaces any `.gguf` files (or MLX model directories) in `~/Documents/Models` so users who follow the [`CLI quickstart`](docs/QUICKSTART-CLI.md) and drop files there see them in the SwiftUI `ModelManagementSheet` without extra setup. App-scoped storage always wins on a collision. See [`docs/LOCAL-GGUF.md`](docs/LOCAL-GGUF.md) for the full storage contract and the typed error surface (`ModelDiscoveryError`) the sheet uses to explain load failures.

## Key Types

| Type | Purpose |
|------|---------|
| `ManifoldKit.quickStart` | One-call bootstrap — returns `QuickStartResult { bootstrap, viewModel, sessionManager }`. |
| `ManifoldBootstrap` | SwiftData-backed bootstrap — installs configuration, builds persistence adapters, holds shared services. Drop down to this when you need a custom inference service or model container. |
| `ChatViewModel` | Central chat controller — messages, generation, model loading, settings. |
| `SessionManagerViewModel` | Chat session CRUD and selection. |
| `ModelManagementViewModel` | HuggingFace search, downloads, local model management (`ManifoldUIModelManagement`). |
| `InferenceService` | Backend orchestrator — selects and delegates to the right backend. |
| `ConversationRuntime` | Single turn loop — all turn-flow operations dispatched via `processTurn(TurnInput(...))` with `ConversationEvent` hooks. |
| `ChatView` | Main chat interface with message list and input bar. |
| `SessionListView` | Sidebar session list with rename/delete. |
| `ModelManagementSheet` | Combined model browser + storage management. |
| `InferenceBackend` | Common interface for all inference engines — implement this to add a custom backend. |
| `ManifoldKitError` | Unified error rim — every public throws normalises to this type. |

For the full surface (protocols, services, views), browse `Sources/` or read the DocC catalogues in each module's `*.docc/` directory.

## Tool Calling

> [!WARNING]
> The `@ToolSchema` macro is gated behind the `Macros` SwiftPM trait (default-off). Default builds skip swift-syntax (~647 source files) and `@ToolSchema` is invisible. To use the macro, opt in with `--traits Macros`. Without it, declare `JSONSchemaValue` by hand on `ToolDefinition.parameters`.

Register tools with `ToolRegistry` and pass `toolRegistry.definitions` as `GenerationConfig.tools`:

```swift,no-build
let registry = ToolRegistry()
registry.register(MyWeatherTool())

let (_, stream) = try inferenceService.enqueue(
    messages: history,
    tools: registry.definitions
)
```

**Local backend tool ceiling:** Local instruct models (3B–8B) degrade sharply when given more than ~5 tool definitions per request. For cloud backends (OpenAI, Anthropic, large Ollama models) 20+ tools is fine. When targeting a local backend, curate tools per request and keep definitions at or below 5 per call.

For the complete guide — tool definition shape, `TypedToolExecutor`, streaming tool results, approval gates, and the `preToolUseHook` — see [docs/QUICKSTART-TOOLS.md](docs/QUICKSTART-TOOLS.md).

## MCP

```swift,no-build
import ManifoldInference
import ManifoldMCP

let client = MCPClient()
let source = try await client.connect(descriptor)
await source.register(in: registry)
```

For a complete walkthrough (descriptor setup, lifecycle, and built-in catalog), see `Sources/ManifoldMCP/ManifoldMCP.docc/Articles/MCPGettingStarted.md`.

ManifoldKit also supports running as an **MCP server** — exposing your app's live state and tools to external MCP clients such as Claude Desktop, other agents, or any MCP-aware host. Import `ManifoldMCPHost` and follow the setup guide at `Sources/ManifoldMCPHost/ManifoldMCPHost.docc/Articles/MCPHostServer.md`. This is the entry point for agent-platform builders who want to surface their app's capabilities to the broader MCP ecosystem rather than consuming external tools.

### MCP capability coverage

Honest expectations — ManifoldKit's MCP surface is **tool-and-resource first**, with full OAuth 2.1. What ships today, verified against `Sources/ManifoldMCP` / `Sources/ManifoldMCPHost`:

| Capability | Client (consume) | Host (expose) | Notes |
|---|---|---|---|
| **Tools** (`tools/list`, `tools/call`) | ✅ | ✅ | `MCPToolSource` / `MCPToolExecutor`; bridged into the `ToolRegistry`. |
| **Resources** (`resources/list`, `resources/read`) | ⚠️ partial | ✅ | Host serves list + read; client **detects** `supportsResources` but no outbound `resources/*` call is wired yet (only `tools/*` is consumed). |
| **Prompts** (`prompts/list`, `prompts/get`) | ⚠️ partial | ❌ | Capability is **detected** (`supportsPrompts`) but not yet consumed — no client call wired. |
| **OAuth 2.1** | ✅ | — | Authorization-server discovery, token exchange, PKCE, secured token store. |
| **Sampling** (`sampling/createMessage`) | ✅ | ❌ | Client parses the request off the wire and routes it through the host-supplied `MCPClientConfiguration.samplingHandler`; `ManifoldMCP` itself runs no inference. Host-side (accepting sampling requests from external MCP clients) not implemented. Closed [#1925](https://github.com/ManifoldKit/ManifoldKit/issues/1925). |
| **Elicitation** (`elicitation/create`) | ✅ | ❌ | Client parses the request off the wire and routes it through the host-supplied `MCPClientConfiguration.elicitationHandler`; `ManifoldMCP` itself renders no UI. Host-side (accepting elicitation requests from external MCP clients) not implemented. Closes [#1926](https://github.com/ManifoldKit/ManifoldKit/issues/1926). |
| **Transports** | stdio, streamable-HTTP (SSE) | stdio, streamable-HTTP | Both client and host support both transports. |

## Handoffs and Hooks

Two session-scoped extension points complement MCP for non-MCP hosts:

- **Agent handoffs** — multi-persona sessions where the model emits `transfer_to_<name>` to swap the active agent. See `Sources/ManifoldRuntime/ManifoldRuntime.docc/Articles/AgentHandoffs.md`.
- **Hook system** — synchronous `preToolUse` (sanitize/block) and `preCompact` (observe) hooks distinct from the observational event stream. See `Sources/ManifoldRuntime/ManifoldRuntime.docc/Articles/HookSystem.md`.

`ManifoldSkills` (filesystem-discovered Claude-Code-compatible `SKILL.md` skills) was retired 2026-08-06 for zero adoption — see [docs/MIGRATION-skills-removed.md](docs/MIGRATION-skills-removed.md). Its `AGENTS.md` ambient-instruction loading survives as the separate `ManifoldAgentInstructions` product, wired via `ConversationRuntimeOptions.addAgentInstructions(currentDirectory:stoppingAt:)` — see the migration note for the recipe.

## Custom Backends

Implement `InferenceBackend` and register it. The protocol takes a precomputed `ModelLoadPlan` so the caller's memory-admission verdict and effective context size flow through to the backend instead of being recomputed:

```swift,no-build
class MyBackend: InferenceBackend, @unchecked Sendable {
    var isModelLoaded = false
    var isGenerating = false
    var capabilities: BackendCapabilities { /* ... */ }

    func loadModel(from url: URL, plan: ModelLoadPlan) async throws { /* ... */ }
    func generate(prompt: String, systemPrompt: String?, config: GenerationConfig)
        throws -> GenerationStream { /* ... */ }
    func stopGeneration() { /* ... */ }
    func unloadModel() { /* ... */ }
}

inferenceService.registerBackendFactory { modelType in
    switch modelType {
    case .gguf: return MyBackend()
    default: return nil
    }
}
```

`plan.effectiveContextSize` carries the resolved context window and `plan.verdict` is one of `.allow` / `.warn` / `.deny`. Callers must check the verdict before invoking `loadModel`; conformers may rely on that precondition.

## Cloud API Configuration

Cloud endpoints flow through storage-neutral `APIEndpointRecord` values. `APIConfigurationView` persists records through the runtime's `EndpointStore`:

```swift,no-build
let endpoint = APIEndpointRecord(
    name: "My OpenAI",
    provider: .openAI,
    baseURL: "https://api.openai.com",
    modelName: "gpt-4o-mini"
)
try KeychainService.store(key: "sk-...", account: endpoint.keychainAccount)
try await runtime.endpointStore.insertEndpoint(endpoint)
```

`KeychainService.store` / `.delete` and the SwiftData `APIEndpoint.setAPIKey` / `.deleteAPIKey` helpers throw `KeychainError` on failure. Deleting a non-existent item is non-throwing (`errSecItemNotFound` is treated as success), so `tearDown` / `deinit` cleanup can keep its `try?` idiom.

## Prompt Templates

GGUF models require explicit chat formatting. ManifoldKit includes templates for ChatML, Llama 3, Mistral, Alpaca, Gemma, and Phi. Templates auto-detect from GGUF metadata when available. User content is sanitised to strip special tokens and prevent prompt injection.

## Security

See [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) for the full threat model. A quick summary:

- API keys stored in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Keys read just-in-time from Keychain rather than cached as long-lived properties; during an in-flight `URLSession` request the key bytes do exist in process memory as a Swift `String` and are not zeroized after use (see [docs/FIPS.md](docs/FIPS.md) §non-mitigations).
- Certificate pinning via `PinnedSessionDelegate`; `api.openai.com` and `api.anthropic.com` fail closed if pin sets are missing/empty. Credentialed requests to non-loopback hosts without SPKI pins also fail closed by default (`allowUnpinnedCredentialedHosts = false`) — add pins for custom endpoints or opt in to residual DNS-rebinding risk. TLS for unpinned custom hosts can be further hardened via `customHostTrustPolicy = .requireExplicitPins`.
- HTTPS enforced for non-localhost endpoints.
- User content sanitised in prompt templates to prevent injection.
- Sensitive data uses `privacy: .private` in `os.Logger` calls; error response bodies filtered before logging.

For regulated deployments (healthcare, federal-adjacent, finance), see [docs/FIPS.md](docs/FIPS.md) for the full answer to "are your cryptographic primitives FIPS 140-3 validated?".

## Binary Dependencies

Core ManifoldKit has **no pre-built binary dependencies** — the heavy xcframeworks moved out with the v0.48 companion-package split:

- **llama.swift** (pre-built llama.cpp xcframework) is pinned by [`manifold-llama`](https://github.com/ManifoldKit/manifold-llama). For source-verified builds, follow the [llama.swift build instructions](https://github.com/mattt/llama.swift) to compile your own.
- **mlx-swift** (Apple's MLX framework, pre-built xcframework from [ml-explore/mlx-swift](https://github.com/ml-explore/mlx-swift)) is pinned by [`manifold-mlx`](https://github.com/ManifoldKit/manifold-mlx). Source builds supported via that upstream repo.

Review each companion package's `Package.resolved` for the exact versions in use.

## Troubleshooting

### "XCFramework Info.plist not found" or "workspace-state.json desync"

This typically happens after changing the active trait set. SwiftPM caches binary-target paths in `.build/workspace-state.json` and does not auto-re-resolve stale paths. Run:

```bash
scripts/clean-build.sh
```

### Stale "No such module 'ManifoldPersistenceSwiftData'" in the editor

SourceKit can retain stale module-not-found diagnostics from a previous trait-set build. Restart the SourceKit language server (Xcode: *Product → Clean Build Folder*, then reopen; VS Code: "Swift: Restart SourceKit-LSP" from the command palette). If that's insufficient, run `scripts/clean-build.sh`. For non-destructive investigation see `docs/SOURCEKIT_DIAGNOSTICS.md`.

## Example App

Start with [`Example/Examples/MinimalExample`](Example/Examples/MinimalExample) — the canonical Hello World. The full-featured reference app lives at [`Example/Advanced`](Example/Advanced); open it once the minimal example makes sense.

```bash
cd Example
open Advanced.xcodeproj
```

## How ManifoldKit compares to AnyLanguageModel

AnyLanguageModel is HuggingFace's Swift package — it mirrors Apple's `FoundationModels` API and exposes many providers behind a single protocol. ManifoldKit and AnyLanguageModel occupy adjacent niches: AnyLanguageModel optimises for provider coverage and API familiarity; ManifoldKit optimises for production reliability and drop-in chat UI (`ChatView` + `SessionListView` + `ModelManagementSheet` on day one). Pick the one whose axis matches the problem you're solving.

WWDC 2026 validated AnyLanguageModel's bet: Apple opened Foundation Models itself to third-party providers behind a near-identical shape (`LanguageModel` / `LanguageModelExecutor`, driving `LanguageModelSession`), with Anthropic's `ClaudeForFoundationModels` (beta) and Google's Gemini-via-Firebase (preview) shipping on top — both iOS 27+ only, both currently pre-GA. That's real validation for the "one API over many models" idea, and it's a reason ManifoldKit doesn't compete on that axis either: reaching Claude or Gemini on the OSes ManifoldKit actually targets (iOS 18+ / macOS 15+) still means ManifoldKit's own cloud backends, not the new OS-gated provider layer.

ManifoldKit previously **consumed** AnyLanguageModel as a backend via the `ManifoldAnyLanguageModel` product. That bridge was retired in #2435 — zero adoption, plus dependency coupling to a pre-1.0 external package — and most of the providers it named (xAI, Groq, Mistral, OpenRouter — Gemini's own OpenAI-compatible endpoint is not reachable this way, but its models are available through OpenRouter) are reached the same way any OpenAI-compatible endpoint is: `APIProvider.custom` + the native `OpenAIBackend` pointed at the provider's base URL. That path has tool calling and structured output the bridge never advertised, and retry + circuit-breaking every `ManifoldCloudCore`-backed family gets. Certificate pinning is **not** automatic for these hosts, though — `APIProvider.custom` isn't in the default pin set, and ManifoldKit fails a credentialed request closed rather than sending it unpinned; populate `PinnedSessionDelegate.pinnedHosts` or opt out via `ManifoldConfiguration.allowUnpinnedCredentialedHosts` before the first request. See [docs/MIGRATION-anylanguagemodel-retired.md](docs/MIGRATION-anylanguagemodel-retired.md) for the full recipe.

Coming from Apple's `LanguageModelSession` / `@Generable` or AnyLanguageModel's provider abstraction? [docs/MIGRATING-FROM-FOUNDATION-MODELS.md](docs/MIGRATING-FROM-FOUNDATION-MODELS.md) maps those idioms onto ManifoldKit's `quickStart()` / `ChatViewModel` / `ToolDefinition` surface.

## Migrating from BaseChatKit

This package was renamed from `BaseChatKit` to `ManifoldKit` in v0.20. The old GitHub URL redirects, but:

- Update SPM dependencies to `.package(url: "https://github.com/ManifoldKit/ManifoldKit.git", ...)` with `from: "0.77.0"` <!-- x-release-please-version -->
- Update imports: `import BaseChatKit` → `import ManifoldKit` (and similarly for sub-modules).
- Renamed public types: `BaseChatBootstrap` → `ManifoldBootstrap`, `BaseChatConfiguration` → `ManifoldConfiguration`, `BaseChatSchemaV3/4/5` → `ManifoldSchemaV3/4/5`, `BaseChatMigrationPlan` → `ManifoldMigrationPlan`, `BaseChatBackgroundTaskIdentifiers` → `ManifoldBackgroundTaskIdentifiers`.
- **BREAKING — local SwiftData stores reset.** Apps upgrading from 0.19.x create fresh databases on first launch. We chose this clean break over preserving data with `@Model.originalName` because v0.20 is pre-1.0.
- Cache directories `~/Library/Caches/BaseChatKit/` and `~/Library/Application Support/BaseChatKit/` are orphaned; users get fresh state.
- Background-task identifiers `com.basechatkit.background.*` → `com.manifoldkit.background.*` — update `BGTaskSchedulerPermittedIdentifiers` in Info.plist.

## License

MIT License. See [LICENSE](LICENSE) for details.
