# Tool Calling

Register tools the model can invoke, dispatch the calls it emits, and feed results back into the conversation. Tool calling behaves identically across backends that report `BackendCapabilities.supportsToolCalling` — MLX, llama.cpp, Foundation Models, OpenAI, Anthropic, and tool-capable Ollama models.

The types in this guide live in `ManifoldInference`. The umbrella `import ManifoldKit` re-exports them; BYO-UI consumers import `ManifoldInference` directly.

## The shape of a tool

A tool is a `ToolDefinition` (the JSON-Schema contract the model sees) paired with an executor that runs it. The protocol is `ToolExecutor`, but most callers use `TypedToolExecutor`, which decodes JSON arguments into a Swift type, runs a handler, and encodes the result back to JSON.

```swift,no-build
import ManifoldInference

struct WeatherArgs: Decodable, Sendable { let city: String }
struct WeatherResult: Encodable, Sendable { let summary: String; let celsius: Double }

let weatherSchema: JSONSchemaValue = .object([
    "type": .string("object"),
    "properties": .object([
        "city": .object([
            "type": .string("string"),
            "description": .string("City name")
        ])
    ]),
    "required": .array([.string("city")])
])

let weather = TypedToolExecutor<WeatherArgs, WeatherResult>(
    definition: ToolDefinition(
        name: "get_weather",
        description: "Returns current weather for a city.",
        parameters: weatherSchema
    )
) { args in
    WeatherResult(summary: "Sunny", celsius: 22.0)
}
```

`ToolDefinition.parameters` is a `JSONSchemaValue` — a typed enum (`.object`, `.array`, `.string`, `.number`, `.bool`, `.null`), not a `[String: Any]` dictionary. Build the schema with the enum cases as shown above.

> Prefer to declare the schema once on the argument type? The `@ToolSchema` macro synthesises a `static var jsonSchema` from your `Decodable` struct, so you can pass `WeatherArgs.jsonSchema` to `parameters:`. The macro is gated behind the `Macros` SwiftPM trait (default-off, because it pulls in swift-syntax). Without that trait, hand-write the `JSONSchemaValue` as above.

## Registering tools

A `ToolRegistry` holds executors keyed by name (case-insensitive). Register on construction or with `register(_:)`:

```swift,no-build
let registry = ToolRegistry()
registry.register(weather)
```

Wire the registry into an `InferenceService` at init time:

```swift,no-build
let inference = InferenceService(toolRegistry: registry)
OllamaBackends.register(with: inference)
CloudSaaSBackends.register(with: inference)
FoundationBackends.register(with: inference)
```

The coordinator re-reads the registry on every turn, so you can `register(_:)` more tools later through `inference.toolRegistry` (a get-only accessor returning the same instance). The registry property cannot be reassigned after init — pass the populated registry to the initializer.

## Passing tools to a request

For the queued chat path, put `registry.definitions` on a `GenerationConfig`:

```swift,no-build
var config = GenerationConfig(...)
config.tools = registry.definitions
config.toolChoice = .auto          // .auto | .none | .required | .tool(name:)
config.maxToolIterations = 10      // per-request cap on the tool loop

let (_, stream) = try inference.enqueue(messages: history, config: config)
```

When a registry is installed on the `InferenceService`, the generation coordinator dispatches `toolCall` events through it automatically and feeds each `ToolResult` back into the conversation before the next turn — you observe the loop through the event stream rather than dispatching by hand.

## The local-model tool ceiling

Local instruct models in the 3B–8B range degrade sharply when given more than about **5 tool definitions** per request: they confuse tools, hallucinate arguments, or stop calling tools entirely. Cloud backends (OpenAI, Anthropic, large Ollama models) handle 20+ without issue.

`ToolRegistry.definitions` logs a warning when it returns more than 5 entries. When you target a local backend, curate tools per request rather than advertising the full catalog — pass a filtered subset to `config.tools`, or use `advertisedToolNames` / `advertisedDefinitions` to hide tools from the model while keeping them dispatchable for in-flight calls.

## Observing the tool loop

If you drive generation directly (BYO-UI), the events you switch on are:

| Event | Meaning |
|-------|---------|
| `.toolCall(ToolCall)` | The model emitted a complete tool call. |
| `.toolCallStart(callId:name:)` / `.toolCallArgumentsDelta(callId:textDelta:)` | Streaming assembly of a call (deltas merge into one `.toolCall`). |
| `.toolResult(ToolResult)` | A dispatched tool's outcome was recorded into the transcript. |
| `.toolProgress(ToolProgressEvent)` | Interim progress from a streaming executor. |
| `.toolIterationLimitExceeded(iterations:)` | The `maxToolIterations` cap was hit. |

