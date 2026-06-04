// swift-tools-version: 6.1

// Trait reference (full table in README §2.4):
//   - Defaults: MLX, Llama, HuggingFace.
//   - Opt-in heavy/network traits: Ollama, CloudSaaS, MCP, MCPBuiltinCatalog,
//     Voice, Tools, AppIntents, Server, Macros, Fuzz, AnyLanguageModel,
//     HuggingFace.
//   - `FoundationOnly` is an explicit "App Store-lean" marker for indie iOS
//     26+/macOS 26+ apps that only need Apple Foundation Models. Pass
//     `traits: ["FoundationOnly"]` from the consumer manifest — SwiftPM
//     treats that as the full enabled-trait set, so the MLX/Llama/HuggingFace
//     defaults drop out and ManifoldBackends compiles to FoundationBackend +
//     cloud-stub bodies only (no MLX checkout, no LlamaSwift xcframework, no
//     swift-huggingface). Mutual exclusion with MLX/Llama/HuggingFace is
//     enforced by the consumer override semantics, not by the package itself.
//   - The CI gate `foundation-only-build` (`.github/workflows/ci.yml`)
//     enforces a ≤ 5 MB ManifoldBackends artifact and zero MLX/Llama symbol
//     leaks under the FoundationOnly trait.

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
        // ManifoldPersistenceSwiftData + ManifoldBackends + ManifoldUI so a
        // typical app can `import ManifoldKit` and skip the 4–6 import dance.
        // Specialised modules (MCP, Voice, ModelManagement, AppIntents, …) stay
        // explicit imports because not every host wants them in the build graph.
        .library(name: "ManifoldKit", targets: ["ManifoldKit"]),
        .library(name: "ManifoldInference", targets: ["ManifoldInference"]),
        .library(name: "ManifoldMCP", targets: ["ManifoldMCP"]),
        .library(name: "ManifoldMCPHost", targets: ["ManifoldMCPHost"]),
        .library(name: "ManifoldRuntime", targets: ["ManifoldRuntime"]),
        .library(name: "ManifoldPersistenceSwiftData", targets: ["ManifoldPersistenceSwiftData"]),
        // Initiative I7 split ManifoldBackends into 5 trait-gated source
        // targets. The legacy `ManifoldBackends` target/module is preserved
        // (renamed only on disk to `Sources/ManifoldBackendsUmbrella` to make
        // its role visible) so existing `import ManifoldBackends` consumers
        // keep compiling — the target body is now a thin re-export shim plus
        // the cross-family registration glue (DefaultBackends and the
        // BackendRegistrar conformances).
        .library(name: "ManifoldBackends", targets: ["ManifoldBackends"]),
        .library(name: "ManifoldCloudCore", targets: ["ManifoldCloudCore"]),
        .library(name: "ManifoldMLX", targets: ["ManifoldMLX"]),
        .library(name: "ManifoldLlama", targets: ["ManifoldLlama"]),
        .library(name: "ManifoldFoundation", targets: ["ManifoldFoundation"]),
        .library(name: "ManifoldCloud", targets: ["ManifoldCloud"]),
        .library(name: "ManifoldUI", targets: ["ManifoldUI"]),
        .library(name: "ManifoldUIModelManagement", targets: ["ManifoldUIModelManagement"]),
        .library(name: "ManifoldHuggingFace", targets: ["ManifoldHuggingFace"]),
        .library(name: "ManifoldVoice", targets: ["ManifoldVoice"]),
        .library(name: "ManifoldFuzz", targets: ["ManifoldFuzz"]),
        .executable(name: "fuzz-chat", targets: ["fuzz-chat"]),
        .library(name: "ManifoldTools", targets: ["ManifoldTools"]),
        .executable(name: "manifold-tools", targets: ["manifold-tools"]),
        .library(name: "ManifoldAppIntents", targets: ["ManifoldAppIntents"]),
        .library(name: "ManifoldSkills", targets: ["ManifoldSkills"]),
        .executable(name: "ManifoldServer", targets: ["ManifoldServer"]),
    ],
    traits: [
        .default(enabledTraits: ["MLX", "Llama", "HuggingFace", "Skills"]),
        .trait(name: "MLX", description: "Enable the MLX inference backend (requires Apple Silicon)"),
        .trait(name: "Llama", description: "Enable the llama.cpp (GGUF) inference backend"),
        .trait(name: "HuggingFace", description: "Enable HuggingFace Hub search, browse, and download"),
        .trait(name: "AnyLanguageModel", description: "Enable the AnyLanguageModel bridge backend target."),
        .trait(name: "Ollama", description: "Self-hosted / private-datacenter HTTP inference. Moves out of defaults in next major."),
        .trait(name: "CloudSaaS", description: "Third-party SaaS providers (Claude, OpenAI). Off by default."),
        .trait(name: "MCP", description: "Enable the ManifoldMCP module and MCP client surface."),
        .trait(name: "MCPBuiltinCatalog", description: "Enable ManifoldMCP's built-in catalog descriptors."),
        .trait(name: "Voice", description: "Enable the ManifoldVoice speech I/O spike and voice composer UI."),
        .trait(name: "Tools", description: "Enable the ManifoldTools end-to-end tool-calling validation harness and its `manifold-tools` CLI."),
        .trait(name: "AppIntents", description: "Enable the ManifoldAppIntents AppIntent ↔ ToolDefinition bridge."),
        .trait(name: "Server", description: "Enable ManifoldServer (OpenAI-compatible HTTP server) and its Hummingbird dependency."),
        .trait(name: "Macros", description: "Enable the @ToolSchema macro plugin and its swift-syntax dependency. Off by default — pulls ~647 source files into the build graph."),
        .trait(name: "Skills", description: "Enable the ManifoldSkills module (Claude-Code-compatible SKILL.md discovery + invoke_skill dispatcher). Default-on; macOS-only filesystem scan in v1."),
        // Fuzz is intentionally NOT a default trait. Enabling it adds ManifoldBackends
        // (and transitively LlamaSwift) to fuzz-chat, which conflicts with the MLX
        // integration test targets in the auto-generated Xcode scheme. Run the fuzzer via
        // scripts/fuzz.sh, which passes --traits Fuzz,MLX,Llama explicitly.
        .trait(name: "Fuzz", description: "Enable real inference backends in fuzz-chat (Ollama, Llama, Foundation). Required by scripts/fuzz.sh; not needed for swift test or xcodebuild test."),
        // FoundationOnly is an explicit App Store-lean marker. Consumers that
        // pass `traits: ["FoundationOnly"]` override the default trait set
        // (which is MLX + Llama + HuggingFace), so ManifoldBackends compiles
        // without MLX, llama.cpp, or swift-huggingface — keeping the BCK
        // overhead under 5 MB and dropping ~700 MB of binary dependencies
        // from the resolved graph. Apple Foundation Models still work via
        // FoundationBackend (iOS 26 / macOS 26+). See docs/AppStoreSubmission.md.
        .trait(name: "FoundationOnly", description: "App Store-lean: Apple Foundation Models only. Pass `traits: [\"FoundationOnly\"]` from the consumer manifest — overrides the MLX/Llama/HuggingFace default trait set."),
        // WWDC 2026 pre-emptive stubs. No associated targets or source files —
        // these traits exist solely so `#if SystemAIProviderExtension` and
        // `#if CoreAI` conditional blocks can be written today and flip live on
        // June 8 without a Package.swift change. See docs/wwdc-2026-trait-stubs.md.
        .trait(name: "SystemAIProviderExtension", description: "Stubs for the iOS 27 system AI provider extension surface (Siri/Writing Tools backend slot). No-op until WWDC 2026 ships the API."),
        .trait(name: "CoreAI", description: "Placeholder for Apple's rumoured Core AI framework (Core ML successor). No-op until WWDC 2026 confirms the surface."),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.31.3"),
        // 3.31.3 ships the decoupled MLXHuggingFace target (the original reason for the
        // manual revision pin) and adds the `gemma4` model_type to LLMTypeRegistry so
        // mlx-community/gemma-4-* can load.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.3"),
        // flux.swift vendored: mzbac/flux.swift pins swift-transformers 0.1.x
        // while ManifoldKit needs 1.2.x — same conflict that forced StableDiffusion
        // to be vendored. Source lives in Sources/FluxSwift (MIT license, 12 files).
        // mlx-swift-examples was previously a direct dependency for StableDiffusion.
        // Its package manifest declared platforms: iOS 16 while depending on mlx-swift
        // which requires iOS 17, causing a SPM platform-validation error for consumers.
        // The StableDiffusion source (9 files, MIT) is now vendored in Sources/StableDiffusion.
        // If upstream resolves the platform conflict and cuts a new tag, revert to the
        // package dependency. Tracked in umbrella issue #1002.
        // Pin 0.9.0 exactly: this is the verified tag that still exports the
        // `HuggingFace` product consumed by ManifoldHuggingFace and its tests.
        .package(url: "https://github.com/huggingface/swift-huggingface.git", exact: "0.9.0"),
        .package(url: "https://github.com/huggingface/AnyLanguageModel", from: "0.8.0"),
        // Explicit dep required: mlx-swift-lm no longer pulls swift-transformers transitively.
        // The MLXHuggingFace macro generates `AutoTokenizer.from(modelFolder:)` which lives here.
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.2.0"),
        // Pinned version: 2.8772.0 (Package.resolved rev 3fec82010cfbe56aa78bb4177c8f4f33dace8779).
        // Wraps llama.cpp build b8772 as a pre-built xcframework binary.
        // See docs/LLAMA_CONTRACT.md for the full C API contract, threading rules, and upgrade procedure.
        .package(url: "https://github.com/mattt/llama.swift", from: "2.8772.0"),
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
        // swift-log: pulled in by vendored FluxSwift source. Lightweight structured
        // logging façade; no runtime overhead beyond the backend you install.
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
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
        .target(
            name: "ManifoldInference",
            dependencies: [
                .target(name: "ManifoldMacrosPlugin", condition: .when(traits: ["Macros"])),
            ],
            path: "Sources/ManifoldInference",
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
                .define("Macros", .when(traits: ["Macros"])),
                .define("FoundationOnly", .when(traits: ["FoundationOnly"])),
            ]
        ),
        // MCP: Model Context Protocol client surface, descriptors, transports,
        // OAuth, catalog presets, and tool bridge. It depends on Inference
        // directly and intentionally stays runtime-/SwiftData-free; the
        // runtime-backed server lives in ManifoldMCPHost below.
        .target(
            name: "ManifoldMCP",
            dependencies: ["ManifoldInference"],
            path: "Sources/ManifoldMCP",
            swiftSettings: [
                .define("MCPBuiltinCatalog", .when(traits: ["MCPBuiltinCatalog"])),
            ]
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
        // (the body is platform-gated with `#if os(macOS)`); consumer edges
        // are trait-gated per `feedback_trait_gating_internal_edges` —
        // wrapping a library-to-library edge in `.when(traits: ["Skills"])`
        // while sources still import unconditionally is the broken shape.
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
        // Vendored StableDiffusion (from mlx-swift-examples, MIT License).
        // All sources are inside #if MLX guards so non-MLX builds compile to empty files.
        // Dependencies: MLX + MLXNN from mlx-swift, Hub from swift-transformers (both already direct deps).
        .target(
            name: "StableDiffusion",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift", condition: .when(traits: ["MLX"])),
                .product(name: "MLXNN", package: "mlx-swift", condition: .when(traits: ["MLX"])),
                .product(name: "Hub", package: "swift-transformers", condition: .when(traits: ["MLX"])),
            ],
            path: "Sources/StableDiffusion",
            exclude: ["LICENSE"],
            swiftSettings: [.define("MLX", .when(traits: ["MLX"]))]
        ),
        // ─────────────────────────────────────────────────────────────────
        // Backends — initiative I7 split.
        //
        // The original 11.7k-LOC `ManifoldBackends` target hosted four
        // unrelated runtimes (MLX / llama.cpp / Foundation / Cloud). Any
        // single-line change recompiled all 11.7k LOC; cross-runtime symbol
        // visibility forced 28 `@unchecked Sendable` conformances and three
        // dummy `*Stub.swift` files to keep the link alive when traits flipped
        // families off. Splitting per family eliminates the stubs and lets
        // SwiftPM trait-gate at the consumer→library edge instead of file-by-
        // file `#if`s smeared across the body.
        //
        // Trait-gating rule (per CLAUDE.md): gate the consumer→family edge,
        // not the family→library edge. `ManifoldCloud → ManifoldCloudCore` is
        // unconditional (always linked together); `Consumer → ManifoldCloud`
        // is gated by `CloudSaaS || Ollama` so a `FoundationOnly` build never
        // pulls Cloud sources at all.
        //
        // The legacy `ManifoldBackends` target/module is preserved as a thin
        // re-export shim (sources moved to `Sources/ManifoldBackendsUmbrella/`
        // to make the role obvious in directory listings) that hosts
        // cross-family glue (`DefaultBackends`, the per-family
        // `BackendRegistrar` conformances) and `@_exported import`s the four
        // family targets so existing `import ManifoldBackends` consumers keep
        // compiling without edits.
        // ─────────────────────────────────────────────────────────────────

        // ManifoldCloudCore: shared SSE / TLS-pinning / DNS-rebind / URLSession
        // infrastructure. Always linked — the file bodies are themselves
        // gated by `#if Ollama || CloudSaaS` so a FoundationOnly build still
        // compiles this target to empty objects (cheap) and links them.
        .target(
            name: "ManifoldCloudCore",
            dependencies: ["ManifoldInference"],
            path: "Sources/ManifoldCloudCore",
            swiftSettings: [
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("Ollama", .when(traits: ["Ollama"])),
            ]
        ),

        // ManifoldMLX: MLX inference backend, resource arbiter, capability
        // probe, MLX-specific tool dialect.
        .target(
            name: "ManifoldMLX",
            dependencies: [
                "ManifoldInference",
                .product(name: "MLX", package: "mlx-swift", condition: .when(traits: ["MLX"])),
                .product(name: "MLXRandom", package: "mlx-swift", condition: .when(traits: ["MLX"])),
                .product(name: "MLXLLM", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
                // MLXVLM ships the MoE Gemma 4 decoder (Libraries/MLXVLM/Models/Gemma4.swift)
                // that LLMModelFactory's Gemma4Text.swift lacks. MLXBackend sniffs config.json
                // and routes models with `text_config.enable_moe_block == true` (e.g.
                // mlx-community/gemma-4-26b-a4b-it-4bit) to VLMModelFactory.shared.loadContainer.
                // See issue #752.
                .product(name: "MLXVLM", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
                .product(name: "Tokenizers", package: "swift-transformers", condition: .when(traits: ["MLX"])),
                // Hub is consumed directly by the FLUX diffusion backend (merged from
                // the former ManifoldFlux target) for repository snapshot downloads.
                .product(name: "Hub", package: "swift-transformers", condition: .when(traits: ["MLX"])),
                // Vendored StableDiffusion (Sources/StableDiffusion), used by MLXDiffusionBackend.
                .target(name: "StableDiffusion", condition: .when(traits: ["MLX"])),
                // Vendored FluxSwift (Sources/FluxSwift), used by FluxDiffusionBackend.
                // Merged in from the former ManifoldFlux target — same MLX trait, same
                // vendored dep, single backend class; standalone target was pure overhead.
                .target(name: "FluxSwift", condition: .when(traits: ["MLX"])),
            ],
            path: "Sources/ManifoldMLX",
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
            ]
        ),

        // FluxSwift: vendored mzbac/flux.swift (MIT). Provides FLUX.1 transformer,
        // VAE, text encoders, tokenizer, and quantization utilities.
        // Vendored instead of a package dependency because flux.swift pins
        // swift-transformers 0.1.x; ManifoldKit requires 1.2.x.
        .target(
            name: "FluxSwift",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift", condition: .when(traits: ["MLX"])),
                .product(name: "MLXNN", package: "mlx-swift", condition: .when(traits: ["MLX"])),
                .product(name: "MLXFast", package: "mlx-swift", condition: .when(traits: ["MLX"])),
                .product(name: "MLXOptimizers", package: "mlx-swift", condition: .when(traits: ["MLX"])),
                .product(name: "MLXRandom", package: "mlx-swift", condition: .when(traits: ["MLX"])),
                .product(name: "Tokenizers", package: "swift-transformers", condition: .when(traits: ["MLX"])),
                .product(name: "Logging", package: "swift-log", condition: .when(traits: ["MLX"])),
            ],
            path: "Sources/FluxSwift",
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
            ]
        ),

        // ManifoldLlama: llama.cpp (GGUF) inference, generation driver,
        // process-lifecycle refcount, embedding backend, GGUF-specific tool
        // call parser, tokenizer adapters.
        .target(
            name: "ManifoldLlama",
            dependencies: [
                "ManifoldInference",
                .product(name: "LlamaSwift", package: "llama.swift", condition: .when(traits: ["Llama"])),
            ],
            path: "Sources/ManifoldLlama",
            swiftSettings: [
                .define("Llama", .when(traits: ["Llama"])),
            ]
        ),

        // ManifoldFoundation: Apple Foundation Models bridge. No trait —
        // gated by OS availability via `#if canImport(FoundationModels)` and
        // `@available(iOS 26, macOS 26, *)`.
        .target(
            name: "ManifoldFoundation",
            dependencies: ["ManifoldInference"],
            path: "Sources/ManifoldFoundation"
        ),

        // ManifoldCloud: SaaS + LAN cloud backends (OpenAI Chat Completions,
        // OpenAI Responses, Anthropic Claude, Ollama). Inherits the shared
        // SSE / TLS / DNS-rebind plumbing from ManifoldCloudCore.
        .target(
            name: "ManifoldCloud",
            dependencies: [
                "ManifoldInference",
                "ManifoldCloudCore",
            ],
            path: "Sources/ManifoldCloud",
            swiftSettings: [
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("Ollama", .when(traits: ["Ollama"])),
            ]
        ),

        // ManifoldBackends: the legacy umbrella module, now a thin re-export
        // shim. Hosts cross-family registration glue (`DefaultBackends`, the
        // per-family `BackendRegistrar` conformances `MLXBackends` /
        // `LlamaBackends` / `FoundationBackends` / `CloudBackends`) and
        // `@_exported import`s the four family targets so existing
        // `import ManifoldBackends` consumers keep compiling without edits.
        // The target name stays `ManifoldBackends` (module name follows the
        // target) so `@testable import ManifoldBackends` is preserved; the
        // sources live under `Sources/ManifoldBackendsUmbrella/` to make the
        // role obvious from the directory listing.
        .target(
            name: "ManifoldBackends",
            dependencies: [
                "ManifoldInference",
                "ManifoldCloudCore",
                "ManifoldFoundation",
                .target(name: "ManifoldMLX", condition: .when(traits: ["MLX"])),
                .target(name: "ManifoldLlama", condition: .when(traits: ["Llama"])),
                .target(name: "ManifoldCloud", condition: .when(traits: ["CloudSaaS", "Ollama"])),
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel", condition: .when(traits: ["AnyLanguageModel"])),
            ],
            path: "Sources/ManifoldBackendsUmbrella",
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
                .define("FoundationOnly", .when(traits: ["FoundationOnly"])),
                .define("AnyLanguageModel", .when(traits: ["AnyLanguageModel"])),
            ]
        ),
        // UI: SwiftUI views and view models — depends on runtime ports, not persistence adapters.
        .target(
            name: "ManifoldUI",
            dependencies: [
                "ManifoldRuntime",
                "ManifoldInference",
                .target(name: "ManifoldCloudCore", condition: .when(traits: ["CloudSaaS"])),
            ],
            path: "Sources/ManifoldUI",
            swiftSettings: [
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
            ]
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
                .target(name: "ManifoldHuggingFace", condition: .when(traits: ["HuggingFace"])),
            ],
            path: "Sources/ManifoldUIModelManagement",
            swiftSettings: [
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
            ]
        ),
        .target(
            name: "ManifoldHuggingFace",
            dependencies: [
                "ManifoldInference",
                .product(name: "HuggingFace", package: "swift-huggingface", condition: .when(traits: ["HuggingFace"])),
            ],
            path: "Sources/ManifoldHuggingFace",
            swiftSettings: [
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
            ]
        ),
        // ManifoldKit: umbrella library. Single-file `Exports.swift`
        // re-exports the four most-imported modules so app code can write
        // `import ManifoldKit` and reach `ChatView`, `ChatViewModel`,
        // `ManifoldBootstrap`, `DefaultBackends`, and the public Inference
        // surface from one import. Specialised modules stay opt-in (see
        // `Exports.swift` for the rationale).
        .target(
            name: "ManifoldKit",
            dependencies: [
                "ManifoldInference",
                "ManifoldRuntime",
                "ManifoldPersistenceSwiftData",
                "ManifoldBackends",
                "ManifoldUI",
                .target(name: "ManifoldSkills", condition: .when(traits: ["Skills"])),
            ],
            path: "Sources/ManifoldKit",
            swiftSettings: [
                .define("Skills", .when(traits: ["Skills"])),
            ]
        ),
        // Voice: optional speech-recognition / synthesis adapters plus chat UI accessories.
        .target(
            name: "ManifoldVoice",
            dependencies: ["ManifoldUI"],
            path: "Sources/ManifoldVoice",
            swiftSettings: [
                .define("Voice", .when(traits: ["Voice"])),
            ]
        ),
        // Shared test mocks and utilities
        .target(
            name: "ManifoldTestSupport",
            dependencies: [
                "ManifoldRuntime",
                "ManifoldPersistenceSwiftData",
                "ManifoldInference",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
            ],
            path: "Sources/ManifoldTestSupport",
            exclude: ["FuzzCalibrationCorpus"],
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
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
        // ManifoldSkills tests — consumer edge to ManifoldSkills is trait-gated
        // (per `feedback_trait_gating_internal_edges`) so default-traits-off
        // CI lanes don't try to build the module against the empty no-op body.
        .testTarget(
            name: "ManifoldSkillsTests",
            dependencies: [
                .target(name: "ManifoldSkills", condition: .when(traits: ["Skills"])),
                "ManifoldInference",
                "ManifoldRuntime",
                "ManifoldContractTestSupport",
            ],
            swiftSettings: [
                .define("Skills", .when(traits: ["Skills"])),
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
            ]
        ),
        .testTarget(
            name: "ManifoldInferenceTests",
            dependencies: [
                "ManifoldInference",
                "ManifoldTestSupport",
                .target(name: "ManifoldMacrosPlugin", condition: .when(traits: ["Macros"])),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax", condition: .when(traits: ["Macros"])),
            ],
            // SilentCatchAuditTest reads `silent_catch_allowlist.txt` directly
            // from its on-disk source location via `#filePath`, so we don't
            // need to bundle it into the test binary — just tell SwiftPM to
            // ignore it when collecting resources.
            exclude: ["silent_catch_allowlist.txt"],
            swiftSettings: [
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
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
        .testTarget(
            name: "ManifoldMCPTests",
            dependencies: [
                .target(name: "ManifoldMCP", condition: .when(traits: ["MCP"])),
                .target(name: "ManifoldMCPHost", condition: .when(traits: ["MCP"])),
                "ManifoldInference",
                "ManifoldRuntime",
                "ManifoldTestSupport",
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .define("MCP", .when(traits: ["MCP"])),
            ]
        ),
        .testTarget(
            name: "ManifoldMCPE2ETests",
            dependencies: [
                .target(name: "ManifoldMCP", condition: .when(traits: ["MCP"])),
                "ManifoldInference",
                "ManifoldTestSupport",
            ],
            swiftSettings: [
                .define("MCP", .when(traits: ["MCP"])),
            ]
        ),
        // Umbrella test target — covers every family target via per-trait
        // conditional deps so `@testable import ManifoldMLX`,
        // `@testable import ManifoldLlama`, etc. resolve from the same
        // suite. The `ManifoldBackends` dep also keeps
        // `@testable import ManifoldBackends` working for tests that exercise
        // the umbrella's cross-family glue (DefaultBackends, BackendRegistrar
        // conformances).
        .testTarget(
            name: "ManifoldBackendsTests",
            dependencies: [
                "ManifoldBackends",
                "ManifoldCloudCore",
                "ManifoldFoundation",
                .target(name: "ManifoldMLX", condition: .when(traits: ["MLX"])),
                .target(name: "ManifoldLlama", condition: .when(traits: ["Llama"])),
                .target(name: "ManifoldCloud", condition: .when(traits: ["CloudSaaS", "Ollama"])),
                "ManifoldUI",
                "ManifoldRuntime",
                "ManifoldPersistenceSwiftData",
                "ManifoldInference",
                "ManifoldTestSupport",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel", condition: .when(traits: ["AnyLanguageModel"])),
            ],
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
                .define("FoundationOnly", .when(traits: ["FoundationOnly"])),
                .define("AnyLanguageModel", .when(traits: ["AnyLanguageModel"])),
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
                .target(name: "ManifoldVoice", condition: .when(traits: ["Voice"])),
                .product(name: "ViewInspector", package: "ViewInspector"),
            ],
            swiftSettings: [
                .define("Voice", .when(traits: ["Voice"])),
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
            ],
            swiftSettings: [
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
            ]
        ),
        .testTarget(
            name: "ManifoldHuggingFaceTests",
            dependencies: [
                .target(name: "ManifoldHuggingFace", condition: .when(traits: ["HuggingFace"])),
                "ManifoldInference",
                "ManifoldTestSupport",
                .product(name: "HuggingFace", package: "swift-huggingface", condition: .when(traits: ["HuggingFace"])),
            ],
            path: "Tests/ManifoldHuggingFaceTests",
            swiftSettings: [
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
            ]
        ),
        // ManifoldServer: OpenAI-compatible HTTP server. Shipped as a single
        // executable target — the routing layer, trait-aware backend provider,
        // and `@main` entry point all live here. Trait-gated behind `Server`,
        // which also conditionally pulls in Hummingbird. Without the trait the
        // target compiles to a no-op stub that prints a "trait not enabled"
        // message (see `ManifoldServerCommand.swift`).
        //
        // ManifoldBackends and ManifoldInference are also `Server`-conditional
        // for the same reason `fuzz-chat`'s ManifoldBackends dep is `Fuzz`-
        // conditional (see comment on the `Fuzz` trait above): an unconditional
        // ManifoldBackends dep on a second executable in the auto-generated
        // `ManifoldKit-Package` Xcode scheme produces two `Copy llama.framework`
        // tasks that collide on the same output path — breaking
        // `xcodebuild test -only-testing ManifoldMLXIntegrationTests`. Gating
        // the deps keeps `manifold-tools` as the sole executable that pulls
        // llama.framework into the auto-scheme. See issue #982.
        .executableTarget(
            name: "ManifoldServer",
            dependencies: [
                .target(name: "ManifoldInference", condition: .when(traits: ["Server"])),
                .target(name: "ManifoldBackends", condition: .when(traits: ["Server"])),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Hummingbird", package: "hummingbird", condition: .when(traits: ["Server"])),
            ],
            path: "Sources/ManifoldServer",
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
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
            ],
            swiftSettings: [
                .define("Server", .when(traits: ["Server"])),
            ]
        ),
        .testTarget(
            name: "ManifoldE2ETests",
            dependencies: [
                "ManifoldBackends",
                "ManifoldCloudCore",
                "ManifoldFoundation",
                .target(name: "ManifoldMLX", condition: .when(traits: ["MLX"])),
                .target(name: "ManifoldLlama", condition: .when(traits: ["Llama"])),
                .target(name: "ManifoldCloud", condition: .when(traits: ["CloudSaaS", "Ollama"])),
                "ManifoldUI",
                "ManifoldRuntime",
                "ManifoldPersistenceSwiftData",
                "ManifoldInference",
                "ManifoldTestSupport",
                .target(name: "ManifoldTools", condition: .when(traits: ["Tools"])),
                .target(name: "ManifoldHuggingFace", condition: .when(traits: ["HuggingFace"])),
            ],
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
                .define("Tools", .when(traits: ["Tools"])),
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
            exclude: ["__Snapshots__"],
            swiftSettings: [
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
            ]
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
        // Trait-free so it never pulls MLX/Llama transitively — backend selection
        // happens in `ManifoldFuzzBackends` (importable real-backend factories),
        // `fuzz-chat` (CLI), and `ManifoldFuzzTests` (XCTest harness).
        .target(
            name: "ManifoldFuzz",
            dependencies: ["ManifoldInference"],
            path: "Sources/ManifoldFuzz",
            resources: [.process("Resources")]
        ),
        // Importable real-backend factories for fuzz campaigns. Shared by the
        // CLI and the Xcode-hosted MLX fuzz tests so XCTest can reuse the same
        // wiring without importing the `fuzz-chat` executable target.
        .target(
            name: "ManifoldFuzzBackends",
            dependencies: [
                "ManifoldFuzz",
                "ManifoldInference",
                "ManifoldBackends",
            ],
            path: "Sources/ManifoldFuzzBackends",
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
                .define("Fuzz", .when(traits: ["Fuzz"])),
            ]
        ),
        // CLI driver. Wires Ollama, Llama, Foundation; MLX runs via xcodebuild fuzz path.
        // ManifoldBackends is conditional on the Fuzz trait to avoid a llama.framework
        // copy conflict with ManifoldMLXIntegrationTests in the auto-generated Xcode scheme.
        // Use scripts/fuzz.sh (which passes --traits Fuzz,MLX,Llama) to run the fuzzer.
        .executableTarget(
            name: "fuzz-chat",
            dependencies: [
                .target(name: "ManifoldFuzz", condition: .when(traits: ["Fuzz"])),
                "ManifoldInference",
                "ManifoldTestSupport",
                .target(name: "ManifoldFuzzBackends", condition: .when(traits: ["Fuzz"])),
            ],
            path: "Sources/fuzz-chat",
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
                .define("Fuzz", .when(traits: ["Fuzz"])),
            ]
        ),
        .testTarget(
            name: "ManifoldFuzzTests",
            dependencies: [
                .target(name: "ManifoldFuzz", condition: .when(traits: ["Fuzz"])),
                .target(name: "ManifoldFuzzBackends", condition: .when(traits: ["Fuzz"])),
                .target(name: "ManifoldBackends", condition: .when(traits: ["Fuzz"])),
                "ManifoldInference",
                "ManifoldTestSupport",
            ],
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
                .define("Fuzz", .when(traits: ["Fuzz"])),
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
            exclude: ["README.md"],
            resources: [
                .copy("Scenarios/built-in"),
            ]
        ),
        .executableTarget(
            name: "manifold-tools",
            dependencies: [
                .target(name: "ManifoldTools", condition: .when(traits: ["Tools"])),
                .target(name: "ManifoldBackends", condition: .when(traits: ["Tools"])),
                "ManifoldInference",
            ],
            path: "Sources/manifold-tools",
            swiftSettings: [
                .define("Tools", .when(traits: ["Tools"])),
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
            ]
        ),
        .testTarget(
            name: "ManifoldToolsTests",
            dependencies: [
                .target(name: "ManifoldTools", condition: .when(traits: ["Tools"])),
                "ManifoldInference",
                "ManifoldTestSupport",
            ],
            swiftSettings: [
                .define("Tools", .when(traits: ["Tools"])),
            ]
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
                .target(name: "ManifoldAppIntents", condition: .when(traits: ["AppIntents"])),
                "ManifoldInference",
            ],
            swiftSettings: [
                .define("AppIntents", .when(traits: ["AppIntents"])),
            ]
        ),
        // Xcode-only: real MLX model inference requiring Metal shader library.
        // Cannot run via `swift test` — MLX's metallib is only compiled by Xcode.
        // Run with: xcodebuild test -scheme ManifoldKit-Package -only-testing ManifoldMLXIntegrationTests
        .testTarget(
            name: "ManifoldMLXIntegrationTests",
            dependencies: [
                "ManifoldBackends",
                .target(name: "ManifoldMLX", condition: .when(traits: ["MLX"])),
                "ManifoldRuntime",
                "ManifoldPersistenceSwiftData",
                "ManifoldInference",
                "ManifoldTestSupport",
            ],
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
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
            ]
        ),
        // ManifoldKitTests: tests against the umbrella module's own public
        // surface. Currently hosts FeatureMatrixTests, which audits the
        // trait→capability matrix in Sources/ManifoldKit/FeatureMatrix.swift
        // against the trait list in Package.swift. Trait-free so it runs
        // under --disable-default-traits.
        .testTarget(
            name: "ManifoldKitTests",
            dependencies: [
                "ManifoldKit",
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
    ],
    swiftLanguageModes: [.v6]
)
