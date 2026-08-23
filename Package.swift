// swift-tools-version: 6.1

// Trait reference (full table in README §2.4):
//   - There are NO default traits. `swift build` builds the full core surface.
//   - Opt-in traits: Server, Macros (genuine build-cost levers on leaf edges)
//     plus the two WWDC 2026 stubs (SystemAIProviderExtension, CoreAI).
//   - Retired in v0.48: MCP, MCPBuiltinCatalog (PR A2); Voice, Tools,
//     AppIntents, Skills (PR A3); Ollama, CloudSaaS (PR A4); AnyLanguageModel
//     (PR A5 — became the always-compiled ManifoldAnyLanguageModel product,
//     itself retired outright in #2435 for zero adoption; see
//     docs/MIGRATION-anylanguagemodel-retired.md);
//     MLX, Llama, HuggingFace, Fuzz, FoundationOnly (PR C2 — the MLX and
//     llama.cpp backend families moved to the manifold-mlx / manifold-llama
//     companion packages, #1749). See docs/MIGRATION-0.48.md.
//   - Local inference (MLX / GGUF) now lives in companion packages:
//       https://github.com/ManifoldKit/manifold-mlx
//       https://github.com/ManifoldKit/manifold-llama
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
        // ManifoldAnyLanguageModel product removed (#2435): zero adoption
        // plus dependency coupling to the pre-1.0 external AnyLanguageModel
        // package. See docs/MIGRATION-anylanguagemodel-retired.md.
        .library(name: "ManifoldUI", targets: ["ManifoldUI"]),
        .library(name: "ManifoldUIModelManagement", targets: ["ManifoldUIModelManagement"]),
        .library(name: "ManifoldHuggingFace", targets: ["ManifoldHuggingFace"]),
        .library(name: "ManifoldVoice", targets: ["ManifoldVoice"]),
        // ManifoldFuzz IS a published product: the companion backend packages
        // (manifold-mlx / manifold-llama, #1749) now run their own fuzz drivers
        // against real MLX/llama backends — the exact "external consumer" whose
        // prior absence justified keeping this a bare target. A companion cannot
        // `import ManifoldFuzz` cross-package without a product, and the local
        // backends can't run via core's `swift run fuzz-chat` (MLX needs an
        // Xcode-compiled metallib), so the driver has to live over there. This
        // re-widens the api-digester gate's product surface deliberately.
        // ManifoldFuzzBackends stays an internal target — a companion supplies
        // its own FuzzBackendFactory rather than pulling core's Ollama/OpenAI/
        // Foundation family deps.
        .library(name: "ManifoldFuzz", targets: ["ManifoldFuzz"]),
        // Test-support products: published so companion backend packages
        // (manifold-mlx / manifold-llama, #1749) can run the same mocks and
        // contract checks out-of-package. ManifoldBackendTestKit links XCTest
        // and must stay a SEPARATE product from ManifoldTestSupport — see the
        // ManifoldContractTestSupport target comment (#1409 dyld lesson).
        .library(name: "ManifoldTestSupport", targets: ["ManifoldTestSupport"]),
        // Persistence-dependent test mocks split out of ManifoldTestSupport
        // (arch-plan 4.4, #2158 wave2 P2): GlassBoxDemoRAG, InMemoryPersistenceHarness,
        // and makeInMemoryContainer() need SwiftData + ManifoldPersistenceSwiftData.
        // Mirrors the precedented TestSupport/ContractTestSupport split — kept
        // separate so pure-engine consumers (companion repos, leaf test suites)
        // stop linking the persistence stack to get one mock.
        .library(name: "ManifoldPersistenceTestSupport", targets: ["ManifoldPersistenceTestSupport"]),
        .library(name: "ManifoldBackendTestKit", targets: ["ManifoldBackendTestKit"]),
        .executable(name: "fuzz-chat", targets: ["fuzz-chat"]),
        .library(name: "ManifoldTools", targets: ["ManifoldTools"]),
        .executable(name: "manifold-tools", targets: ["manifold-tools"]),
        .library(name: "ManifoldAppIntents", targets: ["ManifoldAppIntents"]),
        // ManifoldSkills (SKILL.md filesystem discovery + invoke_skill dispatch)
        // retired 2026-08-06 (#2434, zero adopters). The AGENTS.md ambient-
        // instruction half survives as ManifoldAgentInstructions below — see
        // docs/MIGRATION-skills-removed.md.
        .library(name: "ManifoldAgentInstructions", targets: ["ManifoldAgentInstructions"]),
        // The `manifold-server` CLI binary. Product name stays `ManifoldServer`
        // (docs/QUICKSTART-SERVER.md and scripts/benchmark.sh both build
        // `--product ManifoldServer`) even though it now points at the
        // `ManifoldServerCLI` target — see that target's comment.
        .executable(name: "ManifoldServer", targets: ["ManifoldServerCLI"]),
        // Library product exposing the `ManifoldServer` module (the module
        // name, not this product name, is what a consumer `import`s) — lets a
        // host app or companion package call
        // `ManifoldServer.serve(configuration:backendProvider:)` to embed the
        // server with an injected backend, rather than only shelling out to
        // the CLI binary. The product name is distinct from the module name
        // because SwiftPM requires unique product names within a package and
        // `ManifoldServer` is already taken by the executable product above.
        .library(name: "ManifoldServerKit", targets: ["ManifoldServer"]),
        // Optional OTLP/HTTP exporter — not re-exported by the ManifoldKit
        // umbrella. Import explicitly: `import ManifoldTelemetryOTLP`.
        .library(name: "ManifoldTelemetryOTLP", targets: ["ManifoldTelemetryOTLP"]),
        // ManifoldAppEval: golden-scenario eval harness for APPS built on
        // ManifoldKit (estate#1). Not re-exported by the ManifoldKit umbrella —
        // same precedent as ManifoldTools/ManifoldFuzz/ManifoldTelemetryOTLP —
        // consumers import it explicitly from test targets or dedicated eval
        // executables. See docs/APP-EVAL.md.
        .library(name: "ManifoldAppEval", targets: ["ManifoldAppEval"]),
    ],
    traits: [
        // No default traits since v0.48 (PR C2): the heavy MLX / llama.cpp
        // families moved to companion packages, so a plain `swift build` is
        // already the lean shape. Server and Macros remain genuine opt-in
        // build-cost levers on leaf edges (Hummingbird, swift-syntax).
        .trait(name: "Server", description: "Enable ManifoldServer (OpenAI-compatible HTTP server) and its Hummingbird dependency."),
        .trait(name: "Macros", description: "Enable the @ToolSchema macro plugin and its swift-syntax dependency. Off by default — pulls ~647 source files into the build graph."),
        // WWDC 2026 stubs resolved against the Xcode 27 beta SDK. Neither has
        // associated targets or source files; see docs/wwdc-2026-trait-stubs.md.
        .trait(name: "SystemAIProviderExtension", description: "No-op stub: the anticipated Siri/Writing Tools provider slot is not present in the Xcode 27 beta SDK."),
        .trait(name: "CoreAI", description: "No-op stub: Core AI integration is provided by apple/coreai-models through FoundationModels.LanguageModelExecutor, not this trait."),
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
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
        // Test-only: SwiftUI view-tree inspection for accessibility contract tests.
        // Must never appear in any production target.
        .package(url: "https://github.com/nalexn/ViewInspector", from: "0.10.3"),
        // swift-syntax for the @ToolSchema macro plugin. Widened to 602.0.0..<604.0.0
        // to match what mlx-swift-lm 3.31.4 (companion manifold-mlx) now requires
        // transitively — a narrower range produces a duplicate-dependency resolution
        // conflict against the companion package. 602/603 correspond to Swift 6.2/6.3
        // macro ABI and build fine on the current toolchain (CI = Xcode 26.3 / Swift
        // 6.3.x). Do not bump beyond what the installed toolchain supports.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "602.0.0"..<"604.0.0"),
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
        // traffic in (ChatMessage, ChatSession, MessagePart,
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
        // ManifoldAgentInstructions: AGENTS.md ambient-instruction filesystem
        // discovery, extracted out of the retired ManifoldSkills (#2434) — the
        // only half of that module with a real use case. Depends on
        // ManifoldInference ONLY (not ManifoldRuntime): it conforms to
        // PromptContextProvider (ManifoldInference) directly, so it stays a
        // leaf-ish module a host can link without pulling in the runtime.
        // `ManifoldKit`'s ConversationRuntimeOptions+AgentInstructions.swift
        // is the wiring bridge that needs both — see that file's header comment.
        // Library target is unconditional (the body is platform-gated with
        // `#if os(macOS)`, same contract as the old SkillLoader).
        .target(
            name: "ManifoldAgentInstructions",
            dependencies: [
                "ManifoldInference",
            ],
            path: "Sources/ManifoldAgentInstructions"
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
        // StableDiffusion) at https://github.com/ManifoldKit/manifold-mlx and
        // ManifoldLlama at https://github.com/ManifoldKit/manifold-llama
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

        // ManifoldAnyLanguageModel target removed (#2435): zero adoption
        // plus dependency coupling. See docs/MIGRATION-anylanguagemodel-retired.md.
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
                // New edge (Unit 2 §L4, docs/UI-REFRESH-2026-PLAN.md): the
                // promoted Connected Services settings surface
                // (`Views/Settings/ConnectedServicesView.swift`) reuses
                // `MCPToolCountView` rather than re-implement the Foundation
                // Models 16-tool-cap footnote a second time. Legal — no
                // cycle: `ManifoldMCP` depends only on `ManifoldInference`,
                // never on any UI target — and does not violate the "UI
                // never imports a backend family" rule, which targets
                // Foundation/Ollama/CloudSaaS specifically; MCP is a tool
                // bridge, not a backend family. FLAGGED AS AN EXPLICIT REVIEW
                // ITEM in the PR body per the tranche brief. If the reviewer
                // rules the edge undesirable, the fallback is re-homing a
                // minimal count view in this target instead of importing
                // `ManifoldMCP`.
                "ManifoldMCP",
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
                // Seed-model path: `quickStart(seed:)` drives a background download on
                // first launch when no model is available. The concrete
                // BackgroundDownloadManager + HuggingFaceService live in
                // ManifoldHuggingFace (unconditional since the HuggingFace
                // trait retired in v0.48, PR C2).
                "ManifoldHuggingFace",
                // AGENTS.md ambient-instruction wiring bridge
                // (ConversationRuntimeOptions+AgentInstructions.swift) — same
                // "linked but not @_exported" shape as ManifoldHuggingFace above: hosts that
                // want the AgentInstruction* types import ManifoldAgentInstructions
                // explicitly (#2434).
                "ManifoldAgentInstructions",
            ],
            path: "Sources/ManifoldKit"
        ),
        // Voice: optional speech-recognition / synthesis adapters plus chat UI accessories.
        .target(
            name: "ManifoldVoice",
            dependencies: ["ManifoldUI"],
            path: "Sources/ManifoldVoice"
        ),
        // Shared test mocks and utilities. Deliberately does NOT depend on
        // ManifoldPersistenceSwiftData — the persistence-touching mocks
        // (GlassBoxDemoRAG, InMemoryPersistenceHarness, makeInMemoryContainer())
        // live in ManifoldPersistenceTestSupport (arch-plan 4.4, wave2 P2) so
        // pure-engine consumers (companion repos, leaf test suites) don't pull
        // in the SwiftData stack transitively for one mock.
        .target(
            name: "ManifoldTestSupport",
            dependencies: [
                "ManifoldRuntime",
                "ManifoldInference",
            ],
            path: "Sources/ManifoldTestSupport",
            exclude: ["FuzzCalibrationCorpus"],
            resources: [
                // Sample Markdown corpus the Glass Box research-session demo
                // (GlassBoxDemoRAG, now in ManifoldPersistenceTestSupport)
                // ingests into the real RAG stack (#1575). Bundled here because
                // SampleDocumentCorpus.swift has no persistence dependency of
                // its own and stays in this target; the live integration test
                // resolves it via Bundle.module.
                .copy("Fixtures/Documents")
            ]
        ),
        // Persistence-dependent test mocks split out of ManifoldTestSupport
        // (arch-plan 4.4, docs/plans/api-review-wave2-2026-07.md Track 2 P2):
        // GlassBoxDemoRAG, InMemoryPersistenceHarness, and makeInMemoryContainer()
        // are the only 3 of ManifoldTestSupport's ~41 files that needed SwiftData
        // + ManifoldPersistenceSwiftData — split out so pure-engine consumers
        // (companion repos, leaf Hardware/Secrets/Networking test suites) stop
        // linking the whole persistence stack to get one mock. Depends on
        // ManifoldTestSupport for SampleDocumentCorpus (GlassBoxDemoRAG's bundled
        // fixture corpus), which has no persistence dependency and stays put.
        .target(
            name: "ManifoldPersistenceTestSupport",
            dependencies: [
                "ManifoldTestSupport",
                "ManifoldRuntime",
                "ManifoldPersistenceSwiftData",
                "ManifoldInference",
            ],
            path: "Sources/ManifoldPersistenceTestSupport"
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
                // EventSubsequenceAssertion.swift delegates to
                // EventSubsequenceChecker and extends RuntimeScenarioRunner
                // with the XCTest assert(result:) adapter (both relocated to
                // ManifoldAppEval, wave 1 of the app-eval harness).
                "ManifoldAppEval",
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
                // ConversationExporterTests.swift/TouchSessionScalePerformanceTests.swift
                // use InMemoryPersistenceHarness; SwiftDataEndpointStoreTests.swift,
                // SwiftDataPersonaStoreTests.swift, and SwiftDataSamplerPresetStoreTests.swift
                // use makeInMemoryContainer() — both moved here in the 4.4 TestSupport split.
                "ManifoldPersistenceTestSupport",
            ]
        ),
        // ManifoldRuntime-focused tests: protocol contracts, value types, and
        // services. Some suites here (ConversationRunStateTests.swift,
        // SessionListServiceDeleteAllTests.swift, TurnDriverDispatchTests.swift)
        // do exercise InMemoryPersistenceHarness — the "don't import SwiftData"
        // framing above predates that; tests exercising both ManifoldRuntime and
        // ManifoldPersistenceSwiftData as adapter-against-port integrations were
        // meant to stay in ManifoldCoreTests, but these three drifted here. Not
        // relocated by this PR (out of scope for the TestSupport split) — flagged
        // for a follow-up sweep.
        .testTarget(
            name: "ManifoldRuntimeTests",
            dependencies: [
                "ManifoldRuntime",
                "ManifoldInference",
                "ManifoldTestSupport",
                "ManifoldContractTestSupport",
                // ScriptedBackendRuntimeTests.swift imports ScriptedGenerationBackend,
                // relocated to ManifoldAppEval (app-eval harness wave 1).
                "ManifoldAppEval",
                // ConversationRunStateTests.swift, SessionListServiceDeleteAllTests.swift,
                // and TurnDriverDispatchTests.swift use InMemoryPersistenceHarness
                // (and TurnDriverDispatchTests.swift/ConversationRunStateTests.swift
                // directly `import ManifoldPersistenceSwiftData`, previously reached
                // transitively through ManifoldTestSupport before the 4.4 split).
                "ManifoldPersistenceTestSupport",
                "ManifoldPersistenceSwiftData",
            ]
        ),
        .testTarget(
            name: "ManifoldAgentInstructionsTests",
            dependencies: [
                "ManifoldAgentInstructions",
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
                // Most suites here use InMemoryPersistenceHarness / makeInMemoryContainer().
                "ManifoldPersistenceTestSupport",
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
                // RuntimeScenarioRunnerTests.swift, ScriptedGenerationBackendTests.swift,
                // and ResearchSessionLiveRAGIntegrationTests.swift import
                // RuntimeScenario(Registry)/ScriptedGenerationBackend/
                // ContextWindowPreTurnCompressionPolicy, relocated to
                // ManifoldAppEval (app-eval harness wave 1).
                "ManifoldAppEval",
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
            // SilentCatchAuditTest and UnlockedNonisolatedUnsafeTestSeamAuditTest
            // (#2094) both read their allowlist directly from its on-disk source
            // location via `#filePath`, so we don't need to bundle either into
            // the test binary — just tell SwiftPM to ignore them when collecting
            // resources.
            exclude: ["silent_catch_allowlist.txt", "unlocked_nonisolated_unsafe_allowlist.txt"],
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
                // FoundationModelE2ETests.swift and CloudEndpointSelectionIntegrationTests.swift
                // use makeInMemoryContainer(), moved here in the 4.4 TestSupport split.
                "ManifoldPersistenceTestSupport",
                "ManifoldBackendTestKit",
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
                // Most suites here use makeInMemoryContainer() / InMemoryPersistenceHarness,
                // moved here in the 4.4 TestSupport split.
                "ManifoldPersistenceTestSupport",
                // WebSearchToolSourceTests.swift / ImageGenerationToolSourceTests.swift /
                // VideoGenerationToolSourceTests.swift adopt SessionToolSourceContract.
                "ManifoldContractTestSupport",
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
                // TestChatViewModelFactory.swift uses makeInMemoryContainer(),
                // moved here in the 4.4 TestSupport split.
                "ManifoldPersistenceTestSupport",
                // ConnectedServicesConsentTests (#2320) imports ViewInspector;
                // plain `swift test` masked the missing declaration (the
                // module already sits in the shared build tree via
                // ManifoldUITests), but CI's compile-pruned selective mode
                // resolves strictly and fails without it.
                .product(name: "ViewInspector", package: "ViewInspector"),
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
        // ManifoldServer: OpenAI-compatible HTTP server implementation —
        // routing layer, trait-aware backend provider, and the public
        // `ManifoldServer.serve(configuration:backendProvider:)` facade a host
        // app embeds directly (v0.71+, the ServerBackendProvider seam). A
        // REGULAR (non-executable) target so it can back the
        // `ManifoldServerKit` library product — SwiftPM rejects an
        // `.executableTarget` in a `.library()` product, which is why the
        // `@main` entry point lives in the separate `ManifoldServerCLI`
        // target below instead of here. Trait-gated behind `Server`, which
        // also conditionally pulls in Hummingbird. Without the trait the
        // target compiles to nothing (every file is wrapped in `#if Server`).
        //
        // ManifoldBackends and ManifoldInference are `Server`-conditional so
        // a trait-off build compiles the no-op stub without dragging the full
        // backend graph into the executable. (The historical #982
        // llama.framework copy-collision rationale died with the C2 split —
        // llama.framework no longer exists in this package's graph.)
        .target(
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
        // Thin `@main` shim for the `manifold-server` CLI binary — see the
        // `ManifoldServer` target comment above for why this is a separate
        // target. Contains one file that forwards to
        // `ManifoldServerCommand.main()` (defined in `ManifoldServer`).
        .executableTarget(
            name: "ManifoldServerCLI",
            dependencies: [
                .target(name: "ManifoldServer"),
            ],
            path: "Sources/ManifoldServerCLI",
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
                // LoopDetectionE2ETests.swift uses makeInMemoryContainer(),
                // moved here in the 4.4 TestSupport split. (The other E2E
                // suites here call ModelContainerFactory.makeInMemoryContainer()
                // directly via ManifoldPersistenceSwiftData above.)
                "ManifoldPersistenceTestSupport",
                // RuntimeScenarioRunner (live-mode Glass Box gate, #1576) lives here.
                "ManifoldContractTestSupport",
                "ManifoldTools",
                "ManifoldHuggingFace",
                // GlassBoxScenarioLiveE2ETests.swift imports RuntimeScenario /
                // RuntimeScenarioRegistry / ScriptedGenerationBackend, relocated
                // to ManifoldAppEval (app-eval harness wave 1).
                "ManifoldAppEval",
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
                // TurnLoopCharacterizationTests.swift, CompressionGoldenTests.swift,
                // and SessionToolSourceDispatchTest.swift use InMemoryPersistenceHarness,
                // moved here in the 4.4 TestSupport split.
                "ManifoldPersistenceTestSupport",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
                // TurnLoopCharacterizationTests.swift and CompressionGoldenTests.swift
                // import ScriptedGenerationBackend, relocated to ManifoldAppEval
                // (app-eval harness wave 1).
                "ManifoldAppEval",
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
                // read_file / list_dir / sample_repo_search sandbox fixture tree
                // (moved from Tests/Fixtures/manifold-tools, #C1) — ships inside
                // Bundle.module so ToolFixtures.bundledRoot() resolves it
                // regardless of CWD, mirroring the built-in scenario corpus.
                .copy("Fixtures/manifold-tools"),
            ]
        ),
        // manifold-tools does NOT depend on the (retired) ManifoldBackends
        // umbrella: it takes the ManifoldOllama and ManifoldCloudSaaS family
        // products directly (both unconditional since the Ollama/CloudSaaS
        // traits retired in PR A4).
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
        // ManifoldAppEval: golden-scenario eval harness for apps built on
        // ManifoldKit (estate#1, design doc appeval-design-v2). Deps are
        // deliberately ManifoldInference + ManifoldRuntime only — no
        // ManifoldTestSupport / ManifoldContractTestSupport / XCTest edge, so
        // the harness can be imported from a plain executable or any test
        // target without pulling in XCTest (the #1409 dyld constraint).
        // Not re-exported by the ManifoldKit umbrella (consumers opt in
        // explicitly, same precedent as ManifoldTools/ManifoldFuzz/
        // ManifoldTelemetryOTLP).
        .target(
            name: "ManifoldAppEval",
            dependencies: [
                "ManifoldInference",
                "ManifoldRuntime",
            ],
            path: "Sources/ManifoldAppEval"
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
                // NOTE: QuickStart*Tests.swift call `ModelContainerFactory.
                // makeInMemoryContainer()` directly (ManifoldPersistenceSwiftData
                // above), not the ManifoldTestSupport free function, so this
                // target does NOT need ManifoldPersistenceTestSupport (4.4 split).
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
        // ManifoldAppEvalTests: schema decode/mapper/scorer/probe/renderer/ledger
        // unit tests plus the wave-1 dogfood (MK's own compression golden
        // re-expressed as a JSON fixture, run through the full deterministic
        // lane). Deliberately does NOT depend on ManifoldTestSupport /
        // ManifoldContractTestSupport — mirrors ManifoldAppEval's own
        // dependency discipline.
        .testTarget(
            name: "ManifoldAppEvalTests",
            dependencies: [
                "ManifoldAppEval",
                "ManifoldInference",
                "ManifoldRuntime",
            ],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
