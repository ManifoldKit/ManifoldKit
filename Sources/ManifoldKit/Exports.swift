// ManifoldKit umbrella — re-exports the 80%-case modules so app code can write
// `import ManifoldKit` instead of stitching together 4–6 module imports.
//
// What's covered: the runtime, persistence, backends, UI, and the inference
// surface they all consume. A typical SwiftUI chat host needs nothing else.
//
// What's NOT covered (import directly when you need them):
//   - `ManifoldUIModelManagement` — model browser/download/API editor UI.
//     Many apps don't ship the management surface; keeping it out of the
//     umbrella lets chat-only consumers compile without the 1,800+ LOC.
//   - `ManifoldMCP` — Model Context Protocol client (no trait since v0.48).
//   - `ManifoldVoice` — speech I/O composer.
//   - `ManifoldHuggingFace` — Hub browse/download (default-on under
//     `HuggingFace`, but exposed only via `ManifoldUIModelManagement` UI hooks).
//   - `ManifoldTools`, `ManifoldAppIntents`, `ManifoldServer`,
//     `ManifoldFuzz` — specialised opt-in modules.
//   - `ManifoldAnyLanguageModel` — the AnyLanguageModel provider bridge
//     (its own product since v0.48; the `AnyLanguageModel` trait is retired).
//
// `ManifoldInference` is re-exported explicitly because consumers who write a
// custom backend, register a factory, or read `BackendName` need its surface
// even though they can also reach it transitively through `ManifoldRuntime`.
@_exported import ManifoldInference
@_exported import ManifoldRuntime
@_exported import ManifoldPersistenceSwiftData
@_exported import ManifoldBackends
@_exported import ManifoldUI
