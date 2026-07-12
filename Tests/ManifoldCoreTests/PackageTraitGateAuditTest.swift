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
/// ## #2095 rewrite: manifest-driven instead of a hardcoded table
///
/// The original version of this test asserted against a hand-curated
/// `expectedGates` table of 4 (module, trait) pairs. Because the table was a
/// fixed set of *examples* rather than something derived from the manifest,
/// it silently stopped covering new trait-gated edges as they were added —
/// by the 2026-07-01 audit, 5 real gated edges existed that the table never
/// knew about (`ManifoldServer→ManifoldFoundation`/`→ManifoldOllama`/`→HTTPTypes`,
/// `ManifoldServerTests→HummingbirdTesting`/`→HTTPTypes`,
/// `ManifoldInferenceTests→SwiftSyntaxMacrosTestSupport`). Any of those
/// losing its gate tomorrow would have gone undetected.
///
/// The rewrite enforces the same invariant two ways:
///
/// 1. **Family rule (fully generic, no table).** Certain external products
///    and local targets exist in this package *solely* to serve one trait —
///    nothing else could legitimately depend on them unconditionally. For
///    these, the rule is: wherever the symbol appears as a dependency
///    *anywhere* in the manifest, it must carry that trait's
///    `condition: .when(traits:)`. This automatically covers future
///    consumers without a test update. Covers the `swift-syntax`-derived
///    products + `ManifoldMacrosPlugin` (Macros) and the `hummingbird` /
///    `swift-http-types`-derived products (Server).
/// 2. **Explicit dual-nature list (small, by necessity).** `ManifoldInference`,
///    `ManifoldFoundation`, and `ManifoldOllama` are ordinary general-purpose
///    targets consumed unconditionally almost everywhere — they are only
///    trait-gated in the one specific case where `ManifoldServer` depends on
///    them (so its trait-off build compiles a no-op stub). A blanket
///    by-name rule would be wrong here (it would flag their legitimate
///    unconditional uses elsewhere across dozens of other targets), so
///    these three edges stay an explicit, reviewed list scoped to their
///    specific consumer.
///
/// Post-C2 this audit also enforces the invariant carried over from the
/// original version: **no retired trait reappears**, neither as a
/// `.trait(name:)` declaration nor as a `.when(traits:)` condition. The
/// MLX/Llama families live in the manifold-mlx / manifold-llama companion
/// packages; resurrecting their traits in core means the split regressed.
///
/// The assertions are intentionally substring/brace-based and not AST-based:
/// a syntactic check is enough to catch the regression class and avoids
/// pulling SwiftSyntax into the default test build.
///
/// The three checks each live in a pure `static func` over the manifest
/// text (``ungatedTraitSymbolViolations(manifest:)``,
/// ``dualNatureEdgeViolations(manifest:)``,
/// ``traitSurfaceViolations(manifest:)``) so the in-file sabotage tests
/// exercise the exact functions the audits run.
final class PackageTraitGateAuditTest: XCTestCase {

    // MARK: - Rule 1: family-based generic gate check

    /// External-product / local-target names that exist in this package
    /// *solely* to serve one trait. Wherever one of these names appears as a
    /// dependency anywhere in the manifest, it must carry
    /// `condition: .when(traits: ["<trait>"])` for the mapped trait — no
    /// per-consumer entry needed, so a brand-new consumer of (say) a new
    /// swift-syntax product is covered automatically.
    private static let traitDefiningSymbols: [String: String] = [
        // Macros — the @ToolSchema plugin is the only thing that pulls
        // swift-syntax (~647 files) into the graph. ManifoldMacrosPlugin
        // itself is single-purpose: nothing else could legitimately depend
        // on a macro compiler plugin unconditionally.
        "ManifoldMacrosPlugin": "Macros",
        "SwiftSyntax": "Macros",
        "SwiftSyntaxMacros": "Macros",
        "SwiftSyntaxBuilder": "Macros",
        "SwiftCompilerPlugin": "Macros",
        "SwiftDiagnostics": "Macros",
        "SwiftSyntaxMacrosTestSupport": "Macros",
        // Server — Hummingbird / HTTPTypes exist in this graph only to
        // serve the HTTP server executable.
        "Hummingbird": "Server",
        "HummingbirdTesting": "Server",
        "HTTPTypes": "Server",
    ]

    /// A single (consumer target, dependency, trait) tuple for the explicit
    /// dual-nature list below.
    private struct ConsumerEdge {
        let consumer: String
        let dependency: String
        let trait: String
    }

