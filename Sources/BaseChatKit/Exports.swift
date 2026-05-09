// BaseChatKit umbrella — re-exports the 80%-case modules so app code can write
// `import BaseChatKit` instead of stitching together 4–6 module imports.
//
// What's covered: the runtime, persistence, backends, UI, and the inference
// surface they all consume. A typical SwiftUI chat host needs nothing else.
//
// What's NOT covered (import directly when you need them):
//   - `BaseChatUIModelManagement` — model browser/download/API editor UI.
//     Many apps don't ship the management surface; keeping it out of the
//     umbrella lets chat-only consumers compile without the 1,800+ LOC.
//   - `BaseChatMCP` — Model Context Protocol client (trait `MCP`).
//   - `BaseChatVoice` — speech I/O composer (trait `Voice`).
//   - `BaseChatHuggingFace` — Hub browse/download (default-on under
//     `HuggingFace`, but exposed only via `BaseChatUIModelManagement` UI hooks).
//   - `BaseChatTools`, `BaseChatAppIntents`, `BaseChatAnyLanguageModelBridge`,
//     `BaseChatServer`, `BaseChatFuzz` — specialised opt-in modules.
//
// `BaseChatInference` is re-exported explicitly because consumers who write a
// custom backend, register a factory, or read `BackendName` need its surface
// even though they can also reach it transitively through `BaseChatRuntime`.
@_exported import BaseChatInference
@_exported import BaseChatRuntime
@_exported import BaseChatPersistenceSwiftData
@_exported import BaseChatBackends
@_exported import BaseChatUI
