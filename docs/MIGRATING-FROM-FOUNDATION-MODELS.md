# Migrating from Apple Foundation Models

**Audience:** consumer
**Status:** living

If you already think in Apple's `LanguageModelSession` / `@Generable` idioms,
this guide maps that mental model onto ManifoldKit's surface. ManifoldKit
operates one altitude *above* model access: the session, tool, and
structured-output concepts you know sit inside a persisted turn loop, approval
policy, and app UI. Structured output is the important exception — ManifoldKit
does not yet offer Apple's decoded-instance ergonomics.

> **TL;DR.** A `LanguageModelSession` becomes a `ChatViewModel` (or a
> `ConversationRuntime` if you want headless control). `session.respond(to:)`
> becomes `chatVM.sendMessage(_:)`. Tools map onto `ToolDefinition` +
> `ToolRegistry`. `@Generable` has **no macro equivalent yet** — use the raw
> structured-output strategies on `GenerationRuntimeHints.structuredOutput`
> (v0.69+; not `GenerationConfig`) and track the ergonomic sugar in
> [#1915](https://github.com/ManifoldKit/ManifoldKit/issues/1915).

---

## Why migrate (and why not)

Apple's `FoundationModels` framework provides a clean session API and, on iOS
27/macOS 27, a public `LanguageModel` / `LanguageModelExecutor` provider seam.
Apple also publishes first-party integrations for MLX and Core AI plus cloud
chat-completions utilities. ManifoldKit does not claim to be the only provider
abstraction on Apple platforms.

ManifoldKit **wraps Apple's system model** as one backend (`FoundationBackend`,
iOS 26 / macOS 26+) and adds the product layer: one persisted multi-session turn
loop across local and cloud engines, drop-in SwiftUI, tool approval, RAG, model
management, and backend-independent operations. Use ManifoldKit when you need
that sustained app surface; stay on raw `FoundationModels` when its session and
provider ecosystem are sufficient.

ManifoldKit no longer wraps AnyLanguageModel as a dependency — the bridge
product (`ManifoldAnyLanguageModel`) was retired in #2435 for zero adoption.
Providers without a native ManifoldKit backend — xAI, Groq, Mistral,
OpenRouter — reach ManifoldKit the same way any custom cloud endpoint does:
`APIProvider.custom` + the native `OpenAIBackend` pointed at the provider's
base URL. **Gemini is the exception**: its own OpenAI-compatible endpoint
uses a completions path `OpenAIBackend` cannot reach (no `baseURL` fixes
this — see the migration note), so Gemini models are reached through
OpenRouter instead, not directly. See
[MIGRATION-anylanguagemodel-retired.md](MIGRATION-anylanguagemodel-retired.md)
for the full recipe and the pinning step every one of these hosts also needs.

---

## Concept map

| Apple `FoundationModels` / AnyLanguageModel | ManifoldKit equivalent | Notes |
|---|---|---|
| `LanguageModelSession` | `ChatViewModel` (UI) or `ConversationRuntime` (headless) | Persisted, multi-turn, multi-backend |
| `session.respond(to:)` / `streamResponse(to:)` | `chatVM.sendMessage(_:)` | Streaming is built into the turn loop |
| `SystemLanguageModel` (the model) | `FoundationBackend` | One backend inside the shared runtime |
| `LanguageModel` / `LanguageModelExecutor` (iOS 27 / macOS 27 provider seam) | `InferenceBackend` | Different ownership boundaries: Apple's session owns its loop; ManifoldKit's `ConversationRuntime` owns the app turn loop |
| AnyLanguageModel `LanguageModel` (provider abstraction) | `InferenceBackend` + `OpenAIBackend` via `APIProvider.custom` | Not a wrapped dependency — a native client pointed at the provider's OpenAI-compatible endpoint |
| `Tool` protocol / tool calling | `ToolDefinition` + `ToolRegistry` + `ToolExecutor` | Local **and** cloud, with approval gating |
| `@Generable` / guided generation | `GenerationRuntimeHints.structuredOutput` (`.gbnf` / `.jsonSchema` / `.guided` / `.jsonPrompting`) | **No `@Generable` macro** — see below. (Pre-v0.69 this lived on `GenerationConfig`; that placement is retired.) |
| `GenerationOptions` (temperature, etc.) | `GenerationConfig` (temperature, topP, topK, …) | Same knobs, one struct; pass per-request extras via `GenerationRuntimeHints` |
| Transcript / conversation history | `MessageStore` + `SessionStore` (SwiftData) | Persisted by default |

