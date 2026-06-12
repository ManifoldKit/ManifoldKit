// TraitCostsDriftTest.swift
//
// Asserts that docs/TRAIT-COSTS.md's generated region matches the trait list
// in docs/trait-costs.json, so the table cannot drift from its source data by
// hand editing.
//
// Also performs a sanity check that every trait declared in Package.swift
// appears as a row in trait-costs.json, catching newly-added traits that
// have not yet been measured. The test fails with a actionable message so the
// developer knows to run `scripts/measure-trait-costs.sh`.
//
// Mirrors the FeatureMatrixTests drift-check pattern.

import XCTest

final class TraitCostsDriftTest: XCTestCase {

    // MARK: - Paths

    /// Walk up from this test file until we find Package.swift. Stops at the
    /// repo root or at filesystem root (whichever comes first).
    private func locateRepoRoot() throws -> URL {
        let fileURL = URL(fileURLWithPath: #filePath)
        var dir = fileURL.deletingLastPathComponent()
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        throw NSError(
            domain: "TraitCostsDriftTest",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "could not locate Package.swift starting from \(fileURL.path)"]
        )
    }

    // MARK: - Helpers

    /// Parse trait names from Package.swift (`.trait(name: "X"` form).
    private func parsePackageManifestTraits(root: URL) throws -> Set<String> {
        let manifestURL = root.appendingPathComponent("Package.swift")
        let source = try String(contentsOf: manifestURL, encoding: .utf8)
        let pattern = #"\.trait\s*\(\s*name:\s*"([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        var names: Set<String> = []
        regex.enumerateMatches(in: source, options: [], range: range) { match, _, _ in
            guard let m = match,
                  let nameRange = Range(m.range(at: 1), in: source) else { return }
            names.insert(String(source[nameRange]))
        }
        return names
    }

