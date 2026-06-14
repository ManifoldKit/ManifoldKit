import XCTest

/// Guards the post-split trait surface of `Package.swift`.
///
/// History: issue #951 found several declared traits were *decorative* — the
/// trait existed in the manifest but no `condition: .when(traits:)` clause
/// was attached to the consuming dependency edges, so every
/// `swift build` still pulled the modules into the link graph. PR #946
/// established the gating pattern for the `Server` trait. The MCP /
/// MCPBuiltinCatalog traits were retired in v0.48 PR A2; Voice / Tools /
/// AppIntents / Skills in PR A3; Ollama / CloudSaaS in PR A4; and MLX /
/// Llama / HuggingFace / Fuzz / FoundationOnly in PR C2 (the companion
/// split, #1749).
///
/// Post-C2 this audit enforces two invariants:
///
/// 1. **The surviving traits stay non-decorative.** `Server` and `Macros`
///    are genuine build-cost levers (Hummingbird; swift-syntax ~647 files);
///    their consumer edges must keep `condition: .when(traits:)` clauses.
///    (The WWDC stub traits `SystemAIProviderExtension` / `CoreAI` are
///    deliberately decorative by design — no targets exist yet.)
/// 2. **No retired trait reappears.** Neither as a `.trait(name:)`
///    declaration nor as a `.when(traits:)` condition. The MLX/Llama
///    families live in the manifold-mlx / manifold-llama companion
///    packages; resurrecting their traits in core means the split regressed.
///
/// The assertions are intentionally substring-based and not AST-based: a
/// syntactic check is enough to catch the regression class and avoids
/// pulling SwiftSyntax into the default test build.
final class PackageTraitGateAuditTest: XCTestCase {

    /// Each entry is one expected `condition: .when(traits: [...])` clause
    /// on a consumer→module dependency edge. The `description` is what gets
    /// surfaced on failure.
    private struct ExpectedGate {
        let description: String
        let module: String
        let trait: String
    }

    private static let expectedGates: [ExpectedGate] = [
        // Server: the executable's deps are Server-conditional so a trait-off
        // build compiles the no-op stub without Hummingbird or the backend
        // graph (PR #946 pattern).
        .init(description: "ManifoldServer → ManifoldInference", module: "ManifoldInference", trait: "Server"),
        .init(description: "ManifoldServer → Hummingbird", module: "Hummingbird", trait: "Server"),

        // Macros: the @ToolSchema plugin is the only thing that pulls
        // swift-syntax (~647 files) into the graph.
        .init(description: "ManifoldInference → ManifoldMacrosPlugin", module: "ManifoldMacrosPlugin", trait: "Macros"),
        .init(description: "ManifoldMacrosPlugin → SwiftSyntax", module: "SwiftSyntax", trait: "Macros"),
    ]

    /// The complete allowed trait set post-C2. Anything else in the manifest
    /// is a regression (or needs a deliberate update here in the same PR).
    private static let allowedTraits: Set<String> = [
        "Server",
        "Macros",
        // WWDC 2026 pre-emptive stubs — no targets, deliberately decorative.
        "SystemAIProviderExtension",
        "CoreAI",
    ]

    /// Traits retired across the v0.48 train. Their reappearance — as a
    /// declaration or a `.when(traits:)` condition — means a retired gating
    /// shape crept back in.
    private static let retiredTraits: Set<String> = [
        "MCP", "MCPBuiltinCatalog",            // PR A2
        "Voice", "Tools", "AppIntents", "Skills", // PR A3
        "Ollama", "CloudSaaS",                 // PR A4
        "AnyLanguageModel",                    // PR A5
        "MLX", "Llama", "HuggingFace", "Fuzz", "FoundationOnly", // PR C2
    ]