---

## 1. Session → ChatViewModel

In `FoundationModels` you create a session and ask it to respond. In ManifoldKit
the equivalent is `quickStart()`, which hands you a fully wired `ChatViewModel`
backed by a persisted turn loop:

```swift,no-build
import ManifoldKit

// FoundationModels:
//   let session = LanguageModelSession()
//   let reply = try await session.respond(to: "Summarise this.")

// ManifoldKit:
let result = try await ManifoldKit.quickStart()
let chatVM = result.viewModel
let reply = try await chatVM.sendMessage("Summarise this.")
```

`quickStart()` returns a `QuickStartResult` carrying the `viewModel`,
`bootstrap`, and `sessionManager`. Drop the `viewModel` into your SwiftUI
environment and present the shipped `ChatView`, or call `sendMessage(_:)`
yourself for a headless flow. Unlike a `LanguageModelSession`, the conversation
is **persisted** across launches via SwiftData — no transcript bookkeeping.

For full control without the view model, drive `ConversationRuntime` directly —
it owns `send`/`regenerate`/`edit`/`branch`/`cancel` through a single
`processTurn(_:)` entry point taking a `TurnInput`. Most apps don't need this;
`ChatViewModel` is the ergonomic session equivalent.

---

## 2. Picking the model = picking the backend

`FoundationModels` gives you exactly one model. ManifoldKit's `FoundationBackend`
wraps that same model, but it's one registrar among several:

```swift,no-build
import ManifoldKit
import ManifoldFoundation   // FoundationBackends registrar (iOS 26 / macOS 26+)

// Register only Apple's on-device model — closest to staying on FoundationModels:
let result = try await ManifoldKit.quickStart(backends: [FoundationBackends.self])
```

`FoundationBackend` is gated `@available(iOS 26, macOS 26, *)`;
`FoundationBackends.register(with:)` checks availability at call time and no-ops
on older OSes, so it's safe to list unconditionally. Add other registrars
(`OllamaBackends`, `CloudSaaSBackends`, the companion `LlamaBackends` /
`MLXBackends`) to the array to offer more models behind the same `ChatViewModel`.

To reach a provider AnyLanguageModel supports but ManifoldKit doesn't implement
natively, configure it as a custom OpenAI-compatible endpoint — see
[MIGRATION-anylanguagemodel-retired.md](MIGRATION-anylanguagemodel-retired.md):

```swift,no-build
import ManifoldInference

// OpenRouter's OpenAI-compatible endpoint — same recipe for xAI, Groq,
// Mistral, or any other OpenAI-compatible provider. NOTE: no trailing /v1 —
// OpenAIBackend appends `v1/chat/completions` itself. (Gemini's own endpoint
// is NOT reachable this way — its completions path doesn't match; reach
// Gemini models through OpenRouter instead. See the migration note.)
// One InferenceBackend, same turn loop.
let endpoint = APIEndpointRecord(
    name: "OpenRouter",
    provider: .custom,
    baseURL: "https://openrouter.ai/api",
    modelName: "openai/gpt-4o-mini"
)
try KeychainService.store(key: "sk-or-v1-...", account: endpoint.keychainAccount)
try await bootstrap.endpointStore.insertEndpoint(endpoint)
// Also required before the first request: certificate pinning
// (PinnedSessionDelegate.pinnedHosts) or the documented opt-out — see
// MIGRATION-anylanguagemodel-retired.md § Certificate pinning.
```

---

## 3. Tools

Apple's `Tool` protocol and ManifoldKit's `ToolDefinition` express the same idea:
a named, described, schema'd capability the model can call. ManifoldKit's version
works across **every** backend (local and cloud) and adds human-in-the-loop
approval.

```swift,no-build
import ManifoldKit

let getWeather = ToolDefinition(
    name: "get_weather",
    description: "Look up the current weather for a city.",
    // parameters is a JSONSchemaValue — a typed enum (.object / .string / …),
    // not a [String: Any]. Build the JSON-Schema document explicitly:
    parameters: .object([
        "type": .string("object"),
        "properties": .object([
            "city": .object([
                "type": .string("string"),
                "description": .string("City name")
            ])
        ]),
        "required": .array([.string("city")])
    ])
)
```

