// FeatureMatrix.swift
//
// Single source of truth for the trait → capability mapping.
//
// Why this exists: until now, "which trait do I need for X?" was prose
// scattered across README §2.4, CONTRIBUTING, and DefaultBackends comments.
// Drifting prose meant the answer to "do I need `CloudSaaS` or `Ollama` for
// OpenAI?" required reading three files. This file is the machine-readable
// matrix; `scripts/render-feature-matrix.sh` renders it to
// `docs/FeatureMatrix.md`, and `FeatureMatrixTests` asserts every trait in
// `Package.swift` has an entry here (failing CI when someone adds a trait
// without updating the matrix).
//
// Trait names MUST match the strings in `Package.swift`'s `traits:` block
// verbatim. `FeatureMatrixTests` enforces this both directions.

import Foundation

/// A user-facing capability that one or more traits unlock.
///
/// Capabilities are the *outcome* a consumer wants ("I want to call Claude")
/// rather than the lever they need to flip (the `CloudSaaS` trait).
public enum ManifoldCapability: String, CaseIterable, Sendable {
    case localInference          // run a model on-device
    case mlxBackend
    case llamaBackend
    case foundationBackend
    case cloudOpenAI
    case cloudClaude
    case ollama
    case toolCalling
    case visionInput
    case voiceIO
    case mcpClient
    case mcpHost
    case ragKnowledgeBase
    case imageGeneration
    case modelDownload           // HuggingFace background download
    case embeddings
    case providerBridge          // additional providers via the AnyLanguageModel bridge
}

/// A SwiftPM trait declared in `Package.swift` and the capabilities it unlocks.
///
/// `name` must match the SwiftPM trait name byte-for-byte — the audit test
/// regexes the manifest for trait names and asserts exact equality both ways.
public struct ManifoldTrait: Sendable, Hashable {
    public let name: String
    public let description: String
    public let unlocks: [ManifoldCapability]

    public init(name: String, description: String, unlocks: [ManifoldCapability]) {
        self.name = name
        self.description = description
        self.unlocks = unlocks
    }
}

public enum FeatureMatrix {
    // MARK: - Source of truth