    func test_packageManifestDeclaresExpectedTraitGates() throws {
        let manifestURL = try Self.locatePackageManifest()
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        var violations: [String] = []
        for gate in Self.expectedGates {
            if !Self.manifest(manifest, declaresGate: gate) {
                violations.append("\(gate.description) — missing `condition: .when(traits: [\"\(gate.trait)\"])` on the `name: \"\(gate.module)\"` edge")
            }
        }

        if !violations.isEmpty {
            let formatted = violations.map { "  - \($0)" }.joined(separator: "\n")
            XCTFail("""
                Package.swift trait-gating regressed. The following consumer→module
                edges no longer carry their expected `condition: .when(traits: [...])`
                clause. See issue #951 and PR #946 for the established pattern.

                Violations:
                \(formatted)

                If a gap is intentional (e.g. you renamed a target), update
                `expectedGates` in this test in the same PR. DO NOT silently
                drop entries.
                """)
        }
    }

    /// Post-C2: only the surviving traits may be declared, and no retired
    /// trait may appear in any `.when(traits:)` condition. One un-gated (or
    /// re-gated) edge is enough to reintroduce the dep-graph inflation #951
    /// closed — or, worse, a phantom trait consumers can't satisfy.
    func test_packageManifestDeclaresOnlySurvivingTraits() throws {
        let manifestURL = try Self.locatePackageManifest()
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        var violations: [String] = []

        // Declared traits.
        for trait in Self.declaredTraits(in: manifest) {
            if !Self.allowedTraits.contains(trait) {
                violations.append("`.trait(name: \"\(trait)\")` declared — not in the post-C2 allowed set \(Self.allowedTraits.sorted())")
            }
        }

        // `.when(traits:)` conditions referencing retired traits.
        for rawLine in manifest.components(separatedBy: "\n") {
            guard rawLine.contains(".when(traits:") else { continue }
            for retired in Self.retiredTraits where rawLine.contains("\"\(retired)\"") {
                violations.append("retired trait `\(retired)` referenced in condition: \(rawLine.trimmingCharacters(in: .whitespaces))")
            }
        }

        if !violations.isEmpty {
            let formatted = violations.map { "  - \($0)" }.joined(separator: "\n")
            XCTFail("""
                Package.swift references traits outside the post-C2 surface
                (survivors: Server, Macros + the WWDC stubs). The MLX/Llama
                families live in the manifold-mlx / manifold-llama companion
                packages (#1749) — retired traits must not reappear.

                Violations:
                \(formatted)

                If a new trait is intentional, add it to `allowedTraits` in
                this test in the same PR with a rationale.
                """)
        }
    }

    // MARK: - Helpers

    /// Whether `manifest` contains a dependency line that names `gate.module`
    /// AND attaches `condition: .when(traits: ["<trait>"])`. The manifest
    /// declaration spans one logical line in practice, so a single line scan
    /// is sufficient. Matches both `.target(name:)` and `.product(name:)`.
    private static func manifest(_ manifest: String, declaresGate gate: ExpectedGate) -> Bool {
        let needleNamePart = "name: \"\(gate.module)\""
        let needleTraitPart = "traits: [\"\(gate.trait)\"]"

        for rawLine in manifest.components(separatedBy: "\n") {
            if rawLine.contains(needleNamePart),
               rawLine.contains("condition:"),
               rawLine.contains(".when("),
               rawLine.contains(needleTraitPart) {
                return true
            }
        }
        return false
    }

    /// Parses `.trait(name: "X", ...)` declarations out of the manifest.
    private static func declaredTraits(in manifest: String) -> Set<String> {
        var found: Set<String> = []
        let pattern = #"\.trait\(\s*name:\s*"([A-Za-z_][A-Za-z0-9_]*)""#
        let ns = manifest as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        regex.enumerateMatches(in: manifest, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 2 else { return }
            found.insert(ns.substring(with: m.range(at: 1)))
        }
        return found
    }

    /// Walks upward from this test file to find the repo root's
    /// `Package.swift`. Mirrors `UserDefaultsStandardAuditTest.locateTestsDirectory`
    /// (sibling fixture-pathing pattern).
    private static func locatePackageManifest(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "PackageTraitGateAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Package.swift from #filePath",
        ])
    }
}