Register the definition with an executor in the `ToolRegistry`, and the turn loop
calls it automatically — the same multi-step tool loop you'd hand-roll around
`session.respond(to:)`. See [QUICKSTART-TOOLS.md](QUICKSTART-TOOLS.md) for the
end-to-end registry + executor wiring, and [LOCAL-TOOL-CALLING.md](LOCAL-TOOL-CALLING.md)
for how local GGUF/MLX models emit tool calls.

> If you used Apple's `@Generable` purely to *describe a tool's arguments*,
> ManifoldKit has the `@ToolSchema` macro (opt-in `Macros` trait) that generates
> a `ToolDefinition`'s parameter schema from a Swift type. That is the **only**
> `@Generable`-shaped macro in ManifoldKit today.

---

## 4. Structured output: `@Generable`'s honest mapping

This is the one place where the translation is **not** one-to-one, so be precise.

Apple's `@Generable` + guided generation gives you a *decoded Swift instance*
straight from the model. **ManifoldKit has no `@Generable` macro and no
`generate(as: MyType.self)` API.** What ships is the raw strategy layer on
`GenerationRuntimeHints.structuredOutput` (moved off `GenerationConfig` in
v0.69 — that field is gone):

```swift,no-build
import ManifoldKit

var config = GenerationConfig()
var hints = GenerationRuntimeHints()

// Constrain output with a JSON Schema document (capability-routed):
hints.structuredOutput = .jsonSchema(#"""
{ "type": "object",
  "properties": { "sentiment": { "enum": ["pos", "neg", "neutral"] } },
  "required": ["sentiment"] }
"""#)

let (_, stream) = try inference.enqueue(
    messages: [.user("Classify this…")],
    config: config,
    hints: hints
)

// Other strategies:
//   .gbnf("root ::= ...")       — GBNF grammar (llama.cpp-class backends)
//   .guided(MyType.self)        — Foundation guided-generation target type
//   .jsonPrompting              — prompt-level JSON instruction fallback
```

`StructuredOutputRouter` picks the best mechanism the active backend supports
(grammar-constrained decoding where available, falling back to `.jsonPrompting`).
You then **decode the returned string yourself** (`JSONDecoder`) — ManifoldKit
constrains the *generation*, but does not hand you a typed instance.

> The `@Generable`/Codable → decoded-instance ergonomics are tracked in
> [#1915](https://github.com/ManifoldKit/ManifoldKit/issues/1915). Until that
> ships, do **not** expect `let x: MyType = try await ...generate(...)` — it
> does not exist. Map `@Generable` onto the raw strategy above.

---

## 5. Generation options

`GenerationOptions` → `GenerationConfig`. The sampling knobs you know
(`temperature`, `topP`, `topK`, repetition penalties, `maxThinkingTokens`,
`tools`, `toolChoice`, `maxToolIterations`) all live on the one
`GenerationConfig` struct, set per turn.

---

## Migration checklist

1. Replace `LanguageModelSession()` with `try await ManifoldKit.quickStart()`;
   use `result.viewModel`.
2. Replace `session.respond(to:)` with `chatVM.sendMessage(_:)`.
3. To stay on Apple's model only, pass `backends: [FoundationBackends.self]`.
4. Port `Tool`s to `ToolDefinition` + a `ToolRegistry` executor.
5. Port `@Generable` to `GenerationRuntimeHints.structuredOutput` (raw strategy)
   + manual `JSONDecoder` — no typed-instance API yet ([#1915]).
6. For a non-native provider AnyLanguageModel supports, configure it as a
   custom OpenAI-compatible endpoint (`APIProvider.custom` + `OpenAIBackend`) —
   see [MIGRATION-anylanguagemodel-retired.md](MIGRATION-anylanguagemodel-retired.md).

[#1915]: https://github.com/ManifoldKit/ManifoldKit/issues/1915

---

## See also

- [`QUICKSTART.md`](QUICKSTART.md) — the `quickStart()` and bootstrap paths.
- [`MIGRATION-anylanguagemodel-retired.md`](MIGRATION-anylanguagemodel-retired.md) — reaching AnyLanguageModel's providers via a custom OpenAI-compatible endpoint.
- [`QUICKSTART-TOOLS.md`](QUICKSTART-TOOLS.md) — tool registry + executor.
- [`POSITIONING.md`](POSITIONING.md) §9 — ManifoldKit vs. AnyLanguageModel.
