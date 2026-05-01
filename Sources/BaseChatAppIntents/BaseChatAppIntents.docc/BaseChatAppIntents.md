# ``BaseChatAppIntents``

Bridge an `AppIntent` into BaseChatKit's tool-calling pipeline so an inference
backend can invoke it like any other registered tool.

## Overview

`BaseChatAppIntents` ships two public types: ``AppIntentToolExecutor``, which
wraps any `AppIntent` and exposes it through the `ToolExecutor` protocol in
`BaseChatInference`, and ``IntentEnumParameter``, the marker protocol your
parameter enums adopt so the schema builder can enumerate their cases. The
executor:

1. Walks the intent's `@Parameter` properties via reflection and synthesises a
   JSON-Schema document for ``ToolDefinition/parameters``.
2. Decodes the model's argument payload back into a fresh intent instance.
3. Calls `perform()` on the intent and surfaces the resulting `IntentResult`
   as a ``ToolResult``.

Authorisation failures surface with ``ToolResult/ErrorKind/permissionDenied``;
JSON-decode failures surface with ``ToolResult/ErrorKind/invalidArguments``;
all other thrown errors classify as ``ToolResult/ErrorKind/permanent``.

The module depends only on `BaseChatInference`, so apps that don't need
SwiftData persistence or the full chat UI can adopt it with no transitive
weight. AppIntents itself ships with the OS, so there is no third-party
dependency.

## Five-line wiring

Once your `AppIntent` adopts `Decodable`, registering it as a tool is a
five-line affair:

```swift
import BaseChatAppIntents
import BaseChatInference

let registry = ToolRegistry()
registry.register(AppIntentToolExecutor(AskBaseChatDemoIntent.self))
inferenceService.toolRegistry = registry
```

The model now sees `ask_base_chat_demo_intent` in its tool list and can
invoke it whenever the conversation calls for it.

`AppIntentToolExecutor` requires per-call approval by default. For explicitly
read-only intents, opt out deliberately:

```swift
registry.register(
    AppIntentToolExecutor(
        AskBaseChatDemoIntent.self,
        approvalPolicy: .readOnlyAutoApprove
    )
)
```

## Decodable boilerplate

AppIntents do not synthesise `Decodable` automatically because the
`@Parameter` property wrappers shadow the storage. A four-line conformance
keyed by the property names is enough:

```swift
struct AskBaseChatDemoIntent: AppIntent, Decodable {
    static let title: LocalizedStringResource = "Ask BaseChat Demo"
    @Parameter(title: "Prompt") var prompt: String

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        self.prompt = try c.decode(String.self, forKey: .prompt)
    }

    private enum CodingKeys: String, CodingKey { case prompt }

    func perform() async throws -> some IntentResult { .result() }
}
```

## Parameter-type coverage

| Swift type                       | JSON Schema                                  |
|----------------------------------|----------------------------------------------|
| `String`                         | `{ "type": "string" }`                       |
| `Int`, `Int32`, `Int64`          | `{ "type": "integer" }`                      |
| `Double`, `Float`, `CGFloat`     | `{ "type": "number" }`                       |
| `Bool`                           | `{ "type": "boolean" }`                      |
| `Date`                           | `{ "type": "string", "format": "date-time" }`|
| `URL`                            | `{ "type": "string", "format": "uri" }`      |
| Optional<T>                      | (recurses; field becomes non-required)       |
| `T: IntentEnumParameter`         | `{ "type": "string", "enum": [...] }`        |

Enums become first-class JSON-Schema enums when they conform to
``IntentEnumParameter`` — a thin marker over `CaseIterable & RawRepresentable`
whose `RawValue` is `String`. AppIntents already encourages this shape for
`AppEnum` types, so the conformance is usually zero work.

## Availability

``AppIntentToolExecutor`` is annotated `@available(iOS 26, macOS 26, *)`
because it ships alongside the on-device LLM-actuation features in the
current AppIntents revision. Apps with older minimum-deployment targets
should gate registration behind `if #available(iOS 26, macOS 26, *)`.

## Topics

### Bridging AppIntents to ToolExecutor

- ``AppIntentToolExecutor``
- ``IntentEnumParameter``