    /// The trait roster. Order matches `Package.swift` for diff-readability;
    /// `markdown()` alphabetizes for the rendered table.
    ///
    /// When adding a trait to `Package.swift`, add it here too. If you don't
    /// know yet which capabilities it unlocks, list it with `unlocks: []` and
    /// add the name to `FeatureMatrixTests.pendingMapping` — that keeps CI
    /// green while making the gap visible.
    public static let traits: [ManifoldTrait] = [
        ManifoldTrait(
            name: "MLX",
            description: "Enable the MLX inference backend (requires Apple Silicon)",
            unlocks: [.localInference, .mlxBackend, .visionInput, .imageGeneration]
        ),
        ManifoldTrait(
            name: "Llama",
            description: "Enable the llama.cpp (GGUF) inference backend",
            unlocks: [.localInference, .llamaBackend, .embeddings]
        ),
        ManifoldTrait(
            name: "HuggingFace",
            description: "Enable HuggingFace Hub search, browse, and download",
            unlocks: [.modelDownload]
        ),
        ManifoldTrait(
            name: "AnyLanguageModel",
            description: "Reach providers without a native backend (Gemini, xAI, Groq, Mistral, OpenRouter, and others) through the AnyLanguageModel bridge.",
            unlocks: [.providerBridge]
        ),
        ManifoldTrait(
            name: "Ollama",
            description: "Self-hosted / private-datacenter HTTP inference. Moves out of defaults in next major.",
            unlocks: [.ollama, .toolCalling, .embeddings]
        ),
        ManifoldTrait(
            name: "CloudSaaS",
            description: "Third-party SaaS providers (Claude, OpenAI). Off by default.",
            unlocks: [.cloudOpenAI, .cloudClaude, .toolCalling, .visionInput]
        ),
        ManifoldTrait(
            name: "MCP",
            description: "Enable the ManifoldMCP module and MCP client surface.",
            unlocks: [.mcpClient, .mcpHost]
        ),
        ManifoldTrait(
            name: "MCPBuiltinCatalog",
            description: "Enable ManifoldMCP's built-in catalog descriptors.",
            unlocks: [.mcpClient]
        ),
        ManifoldTrait(
            name: "Voice",
            description: "Enable the ManifoldVoice speech I/O spike and voice composer UI.",
            unlocks: [.voiceIO]
        ),
        ManifoldTrait(
            name: "Tools",
            description: "Enable the ManifoldTools end-to-end tool-calling validation harness and its `manifold-tools` CLI.",
            unlocks: [.toolCalling]
        ),
        ManifoldTrait(
            name: "AppIntents",
            description: "Enable the ManifoldAppIntents AppIntent ↔ ToolDefinition bridge.",
            unlocks: [.toolCalling]
        ),
        ManifoldTrait(
            name: "Server",
            description: "Enable ManifoldServer (OpenAI-compatible HTTP server) and its Hummingbird dependency.",
            unlocks: [.embeddings]
        ),
        ManifoldTrait(
            name: "Macros",
            description: "Enable the @ToolSchema macro plugin and its swift-syntax dependency. Off by default — pulls ~647 source files into the build graph.",
            unlocks: [.toolCalling]
        ),
        ManifoldTrait(
            name: "Skills",
            description: "Enable the ManifoldSkills target: Claude-Code-compatible filesystem skill discovery (~/.claude/skills/<name>/SKILL.md) plus a single `invoke_skill` dispatch tool. macOS-only in v1 — compiles on iOS as a no-op registry.",
            unlocks: [.toolCalling]
        ),
        ManifoldTrait(
            name: "Fuzz",
            description: "Enable real inference backends in fuzz-chat (Ollama, Llama, Foundation). Required by scripts/fuzz.sh; not needed for swift test or xcodebuild test.",
            unlocks: []
            // TODO(dx-matrix): Fuzz is a test/harness lever, not a runtime
            // capability. Leaving `unlocks` empty is intentional; pending
            // mapping allowlist keeps CI green.
        ),
        ManifoldTrait(
            name: "FoundationOnly",
            description: "App Store-lean: Apple Foundation Models only. Pass `traits: [\"FoundationOnly\"]` from the consumer manifest — overrides the MLX/Llama/HuggingFace default trait set.",
            unlocks: [.foundationBackend]
        ),
        // WWDC 2026 pre-emptive stubs. No targets, no source files — pure
        // compile-condition placeholders until the frameworks ship on June 8.
        // See docs/wwdc-2026-trait-stubs.md for deferred decision points.
        ManifoldTrait(
            name: "SystemAIProviderExtension",
            description: "Stubs for the iOS 27 system AI provider extension surface (Siri/Writing Tools backend slot). No-op until WWDC 2026 ships the API.",
            unlocks: []
            // TODO(dx-matrix): post-WWDC, remove "SystemAIProviderExtension"
            // from FeatureMatrixTests.pendingMapping and add the concrete
            // ManifoldCapability cases it unlocks.
        ),
        ManifoldTrait(
            name: "CoreAI",
            description: "Placeholder for Apple's rumoured Core AI framework (Core ML successor). No-op until WWDC 2026 confirms the surface.",
            unlocks: []
            // TODO(dx-matrix): post-WWDC, remove "CoreAI" from
            // FeatureMatrixTests.pendingMapping and add the concrete
            // ManifoldCapability cases it unlocks.
        ),
    ]

    // MARK: - Lookups

    /// Traits that unlock the given capability. Order matches `traits`.
    public static func traits(unlocking capability: ManifoldCapability) -> [ManifoldTrait] {
        traits.filter { $0.unlocks.contains(capability) }
    }

    /// Capabilities the named trait unlocks. Returns `[]` if the name is unknown
    /// — callers wanting "exists?" semantics should check `traits` directly.
    public static func capabilities(for traitName: String) -> [ManifoldCapability] {
        traits.first(where: { $0.name == traitName })?.unlocks ?? []
    }

    // MARK: - Rendering

    /// GitHub-flavoured Markdown table, alphabetized by trait name.
    /// `scripts/render-feature-matrix.sh` writes this to `docs/FeatureMatrix.md`.
    public static func markdown() -> String {
        var lines: [String] = []
        lines.append("# ManifoldKit Feature Matrix")
        lines.append("")
        lines.append("Generated from `Sources/ManifoldKit/FeatureMatrix.swift` by `scripts/render-feature-matrix.sh`.")
        lines.append("Do not edit by hand — re-run the script.")
        lines.append("")
        lines.append("| Trait | Description | Capabilities Unlocked |")
        lines.append("|-------|-------------|-----------------------|")
        for trait in traits.sorted(by: { $0.name.lowercased() < $1.name.lowercased() }) {
            let caps = trait.unlocks.isEmpty
                ? "_(none — harness/build lever)_"
                : trait.unlocks.map { "`\($0.rawValue)`" }.joined(separator: ", ")
            // Escape pipes inside the description so a stray `|` doesn't break the table.
            let safeDesc = trait.description.replacingOccurrences(of: "|", with: "\\|")
            lines.append("| `\(trait.name)` | \(safeDesc) | \(caps) |")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }
}
