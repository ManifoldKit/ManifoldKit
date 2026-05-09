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
//     defaults drop out and BaseChatBackends compiles to FoundationBackend +
//     cloud-stub bodies only (no MLX checkout, no LlamaSwift xcframework, no
//     swift-huggingface). Mutual exclusion with MLX/Llama/HuggingFace is
//     enforced by the consumer override semantics, not by the package itself.
//   - The CI gate `foundation-only-build` (`.github/workflows/ci.yml`)
//     enforces a ≤ 5 MB BaseChatBackends artifact and zero MLX/Llama symbol
//     leaks under the FoundationOnly trait.

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "BaseChatKit",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "BaseChatInference", targets: ["BaseChatInference"]),
        .library(name: "BaseChatMCP", targets: ["BaseChatMCP"]),
        .library(name: "BaseChatRuntime", targets: ["BaseChatRuntime"]),
        .library(name: "BaseChatPersistenceSwiftData", targets: ["BaseChatPersistenceSwiftData"]),
        .library(name: "BaseChatBackends", targets: ["BaseChatBackends"]),
        .library(name: "BaseChatUI", targets: ["BaseChatUI"]),
        .library(name: "BaseChatUIModelManagement", targets: ["BaseChatUIModelManagement"]),
        .library(name: "BaseChatHuggingFace", targets: ["BaseChatHuggingFace"]),
        .library(name: "BaseChatAnyLanguageModelBridge", targets: ["BaseChatAnyLanguageModelBridge"]),
        .library(name: "BaseChatVoice", targets: ["BaseChatVoice"]),
        .library(name: "BaseChatFuzz", targets: ["BaseChatFuzz"]),
        .executable(name: "fuzz-chat", targets: ["fuzz-chat"]),
        .library(name: "BaseChatTools", targets: ["BaseChatTools"]),
        .executable(name: "bck-tools", targets: ["bck-tools"]),
        .library(name: "BaseChatAppIntents", targets: ["BaseChatAppIntents"]),
        .executable(name: "BaseChatServer", targets: ["BaseChatServer"]),
    ],
    traits: [
        .default(enabledTraits: ["MLX", "Llama", "HuggingFace"]),
        .trait(name: "MLX", description: "Enable the MLX inference backend (requires Apple Silicon)"),
        .trait(name: "Llama", description: "Enable the llama.cpp (GGUF) inference backend"),
        .trait(name: "HuggingFace", description: "Enable HuggingFace Hub search, browse, and download"),
        .trait(name: "AnyLanguageModel", description: "Enable the AnyLanguageModel bridge backend target."),
        .trait(name: "Ollama", description: "Self-hosted / private-datacenter HTTP inference. Moves out of defaults in next major."),
        .trait(name: "CloudSaaS", description: "Third-party SaaS providers (Claude, OpenAI). Off by default."),
        .trait(name: "MCP", description: "Enable the BaseChatMCP module and MCP client surface."),
        .trait(name: "MCPBuiltinCatalog", description: "Enable BaseChatMCP's built-in catalog descriptors."),
        .trait(name: "Voice", description: "Enable the BaseChatVoice speech I/O spike and voice composer UI."),
        .trait(name: "Tools", description: "Enable the BaseChatTools end-to-end tool-calling validation harness and its `bck-tools` CLI."),
        .trait(name: "AppIntents", description: "Enable the BaseChatAppIntents AppIntent ↔ ToolDefinition bridge."),
        .trait(name: "Server", description: "Enable BaseChatServer (OpenAI-compatible HTTP server) and its Hummingbird dependency."),
        .trait(name: "Macros", description: "Enable the @ToolSchema macro plugin and its swift-syntax dependency. Off by default — pulls ~647 source files into the build graph."),
        // Fuzz is intentionally NOT a default trait. Enabling it adds BaseChatBackends
        // (and transitively LlamaSwift) to fuzz-chat, which conflicts with the MLX
        // integration test targets in the auto-generated Xcode scheme. Run the fuzzer via
        // scripts/fuzz.sh, which passes --traits Fuzz,MLX,Llama explicitly.
        .trait(name: "Fuzz", description: "Enable real inference backends in fuzz-chat (Ollama, Llama, Foundation). Required by scripts/fuzz.sh; not needed for swift test or xcodebuild test."),
        // FoundationOnly is an explicit App Store-lean marker. Consumers that
        // pass `traits: ["FoundationOnly"]` override the default trait set
        // (which is MLX + Llama + HuggingFace), so BaseChatBackends compiles
        // without MLX, llama.cpp, or swift-huggingface — keeping the BCK
        // overhead under 5 MB and dropping ~700 MB of binary dependencies
        // from the resolved graph. Apple Foundation Models still work via
        // FoundationBackend (iOS 26 / macOS 26+). See docs/AppStoreSubmission.md.
        .trait(name: "FoundationOnly", description: "App Store-lean: Apple Foundation Models only. Pass `traits: [\"FoundationOnly\"]` from the consumer manifest — overrides the MLX/Llama/HuggingFace default trait set."),
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.31.3"),
        // 3.31.3 ships the decoupled MLXHuggingFace target (the original reason for the
        // manual revision pin) and adds the `gemma4` model_type to LLMTypeRegistry so
        // mlx-community/gemma-4-* can load.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", from: "3.31.3"),
        // mlx-swift-examples was previously a direct dependency for StableDiffusion.
        // Its package manifest declared platforms: iOS 16 while depending on mlx-swift
        // which requires iOS 17, causing a SPM platform-validation error for consumers.
        // The StableDiffusion source (9 files, MIT) is now vendored in Sources/StableDiffusion.
        // If upstream resolves the platform conflict and cuts a new tag, revert to the
        // package dependency. Tracked in umbrella issue #1002.
        .package(url: "https://github.com/huggingface/swift-huggingface.git", from: "0.9.0"),
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
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
    ],
    targets: [
        // Macro compiler plugin: implements @ToolSchema. Runs at build time in
        // the compiler's plugin host, not in app binaries. Only target that
        // pulls swift-syntax into the graph — gated behind the `Macros` trait
        // (off by default) so the ~647-file swift-syntax tree stays out of
        // default builds. Consumers using `@ToolSchema` must add `--traits Macros`.
        .macro(
            name: "BaseChatMacrosPlugin",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax", condition: .when(traits: ["Macros"])),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax", condition: .when(traits: ["Macros"])),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax", condition: .when(traits: ["Macros"])),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax", condition: .when(traits: ["Macros"])),
                .product(name: "SwiftDiagnostics", package: "swift-syntax", condition: .when(traits: ["Macros"])),
            ],
            path: "Sources/BaseChatMacrosPlugin",
            swiftSettings: [
                .define("Macros", .when(traits: ["Macros"])),
            ]
        ),
        // Inference: models, protocols, services — no SwiftData, no heavy ML deps.
        // Hosts the @ToolSchema attribute declaration so callers get the macro
        // for free wherever JSONSchemaValue is in scope. The macro plugin and
        // its swift-syntax dependency are trait-gated (`Macros`, off by
        // default); the `Sources/BaseChatInference/Macros/ToolSchema.swift`
        // declaration is wrapped in `#if Macros` so the public API is only
        // visible when the trait is enabled.
        .target(
            name: "BaseChatInference",
            dependencies: [
                .target(name: "BaseChatMacrosPlugin", condition: .when(traits: ["Macros"])),
            ],
            path: "Sources/BaseChatInference",
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
        // MCP: Model Context Protocol client surface and tool bridge.
        .target(
            name: "BaseChatMCP",
            dependencies: ["BaseChatInference"],
            path: "Sources/BaseChatMCP",
            swiftSettings: [
                .define("MCPBuiltinCatalog", .when(traits: ["MCPBuiltinCatalog"])),
            ]
        ),
        // Runtime: ports (EndpointStore, SamplerPresetStore, BenchmarkCache),
        // use cases (PromptContextPipeline, ChatExportService, SessionListService),
        // and session-list orchestration. No SwiftData, no SwiftUI, no Observation.
        .target(
            name: "BaseChatRuntime",
            dependencies: [
                .target(name: "BaseChatInference"),
            ],
            path: "Sources/BaseChatRuntime"
        ),
        // PersistenceSwiftData: SwiftData schema (@Model types), container factory,
        // SwiftData adapter implementations, and the full-stack bootstrap class.
        .target(
            name: "BaseChatPersistenceSwiftData",
            dependencies: [
                .target(name: "BaseChatRuntime"),
                .target(name: "BaseChatInference"),
            ],
            path: "Sources/BaseChatPersistenceSwiftData"
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
        // Backends: MLX, llama.cpp, Foundation, cloud
        .target(
            name: "BaseChatBackends",
            dependencies: [
                "BaseChatInference",
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
                // Vendored StableDiffusion (Sources/StableDiffusion), used by MLXDiffusionBackend.
                // Replaces the mlx-swift-examples package dep which had a platform conflict (iOS 16 vs iOS 17).
                .target(name: "StableDiffusion", condition: .when(traits: ["MLX"])),
                .product(name: "LlamaSwift", package: "llama.swift", condition: .when(traits: ["Llama"])),
            ],
            path: "Sources/BaseChatBackends",
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
                .define("FoundationOnly", .when(traits: ["FoundationOnly"])),
            ]
        ),
        // UI: SwiftUI views and view models — depends on runtime ports, not persistence adapters.
        .target(
            name: "BaseChatUI",
            dependencies: ["BaseChatRuntime", "BaseChatInference"],
            path: "Sources/BaseChatUI",
            swiftSettings: [
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
            ]
        ),
        // Model management UI: download/storage browser, API endpoint editors,
        // remote-server configuration. Peeled out of BaseChatUI in v2.0 so a
        // chat-only host can ship without ~1,800 LOC of management surface.
        // Depends on BaseChatUI (the moved views consume `ChatViewModel` via
        // `@Environment`); BaseChatUI MUST NOT depend on this target — that
        // would close the dep cycle. The CI lint in `.github/workflows/ci.yml`
        // enforces this.
        .target(
            name: "BaseChatUIModelManagement",
            dependencies: [
                "BaseChatUI",
                "BaseChatRuntime",
                "BaseChatInference",
                .target(name: "BaseChatHuggingFace", condition: .when(traits: ["HuggingFace"])),
            ],
            path: "Sources/BaseChatUIModelManagement",
            swiftSettings: [
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
            ]
        ),
        .target(
            name: "BaseChatHuggingFace",
            dependencies: [
                "BaseChatInference",
                .product(name: "HuggingFace", package: "swift-huggingface", condition: .when(traits: ["HuggingFace"])),
            ],
            path: "Sources/BaseChatHuggingFace",
            swiftSettings: [
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
            ]
        ),
        .target(
            name: "BaseChatAnyLanguageModelBridge",
            dependencies: [
                "BaseChatInference",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel", condition: .when(traits: ["AnyLanguageModel"])),
            ],
            path: "Sources/BaseChatAnyLanguageModelBridge",
            swiftSettings: [
                .define("AnyLanguageModel", .when(traits: ["AnyLanguageModel"])),
            ]
        ),
        // Voice: optional speech-recognition / synthesis adapters plus chat UI accessories.
        .target(
            name: "BaseChatVoice",
            dependencies: ["BaseChatUI"],
            path: "Sources/BaseChatVoice",
            swiftSettings: [
                .define("Voice", .when(traits: ["Voice"])),
            ]
        ),
        // Shared test mocks and utilities
        .target(
            name: "BaseChatTestSupport",
            dependencies: [
                "BaseChatRuntime",
                "BaseChatPersistenceSwiftData",
                "BaseChatInference",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
            ],
            path: "Sources/BaseChatTestSupport",
            exclude: ["FuzzCalibrationCorpus"],
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
            ]
        ),
        .testTarget(
            name: "BaseChatCoreTests",
            dependencies: [
                "BaseChatRuntime",
                "BaseChatPersistenceSwiftData",
                "BaseChatInference",
                "BaseChatTestSupport",
            ]
        ),
        // BaseChatRuntime-only tests: protocol contracts, value types, and
        // services that don't import SwiftData. Tests that exercise both
        // BaseChatRuntime and BaseChatPersistenceSwiftData (e.g. the
        // adapter-against-port integrations) stay in BaseChatCoreTests.
        .testTarget(
            name: "BaseChatRuntimeTests",
            dependencies: [
                "BaseChatRuntime",
                "BaseChatInference",
                "BaseChatTestSupport",
            ]
        ),
        // BaseChatPersistenceSwiftData-only tests: SwiftData @Model schema,
        // ModelContainerFactory, BaseChatBootstrap, and the SwiftData adapter
        // implementations of the runtime ports.
        .testTarget(
            name: "BaseChatPersistenceSwiftDataTests",
            dependencies: [
                "BaseChatPersistenceSwiftData",
                "BaseChatRuntime",
                "BaseChatInference",
                "BaseChatTestSupport",
            ]
        ),
        // Tests for the shared test-helper module itself (e.g. `withTimeout`).
        // Kept as a dedicated target so hang-sabotage helpers don't accrete
        // inside product-suite test targets and so they can be exercised
        // with `swift test --filter BaseChatTestSupportTests`.
        .testTarget(
            name: "BaseChatTestSupportTests",
            dependencies: ["BaseChatTestSupport"]
        ),
        .testTarget(
            name: "BaseChatInferenceTests",
            dependencies: [
                "BaseChatInference",
                "BaseChatTestSupport",
                .target(name: "BaseChatMacrosPlugin", condition: .when(traits: ["Macros"])),
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
        // Swift Testing suites split from BaseChatInferenceTests to prevent a
        // libmalloc double-free SIGABRT that occurs when XCTest and Swift Testing
        // harnesses both initialise in the same process (~25% of CI runs).
        .testTarget(
            name: "BaseChatInferenceSwiftTestingTests",
            dependencies: ["BaseChatInference", "BaseChatTestSupport"]
        ),
        .testTarget(
            name: "BaseChatMCPTests",
            dependencies: [
                .target(name: "BaseChatMCP", condition: .when(traits: ["MCP"])),
                "BaseChatInference",
                "BaseChatTestSupport",
            ],
            resources: [.copy("Fixtures")],
            swiftSettings: [
                .define("MCP", .when(traits: ["MCP"])),
            ]
        ),
        .testTarget(
            name: "BaseChatMCPE2ETests",
            dependencies: [
                .target(name: "BaseChatMCP", condition: .when(traits: ["MCP"])),
                "BaseChatInference",
                "BaseChatTestSupport",
            ],
            swiftSettings: [
                .define("MCP", .when(traits: ["MCP"])),
            ]
        ),
        .testTarget(
            name: "BaseChatBackendsTests",
            dependencies: [
                "BaseChatBackends",
                "BaseChatUI",
                "BaseChatRuntime",
                "BaseChatPersistenceSwiftData",
                "BaseChatInference",
                "BaseChatTestSupport",
                .product(name: "MLXLMCommon", package: "mlx-swift-lm", condition: .when(traits: ["MLX"])),
            ],
            swiftSettings: [
                .define("MLX", .when(traits: ["MLX"])),
                .define("Llama", .when(traits: ["Llama"])),
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
                .define("FoundationOnly", .when(traits: ["FoundationOnly"])),
            ]
        ),
        .testTarget(
            name: "BaseChatUITests",
            dependencies: [
                "BaseChatUI",
                "BaseChatRuntime",
                "BaseChatPersistenceSwiftData",
                "BaseChatInference",
                "BaseChatTestSupport",
                .product(name: "ViewInspector", package: "ViewInspector"),
            ]
        ),
        .testTarget(
            name: "BaseChatVoiceTests",
            dependencies: [
                .target(name: "BaseChatVoice", condition: .when(traits: ["Voice"])),
                .product(name: "ViewInspector", package: "ViewInspector"),
            ],
            swiftSettings: [
                .define("Voice", .when(traits: ["Voice"])),
            ]
        ),
        .testTarget(
            name: "BaseChatUIModelManagementTests",
            dependencies: [
                "BaseChatUIModelManagement",
                "BaseChatUI",
                "BaseChatRuntime",
                "BaseChatPersistenceSwiftData",
                "BaseChatInference",
                "BaseChatTestSupport",
            ],
            swiftSettings: [
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
            ]
        ),
        .testTarget(
            name: "BaseChatHuggingFaceTests",
            dependencies: [
                .target(name: "BaseChatHuggingFace", condition: .when(traits: ["HuggingFace"])),
                "BaseChatInference",
                "BaseChatTestSupport",
                .product(name: "HuggingFace", package: "swift-huggingface", condition: .when(traits: ["HuggingFace"])),
            ],
            path: "Tests/BaseChatHuggingFaceTests",
            swiftSettings: [
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
            ]
        ),
        .testTarget(
            name: "BaseChatAnyLanguageModelBridgeTests",
            dependencies: [
                .target(name: "BaseChatAnyLanguageModelBridge", condition: .when(traits: ["AnyLanguageModel"])),
                "BaseChatInference",
                .product(name: "AnyLanguageModel", package: "AnyLanguageModel", condition: .when(traits: ["AnyLanguageModel"])),
            ],
            path: "Tests/BaseChatAnyLanguageModelBridgeTests",
            swiftSettings: [
                .define("AnyLanguageModel", .when(traits: ["AnyLanguageModel"])),
            ]
        ),
        // BaseChatServer: OpenAI-compatible HTTP server. Shipped as a single
        // executable target — the routing layer, trait-aware backend provider,
        // and `@main` entry point all live here. Trait-gated behind `Server`,
        // which also conditionally pulls in Hummingbird. Without the trait the
        // target compiles to a no-op stub that prints a "trait not enabled"
        // message (see `BaseChatServerCommand.swift`).
        //
        // BaseChatBackends and BaseChatInference are also `Server`-conditional
        // for the same reason `fuzz-chat`'s BaseChatBackends dep is `Fuzz`-
        // conditional (see comment on the `Fuzz` trait above): an unconditional
        // BaseChatBackends dep on a second executable in the auto-generated
        // `BaseChatKit-Package` Xcode scheme produces two `Copy llama.framework`
        // tasks that collide on the same output path — breaking
        // `xcodebuild test -only-testing BaseChatMLXIntegrationTests`. Gating
        // the deps keeps `bck-tools` as the sole executable that pulls
        // llama.framework into the auto-scheme. See issue #982.
        .executableTarget(
            name: "BaseChatServer",
            dependencies: [
                .target(name: "BaseChatInference", condition: .when(traits: ["Server"])),
                .target(name: "BaseChatBackends", condition: .when(traits: ["Server"])),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Hummingbird", package: "hummingbird", condition: .when(traits: ["Server"])),
            ],
            path: "Sources/BaseChatServer",
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
            name: "BaseChatServerTests",
            dependencies: [
                "BaseChatServer",
                "BaseChatInference",
                "BaseChatTestSupport",
                .product(name: "HummingbirdTesting", package: "hummingbird", condition: .when(traits: ["Server"])),
            ],
            swiftSettings: [
                .define("Server", .when(traits: ["Server"])),
            ]
        ),
        .testTarget(
            name: "BaseChatE2ETests",
            dependencies: [
                "BaseChatBackends",
                "BaseChatUI",
                "BaseChatRuntime",
                "BaseChatPersistenceSwiftData",
                "BaseChatInference",
                "BaseChatTestSupport",
                .target(name: "BaseChatTools", condition: .when(traits: ["Tools"])),
                .target(name: "BaseChatHuggingFace", condition: .when(traits: ["HuggingFace"])),
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
            name: "BaseChatSnapshotTests",
            dependencies: [
                "BaseChatUI",
                "BaseChatUIModelManagement",
                "BaseChatRuntime",
                "BaseChatPersistenceSwiftData",
                "BaseChatInference",
                "BaseChatTestSupport",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            exclude: ["__Snapshots__"],
            swiftSettings: [
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
            ]
        ),
        // Fuzzing engine: corpus, runner, capture, detectors, sink. Backend-agnostic.
        // Trait-free so it never pulls MLX/Llama transitively — backend selection
        // happens in `BaseChatFuzzBackends` (importable real-backend factories),
        // `fuzz-chat` (CLI), and `BaseChatFuzzTests` (XCTest harness).
        .target(
            name: "BaseChatFuzz",
            dependencies: ["BaseChatInference"],
            path: "Sources/BaseChatFuzz",
            resources: [.process("Resources")]
        ),
        // Importable real-backend factories for fuzz campaigns. Shared by the
        // CLI and the Xcode-hosted MLX fuzz tests so XCTest can reuse the same
        // wiring without importing the `fuzz-chat` executable target.
        .target(
            name: "BaseChatFuzzBackends",
            dependencies: [
                "BaseChatFuzz",
                "BaseChatInference",
                "BaseChatBackends",
            ],
            path: "Sources/BaseChatFuzzBackends",
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
        // BaseChatBackends is conditional on the Fuzz trait to avoid a llama.framework
        // copy conflict with BaseChatMLXIntegrationTests in the auto-generated Xcode scheme.
        // Use scripts/fuzz.sh (which passes --traits Fuzz,MLX,Llama) to run the fuzzer.
        .executableTarget(
            name: "fuzz-chat",
            dependencies: [
                .target(name: "BaseChatFuzz", condition: .when(traits: ["Fuzz"])),
                "BaseChatInference",
                "BaseChatTestSupport",
                .target(name: "BaseChatFuzzBackends", condition: .when(traits: ["Fuzz"])),
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
            name: "BaseChatFuzzTests",
            dependencies: [
                .target(name: "BaseChatFuzz", condition: .when(traits: ["Fuzz"])),
                .target(name: "BaseChatFuzzBackends", condition: .when(traits: ["Fuzz"])),
                .target(name: "BaseChatBackends", condition: .when(traits: ["Fuzz"])),
                "BaseChatInference",
                "BaseChatTestSupport",
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
        // BaseChatTools: end-to-end tool-calling validation harness.
        // Ships a fixed reference toolset (now, calc, read_file, list_dir,
        // http_get_fixture), a declarative scenario runner, and a JSONL
        // transcript logger. Library target so the test suite can exercise
        // the runner against in-process scripted backends; the CLI lives in
        // the `bck-tools` executable target below.
        .target(
            name: "BaseChatTools",
            dependencies: [
                "BaseChatInference",
            ],
            path: "Sources/BaseChatTools",
            exclude: ["README.md"],
            resources: [
                .copy("Scenarios/built-in"),
            ]
        ),
        .executableTarget(
            name: "bck-tools",
            dependencies: [
                .target(name: "BaseChatTools", condition: .when(traits: ["Tools"])),
                .target(name: "BaseChatBackends", condition: .when(traits: ["Tools"])),
                "BaseChatInference",
            ],
            path: "Sources/bck-tools",
            swiftSettings: [
                .define("Tools", .when(traits: ["Tools"])),
                .define("Ollama", .when(traits: ["Ollama"])),
                .define("CloudSaaS", .when(traits: ["CloudSaaS"])),
                .define("HuggingFace", .when(traits: ["HuggingFace"])),
            ]
        ),
        .testTarget(
            name: "BaseChatToolsTests",
            dependencies: [
                .target(name: "BaseChatTools", condition: .when(traits: ["Tools"])),
                "BaseChatInference",
                "BaseChatTestSupport",
            ],
            swiftSettings: [
                .define("Tools", .when(traits: ["Tools"])),
            ]
        ),
        // BaseChatAppIntents: AppIntent ↔ ToolDefinition bridge.
        // Lets hosts expose any AppIntent as a model-callable tool by deriving
        // the JSON-Schema parameters from `@Parameter` reflection. Trait-free
        // and depends only on BaseChatInference so apps can opt in without
        // pulling AppIntents on platforms / module graphs that don't need it.
        .target(
            name: "BaseChatAppIntents",
            dependencies: ["BaseChatInference"],
            path: "Sources/BaseChatAppIntents"
        ),
        .testTarget(
            name: "BaseChatAppIntentsTests",
            dependencies: [
                .target(name: "BaseChatAppIntents", condition: .when(traits: ["AppIntents"])),
                "BaseChatInference",
            ],
            swiftSettings: [
                .define("AppIntents", .when(traits: ["AppIntents"])),
            ]
        ),
        // Xcode-only: real MLX model inference requiring Metal shader library.
        // Cannot run via `swift test` — MLX's metallib is only compiled by Xcode.
        // Run with: xcodebuild test -scheme BaseChatKit-Package -only-testing BaseChatMLXIntegrationTests
        .testTarget(
            name: "BaseChatMLXIntegrationTests",
            dependencies: [
                "BaseChatBackends",
                "BaseChatRuntime",
                "BaseChatPersistenceSwiftData",
                "BaseChatInference",
                "BaseChatTestSupport",
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
                "BaseChatInference",
                "BaseChatRuntime",
                "BaseChatPersistenceSwiftData",
                "BaseChatTestSupport",
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