The complete list is in [`Sources/ManifoldContract/GenerationEvent.swift`](../Sources/ManifoldContract/GenerationEvent.swift).

## Streaming tool results

Long-running tools (downloads, paginated fetches, multi-step queries) can report liveness without breaking the atomic-result contract. Override `executeStreaming(arguments:)` to yield `ToolExecutionEvent.progress(message:fraction:)` chunks, then exactly one `.completed(ToolResult)`:

```swift,no-build
struct BulkFetchTool: ToolExecutor {
    let definition: ToolDefinition

    func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
        // Non-streaming fallback: buffer everything, return one result.
        ToolResult(callId: "", content: try await fetchAll())
    }

    func executeStreaming(arguments: JSONSchemaValue) -> AsyncThrowingStream<ToolExecutionEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var buffer = ""
                    for page in 0..<pageCount {
                        try Task.checkCancellation()
                        buffer += try await fetchPage(page)
                        continuation.yield(.progress(
                            message: "Fetched page \(page + 1) of \(pageCount)",
                            fraction: Double(page + 1) / Double(pageCount)
                        ))
                    }
                    continuation.yield(.completed(ToolResult(callId: "", content: buffer)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

The terminal `ToolResult` is **atomic**: progress events are observational, and only the `.completed` value flows into the transcript. Partial work accumulated before a throw is discarded. The default `executeStreaming` implementation just wraps `execute(arguments:)` and yields one terminal event, so non-streaming executors get this for free. Executors must also cooperate with cancellation — check `Task.checkCancellation()` at yield points so a user stop tears the work down promptly.

## Error classification

Return a `ToolResult` with an explicit `errorKind` when a failure is meaningful to the model. The vocabulary (`ToolResult.ErrorKind`) is locked for 1.0: `invalidArguments`, `permissionDenied`, `notFound`, `timeout`, `rateLimited`, `cancelled`, `transient`, `permanent`, `unknownTool`. Throwing from an executor is the catch-all — the registry records it as `.permanent` (not retry-safe by design). Signal a retriable failure by returning `.transient` explicitly rather than throwing.

## Approving side-effecting tools

Pure-read tools auto-approve. A tool that writes a file, sends a message, or calls a paid API should set `requiresApproval` to `true`:

```swift,no-build
let sendTool = TypedToolExecutor<SendArgs, SendResult>(
    definition: ToolDefinition(name: "send_email", description: "Sends an email.", parameters: schema),
    requiresApproval: true
) { args in try await send(args) }
```

The orchestrator then consults a `ToolApprovalGate` before dispatching. The default is `AutoApproveGate` (dispatches everything). Supply your own conformer — e.g. one that presents a SwiftUI sheet and awaits the user's tap — via `InferenceService(toolRegistry:toolApprovalGate:)`. Returning `.denied(reason:)` synthesises a `ToolResult` with `.permissionDenied` and continues the stream so the model can acknowledge the refusal; it does not cancel generation.

## Sanitizing or blocking with a pre-tool-use hook

Distinct from approval, a `PreToolUseHook` runs synchronously before dispatch and can rewrite arguments or block the call. The closure shape is:

```swift,no-build
let hook: PreToolUseHook = { toolName, arguments, requestGroupID in
    if isDangerous(arguments) {
        return .block(reason: "blocked by policy")
    }
    return .proceed(arguments: sanitized(arguments))
}

let (_, stream) = try inference.enqueue(
    structuredMessages: history,
    config: config,
    preToolUseHook: hook
)
```

`.proceed(arguments:)` must preserve the same set of top-level JSON keys as the original (sanitize-only). `.block(reason:)` synthesises a `permissionDenied` result and lets the turn loop continue. Full-stack hosts wire this through the Runtime `HookRegistry` rather than passing the closure directly — see the [Hook System](../Sources/ManifoldRuntime/ManifoldRuntime.docc/Articles/HookSystem.md) DocC article.

## Bridging external tools

- **MCP** — connect to a Model Context Protocol server and register its tools into the same `ToolRegistry`. See [`Sources/ManifoldMCP/ManifoldMCP.docc/Articles/MCPGettingStarted.md`](../Sources/ManifoldMCP/ManifoldMCP.docc/Articles/MCPGettingStarted.md).
- **AppIntents** — expose an `AppIntent` as a tool with `AppIntentToolExecutor`. See [`docs/QUICKSTART-APPINTENTS.md`](QUICKSTART-APPINTENTS.md).

## Where to go next

- [`docs/QUICKSTART-BRING-YOUR-OWN-UI.md`](QUICKSTART-BRING-YOUR-OWN-UI.md) — drive generation and the tool loop yourself.
- [`Sources/ManifoldTools/README.md`](../Sources/ManifoldTools/README.md) — the `manifold-tools` CLI harness that exercises tool calling end-to-end on a real backend.
