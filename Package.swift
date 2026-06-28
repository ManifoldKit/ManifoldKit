// swift-tools-version: 6.1

// Trait reference (full table in README §2.4):
//   - There are NO default traits. `swift build` builds the full core surface.
//   - Opt-in traits: Server, Macros (genuine build-cost levers on leaf edges)
//     plus the two WWDC 2026 stubs (SystemAIProviderExtension, CoreAI).
//   - Retired in v0.48: MCP, MCPBuiltinCatalog (PR A2); Voice, Tools,
//     AppIntents, Skills (PR A3); Ollama, CloudSaaS (PR A4); AnyLanguageModel
//     (PR A5 — now the always-compiled ManifoldAnyLanguageModel product);
//     MLX, Llama, HuggingFace, Fuzz, FoundationOnly (PR C2 — the MLX and
//     llama.cpp backend families moved to the manifold-mlx / manifold-llama
//     companion packages, #1749). See docs/MIGRATION-0.48.md.
//   - Local inference (MLX / GGUF) now lives in companion packages:
//       https://github.com/roryford/manifold-mlx
//       https://github.com/roryford/manifold-llama
//     Add one as a `.package` dependency and pass its registrar to
//     `ManifoldKit.quickStart(backends:)`.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "ManifoldKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        // Umbrella product. Re-exports ManifoldInference + ManifoldRuntime +
        // ManifoldPersistenceSwiftData + the backend families (Foundation,
        // Ollama, CloudSaaS, CloudCore) + ManifoldUI so a
        // typical app can `import ManifoldKit` and skip the 4–6 import dance.
        // Specialised modules (MCP, Voice, ModelManagement, AppIntents, …) stay
        // explicit imports because not every host wants them in the build graph.
        .library(name: "ManifoldKit", targets: ["ManifoldKit"]),
        .library(name: "ManifoldInference", targets: ["ManifoldInference"]),
        // ManifoldContract: the thin "Contract kernel" reached by extracting
        // the backend-facing surface *downward* out of ManifoldInference in
        // P2a (#1719). Holds the protocols + value/stream types every family
        // backend compiles against (InferenceBackend, GenerationConfig,
        // GenerationEvent, Message, the streaming transforms, …). Depends only
        // on the P1 leaf modules (ManifoldHardware, ManifoldModelCatalog) — no
        // engine state (InferenceService/GenerationQueue/ToolRegistry stay in
        // ManifoldInference). `@_exported import ManifoldContract` in
        // ManifoldInference preserves source compatibility for all existing
        // `import ManifoldInference` consumers.
        .library(name: "ManifoldContract", targets: ["ManifoldContract"]),
        // Leaf networking primitives evicted from the ManifoldInference kernel
        // in P1a (#1608): NetworkActivity observability funnel + PrivateIP
        // classifier. Pure Foundation, zero upward dependencies.
        .library(name: "ManifoldNetworking", targets: ["ManifoldNetworking"]),
        // Leaf security primitives evicted from the ManifoldInference kernel
        // in P1b (#1609): KeychainService, SecureEnclaveKeyManager, SecureBytes.
        // Pure Security framework, zero upward dependencies.
        .library(name: "ManifoldSecrets", targets: ["ManifoldSecrets"]),
        // Leaf device-capability + GGUF primitives evicted from the
        // ManifoldInference kernel in P1c (#1610): device probing, memory-pressure
        // broadcasting, GGUF parsing, and load-plan logic.
        // Zero dependencies — pure system frameworks.
        .library(name: "ManifoldHardware", targets: ["ManifoldHardware"]),
        // Model discovery/catalog/benchmark + image/video-gen records evicted
        // from the ManifoldInference kernel in P1d (#1611): ModelInfo,
        // ModelManifest, ModelCatalog, ModelStorageService, DiagnosticsService,
        // SettingsService, ModelBenchmarkRunner, and all image/video-gen types.
        // Depends on ManifoldHardware (for ModelLoadPlan, GGUF, capability types)
        // and the leaf security/networking primitives.
        .library(name: "ManifoldModelCatalog", targets: ["ManifoldModelCatalog"]),
        .library(name: "ManifoldMCP", targets: ["ManifoldMCP"]),
        .library(name: "ManifoldMCPHost", targets: ["ManifoldMCPHost"]),
        .library(name: "ManifoldRuntime", targets: ["ManifoldRuntime"]),
        .library(name: "ManifoldPersistenceSwiftData", targets: ["ManifoldPersistenceSwiftData"]),
        // The `ManifoldBackends` umbrella product and the `ManifoldCloud`
        // re-export shim were retired in P7 (the 1.0 clean-up). Consumers
        // import the family products directly (ManifoldCloudCore /
        // ManifoldOllama / ManifoldCloudSaaS / ManifoldFoundation) or
        // `import ManifoldKit`. See docs/MIGRATION-shims-retired.md.
        .library(name: "ManifoldCloudCore", targets: ["ManifoldCloudCore"]),
        // ManifoldMLX / ManifoldLlama products removed in v0.48 (PR C2):
        // the families live in the manifold-mlx / manifold-llama companion
        // packages now (#1749). See docs/MIGRATION-0.48.md.
        .library(name: "ManifoldFoundation", targets: ["ManifoldFoundation"]),
        // v0.48 product split (PR A1): the Ollama and SaaS backend families
        // are real products so consumers can take exactly one provider
        // family without traits.
        .library(name: "ManifoldOllama", targets: ["ManifoldOllama"]),
        .library(name: "ManifoldCloudSaaS", targets: ["ManifoldCloudSaaS"]),
        // v0.48 (PR A5): the AnyLanguageModel bridge graduated from the
        // retired `AnyLanguageModel` trait to a standalone product. The
        // external AnyLanguageModel package was always resolved (traits gate
        // compilation, not resolution), so making the edge unconditional
        // costs consumers nothing; opting in is now an `import
        // ManifoldAnyLanguageModel` instead of a trait flag.
        .library(name: "ManifoldAnyLanguageModel", targets: ["ManifoldAnyLanguageModel"]),
        .library(name: "ManifoldUI", targets: ["ManifoldUI"]),
        .library(name: "ManifoldUIModelManagement", targets: ["ManifoldUIModelManagement"]),
        .library(name: "ManifoldHuggingFace", targets: ["ManifoldHuggingFace"]),
        .library(name: "ManifoldVoice", targets: ["ManifoldVoice"]),
        .library(name: "ManifoldFuzz", targets: ["ManifoldFuzz"]),
        // Test-support products: published so companion backend packages
        // (manifold-mlx / manifold-llama, #1749) can run the same mocks and
        // contract checks out-of-package. ManifoldBackendTestKit links XCTest
        // and must stay a SEPARATE product from ManifoldTestSupport — see the
        // ManifoldContractTestSupport target comment (#1409 dyld lesson).
        .library(name: "ManifoldTestSupport", targets: ["ManifoldTestSupport"]),
        .library(name: "ManifoldBackendTestKit", targets: ["ManifoldBackendTestKit"]),
        .executable(name: "fuzz-chat", targets: ["fuzz-chat"]),
        .library(name: "ManifoldTools", targets: ["ManifoldTools"]),
        .executable(name: "manifold-tools", targets: ["manifold-tools"]),
        .library(name: "ManifoldAppIntents", targets: ["ManifoldAppIntents"]),
        .library(name: "ManifoldSkills", targets: ["ManifoldSkills"]),
        .executable(name: "ManifoldServer", targets: ["ManifoldServer"]),
        // Optional OTLP/HTTP exporter — not re-exported by the ManifoldKit
        // umbrella. Import explicitly: `import ManifoldTelemetryOTLP`.
        .library(name: "ManifoldTelemetryOTLP", targets: ["ManifoldTelemetryOTLP"]),
    ],
    traits: [
        // No default traits since v0.48 (PR C2): the heavy MLX / llama.cpp
        // families moved to companion packages, so a plain `swift build` is
        // already the lean shape. Server and Macros remain genuine opt-in
        // build-cost levers on leaf edges (Hummingbird, swift-syntax).
        .trait(name: "Server", description: "Enable ManifoldServer (OpenAI-compatible HTTP server) and its Hummingbird dependency."),
        .trait(name: "Macros", description: "Enable the @ToolSchema macro plugin and its swift-syntax dependency. Off by default — pulls ~647 source files into the build graph."),
        // WWDC 2026 pre-emptive stubs. No associated targets or source files —
        // these traits exist solely so `#if SystemAIProviderExtension` and
        // `#if CoreAI` conditional blocks can be written today and flip live on
        // June 8 without a Package.swift change. See docs/wwdc-2026-trait-stubs.md.
        .trait(name: "SystemAIProviderExtension", description: "Stubs for the iOS 27 system AI provider extension surface (Siri/Writing Tools backend slot). No-op until WWDC 2026 ships the API."),
        .trait(name: "CoreAI", description: "Placeholder for Apple's rumoured Core AI framework (Core ML successor). No-op until WWDC 2026 confirms the surface."),
    ],
    dependencies: [
        // mlx-swift / mlx-swift-lm / mattt/llama.swift / swift-transformers /
        // swift-log left with the backend families in v0.48 (PR C2) — they now
        // live in the manifold-mlx / manifold-llama companion packages (#1749).
        // Pin 0.9.0 exactly: this is the verified tag that still exports the
        // `HuggingFace` product consumed by ManifoldHuggingFace and its tests.
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0"),
        // swift-jinja: renders a GGUF model's *real* embedded Jinja chat template
        // (`tokenizer.chat_template`) rather than approximating it with the
        // hand-rolled `PromptTemplate` enum (#1811). Consumed by ManifoldInference's
        // JinjaPromptRenderer at the existing prompt-assembly site, where the raw
        // template (ModelInfo.chatTemplateRaw) and the message history already meet —
        // local backends (manifold-mlx / manifold-llama) only ever receive the
        // finished prompt string, so the renderer must live core-side, not in the
        // companions. The package's only transitive dep is swift-collections
        // (OrderedCollections); tools-version 6.0 / macOS 13 / iOS 16 all sit below
        // this package's floor. Pin to the 2.x line to track swift-transformers 1.x.
        .package(url: "https://github.com/huggingface/swift-jinja.git", from: "2.0.0"),
        .package(url: "https://github.com/huggingface/AnyLanguageModel", from: "0.8.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
        // Test-only: SwiftUI view-tree inspection for accessibility contract tests.
        // Must never appear in any production target.
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.3"),
        // swift-syntax for the @ToolSchema macro plugin. Pinned to 600.0.x to
        // match the version mlx-swift-lm pulls in transitively — a wider range
        // would produce a duplicate-dependency resolution conflict. 600.x ships
        // ABI-compatible macro APIs for Swift 5.10 / 6.0 and builds fine on
        // Swift 6.1+. Do not bump beyond what the installed toolchain supports.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"601.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        // swift-http-types: HTTPFields, HTTPField, HTTPResponse.Status types used directly
        // in ManifoldServer (ServerApp.swift). Hummingbird 2.x depends on it transitively
        // but does not @_exported import it, so an explicit edge is required.
        // Only linked when the `Server` trait is enabled.
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        // DocC build/host plugin: drives `swift package generate-documentation` for the
        // unified ManifoldKit.docc front door and the GitHub Pages publish workflow.
        // Build-time only (a command plugin); never linked into any product, so it adds
        // no runtime weight and is safe under any trait combination. `from: "1.4.0"`
        // resolves to the latest 1.x (currently 1.5.0); the plugin's own
        // swift-tools-version sits below this package's 6.1 ceiling.
        .package(url: "https://github.com/apple/swift-docc-plugin.git", from: "1.4.0"),
    ],
    targets: [
        // Macro compiler plugin: implements @ToolSchema. Runs at build time in
        // the compiler's plugin host, not in app binaries. Only target that
        // pulls swift-syntax into the graph — gated behind the `Macros` trait
        // (off by default) so the ~647-file swift-syntax tree stays out of
        // default builds. Consumers using `@ToolSchema` must add `--traits Macros`.
        .macro(
            name: "ManifoldMacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax", condition: .when(traits: ["Macros"])),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax", condition: .when(traits: ["Macros"])),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax", condition: .when(traits: ["Macros"])),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax", condition: .when(traits: ["Macros"])),
                .product(name: "SwiftDiagnostics", package: "swift-syntax", condition: .when(traits: ["Macros"])),
            ],
            path: "Sources/ManifoldMacrosPlugin",
            swiftSettings: [
                .define("Macros", .when(traits: ["Macros"])),
            ]
        ),
        // Inference: models, protocols, services — no SwiftData, no heavy ML
        // deps, no persistence ports. The persistence-port protocols
        // (MessageStore, SessionStore, ChatPersistenceError, MessageSearchHit,
        // and the post-write hooks) live in ManifoldRuntime alongside the
        // ConversationRuntime use case that consumes them. The records they
        // traffic in (ChatMessageRecord, ChatSessionRecord, MessagePart,
        // MessageRole) stay here because inference services (PromptAssembler,
        // ContextWindowManager, TranscriptHealer) also consume them and the
        // dep DAG points ManifoldRuntime → ManifoldInference, not the other way.
        // Hosts the @ToolSchema attribute declaration so callers get the macro
        // for free wherever JSONSchemaValue is in scope. The macro plugin and
        // its swift-syntax dependency are trait-gated (`Macros`, off by
        // default); the `Sources/ManifoldInference/Macros/ToolSchema.swift`
        // declaration is wrapped in `#if Macros` so the public API is only
        // visible when the trait is enabled.
        // ManifoldNetworking: leaf-level networking/transport primitives that
        // carry no Contract dependency — the NetworkActivity observability
        // funnel (consumed by HuggingFace downloads and any host UI) and the
        // PrivateIPClassifier (consumed by the SSRF/DNS-rebind guards in
        // ManifoldCloudCore + ManifoldMCP). Extracted from ManifoldInference in
        // P1a (#1608) to thin the kernel. Zero dependencies — pure Foundation —
        // so it can never leak ML/SwiftData/UI symbols (foundation-only gate).
        .target(
            name: "ManifoldNetworking",
            dependencies: [],
            path: "Sources/ManifoldNetworking"
        ),
        // ManifoldSecrets: leaf security primitives (KeychainService,
        // SecureEnclaveKeyManager, SecureBytes) extracted from the
        // ManifoldInference kernel in P1b (#1609). Zero dependencies — pure
        // Security framework — so it can never leak ML/SwiftData/UI symbols.
        .target(
            name: "ManifoldSecrets",
            dependencies: [],
            path: "Sources/ManifoldSecrets"
        ),
        // ManifoldHardware: device-capability probing, memory-pressure
        // broadcasting, GGUF parsing, and load-plan logic extracted from the
        // ManifoldInference kernel in P1c (#1610). Zero dependencies — pure
        // system frameworks (Foundation, MachO, CryptoKit, Observation) — so it
        // can never leak ML/SwiftData/UI symbols.
        .target(
            name: "ManifoldHardware",
            dependencies: [],
            path: "Sources/ManifoldHardware"
        ),
        // ManifoldModelCatalog: model discovery/catalog/benchmark + image/video-gen
        // records extracted from the ManifoldInference kernel in P1d (#1611).
        // Depends on ManifoldHardware for load-plan, GGUF, and capability types;
        // on ManifoldNetworking + ManifoldSecrets for ManifoldConfiguration wiring.
        // `@_exported import ManifoldModelCatalog` in ManifoldInference preserves
        // source compatibility for all existing `import ManifoldInference` call sites.
        .target(
            name: "ManifoldModelCatalog",
            dependencies: [
                .target(name: "ManifoldHardware"),
                .target(name: "ManifoldNetworking"),
                .target(name: "ManifoldSecrets"),
            ],
            path: "Sources/ManifoldModelCatalog"
        ),
        // ManifoldContract: the thin Contract kernel. Backend protocols +
        // value/stream types extracted downward from ManifoldInference in P2a
        // (#1719) so the family backends (and any future engine) compile
        // against a leaf surface that carries no engine state. Depends only on
        // the P1 leaf modules — ManifoldHardware (tool/JSON-schema value types,
        // BackendCapabilities, ModelLoadPlan, InferenceError) and
        // ManifoldModelCatalog (ModelManifest, CloudBackendError, image/video
        // payloads, SSE stream limits), which it `@_exported import`s so its
        // own sources and its consumers resolve those leaf types unchanged.
        // It MUST NOT depend on ManifoldInference — `ManifoldContractNoEngineDependencyTests`
        // is the tripwire.
        .target(
            name: "ManifoldContract",
            dependencies: [
                "ManifoldHardware",
                "ManifoldModelCatalog",
            ],
            path: "Sources/ManifoldContract"
        ),
        .target(
            name: "ManifoldInference",
            dependencies: [
                "ManifoldContract",
                "ManifoldNetworking",
                "ManifoldSecrets",
                "ManifoldHardware",
                "ManifoldModelCatalog",
                // Real GGUF Jinja chat-template rendering (#1811). Library→library
                // edge: unconditional, matching the other always-linked deps.
                .product(name: "Jinja", package: "swift-jinja"),
                .target(name: "ManifoldMacrosPlugin", condition: .when(traits: ["Macros"])),
            ],
            path: "Sources/ManifoldInference",
            swiftSettings: [
                .define("Macros", .when(traits: ["Macros"])),
            ]
        ),
        // MCP: Model Context Protocol client surface, descriptors, transports,
        // OAuth, catalog presets, and tool bridge. It depends on Inference
        // directly and intentionally stays runtime-/SwiftData-free; the
        // runtime-backed server lives in ManifoldMCPHost below.
        .target(
            name: "ManifoldMCP",
            dependencies: ["ManifoldInference"],
            path: "Sources/ManifoldMCP"
        ),
        // ManifoldMCPHost: runtime-backed MCP server boundary. Exposes
        // sessions, messages, RAG documents, and send-message tools to external
        // MCP clients using ManifoldRuntime ports. Kept separate so client-only
        // apps can depend on ManifoldMCP without pulling runtime host surface.
        .target(
            name: "ManifoldMCPHost",
            dependencies: ["ManifoldMCP", "ManifoldRuntime"],
            path: "Sources/ManifoldMCPHost"
        ),
        // Runtime: ports (MessageStore, SessionStore, EndpointStore,
        // SamplerPresetStore, BenchmarkCache), use cases (PromptContextPipeline,
        // ChatExportService, SessionListService, ConversationRuntime), and
        // session-list orchestration. No SwiftData, no SwiftUI, no Observation.
        // MessageStore and SessionStore moved here from ManifoldInference in
        // initiative I4 so persistence ports live alongside the use cases that
        // consume them.
        .target(
            name: "ManifoldRuntime",
            dependencies: [
                .target(name: "ManifoldInference"),
            ],
            path: "Sources/ManifoldRuntime"
        ),
        // ManifoldSkills: Claude-Code-compatible SKILL.md filesystem discovery
        // and `invoke_skill` dispatcher. Library target is unconditional
        // (the body is platform-gated with `#if os(macOS)`). The Skills trait
        // was retired in v0.48 (PR A3) — the umbrella re-export and test edges
        // are unconditional now.
        .target(
            name: "ManifoldSkills",
            dependencies: [
                "ManifoldInference",
                "ManifoldRuntime",
            ],
            path: "Sources/ManifoldSkills"
        ),
        // PersistenceSwiftData: SwiftData schema (@Model types), container factory,
        // SwiftData adapter implementations, and the full-stack bootstrap class.
        .target(
            name: "ManifoldPersistenceSwiftData",
            dependencies: [
                .target(name: "ManifoldRuntime"),
                .target(name: "ManifoldInference"),
            ],
            path: "Sources/ManifoldPersistenceSwiftData"
        ),
        // ─────────────────────────────────────────────────────────────────
        // Backends.
        //
        // Since v0.48 (PR C2) the heavy local-inference families live in
        // companion packages: ManifoldMLX (+ vendored FluxSwift /
        // StableDiffusion) at https://github.com/roryford/manifold-mlx and
        // ManifoldLlama at https://github.com/roryford/manifold-llama
        // (#1749). Core retains Foundation + the cloud families (Ollama,
        // SaaS). Consumers that don't want SaaS code in a shipped binary
        // depend on the specific products they need instead of the umbrella
        // (link-out, not compile-out; docs/FIPS.md).
        //
        // The legacy `ManifoldBackends` umbrella and the `ManifoldCloud`
        // re-export shim were retired in P7 — there is no umbrella target any
        // more; consumers depend on the family products directly (or the
        // `ManifoldKit` umbrella, which re-exports them).
        // ─────────────────────────────────────────────────────────────────

        // ManifoldCloudCore: shared SSE / TLS-pinning / DNS-rebind / URLSession
        // infrastructure, plus the provider-agnostic encoding/parsing surface
        // (`CloudMessageEncoder`, `CloudPayloadHandler`, the OpenAI-compatible
        // Chat Completions parsing) shared by `ManifoldOllama` and
        // `ManifoldCloudSaaS`. Always linked; compiles unconditionally since
        // the v0.48 product split removed its `#if Ollama / CloudSaaS` gates.
        .target(
            name: "ManifoldCloudCore",
            dependencies: [
                "ManifoldInference",
                // DefaultWebSearchRuntime (relocated here in P7 when the
                // ManifoldCloud shim was retired) conforms to the
                // WebSearchRuntime port declared in ManifoldRuntime. This is a
                // library→library edge (not a consumer→family edge) so it stays
                // un-gated per the trait-gating rule. ManifoldRuntime is
                // SwiftData-free and does NOT depend on ManifoldCloudCore, so
                // the edge is acyclic and does not drag SwiftData into the
                // cloud infrastructure layer.
                "ManifoldRuntime",
            ],
            path: "Sources/ManifoldCloudCore"
        ),

        // ManifoldFoundation: Apple Foundation Models bridge. No trait —
        // gated by OS availability via `#if canImport(FoundationModels)` and
        // `@available(iOS 26, macOS 26, *)`.
        // The Foundation Models bridge (`FoundationBackend`) compiles against
        // the Contract surface only (InferenceBackend, GenerationConfig,
        // GenerationEvent, …). The `FoundationBackends` registrar — relocated
        // here in P7 when the ManifoldBackends umbrella was retired — needs the
        // engine's `InferenceService`/`BackendRegistrar`, so this target also
        // links ManifoldInference. (The FoundationOnly trait that motivated the
        // thinned Contract-only edge was retired in v0.48 PR C2.)
        .target(
            name: "ManifoldFoundation",
            dependencies: ["ManifoldContract", "ManifoldInference"],
            path: "Sources/ManifoldFoundation"
        ),

        // ManifoldOllama: the Ollama (self-hosted / LAN) backend family.
        // Compiles unconditionally; all consumer edges are unconditional too
        // since the Ollama trait retired (PR A4). Split out of ManifoldCloud
        // in the v0.48 packaging release (PR A1).
        .target(
            name: "ManifoldOllama",
            dependencies: [
                // Same P2a rationale as the former ManifoldCloud target
                // (#1719): backend bodies compile against the Contract
                // surface; ManifoldCloudCore transitively links
                // ManifoldInference for the registrar.
                "ManifoldContract",
                "ManifoldCloudCore",
            ],
            path: "Sources/ManifoldOllama"
        ),

        // ManifoldCloudSaaS: the SaaS backend family (Anthropic Claude,
        // OpenAI Chat Completions, OpenAI Responses, LM Studio / custom
        // OpenAI-compatible endpoints). Compiles unconditionally; all
        // consumer edges are unconditional too since the CloudSaaS trait
        // retired (PR A4). Split out of ManifoldCloud in the v0.48
        // packaging release (PR A1).
        .target(
            name: "ManifoldCloudSaaS",
            dependencies: [
                "ManifoldContract",
                "ManifoldCloudCore",
            ],
            path: "Sources/ManifoldCloudSaaS"
        ),

        // ManifoldCloud + ManifoldBackends re-export shims removed in P7
        // (the 1.0 clean-up): `import ManifoldCloud` / `import ManifoldBackends`
        // no longer compile. Import the family modules directly
        // (`ManifoldCloudCore`, `ManifoldOllama`, `ManifoldCloudSaaS`,
        // `ManifoldFoundation`) or `import ManifoldKit` for the umbrella.
        // `DefaultWebSearchRuntime` moved into `ManifoldCloudCore`;
        // `FoundationBackends` into `ManifoldFoundation`;
        // `CloudBackends`/`DefaultBackends` were dropped in favour of explicit
        // registrar lists (`OllamaBackends` + `CloudSaaSBackends` +
        // `FoundationBackends`). See docs/MIGRATION-shims-retired.md.

        // AnyLanguageModel provider bridge (v0.48, PR A5 — formerly gated by
        // the retired `AnyLanguageModel` trait inside the umbrella target).
        // The dependency on the external AnyLanguageModel package is
        // deliberately UNCONDITIONAL: the package was always resolved even
        // when the trait was off, and the compiled library is lightweight.
        // Consumers opt in by linking/importing this product; nothing else
        // in the package depends on it, so a consumer that never imports it
        // never links it. See docs/PROVIDER-BRIDGE.md.
        .target(
            name: "ManifoldAnyLanguageModel",
            dependencies: [
                "ManifoldInference",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
            ],
            path: "Sources/ManifoldAnyLanguageModel"
        ),
        // UI: SwiftUI views and view models — depends on runtime ports, not persistence adapters.
        .target(
            name: "ManifoldUI",
            dependencies: [
                "ManifoldRuntime",
                "ManifoldInference",
            ],
            path: "Sources/ManifoldUI"
        ),
        // Model management UI: download/storage browser, API endpoint editors,
        // remote-server configuration. Peeled out of ManifoldUI in v2.0 so a
        // chat-only host can ship without ~1,800 LOC of management surface.
        // Depends on ManifoldUI (the moved views consume `ChatViewModel` via
        // `@Environment`); ManifoldUI MUST NOT depend on this target — that
        // would close the dep cycle. The CI lint in `.github/workflows/ci.yml`
        // enforces this.
        .target(
            name: "ManifoldUIModelManagement",
            dependencies: [
                "ManifoldUI",
                "ManifoldRuntime",
                "ManifoldInference",
                "ManifoldHuggingFace",
            ],
            path: "Sources/ManifoldUIModelManagement"
        ),
        // ManifoldHuggingFace: the swift-huggingface edge is unconditional
        // since v0.48 (PR C2) — the HuggingFace trait is retired, and the
        // conditional `.product` edge was the canonical #1737 SwiftPM hazard.
        .target(
            name: "ManifoldHuggingFace",
            dependencies: [
                "ManifoldInference",
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "Sources/ManifoldHuggingFace"
        ),
        // ManifoldKit: umbrella library. Single-file `Exports.swift`
        // re-exports the most-imported modules so app code can write
        // `import ManifoldKit` and reach `ChatView`, `ChatViewModel`,
        // `ManifoldBootstrap`, the backend families, and the public Inference
        // surface from one import. Specialised modules stay opt-in (see
        // `Exports.swift` for the rationale).
        .target(
            name: "ManifoldKit",
            dependencies: [
                "ManifoldInference",
                // ManifoldModelCatalog edge removed: no source file in Sources/ManifoldKit/
                // imports it directly. ManifoldInference already @_exported imports
                // ManifoldModelCatalog (see ManifoldModelCatalogExport.swift), so umbrella
                // consumers reach ModelInfo, ModelRegistry, etc. transitively.
                "ManifoldRuntime",
                "ManifoldPersistenceSwiftData",
                // The ManifoldBackends umbrella was retired in P7; the umbrella
                // re-exports the surviving backend families directly so
                // `import ManifoldKit` still exposes the backend surface.
                "ManifoldFoundation",
                "ManifoldOllama",
                "ManifoldCloudSaaS",
                "ManifoldCloudCore",
                "ManifoldUI",
                "ManifoldSkills",
                // Seed-model path: `quickStart(seed:)` drives a background download on
                // first launch when no model is available. The concrete
                // BackgroundDownloadManager + HuggingFaceService live in
                // ManifoldHuggingFace (unconditional since the HuggingFace
                // trait retired in v0.48, PR C2).
                "ManifoldHuggingFace",
            ],
            path: "Sources/ManifoldKit"
        ),
        // Voice: optional speech-recognition / synthesis adapters plus chat UI accessories.
        .target(
            name: "ManifoldVoice",
            dependencies: ["ManifoldUI"],
            path: "Sources/ManifoldVoice"
        ),
        // Shared test mocks and utilities
        .target(
            name: "ManifoldTestSupport",
            dependencies: [
                "ManifoldRuntime",
                "ManifoldPersistenceSwiftData",
                "ManifoldInference",
            ],
            path: "Sources/ManifoldTestSupport",
            exclude: ["FuzzCalibrationCorpus"],
            resources: [
                // Sample Markdown corpus the Glass Box research-session demo
                // ingests into the real RAG stack (#1575). Bundled so the live
                // integration test can resolve them via Bundle.module.
                .copy("Fixtures/Documents")
            ]
        ),
        // XCTest-dependent protocol contract mixins, kept in a separate target
        // so that fuzz-chat (an executable) can depend on ManifoldTestSupport
        // without pulling in XCTest, which is only available inside an xctest
        // host process and causes a dyld crash at runtime otherwise.
        //
        // DO NOT merge this back into ManifoldTestSupport. PR #1409 attempted
        // that with a `#if canImport(XCTest)` file-level gate; the gate
        // evaluated true on CI runners where the XCTest *headers* are
        // available but the *runtime* dylib is not on the search path outside
        // an xctest host. Result: `dyld[...]: Library not loaded:
        // @rpath/libXCTestSwiftSupport.dylib` at fuzz-chat startup.
        // `ContractTestSupportSplitAuditTest` (ManifoldCoreTests) enforces
        // this split at the manifest + source-tree level.
        .target(
            name: "ManifoldContractTestSupport",
            dependencies: [
                "ManifoldTestSupport",
                "ManifoldInference",
                "ManifoldRuntime",
            ],
            path: "Sources/ManifoldContractTestSupport"
        ),
        // Backend contract-check kit, published as a product so companion
        // backend packages (manifold-mlx / manifold-llama, #1749) can run the
        // same capability-claim contract suite against core's published API.
        // Links XCTest — the same dyld constraint as ManifoldContractTestSupport
        // applies: never merge into ManifoldTestSupport and never depend on it
        // from an executable target (#1409).
        .target(
            name: "ManifoldBackendTestKit",
            dependencies: [
                "ManifoldTestSupport",
                "ManifoldInference",
            ],
            path: "Sources/ManifoldBackendTestKit"
        ),
        .testTarget(
            name: "ManifoldCoreTests",
            dependencies: [
                "ManifoldRuntime",
                "ManifoldPersistenceSwiftData",
                "ManifoldInference",
                "ManifoldTestSupport",
            ]
        ),
        // ManifoldRuntime-only tests: protocol contracts, value types, and
        // services that don't import SwiftData. Tests that exercise both
        // ManifoldRuntime and ManifoldPersistenceSwiftData (e.g. the
        // adapter-against-port integrations) stay in ManifoldCoreTests.
        .testTarget(
            name: "ManifoldRuntimeTests",
            dependencies: [
                "ManifoldRuntime",
                "ManifoldInference",
                "ManifoldTestSupport",
                "ManifoldContractTestSupport",
            ]
        ),
        .testTarget(
            name: "ManifoldSkillsTests",
            dependencies: [
                "ManifoldSkills",
                "ManifoldInference",
                "ManifoldRuntime",
                "ManifoldContractTestSupport",
            ]
        ),
        // ManifoldPersistenceSwiftData-only tests: SwiftData @Model schema,
        // ModelContainerFactory, ManifoldBootstrap, and the SwiftData adapter
        // implementations of the runtime ports.
        .testTarget(
            name: "ManifoldPersistenceSwiftDataTests",
            dependencies: [
                "ManifoldPersistenceSwiftData",
                "ManifoldRuntime",
                "ManifoldInference",
                "ManifoldTestSupport",
            ]
        ),
        // Tests for the shared test-helper module itself (e.g. `withTimeout`).
        // Kept as a dedicated target so hang-sabotage helpers don't accrete
        // inside product-suite test targets and so they can be exercised
        // with `swift test --filter ManifoldTestSupportTests`.
        .testTarget(
            name: "ManifoldTestSupportTests",
            dependencies: [
                "ManifoldTestSupport",
                "ManifoldInference",
                "ManifoldContractTestSupport",
                // ManifoldRuntime: ConversationEventSubsequenceTests.swift and
                // RuntimeScenarioRunnerTests.swift import it directly.
                "ManifoldRuntime",
                // Live RAG integration test (#1575) wires the real
                // FlatFileVectorStore + SwiftDataDocumentStore + in-memory
                // ModelContainer behind an Ollama-gated XCTSkipUnless.
                "ManifoldPersistenceSwiftData",
            ]
        ),
        .testTarget(
            name: "ManifoldInferenceTests",
            dependencies: [
                "ManifoldInference",
                // P2a (#1719): direct edge so SSEStreamParser/streaming-transform
                // suites can `@testable import ManifoldContract` for the
                // package-level test seams that moved down out of the engine.
                "ManifoldContract",
                "ManifoldTestSupport",
                .target(name: "ManifoldMacrosPlugin", condition: .when(traits: ["Macros"])),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax", condition: .when(traits: ["Macros"])),
            ],
            // SilentCatchAuditTest reads `silent_catch_allowlist.txt` directly
            // from its on-disk source location via `#filePath`, so we don't
            // need to bundle it into the test binary — just tell SwiftPM to
            // ignore it when collecting resources.
            exclude: ["silent_catch_allowlist.txt"],
            // Chat-template byte-match goldens (#1938): real embedded Jinja
            // templates + transformers-generated expected output, copied into
            // the test bundle so ChatTemplateGoldenTests can read them.
            resources: [.copy("Fixtures/ChatTemplates")],
            swiftSettings: [
                .define("Macros", .when(traits: ["Macros"])),
            ]
        ),
        // Swift Testing suites split from ManifoldInferenceTests to prevent a
        // libmalloc double-free SIGABRT that occurs when XCTest and Swift Testing
        // harnesses both initialise in the same process (~25% of CI runs).
        .testTarget(
            name: "ManifoldInferenceSwiftTestingTests",
            dependencies: ["ManifoldInference", "ManifoldTestSupport"]
        ),
        // Re-homed from ManifoldInferenceTests in P1a (#1608) alongside the
        // PrivateIPClassifier + NetworkActivity source. Depends on
        // ManifoldInference too because NetworkActivityCenterTests exercises the
        // URLSessionFactory/CompositeURLSessionDelegate wiring (which stays in
        // the kernel) and on ManifoldTestSupport for MockURLProtocol.
        .testTarget(
            name: "ManifoldNetworkingTests",
            dependencies: ["ManifoldNetworking", "ManifoldInference", "ManifoldTestSupport"]
        ),
        // Re-homed from ManifoldInferenceTests in P1b (#1609) alongside the
        // KeychainService, SecureEnclaveKeyManager, and SecureBytes source.
        // Depends on ManifoldInference too because KeychainServiceTests and
        // KeychainServiceSweepTests exercise ManifoldConfiguration wiring, and
        // on ManifoldTestSupport for MockSecureEnclaveKeyStore.
        .testTarget(
            name: "ManifoldSecretsTests",
            dependencies: ["ManifoldSecrets", "ManifoldInference", "ManifoldTestSupport"]
        ),
        // Re-homed from ManifoldInferenceTests in P1c (#1610) alongside the
        // device-capability, GGUF, memory-pressure, and load-plan source.
        // Depends on ManifoldInference too because MemoryPressureEventTests
        // exercises InferenceService wiring, and on ManifoldTestSupport for
        // MockInferenceBackend.
        .testTarget(
            name: "ManifoldHardwareTests",
            dependencies: ["ManifoldHardware", "ManifoldInference", "ManifoldTestSupport"]
        ),
        // Re-homed from ManifoldInferenceTests in P1d (#1611) alongside the
        // model-catalog, model-storage, model-discovery, and image/video-gen
        // source. Depends on ManifoldInference too because several tests
        // exercise InferenceService wiring, and on ManifoldTestSupport for
        // MockInferenceBackend and mock URL protocols.
        .testTarget(
            name: "ManifoldModelCatalogTests",
            dependencies: [
                "ManifoldModelCatalog",
                "ManifoldInference",
                "ManifoldTestSupport",
            ],
            path: "Tests/ManifoldModelCatalogTests"
        ),
        .testTarget(
            name: "ManifoldMCPTests",
            dependencies: [
                "ManifoldMCP",
                "ManifoldMCPHost",
                "ManifoldInference",
                "ManifoldRuntime",
                "ManifoldTestSupport",
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "ManifoldMCPE2ETests",
            dependencies: [
                "ManifoldMCP",
                "ManifoldInference",
                "ManifoldTestSupport",
            ]
        ),
        // Umbrella test target — covers the surviving family targets
        // (Foundation + Cloud). The MLX / Llama family test files moved to
        // the manifold-mlx / manifold-llama companion packages with the
        // backends (v0.48, PR C2, #1749).
        .testTarget(
            name: "ManifoldBackendsTests",
            dependencies: [
                // The ManifoldBackends / ManifoldCloud umbrella+shim targets
                // were retired in P7; the suites now import the family modules
                // directly. The test-target NAME is retained — CI and docs
                // reference it.
                "ManifoldCloudCore",
                "ManifoldFoundation",
                "ManifoldSecrets",
                "ManifoldHardware",
                // Direct edges for `@testable import ManifoldOllama` /
                // `@testable import ManifoldCloudSaaS`.
                "ManifoldOllama",
                "ManifoldCloudSaaS",
                "ManifoldUI",
                "ManifoldRuntime",
                "ManifoldPersistenceSwiftData",
                "ManifoldInference",
                "ManifoldTestSupport",
                "ManifoldBackendTestKit",
                // AnyLanguageModel bridge suites — unconditional since the
                // trait was retired in v0.48 (PR A5). The direct edge to the
                // external AnyLanguageModel package supplies the
                // LanguageModel protocol the test doubles conform to.
                "ManifoldAnyLanguageModel",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel"),
            ]
        ),
        .testTarget(
            name: "ManifoldUITests",
            dependencies: [
                "ManifoldUI",
                "ManifoldRuntime",
                "ManifoldPersistenceSwiftData",
                "ManifoldInference",
                "ManifoldTestSupport",
                .product(name: "ViewInspector", package: "ViewInspector"),
            ]
        ),
        .testTarget(
            name: "ManifoldVoiceTests",
            dependencies: [
                "ManifoldVoice",
                .product(name: "ViewInspector", package: "ViewInspector"),
            ]
        ),
        .testTarget(
            name: "ManifoldUIModelManagementTests",
            dependencies: [
                "ManifoldUIModelManagement",
                "ManifoldUI",
                "ManifoldRuntime",
                "ManifoldPersistenceSwiftData",
                "ManifoldInference",
                "ManifoldTestSupport",
            ]
        ),
        .testTarget(
            name: "ManifoldHuggingFaceTests",
            dependencies: [
                "ManifoldHuggingFace",
                "ManifoldInference",
                "ManifoldTestSupport",
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            path: "Tests/ManifoldHuggingFaceTests"
        ),
        // ManifoldServer: OpenAI-compatible HTTP server. Shipped as a single
        // executable target — the routing layer, trait-aware backend provider,
        // and `@main` entry point all live here. Trait-gated behind `Server`,
        // which also conditionally pulls in Hummingbird. Without the trait the
        // target compiles to a no-op stub that prints a "trait not enabled"
        // message (see `ManifoldServerCommand.swift`).
        //
        // ManifoldBackends and ManifoldInference are `Server`-conditional so
        // a trait-off build compiles the no-op stub without dragging the full
        // backend graph into the executable. (The historical #982
        // llama.framework copy-collision rationale died with the C2 split —
        // llama.framework no longer exists in this package's graph.)
        .executableTarget(
            name: "ManifoldServer",
            dependencies: [
                .target(name: "ManifoldInference", condition: .when(traits: ["Server"])),
                // ManifoldBackends umbrella retired in P7 — link the families
                // the server actually constructs (FoundationBackend / OllamaBackend).
                .target(name: "ManifoldFoundation", condition: .when(traits: ["Server"])),
                .target(name: "ManifoldOllama", condition: .when(traits: ["Server"])),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Hummingbird", package: "hummingbird", condition: .when(traits: ["Server"])),
                // HTTPTypes is used directly in ServerApp.swift (HTTPFields, HTTPField.Name,
                // HTTPResponse.Status). Hummingbird does not @_exported import it.
                .product(name: "HTTPTypes", package: "swift-http-types", condition: .when(traits: ["Server"])),
            ],
            path: "Sources/ManifoldServer",
            swiftSettings: [
                .define("Server", .when(traits: ["Server"])),
            ]
        ),
        .testTarget(
            name: "ManifoldServerTests",
            dependencies: [
                "ManifoldServer",
                "ManifoldInference",
                "ManifoldTestSupport",
                .product(name: "HummingbirdTesting", package: "hummingbird", condition: .when(traits: ["Server"])),
                // HTTPTypes is imported directly in EmbeddingsEndpointTests, ManifoldServerSmokeTests,
                // and SSECancellationTests — must be a direct dep for @testable import to resolve.
                .product(name: "HTTPTypes", package: "swift-http-types", condition: .when(traits: ["Server"])),
            ],
            swiftSettings: [
                .define("Server", .when(traits: ["Server"])),
            ]
        ),
        .testTarget(
            name: "ManifoldE2ETests",
            dependencies: [
                // ManifoldBackends umbrella retired in P7 — link the surviving
                // family modules directly.
                "ManifoldFoundation",
                "ManifoldOllama",
                "ManifoldCloudSaaS",
                "ManifoldCloudCore",
                "ManifoldUI",
                "ManifoldRuntime",
                "ManifoldPersistenceSwiftData",
                "ManifoldInference",
                "ManifoldTestSupport",
                // RuntimeScenarioRunner (live-mode Glass Box gate, #1576) lives here.
                "ManifoldContractTestSupport",
                "ManifoldTools",
                "ManifoldHuggingFace",
            ]
        ),
        .testTarget(
            name: "ManifoldSnapshotTests",
            dependencies: [
                "ManifoldUI",
                "ManifoldUIModelManagement",
                "ManifoldRuntime",
                "ManifoldPersistenceSwiftData",
                "ManifoldInference",
                "ManifoldTestSupport",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            exclude: ["__Snapshots__"]
        ),
        // Turn-loop golden-transcript harness — gates the P2 engine carve.
        // Snapshots the ConversationEvent stream + persisted records for every
        // ConversationRuntime verb (send/regenerate/edit/cancel/branch) plus
        // tool round-trip and tool-forwarded-no-registry cases. Runs in CI
        // (both the XCTest and local profiles) so any turn-loop behaviour
        // change surfaces as a snapshot diff before it lands. Will relocate
        // into ManifoldEngineTests when P2 creates that target; golden files
        // travel with the test.
        .testTarget(
            name: "ManifoldTurnLoopCharacterizationTests",
            dependencies: [
                "ManifoldRuntime",
                "ManifoldInference",
                "ManifoldPersistenceSwiftData",
                "ManifoldTestSupport",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            exclude: ["__Snapshots__"]
        ),
        // Fuzzing engine: corpus, runner, capture, detectors, sink. Backend-agnostic.
        // Carries no backend deps — backend selection
        // happens in `ManifoldFuzzBackends` (importable real-backend factories),
        // `fuzz-chat` (CLI), and `ManifoldFuzzTests` (XCTest harness).
        .target(
            name: "ManifoldFuzz",
            dependencies: ["ManifoldInference"],
            path: "Sources/ManifoldFuzz",
            resources: [.process("Resources")]
        ),
        // Importable real-backend factories for fuzz campaigns (Ollama,
        // OpenAI, Foundation). The MLX / Llama fuzz factories moved to the
        // companion packages with the backends (v0.48, PR C2). Unconditional
        // since the Fuzz trait retired in the same PR.
        .target(
            name: "ManifoldFuzzBackends",
            dependencies: [
                "ManifoldFuzz",
                "ManifoldInference",
                // ManifoldBackends umbrella retired in P7 — link the families
                // whose backends the fuzz factories construct.
                "ManifoldFoundation",
                "ManifoldOllama",
                "ManifoldCloudSaaS",
            ],
            path: "Sources/ManifoldFuzzBackends"
        ),
        // CLI driver. Wires Ollama, OpenAI, Foundation. Run via scripts/fuzz.sh.
        // (The Fuzz trait and the #982 llama.framework scheme-collision gate
        // died with the C2 split — all edges are unconditional now.)
        .executableTarget(
            name: "fuzz-chat",
            dependencies: [
                "ManifoldFuzz",
                "ManifoldInference",
                "ManifoldTestSupport",
                "ManifoldFuzzBackends",
            ],
            path: "Sources/fuzz-chat"
        ),
        .testTarget(
            name: "ManifoldFuzzTests",
            dependencies: [
                "ManifoldFuzz",
                "ManifoldFuzzBackends",
                // ManifoldBackends umbrella retired in P7.
                "ManifoldFoundation",
                "ManifoldOllama",
                "ManifoldCloudSaaS",
                "ManifoldInference",
                "ManifoldTestSupport",
            ]
        ),
        // ManifoldTools: end-to-end tool-calling validation harness.
        // Ships a fixed reference toolset (now, calc, read_file, list_dir,
        // http_get_fixture), a declarative scenario runner, and a JSONL
        // transcript logger. Library target so the test suite can exercise
        // the runner against in-process scripted backends; the CLI lives in
        // the `manifold-tools` executable target below.
        .target(
            name: "ManifoldTools",
            dependencies: [
                "ManifoldInference",
            ],
            path: "Sources/ManifoldTools",
            // BFCL/calibration holds the one-time, local-only canonical bfcl-eval
            // cross-check (Python) — never built or run by SwiftPM/CI.
            exclude: ["README.md", "BFCL/calibration"],
            resources: [
                .copy("Scenarios/built-in"),
                // BFCL argument-level scorer fixtures (simple-category slice).
                .copy("BFCL/fixtures"),
            ]
        ),
        // manifold-tools does NOT depend on the ManifoldBackends umbrella:
        // the CLI only drives Ollama (or the in-process mock), so it takes
        // the ManifoldOllama family product directly (unconditional since
        // the Ollama trait retired in PR A4).
        .executableTarget(
            name: "manifold-tools",
            dependencies: [
                "ManifoldTools",
                "ManifoldOllama",
                "ManifoldCloudSaaS",
                "ManifoldInference",
            ],
            path: "Sources/manifold-tools"
        ),

        // OTLP/HTTP trace exporter. Optional product — not re-exported by the
        // ManifoldKit umbrella. Consumers add it explicitly and pass an
        // OTLPTraceSink to the backend's traceSink property.
        .target(
            name: "ManifoldTelemetryOTLP",
            dependencies: ["ManifoldInference"],
            path: "Sources/ManifoldTelemetryOTLP"
        ),
        .testTarget(
            name: "ManifoldToolsTests",
            dependencies: [
                "ManifoldTools",
                "ManifoldInference",
                "ManifoldTestSupport",
            ],
            // Golden conformance transcripts (minimal real-run slices) consumed by
            // ConformanceScorer tests. Bundled so the test reads them via
            // Bundle.module rather than depending on cwd / source layout.
            resources: [.copy("Fixtures")]
        ),
        // ManifoldAppIntents: AppIntent ↔ ToolDefinition bridge.
        // Lets hosts expose any AppIntent as a model-callable tool by deriving
        // the JSON-Schema parameters from `@Parameter` reflection. Trait-free
        // and depends only on ManifoldInference so apps can opt in without
        // pulling AppIntents on platforms / module graphs that don't need it.
        .target(
            name: "ManifoldAppIntents",
            dependencies: ["ManifoldInference"],
            path: "Sources/ManifoldAppIntents"
        ),
        .testTarget(
            name: "ManifoldAppIntentsTests",
            dependencies: [
                "ManifoldAppIntents",
                "ManifoldInference",
            ]
        ),
        // T1.5: public-API surface freeze. The Fixture file consumes every
        // public BCK type and method we want to lock against accidental
        // signature change. CI fails if any consumed surface is removed,
        // renamed, or its signature drifts. The test method itself is a
        // single XCTAssertTrue(true) — compilation is the assertion.
        .testTarget(
            name: "APIFreezeTests",
            dependencies: [
                "ManifoldInference",
                "ManifoldRuntime",
                "ManifoldPersistenceSwiftData",
                "ManifoldTestSupport",
                // Backend-seam freeze (Fixtures/BackendSeamConsumer.swift,
                // #1749): the cross-repo surface the companion family
                // packages compile against spans the Contract kernel, the
                // Hardware seam types, and the @_spi(BackendInternals)
                // ChatViewModel initializer in ManifoldUI.
                "ManifoldContract",
                "ManifoldHardware",
                "ManifoldUI",
            ]
        ),
        // ManifoldKitTests: tests against the umbrella module's own public
        // surface. Hosts FeatureMatrixTests (trait→capability matrix audit),
        // QuickStartTests (quickStart() facade), and TraitCostsDriftTest
        // (asserts docs/TRAIT-COSTS.md generated regions match trait-costs.json).
        // Trait-free so it runs under --disable-default-traits.
        .testTarget(
            name: "ManifoldKitTests",
            dependencies: [
                "ManifoldKit",
                // Direct edges for imports used in QuickStartTests.swift.
                // ManifoldInference, ManifoldRuntime, and ManifoldPersistenceSwiftData
                // are re-exported by ManifoldKit transitively but @testable / explicit
                // imports still require a direct declared edge.
                "ManifoldInference",
                "ManifoldRuntime",
                "ManifoldPersistenceSwiftData",
                // MockDownloadManager lives in ManifoldTestSupport so seed tests
                // can drive the download path without real network activity.
                "ManifoldTestSupport",
            ]
        ),
        // Nightly sabotage suite: verifies every file-walking audit test
        // actually catches known violations (the "who watches the watchers"
        // guard). Run with `SABOTAGE=1 swift test --filter ManifoldAuditSabotageSuiteTests`.
        // Without SABOTAGE=1, all tests skip immediately via XCTSkip so they
        // don't inflate the per-PR build time.
        .testTarget(
            name: "ManifoldAuditSabotageSuiteTests",
            dependencies: [
                "ManifoldInference",
                "ManifoldTestSupport",
            ]
        ),
        .testTarget(
            name: "ManifoldTelemetryOTLPTests",
            dependencies: [
                "ManifoldTelemetryOTLP",
                "ManifoldInference",
                "ManifoldTestSupport",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