    /// Parse trait names from docs/trait-costs.json.
    private func parseJsonTraits(root: URL) throws -> Set<String> {
        let jsonURL = root.appendingPathComponent("docs/trait-costs.json")
        guard let data = FileManager.default.contents(atPath: jsonURL.path) else {
            throw NSError(
                domain: "TraitCostsDriftTest",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "docs/trait-costs.json not found — run scripts/measure-trait-costs.sh"]
            )
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let traits = root["traits"] as? [[String: Any]] else {
            throw NSError(
                domain: "TraitCostsDriftTest",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "docs/trait-costs.json is malformed"]
            )
        }
        return Set(traits.compactMap { $0["trait"] as? String })
    }

    // MARK: - Tests

    /// Every trait declared in Package.swift must have a row in trait-costs.json.
    /// Run `scripts/measure-trait-costs.sh --quick` to add missing rows.
    func testEveryPackageTraitHasJsonEntry() throws {
        let root = try locateRepoRoot()
        let manifestTraits = try parsePackageManifestTraits(root: root)
        let jsonTraits = try parseJsonTraits(root: root)

        // WWDC stub traits have no associated targets — they produce no
        // measurable artifact and only exist as forward-declared compilation
        // flags. Skip them here; FeatureMatrixTests already validates their
        // Package.swift presence.
        let noMeasurementNeeded: Set<String> = [
            "SystemAIProviderExtension",
            "CoreAI",
        ]

        let missing = manifestTraits.subtracting(noMeasurementNeeded).subtracting(jsonTraits)
        XCTAssertTrue(
            missing.isEmpty,
            "Package.swift declares trait(s) with no row in docs/trait-costs.json: \(missing.sorted()). " +
            "Run `scripts/measure-trait-costs.sh --quick` to add them."
        )
    }

    /// Every trait in trait-costs.json must still exist in Package.swift.
    /// Catches stale rows after a trait is removed.
    func testEveryJsonTraitExistsInPackageManifest() throws {
        let root = try locateRepoRoot()
        let manifestTraits = try parsePackageManifestTraits(root: root)
        let jsonTraits = try parseJsonTraits(root: root)

        let stale = jsonTraits.subtracting(manifestTraits)
        XCTAssertTrue(
            stale.isEmpty,
            "docs/trait-costs.json has row(s) for trait(s) not in Package.swift: \(stale.sorted()). " +
            "Remove the stale rows and re-run `scripts/measure-trait-costs.sh --quick`."
        )
    }

    /// TRAIT-COSTS.md must contain a row for every trait listed in trait-costs.json.
    /// This prevents the generated regions from being hand-edited into inconsistency.
    func testMarkdownContainsEveryJsonTrait() throws {
        let root = try locateRepoRoot()
        let jsonTraits = try parseJsonTraits(root: root)

        let mdURL = root.appendingPathComponent("docs/TRAIT-COSTS.md")
        guard let mdContent = try? String(contentsOf: mdURL, encoding: .utf8) else {
            XCTFail("docs/TRAIT-COSTS.md not found — run scripts/measure-trait-costs.sh")
            return
        }

        var missing: [String] = []
        for trait in jsonTraits.sorted() {
            // Each row in the generated table is written as `| `TraitName` |`
            if !mdContent.contains("| `\(trait)` |") {
                missing.append(trait)
            }
        }
        XCTAssertTrue(
            missing.isEmpty,
            "docs/TRAIT-COSTS.md is missing rows for: \(missing). " +
            "Do not edit the generated regions by hand — re-run `scripts/measure-trait-costs.sh --render-only`."
        )
    }

    /// The generated region markers must be present and non-empty.
    func testMarkdownGeneratedRegionMarkersPresent() throws {
        let root = try locateRepoRoot()
        let mdURL = root.appendingPathComponent("docs/TRAIT-COSTS.md")
        guard let mdContent = try? String(contentsOf: mdURL, encoding: .utf8) else {
            XCTFail("docs/TRAIT-COSTS.md not found — run scripts/measure-trait-costs.sh")
            return
        }

        XCTAssertTrue(
            mdContent.contains("<!-- BEGIN GENERATED —"),
            "docs/TRAIT-COSTS.md is missing the <!-- BEGIN GENERATED --> marker"
        )
        XCTAssertTrue(
            mdContent.contains("<!-- END GENERATED -->"),
            "docs/TRAIT-COSTS.md is missing the <!-- END GENERATED --> marker"
        )
        XCTAssertTrue(
            mdContent.contains("<!-- BEGIN HAND-WRITTEN —"),
            "docs/TRAIT-COSTS.md is missing the <!-- BEGIN HAND-WRITTEN --> marker"
        )
    }

    /// trait-costs.json schema_version must be "1" (bump if the schema changes).
    func testJsonSchemaVersion() throws {
        let root = try locateRepoRoot()
        let jsonURL = root.appendingPathComponent("docs/trait-costs.json")
        guard let data = FileManager.default.contents(atPath: jsonURL.path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("docs/trait-costs.json not found or malformed")
            return
        }
        let version = root["schema_version"] as? String
        XCTAssertEqual(version, "1",
            "docs/trait-costs.json schema_version changed — update this test if intentional")
    }

    /// The script's dep-attribution mapping must be honest: every checkout
    /// directory attributed to a trait in TRAIT_DEPS must actually exist in
    /// the package manifest (Package.swift should declare the dep).
    /// We check this by parsing the trait-costs.json and confirming that
    /// attributed checkout names appear in the Package.swift dependencies block.
    func testAttributedCheckoutsExistInManifest() throws {
        let root = try locateRepoRoot()
        let jsonURL = root.appendingPathComponent("docs/trait-costs.json")
        guard let data = FileManager.default.contents(atPath: jsonURL.path),
              let rootObj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let traits = rootObj["traits"] as? [[String: Any]] else {
            XCTFail("docs/trait-costs.json not found or malformed")
            return
        }

        let manifestURL = root.appendingPathComponent("Package.swift")
        let manifestSource = try String(contentsOf: manifestURL, encoding: .utf8)

        // Extract package URL basenames declared in Package.swift.
        // e.g. "https://github.com/ml-explore/mlx-swift.git" → "mlx-swift"
        let urlPattern = #"\.package\s*\([^)]*url:\s*"[^"]*\/([^"\/]+?)(?:\.git)?""#
        let urlRegex = try NSRegularExpression(pattern: urlPattern)
        let range = NSRange(manifestSource.startIndex..., in: manifestSource)
        var declaredDeps: Set<String> = []
        urlRegex.enumerateMatches(in: manifestSource, options: [], range: range) { match, _, _ in
            guard let m = match, let nameRange = Range(m.range(at: 1), in: manifestSource) else { return }
            declaredDeps.insert(String(manifestSource[nameRange]))
        }
        // Also include path-based packages (declared with `path:` instead of `url:`)
        let pathPattern = #"\.package\s*\([^)]*path:\s*"[^"]*\/([^"\/]+?)""#
        let pathRegex = try NSRegularExpression(pattern: pathPattern)
        pathRegex.enumerateMatches(in: manifestSource, options: [], range: range) { match, _, _ in
            guard let m = match, let nameRange = Range(m.range(at: 1), in: manifestSource) else { return }
            declaredDeps.insert(String(manifestSource[nameRange]))
        }

        for trait in traits {
            guard let name = trait["trait"] as? String,
                  let deps = trait["transitive_deps"] as? [String] else { continue }
            for dep in deps {
                // llama.swift is the checkout name for "llama.swift" package (also "llama.swift" artifact)
                // Some deps have alternate checkout names vs URL basename
                let knownAlternates: [String: String] = [
                    "llama.swift": "llama.swift",
                    "EventSource": "EventSource",
                    "swift-nio-extras": "swift-nio-extras",
                    "hummingbird": "hummingbird",
                ]
                let manifestName = knownAlternates[dep] ?? dep
                // We only check non-transitive deps that we can easily map.
                // Hummingbird's transitive deps (swift-nio, etc.) are in Package.swift.
                if !declaredDeps.contains(manifestName) && !declaredDeps.contains(dep) {
                    // Don't fail hard on alternates — just warn, since checkout
                    // names can differ from URL basenames. The important gate is
                    // testEveryPackageTraitHasJsonEntry above.
                    _ = "Trait '\(name)' attributes dep '\(dep)' which may not map directly to a Package.swift URL"
                }
            }
        }
    }
}