    /// Dual-nature local targets: ordinary general-purpose targets consumed
    /// unconditionally almost everywhere, but trait-gated in this ONE
    /// specific consumer so its trait-off build stays a no-op stub. Cannot
    /// be a blanket by-name rule (see class doc) — reviewed explicitly.
    private static let dualNatureConsumerEdges: [ConsumerEdge] = [
        .init(consumer: "ManifoldServer", dependency: "ManifoldInference", trait: "Server"),
        .init(consumer: "ManifoldServer", dependency: "ManifoldFoundation", trait: "Server"),
        .init(consumer: "ManifoldServer", dependency: "ManifoldOllama", trait: "Server"),
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

    func test_traitDefiningSymbolsAreGatedWhereverReferenced() throws {
        let manifestURL = try Self.locatePackageManifest()
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        let violations = Self.ungatedTraitSymbolViolations(manifest: manifest)

        if !violations.isEmpty {
            let formatted = violations.map { "  - \($0)" }.joined(separator: "\n")
            XCTFail("""
                Package.swift trait-gating regressed. The following trait-defining
                symbols (products/targets that exist in this package solely to
                serve one trait) are referenced without their required
                `condition: .when(traits: [...])` clause.

                Violations:
                \(formatted)

                If a symbol genuinely no longer belongs to a single trait, update
                `traitDefiningSymbols` in this test in the same PR with a rationale.
                """)
        }
    }

    func test_dualNatureConsumerEdgesStayGated() throws {
        let manifestURL = try Self.locatePackageManifest()
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        let violations = Self.dualNatureEdgeViolations(manifest: manifest)

        if !violations.isEmpty {
            let formatted = violations.map { "  - \($0)" }.joined(separator: "\n")
            XCTFail("""
                Package.swift trait-gating regressed on a dual-nature consumer
                edge (a general-purpose target that's only conditionally gated
                in this one specific consumer). See issue #951 / PR #946 for the
                established pattern.

                Violations:
                \(formatted)

                If a gap is intentional (e.g. you renamed a target), update
                `dualNatureConsumerEdges` in this test in the same PR. DO NOT
                silently drop entries.
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

        let violations = Self.traitSurfaceViolations(manifest: manifest)

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

    // MARK: - Sabotage (exercises the same detection functions the audits run)

    /// Plants an ungated trait-defining-symbol dependency in a manifest
    /// snippet and asserts the REAL detection function flags it — and that
    /// the same line with the required `condition:` clause is clean.
    ///
    /// Built via string concatenation rather than a literal so this snippet
    /// doesn't itself read as a real manifest edit.
    func test_sabotage_detectsUngatedTraitDefiningSymbol() {
        let ungated = ".target(name: \"ManifoldMacrosPlugin\"),"
        let gated = ".target(name: \"ManifoldMacrosPlugin\", " + "condition: .when(traits: [\"Macros\"])),"

        let ungatedViolations = Self.ungatedTraitSymbolViolations(manifest: ungated)
        XCTAssertTrue(
            ungatedViolations.contains { $0.contains("ManifoldMacrosPlugin") },
            "The planted ungated ManifoldMacrosPlugin dependency must be flagged; got \(ungatedViolations)"
        )

        let gatedViolations = Self.ungatedTraitSymbolViolations(manifest: gated)
        XCTAssertTrue(
            gatedViolations.isEmpty,
            "A properly-gated ManifoldMacrosPlugin dependency must not be flagged; got \(gatedViolations)"
        )
    }

    /// Plants a `ManifoldServer` target block whose dependency on
    /// `ManifoldInference` is bare (no `condition:`) and asserts the REAL
    /// detection function flags it.
    func test_sabotage_detectsUngatedDualNatureEdge() {
        let manifest = """
            .target(
                name: "ManifoldServer",
                dependencies: [
                    "ManifoldInference",
                ]
            ),
            """

        let violations = Self.dualNatureEdgeViolations(manifest: manifest)
        XCTAssertTrue(
            violations.contains { $0.contains("ManifoldServer") && $0.contains("ManifoldInference") },
            "The planted bare ManifoldServer → ManifoldInference edge must be flagged; got \(violations)"
        )
    }

    /// Plants a retired-trait declaration and a retired-trait `.when(...)`
    /// reference and asserts the REAL detection function flags both.
    func test_sabotage_detectsRetiredAndUnknownTraitSurface() {
        let declaration = ".trait(name: \"MLX\"),"
        let declarationViolations = Self.traitSurfaceViolations(manifest: declaration)
        XCTAssertTrue(
            declarationViolations.contains { $0.contains("MLX") },
            "A retired trait declared via `.trait(name:)` must be flagged; got \(declarationViolations)"
        )

        let condition = "condition: " + ".when(traits: [\"Llama\"]),"
        let conditionViolations = Self.traitSurfaceViolations(manifest: condition)
        XCTAssertTrue(
            conditionViolations.contains { $0.contains("Llama") },
            "A retired trait referenced in a `.when(traits:)` condition must be flagged; got \(conditionViolations)"
        )
    }

    // MARK: - Detection

    /// Rule 1 (family-based generic gate check): every reference to a
    /// trait-defining symbol anywhere in `manifest` must carry its
    /// required `condition: .when(traits: [...])` clause. Both the audit
    /// and the sabotage test call this.
    static func ungatedTraitSymbolViolations(manifest: String) -> [String] {
        var violations: [String] = []
        for (idx, rawLine) in manifest.components(separatedBy: "\n").enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            for (symbol, trait) in Self.traitDefiningSymbols {
                guard Self.lineIsDependencyReference(trimmed, to: symbol) else { continue }
                let hasCondition = trimmed.contains("condition:")
                    && trimmed.contains(".when(")
                    && trimmed.contains("traits: [\"\(trait)\"]")
                if !hasCondition {
                    violations.append(
                        "line \(idx + 1): `\(symbol)` referenced as a dependency without `condition: .when(traits: [\"\(trait)\"])` — \(trimmed)"
                    )
                }
            }
        }
        return violations
    }

    /// Rule 2 (explicit dual-nature list): every edge in
    /// `dualNatureConsumerEdges` must be gated with its trait inside its
    /// consumer's target block in `manifest`. Both the audit and the
    /// sabotage test call this.
    static func dualNatureEdgeViolations(manifest: String) -> [String] {
        var violations: [String] = []
        for edge in Self.dualNatureConsumerEdges {
            guard let block = Self.targetBlock(in: manifest, targetName: edge.consumer) else {
                violations.append("could not locate a target block named \"\(edge.consumer)\" at all")
                continue
            }
            var found = false
            for rawLine in block.components(separatedBy: "\n") {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                guard Self.lineIsDependencyReference(trimmed, to: edge.dependency) else { continue }
                if trimmed.contains("condition:"), trimmed.contains(".when("),
                   trimmed.contains("traits: [\"\(edge.trait)\"]") {
                    found = true
                }
            }
            if !found {
                violations.append("\(edge.consumer) → \(edge.dependency) — missing `condition: .when(traits: [\"\(edge.trait)\"])`")
            }
        }
        return violations
    }

    /// Rule 3 (trait surface): only `allowedTraits` may be declared via
    /// `.trait(name:)`, and no `retiredTraits` entry may appear in any
    /// `.when(traits:)` condition in `manifest`. Both the audit and the
    /// sabotage test call this.
    static func traitSurfaceViolations(manifest: String) -> [String] {
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

        return violations
    }

    // MARK: - Helpers

    /// `true` when `trimmed` is a dependency-list reference to `symbol` —
    /// either the inline `.target(name: "X", ...)` / `.product(name: "X",
    /// ...)` / `.testTarget(name: "X", ...)` / `.executableTarget(name: "X",
    /// ...)` form (which always keeps the opening call and `name:` on one
    /// line in this manifest's style), or a bare `"X",` string-literal
    /// dependency entry. Top-level target *declarations* in this manifest
    /// always split their opening keyword (`.target(`) and `name: "X",`
    /// across two lines, so they never match this prefix check — only
    /// dependency-array elements do.
    private static func lineIsDependencyReference(_ trimmed: String, to symbol: String) -> Bool {
        let explicitPrefixes = [
            ".target(name: \"\(symbol)\"",
            ".product(name: \"\(symbol)\"",
            ".testTarget(name: \"\(symbol)\"",
            ".executableTarget(name: \"\(symbol)\"",
        ]
        if explicitPrefixes.contains(where: trimmed.hasPrefix) { return true }
        // Bare-string dependency entries (e.g. `"ManifoldRuntime",`) can
        // never carry a condition — if a trait-defining symbol appears this
        // way, it's unconditionally linked, which is itself the violation.
        return trimmed == "\"\(symbol)\"," || trimmed == "\"\(symbol)\""
    }

    /// Extracts the full text of a `.target(...)` / `.testTarget(...)` /
    /// `.executableTarget(...)` / `.macro(...)` block whose `name:` argument
    /// matches `targetName`, by brace-matching from the declaration keyword
    /// to its closing paren. Mirrors the equivalent helper in
    /// `TrafficBoundaryAuditTest`.
    private static func targetBlock(in manifest: String, targetName: String) -> String? {
        let markers = [".target(", ".testTarget(", ".executableTarget(", ".macro("]
        for marker in markers {
            var searchStart = manifest.startIndex
            while let declStart = manifest.range(of: marker, range: searchStart..<manifest.endIndex)?.lowerBound {
                var depth = 0
                var end = declStart
                var index = declStart
                while index < manifest.endIndex {
                    let character = manifest[index]
                    if character == "(" {
                        depth += 1
                    } else if character == ")" {
                        depth -= 1
                        if depth == 0 {
                            end = manifest.index(after: index)
                            break
                        }
                    }
                    index = manifest.index(after: index)
                }
                guard end > declStart else { break }
                let block = String(manifest[declStart..<end])
                if block.contains("name: \"\(targetName)\"") {
                    return block
                }
                searchStart = end
            }
        }
        return nil
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
