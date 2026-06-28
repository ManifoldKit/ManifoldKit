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
//
// Doc-build gate (`BUILDING_DOCC`): `@_exported import` bakes every re-exported
// symbol into ManifoldKit's OWN symbol graph, so DocC renders all ~776 public
// symbols from these eight modules as flat auto-generated groups on the umbrella
// landing page — drowning the curated Topics. That is intended DocC behaviour
// (swift-docc #331), not a misconfiguration. During the docs build we pass
// `-DBUILDING_DOCC` and add `@_documentation(visibility: internal)` to each
// re-export: the imports stay `@_exported` (so ManifoldKit's own sources keep
// module-wide visibility of these types and compile unchanged, and consumers'
// `import ManifoldKit` still re-exports the full surface), but the attribute
// drops the re-exported symbols from ManifoldKit's symbol graph — so the
// umbrella page renders only its own curated entry points. Each module's full
// reference lives on its own page, published alongside via the combined-
// documentation build (see docs.yml).
//
// NOTE — do NOT downgrade these to plain `import` under the gate: `@_exported`
// makes a module visible module-wide, but a plain `import` is file-scoped, so
// ManifoldKit's other sources (which carry no import of their own — e.g.
// ManifoldBootstrap+GenerationToolSources.swift's use of `SessionToolSource`)
// would fail to compile. The attribute keeps `@_exported` and only changes doc
// visibility.
#if BUILDING_DOCC
@_documentation(visibility: internal) @_exported import ManifoldInference
@_documentation(visibility: internal) @_exported import ManifoldRuntime
@_documentation(visibility: internal) @_exported import ManifoldPersistenceSwiftData
@_documentation(visibility: internal) @_exported import ManifoldFoundation
@_documentation(visibility: internal) @_exported import ManifoldOllama
@_documentation(visibility: internal) @_exported import ManifoldCloudSaaS
@_documentation(visibility: internal) @_exported import ManifoldCloudCore
@_documentation(visibility: internal) @_exported import ManifoldUI
#else
@_exported import ManifoldInference
@_exported import ManifoldRuntime
@_exported import ManifoldPersistenceSwiftData
// The ManifoldBackends umbrella shim was retired in P7. Re-export the surviving
// backend families directly so `import ManifoldKit` still exposes the backend
// surface (FoundationBackend / OllamaBackend / cloud backends + the shared
// ManifoldCloudCore infrastructure, including DefaultWebSearchRuntime).
@_exported import ManifoldFoundation
@_exported import ManifoldOllama
@_exported import ManifoldCloudSaaS
@_exported import ManifoldCloudCore
@_exported import ManifoldUI
#endif
