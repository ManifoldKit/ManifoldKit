# Migration: deprecated `@_exported` shims retired (P7)

**Audience:** consumer
**Status:** historical

**This is a breaking change.** The `ManifoldBackends` umbrella and the
`ManifoldCloud` re-export shim — both introduced as one-release deprecation
bridges during the v0.48 packaging split — have been removed. `import
ManifoldBackends` and `import ManifoldCloud` no longer compile.

The public module layout is now 1.0-clean: every backend family is its own
module, with no umbrella facades hiding the dependency graph.

## What changed

| Removed | Replacement |
|---------|-------------|
| `import ManifoldBackends` | Import the family modules directly (`ManifoldFoundation`, `ManifoldOllama`, `ManifoldCloudSaaS`, `ManifoldCloudCore`) — or just `import ManifoldKit`, whose umbrella re-exports all of them. |
| `import ManifoldCloud` | `import ManifoldCloudCore` (shared infrastructure) plus the provider family you need (`ManifoldOllama` and/or `ManifoldCloudSaaS`). |
| `CloudBackends` registrar | Use **both** `OllamaBackends` (`ManifoldOllama`) and `CloudSaaSBackends` (`ManifoldCloudSaaS`). |
| `FoundationBackends` registrar | Same type name, now in `ManifoldFoundation`. |
| `DefaultBackends` (`.register(with:)`, `.registrars`, `compiledBackends`, `canLoad(...)`, etc.) | Pass an explicit registrar list to `ManifoldKit.quickStart(backends:)`. The compiled-in default fold is exposed as `ManifoldKit.defaultBackendRegistrars`. For build-introspection, use `CompiledBackends.current` (`ManifoldHardware`). |

`DefaultWebSearchRuntime` (the `WebSearchRuntime` port conformance that backed
the web-search tool) now lives in **`ManifoldCloudCore`** instead of the retired
`ManifoldCloud` shim. If you imported it via `import ManifoldCloud`, switch to
`import ManifoldCloudCore`.

## How to migrate

### 1. Replace umbrella imports

```swift
// Before
import ManifoldBackends

// After — pick what you use, or lean on the ManifoldKit umbrella
import ManifoldFoundation
import ManifoldOllama
import ManifoldCloudSaaS
import ManifoldCloudCore
// …or simply:
import ManifoldKit
```

```swift
// Before
import ManifoldCloud

// After
import ManifoldCloudCore
import ManifoldCloudSaaS   // for Claude / OpenAI / LM Studio backends
import ManifoldOllama      // for the Ollama backend
```

### 2. Replace `DefaultBackends.register(...)` with explicit registrars

```swift
// Before
let service = InferenceService()
DefaultBackends.register(with: service)

// After
import ManifoldOllama
import ManifoldCloudSaaS
import ManifoldFoundation

let service = InferenceService()
OllamaBackends.register(with: service)
CloudSaaSBackends.register(with: service)
FoundationBackends.register(with: service)
```

### 3. `quickStart` — nothing to do for the common path

`ManifoldKit.quickStart()` still folds the same compiled-in default families
(Ollama + SaaS + Foundation) for you. The list is now public as
`ManifoldKit.defaultBackendRegistrars` if you need to inspect or replicate it.
Companion-package backends still come in via `quickStart(backends:)`:

```swift
import ManifoldKit
import ManifoldLlama   // from the manifold-llama companion package

let kit = try await ManifoldKit.quickStart(backends: [LlamaBackends.self])
```

### 4. Build-time backend introspection

```swift
// Before
let compiled = DefaultBackends.compiledBackends

// After
import ManifoldHardware
let compiled = CompiledBackends.current
```

## Why

The v0.48 packaging release split the monolithic `ManifoldBackends` target into
per-family products so consumers can link exactly the providers they ship. The
umbrella module and the `ManifoldCloud` shim were kept for one release as
source-compatibility bridges. Carrying re-export facades into 1.0 would hide the
real module graph and re-introduce the "import one thing, link everything"
coupling the split removed — so they are retired here.
