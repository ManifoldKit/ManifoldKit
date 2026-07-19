# ManifoldKit Recipes

**Audience:** consumer
**Status:** living

Short, runnable patterns for the most common ManifoldKit tasks. Each recipe is
the minimum viable code — check the linked quickstart for the full walkthrough
including error handling, multi-turn state, and UI wiring.

> **Snippet-gate note.** All recipes use `import ManifoldKit` (the umbrella) —
> they compile against the standard ManifoldKit + ManifoldUI +
> ManifoldUIModelManagement scaffold. Any recipe that needs a module outside the
> umbrella is tagged `swift,no-build` with an explanation.

---

## 1. Tool loop

Register a tool, wire it into the inference service, and run a turn. The turn
loop calls the tool automatically and feeds the result back before the next
token — you observe both through the event stream.

Full walkthrough: [`QUICKSTART-TOOLS.md`](QUICKSTART-TOOLS.md).

```swift,no-build
import ManifoldKit

// 1. Define argument + result types.
struct EchoArgs:   Decodable, Sendable { let text: String }
struct EchoResult: Encodable, Sendable { let echoed: String }

// 2. Build an executor — handler decodes args, returns a result.
let echoTool = TypedToolExecutor<EchoArgs, EchoResult>(
    definition: ToolDefinition(
        name: "echo",
        description: "Returns the input text unchanged.",
        parameters: .object([
            "type": .string("object"),
            "properties": .object([
                "text": .object([
                    "type": .string("string"),
                    "description": .string("Text to echo")
                ])
            ]),
            "required": .array([.string("text")])
        ])
    )
) { args in
    EchoResult(echoed: args.text)
}

// 3. Register and wire into an InferenceService.
let registry = ToolRegistry()
registry.register(echoTool)

let inference = InferenceService(toolRegistry: registry)
OllamaBackends.register(with: inference)

// 4. Run a turn — the dispatch loop fires tools automatically.
var config = GenerationConfig()
config.tools = registry.definitions
config.toolChoice = .auto

let (_, stream) = try inference.enqueue(
    messages: [.user("Echo the phrase 'hello world' for me.")],
    config: config
)
for try await event in stream.events {
    switch event {
    case .token(let t):      print(t, terminator: "")
    case .toolCall(let c):   print("\n[calling \(c.toolName)]")
    case .toolResult(let r): print("[result: \(r.content)]")
    default: break
    }
}
```

> **Local-model ceiling.** Small instruct models (3B–8B) degrade when given more
> than ~5 tool definitions per request. Keep the registered set minimal for
> on-device use; cloud backends (OpenAI, Anthropic) handle 20+ without issue.

---

## 2. RAG (retrieval-augmented generation)

Ingest documents and let the turn loop retrieve relevant passages automatically
before each reply. Once configured, your existing `ChatView` surfaces citations
with no per-turn code.

Full walkthrough: [`QUICKSTART-RAG.md`](QUICKSTART-RAG.md).
Tuning knobs: [`RAG-TUNING.md`](RAG-TUNING.md).

```swift,no-build
import ManifoldKit

// RAG requires the manual bootstrap path (quickStart() has no RAG parameter).
let ragConfig = RAGConfiguration(
    embeddingBackend: nil,   // nil → keyword fallback; pass a LlamaEmbeddingBackend
                             // for semantic search (requires manifold-llama)
    chunkSize: 1800,
    chunkOverlap: 200,
    topK: 5
)

// build() returns (progress stream, task) — await the task for the bootstrap.
let (_, task) = ManifoldBootstrap.build(
    configuration: ManifoldConfiguration.shared,
    ragConfiguration: ragConfig
)
let bootstrap = try await task.value

// Ingest documents — parsing, chunking, and embedding happen here.
let docURL = Bundle.main.url(forResource: "guide", withExtension: "txt")!
try await bootstrap.ragService?.ingest(url: docURL)

// The turn loop calls retrieve() automatically before each turn.
// Citations arrive on the assistant ChatMessage:
//   message.citations   → [Citation] with documentTitle, snippet, score
// ChatView renders a "Sources" disclosure group automatically.
```

> **Re-ingest after switching the embedding backend.** Documents ingested while
> no embedder was loaded store no vector. Load the embedder, then re-ingest for
> semantic search to take effect.

---

## 3. On-device model pick

Score and select the best model for a use case, gate on the load-plan verdict,
then load it — without standing up a `ChatViewModel`.

Full walkthrough: [`QUICKSTART-MODEL-SELECTION.md`](QUICKSTART-MODEL-SELECTION.md).

