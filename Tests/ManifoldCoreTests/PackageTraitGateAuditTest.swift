import XCTest

/// Guards against regressions on issue #951: `Package.swift` must keep the
/// five optional modules — `ManifoldMCP`, `ManifoldVoice`, `ManifoldTools`,
/// `ManifoldAppIntents`, and `ManifoldFuzz` (plus its `ManifoldFuzzBackends`
/// sibling) — gated behind their declared traits. Mirrors the pattern PR #946
/// established for the `Server` trait around `ManifoldServer`.
///
/// ## Why this matters
///
/// The audit in #951 found that several declared traits (`MCP`, `Voice`,
/// `Tools`, `AppIntents`, `Fuzz`) were *decorative* — the trait existed in
/// the manifest but no `condition: .when(traits:)` clause was attached to the
/// dependency edges that consumed those modules. As a result every
/// `swift build --disable-default-traits` invocation still pulled the modules
/// into the link graph, paying the per-PR CI build cost the trait was
/// supposed to amortise away.
///
/// This test reads `Package.swift` text at runtime and asserts that the
/// expected dependency declarations carry their gating clause. A drop or
/// rename in a future Package.swift edit fails this test before CI ever
/// gets to compilation, surfacing the regression at the smallest signal.
///
/// ## What this test enforces
///
/// For each consumer→module edge listed in `expectedGates`, a substring
/// match against `Package.swift` confirms the dependency line contains
/// `condition: .when(traits: ["<Trait>"])`. The assertion is intentionally
/// substring-based and not AST-based: a syntactic check is enough to catch
/// the regression class (someone deleting the `condition:` clause), and
/// avoids pulling SwiftSyntax into the default-trait test build (~647-file
/// dep tree gated behind the `Macros` trait).
///
/// ## Fixing a violation
///
/// Re-add `condition: .when(traits: ["<Trait>"])` to the failing edge. See
/// PR #946 (the `Server` trait pattern) and the `ManifoldHuggingFaceTests`
/// declaration block for live examples of the shape.
///
/// DO NOT relax the assertion to allow the gap. The whole point of the
/// audit is that one un-gated edge is enough to reintroduce the dep-graph
/// inflation issue #951 closed.
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
        // ManifoldMCP — gated by MCP across both test consumers.
        .init(description: "ManifoldMCPTests → ManifoldMCP", module: "ManifoldMCP", trait: "MCP"),
        .init(description: "ManifoldMCPE2ETests → ManifoldMCP", module: "ManifoldMCP", trait: "MCP"),

        // ManifoldVoice — gated by Voice on the test target. The library
        // target's product declaration stays unconditional (apps importing
        // it must opt the trait in via their consumer manifest), but the
        // in-tree test consumer must carry the gate so swift test
        // --disable-default-traits doesn't link Voice symbols.
        .init(description: "ManifoldVoiceTests → ManifoldVoice", module: "ManifoldVoice", trait: "Voice"),

        // ManifoldTools — gated by Tools across the manifold-tools CLI, the test
        // target, and the ManifoldE2ETests scenario consumer. The
        // ManifoldBackends edge inside manifold-tools is also Tools-gated so the
        // executable doesn't pull llama.framework into the auto-generated
        // Xcode scheme when Tools is off.
        .init(description: "manifold-tools → ManifoldTools", module: "ManifoldTools", trait: "Tools"),
        .init(description: "manifold-tools → ManifoldBackends", module: "ManifoldBackends", trait: "Tools"),
        .init(description: "ManifoldToolsTests → ManifoldTools", module: "ManifoldTools", trait: "Tools"),
        .init(description: "ManifoldE2ETests → ManifoldTools", module: "ManifoldTools", trait: "Tools"),

        // ManifoldAppIntents — gated by AppIntents on the test target.
        .init(description: "ManifoldAppIntentsTests → ManifoldAppIntents", module: "ManifoldAppIntents", trait: "AppIntents"),

        // ManifoldFuzz / ManifoldFuzzBackends — gated by Fuzz at the
        // consumer edges (fuzz-chat CLI and ManifoldFuzzTests). The
        // internal edges from ManifoldFuzzBackends to ManifoldFuzz /
        // ManifoldBackends are intentionally unconditional: ManifoldFuzzBackends
        // source files `import ManifoldBackends` unconditionally, so gating
        // those internal edges on Fuzz makes the target fail compilation
        // under `--traits Macros` (no Fuzz). The target compiles always;
        // nothing in the default trait set imports it, so it never gets
        // linked into a default-traits binary.
        .init(description: "fuzz-chat → ManifoldFuzz", module: "ManifoldFuzz", trait: "Fuzz"),
        .init(description: "fuzz-chat → ManifoldFuzzBackends", module: "ManifoldFuzzBackends", trait: "Fuzz"),
        .init(description: "ManifoldFuzzTests → ManifoldFuzz", module: "ManifoldFuzz", trait: "Fuzz"),
        .init(description: "ManifoldFuzzTests → ManifoldFuzzBackends", module: "ManifoldFuzzBackends", trait: "Fuzz"),
    ]

    func test_packageManifestDeclaresExpectedTraitGates() throws {
        let manifestURL = try Self.locatePackageManifest()
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        var violations: [String] = []
        for gate in Self.expectedGates {
            // Sample shape (whitespace-loose): `.target(name: "ManifoldMCP", condition: .when(traits: ["MCP"]))`.
            // We accept either single or double quotes and any reasonable
            // whitespace inside the `traits: [...]` array; the trait name
            // must appear inside that array literal on a line that also
            // names the module.
            if !Self.manifest(manifest, declaresGate: gate) {
                violations.append("\(gate.description) — missing `condition: .when(traits: [\"\(gate.trait)\"])` on the `.target(name: \"\(gate.module)\", …)` edge")
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

    // MARK: - Helpers

    /// Whether `manifest` contains a `.target(...)` dependency line that
    /// names `gate.module` AND attaches `condition: .when(traits: ["<trait>"])`.
    /// The manifest declaration spans one logical line in practice
    /// (matches `ManifoldHuggingFaceTests`-style formatting), so a single
    /// line scan is sufficient.
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
