// FeatureMatrix.swift
//
// Single source of truth for the trait → capability mapping.
//
// Why this exists: until now, "which trait do I need for X?" was prose
// scattered across README §2.4, CONTRIBUTING, and DefaultBackends comments.
// Drifting prose meant the answer to "which trait unlocks X?" required
// reading three files. This file is the machine-readable matrix; `scripts/render-feature-matrix.sh` renders it to
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
/// rather than the lever they need to flip (a SwiftPM trait).
public enum ManifoldCapability: String, CaseIterable, Sendable {
    case localInference          // run a model on-device
    case mlxBackend
    case llamaBackend
    case foundationBackend
    // cloudOpenAI/cloudClaude/ollama are no longer unlocked by any trait —
    // the cloud families compile unconditionally as of v0.48 (Ollama +
    // CloudSaaS traits retired in PR A4). Cases stay: removing public enum
    // cases is a separate API break with no consumer benefit.
    case cloudOpenAI
    case cloudClaude
    case ollama
    case toolCalling
    case visionInput
    case voiceIO
    // mcpClient/mcpHost are no longer unlocked by any trait — ManifoldMCP and
    // ManifoldMCPHost compile unconditionally as of v0.48 (MCP +
    // MCPBuiltinCatalog traits retired). Cases stay: removing public enum
    // cases is a separate API break with no consumer benefit.
    case mcpClient
    case mcpHost
    case ragKnowledgeBase
    case imageGeneration
    case modelDownload           // HuggingFace background download
    case embeddings
    // providerBridge (the AnyLanguageModel bridge) was removed in #2435:
    // zero adoption, and the capability it named no longer exists at all —
    // unlike the cloudOpenAI/mcpClient precedent above, there is no
    // still-shipping feature this case could describe under a different
    // access path, so the "removing a case has no consumer benefit" argument
    // that kept those cases does not apply here. See
    // docs/MIGRATION-anylanguagemodel-retired.md.
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
        // MLX / Llama / HuggingFace / Fuzz / FoundationOnly retired in v0.48
        // (PR C2, #1749): the MLX and llama.cpp families live in the
        // manifold-mlx / manifold-llama companion packages; HuggingFace
        // download machinery compiles unconditionally; the fuzz harness
        // compiles unconditionally; FoundationOnly's lean-build job is the
        // plain default build now. Their capability cases stay on
        // ManifoldCapability (removing public enum cases is a separate API
        // break with no consumer benefit) — they are simply no longer
        // unlocked by any core trait.
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
        // WWDC 2026 pre-emptive stubs. No targets, no source files — pure
        // compile-condition placeholders. Resolved against the macOS 27 beta
        // SDK 2026-06-16 (#1577); see docs/wwdc-2026-trait-stubs.md.
        ManifoldTrait(
            name: "SystemAIProviderExtension",
            description: "Stub: a third-party \"system AI provider\" backend slot — anticipated pre-WWDC but NOT found in the macOS 27 beta SDK (no SystemAIProvider symbol anywhere). The real third-party model seam is FoundationModels.LanguageModelExecutor (macOS 27/iOS 27). Pure no-op stub.",
            unlocks: []
            // The anticipated extension point does not exist in the beta SDK.
            // The real seam is FoundationModels.LanguageModelExecutor, but
            // adopting it forks tool-loop ownership to FoundationModels and
            // belongs in the companion mlx/llama repos — a deferred either/or
            // (docs/wwdc-2026-trait-stubs.md). Stays in pendingMapping while
            // unlocks is empty; do NOT remove until a real capability lands.
        ),
        ManifoldTrait(
            name: "CoreAI",
            description: "No-op stub: the bare CoreAI tensor runtime is not a backend seam, while apple/coreai-models exposes CoreAILanguageModel through FoundationModels.LanguageModelExecutor. A future integration would consume that package rather than this trait.",
            unlocks: []
            // Resolved shape documented in docs/wwdc-2026-trait-stubs.md. Stays in
            // pendingMapping while unlocks is empty; do NOT remove until a real
            // capability lands. Trait rename is out of scope for the docs PR.
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
        lines.append("**Audience:** consumer")
        lines.append("**Status:** living")
        lines.append("")
        lines.append("Generated from `Sources/ManifoldKit/FeatureMatrix.swift` by `scripts/render-feature-matrix.sh`.")
        lines.append("Do not edit by hand — re-run the script.")
        lines.append("")
        lines.append("> **Remaining SwiftPM traits only.** This table lists the opt-in traits still")
        lines.append("> declared in `Package.swift` (`Macros`, `Server`, and WWDC stubs) — it is")
        lines.append("> **not** a full product or backend capability map. Most capabilities compile")
        lines.append("> unconditionally in core, or ship in the `manifold-mlx` / `manifold-llama`")
        lines.append("> companion packages. For the real surface see [AGENTS.md](../AGENTS.md)")
        lines.append("> (products) and [COMPANION-BACKENDS.md](COMPANION-BACKENDS.md).")
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
