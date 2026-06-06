import XCTest

/// Guards against scheme rot introduced by the Tier 2 compile-pruned selective
/// CI initiative (issue #1590).
///
/// ## Why this test exists
///
/// The per-target `.xcscheme` files in `.swiftpm/xcode/xcshareddata/xcschemes/`
/// reference targets by name via `BlueprintName` attributes.  If a target is
/// renamed or removed in `Package.swift` without updating the corresponding
/// scheme, `xcodebuild test -scheme <Name>` silently fails to resolve the
/// target — which either errors at CI or, worse, falls back to a wider build
/// graph than intended.
///
/// This test walks every `.xcscheme` file in the SwiftPM-managed scheme
/// directory, extracts every `BlueprintName` attribute, and asserts that the
/// named target still exists in `Package.swift`.  It catches renames and
/// removals in the same PR that makes the Package.swift edit.
///
/// ## What it does NOT enforce
///
/// It does not enforce the *completeness* of a scheme's `BuildActionEntries`
/// (i.e. it does not verify that the scheme lists all direct dependencies of
/// the test target).  xcodebuild resolves transitive deps from Package.swift
/// automatically; the scheme only needs the top-level library + test target.
///
/// ## Fixing a violation
///
/// Either update `BlueprintName` / `BlueprintIdentifier` in the relevant
/// `.xcscheme` to match the new target name, or delete the scheme if the
/// target no longer exists.  Do this in the same PR as the Package.swift edit.
final class SchemeSubgraphFreshnessTest: XCTestCase {

    func test_schemeBlueprintNamesReferenceExistingTargets() throws {
        let root = try Self.locatePackageRoot()

        let schemesDir = root
            .appendingPathComponent(".swiftpm/xcode/xcshareddata/xcschemes")
        let schemeFiles = try FileManager.default
            .contentsOfDirectory(at: schemesDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "xcscheme" }

        XCTAssertFalse(schemeFiles.isEmpty,
            "Expected at least one .xcscheme file in \(schemesDir.path)")

        let manifest = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8)
        let knownTargets = Self.extractTargetNames(from: manifest)

        var violations: [(scheme: String, blueprint: String)] = []

        for schemeURL in schemeFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let schemeXML = try String(contentsOf: schemeURL, encoding: .utf8)
            let names = Self.extractBlueprintNames(from: schemeXML)
            for name in names where !knownTargets.contains(name) {
                violations.append((scheme: schemeURL.lastPathComponent, blueprint: name))
            }
        }

        if !violations.isEmpty {
            let lines = violations
                .map { "  \($0.scheme): BlueprintName \"\($0.blueprint)\" not found in Package.swift" }
                .joined(separator: "\n")
            XCTFail("""
                Scheme subgraph freshness check failed.
                The following BlueprintName entries reference targets that no
                longer exist in Package.swift.  Update or delete the affected
                scheme in the same PR as the Package.swift change.

                \(lines)
                """)
        }
    }

    // MARK: - Helpers

    /// Extracts the string values of all `BlueprintName = "..."` and
    /// `BlueprintIdentifier = "..."` attributes from xcscheme XML.  Both
    /// attributes name the same target; scanning both is redundant but guards
    /// against an attribute being absent in a hand-edited scheme.
    private static func extractBlueprintNames(from xml: String) -> Set<String> {
        var names = Set<String>()
        // Matches:  BlueprintName = "SomeTargetName"
        //           BlueprintIdentifier = "SomeTargetName"
        let pattern = #"Blueprint(?:Name|Identifier)\s*=\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return names
        }
        let range = NSRange(xml.startIndex..., in: xml)
        for match in regex.matches(in: xml, range: range) {
            if let r = Range(match.range(at: 1), in: xml) {
                names.insert(String(xml[r]))
            }
        }
        return names
    }

    /// Extracts target names declared in Package.swift by scanning for
    /// `name: "..."` occurrences that appear on a line ending in a comma or
    /// following a `.target(` / `.testTarget(` / `.executableTarget(` opener.
    ///
    /// Implementation note: because target-name lines in Package.swift look
    /// like `name: "ManifoldMCP",` (the `name:` key is always first after the
    /// opener), a simple `name: "XYZ"` scan has an acceptably low false-
    /// negative rate for the drift-detection purpose here.  False positives
    /// (non-target `name:` uses) are benign — they only enlarge the known set,
    /// never cause a false failure.
    private static func extractTargetNames(from manifest: String) -> Set<String> {
        var names = Set<String>()
        let pattern = #"name:\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return names
        }
        let range = NSRange(manifest.startIndex..., in: manifest)
        for match in regex.matches(in: manifest, range: range) {
            if let r = Range(match.range(at: 1), in: manifest) {
                names.insert(String(manifest[r]))
            }
        }
        return names
    }

    /// Walks upward from this test file's location to find the repo root
    /// `Package.swift`.  Mirrors the pattern used by `PackageTraitGateAuditTest`
    /// and `UserDefaultsStandardAuditTest`.
    private static func locatePackageRoot(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(
            domain: "SchemeSubgraphFreshnessTest",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Could not locate Package.swift from #filePath"]
        )
    }
}