```swift,no-build
import ManifoldKit

@MainActor
func pickAndLoad(service: InferenceService) async throws {
    let selection = ModelSelection(inferenceService: service)
    try selection.refresh()   // scan the models directory

    // Score every discovered model against a use case, best-first.
    let ranked = selection.rankedModels(useCase: .reasoning)
    guard let best = ranked.first else {
        print("No models found — download one via ModelManagementSheet.")
        return
    }

    // Pre-flight check: will this model fit on this device?
    let plan = ModelLoadPlan.compute(
        for: best.model,
        requestedContextSize: 8_192,
        strategy: .mappable
    )
    if case .deny = plan.verdict {
        print("Won't fit: \(plan.reasons)")
        return
    }

    // Select and load — admission check runs again inside loadSelected().
    selection.select(best.model)
    selection.loadSelected()

    // Observe progress:
    for await status in selection.loadStatusUpdates() {
        switch status {
        case .loading(let p): print("Loading… \(Int((p ?? 0) * 100))%")
        case .loaded:         print("Ready: \(best.model.name)")
        case .failed(let e):  print("Failed: \(e)"); return
        default: break
        }
    }
}
```

> **`supportsReasoning` honest-false footgun.** Single-file GGUFs ship no
> `config.json`, so the reasoning-capability flag is `false` for most local
> models — this means "unknown," not "cannot reason." Don't exclude local models
> from a reasoning picker on that flag alone; use it as a hint and prefer curated
> or cloud reasoners when you need certainty.

---

## 4. Structured output (raw strategy)

Constrain generation to a JSON Schema or GBNF grammar. `StructuredOutputRouter`
picks the strongest mechanism each backend supports; you decode the returned
string yourself.

> **No `@Generable` equivalent yet.** ManifoldKit constrains the *generation*
> but does not hand back a decoded Swift instance. Decode with `JSONDecoder` after
> the turn. The typed-instance ergonomics are tracked in
> [#1915](https://github.com/ManifoldKit/ManifoldKit/issues/1915).

```swift,no-build
import ManifoldKit

struct Sentiment: Decodable {
    enum Label: String, Decodable { case positive, negative, neutral }
    let label: Label
    let confidence: Double
}

// Constrain with a JSON Schema document — routed to grammar-constrained decoding
// where available, falling back to .jsonPrompting on cloud backends.
// structuredOutput lives on GenerationRuntimeHints (v0.69+), not GenerationConfig.
var config = GenerationConfig()
var hints = GenerationRuntimeHints()
hints.structuredOutput = .jsonSchema(#"""
{
  "type": "object",
  "properties": {
    "label":      { "enum": ["positive", "negative", "neutral"] },
    "confidence": { "type": "number", "minimum": 0, "maximum": 1 }
  },
  "required": ["label", "confidence"]
}
"""#)

// enqueue takes [Message] (Message.system / .user / .assistant) — not ChatMessage.
let messages: [Message] = [
    .system("Classify the sentiment of the user's message. Respond in JSON only."),
    .user("I love this library!")
]
let (_, stream) = try inference.enqueue(
    messages: messages,
    config: config,
    hints: hints
)

var raw = ""
for try await event in stream.events {
    if case .token(let t) = event { raw += t }
}

// Decode yourself — ManifoldKit guarantees the JSON shape, not a Swift instance.
let result = try JSONDecoder().decode(Sentiment.self, from: Data(raw.utf8))
print(result.label, result.confidence)
```

**Other strategies:**

```swift,no-build
// GBNF grammar (llama.cpp-class backends):
hints.structuredOutput = .gbnf(#"root ::= "yes" | "no""#)

// Foundation guided-generation target type (iOS/macOS 26+, Foundation backend):
hints.structuredOutput = .guided(MyGuidedType.self)

// JSON-prompting fallback (any backend, no grammar support needed):
hints.structuredOutput = .jsonPrompting
```

`StructuredOutputRouter` selects the best strategy automatically — you only need
to override if you want a specific mechanism regardless of what the backend
supports.

---

## See also

- [`QUICKSTART-TOOLS.md`](QUICKSTART-TOOLS.md) — full tool-calling guide with `TypedToolExecutor`, approval gates, and streaming results.
- [`QUICKSTART-RAG.md`](QUICKSTART-RAG.md) — end-to-end RAG setup with semantic search and reranking.
- [`RAG-TUNING.md`](RAG-TUNING.md) — chunk size, reranker tradeoffs, and the citation surface.
- [`QUICKSTART-MODEL-SELECTION.md`](QUICKSTART-MODEL-SELECTION.md) — `ModelSelection` and `ModelLoadPlan` details.
- [`MIGRATING-FROM-FOUNDATION-MODELS.md`](MIGRATING-FROM-FOUNDATION-MODELS.md) — mapping `@Generable` / `LanguageModelSession` onto ManifoldKit.
