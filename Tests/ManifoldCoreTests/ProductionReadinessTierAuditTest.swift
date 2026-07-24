import XCTest

/// Guards `docs/PRODUCTION-READINESS.md`'s tier assignment against
/// `Package.swift`'s actual `.library` product list (issue #2337's audit
/// "stretch" item).
///
/// ## What it enforces
///
/// `docs/PRODUCTION-READINESS.md` assigns every published `.library` product
/// to exactly one of four maturity tiers (Core guarantees / Supported
/// first-party integrations / Experimental / Labs), each marked by a
/// `<!-- TIER-MANIFEST:<id> --> ... <!-- /TIER-MANIFEST -->` block — a
/// bullet list of backtick-quoted product names directly under each tier
/// heading. This is the machine-checked canonical list; the prose table
/// underneath restates the same names with rationale for human readers, but
/// only the `TIER-MANIFEST` blocks are parsed here.
///
/// Two invariants, mirroring the doc's own claim ("exhaustive +
/// non-overlapping"):
///
/// 1. Every `.library` product declared in `Package.swift` appears in at
///    least one `TIER-MANIFEST` block (exhaustive — nothing silently
///    untiered).
/// 2. No `.library` product appears in more than one `TIER-MANIFEST` block
///    (non-overlapping — a product can't quietly carry two conflicting
///    stability promises).
///
/// Scope note: this audit only tracks `.library` products (the issue's
/// stretch-item wording), not executables, and it does not flag a stale
/// tier entry for a product that was renamed or removed from `Package.swift`
/// — `extractTierMembership` only looks up names it finds; a leftover name
/// that no longer matches any `.library` product silently drops out of both
/// checks. A future tightening could add a "listed but unknown" rule
/// symmetric to the two above.
///
/// The two checks each live in a pure `static func` over (manifest text, doc
/// text) — ``tierCoverageViolations(manifest:doc:)`` — so the in-file
/// sabotage tests exercise the exact function the audit runs. Mirrors
/// `PackageTraitGateAuditTest`'s manifest-driven, function-under-test shape.
final class ProductionReadinessTierAuditTest: XCTestCase {

    private static let tierMarkerStart = "<!-- TIER-MANIFEST:"
    private static let tierMarkerEnd = "<!-- /TIER-MANIFEST -->"

    func test_everyLibraryProductIsTieredExactlyOnce() throws {
        let manifest = try Self.readManifest()
        let doc = try Self.readReadinessDoc()

        let violations = Self.tierCoverageViolations(manifest: manifest, doc: doc)

        if !violations.isEmpty {
            let formatted = violations.map { "  - \($0)" }.joined(separator: "\n")
            XCTFail("""
                docs/PRODUCTION-READINESS.md tier coverage regressed against
                Package.swift's .library product list (issue #2337). Every
                published library product must appear in exactly one
                <!-- TIER-MANIFEST:... --> block in that doc.

                Violations:
                \(formatted)

                If you added, removed, or renamed a .library product, update
                the matching TIER-MANIFEST block in
                docs/PRODUCTION-READINESS.md in the same PR.
                """)
        }
    }

    // MARK: - Sabotage (exercises the same detection function the audit runs)

    /// Plants a `.library` product in a manifest snippet that no
    /// `TIER-MANIFEST` block lists, and asserts the REAL detection function
    /// flags it as untiered.
    func test_sabotage_detectsUntieredProduct() {
        let manifest = #".library(name: "ManifoldNewThing", targets: ["ManifoldNewThing"]),"#
        let doc = """
            <!-- TIER-MANIFEST:core-guarantees -->
            - `ManifoldInference`
            <!-- /TIER-MANIFEST -->
            """

        let violations = Self.tierCoverageViolations(manifest: manifest, doc: doc)

        XCTAssertTrue(
            violations.contains { $0.contains("ManifoldNewThing") && $0.contains("no tier") },
            "A .library product absent from every TIER-MANIFEST block must be flagged; got \(violations)"
        )
    }

    /// Plants a doc where the same product is listed under two different
    /// `TIER-MANIFEST` blocks, and asserts the REAL detection function
    /// flags the overlap.
    func test_sabotage_detectsDoubleTieredProduct() {
        let manifest = #".library(name: "ManifoldInference", targets: ["ManifoldInference"]),"#
        let doc = """
            <!-- TIER-MANIFEST:core-guarantees -->
            - `ManifoldInference`
            <!-- /TIER-MANIFEST -->
            <!-- TIER-MANIFEST:experimental -->
            - `ManifoldInference`
            <!-- /TIER-MANIFEST -->
            """

        let violations = Self.tierCoverageViolations(manifest: manifest, doc: doc)

        XCTAssertTrue(
            violations.contains { $0.contains("ManifoldInference") && $0.contains("more than one tier") },
            "A product listed in two TIER-MANIFEST blocks must be flagged; got \(violations)"
        )
    }

    // MARK: - Detection

    /// Both the audit and the sabotage tests call this. Returns one
    /// human-readable violation string per untiered or double-tiered
    /// `.library` product; empty when coverage is exhaustive and
    /// non-overlapping.
    static func tierCoverageViolations(manifest: String, doc: String) -> [String] {
        let libraryProducts = extractLibraryProducts(manifest: manifest)
        let tierMembership = extractTierMembership(doc: doc)

        var violations: [String] = []
        for product in libraryProducts.sorted() {
            let tiers = tierMembership[product] ?? []
            if tiers.isEmpty {
                violations.append("`\(product)` is a .library product in Package.swift but appears in no tier (no TIER-MANIFEST block lists it)")
            } else if tiers.count > 1 {
                violations.append("`\(product)` appears in more than one tier: \(tiers.sorted().joined(separator: ", "))")
            }
        }
        return violations
    }

    /// Parses every `.library(name: "X", ...)` product declaration out of
    /// `manifest`. Executables (`.executable(name:...)`) are deliberately
    /// not matched — this audit's scope is `.library` products only.
    static func extractLibraryProducts(manifest: String) -> Set<String> {
        var found: Set<String> = []
        let pattern = #"\.library\(\s*name:\s*"([A-Za-z0-9_]+)""#
        let ns = manifest as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        regex.enumerateMatches(in: manifest, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 2 else { return }
            found.insert(ns.substring(with: m.range(at: 1)))
        }
        return found
    }

    /// Returns product name -> the set of tier IDs it's listed under,
    /// parsed from `<!-- TIER-MANIFEST:<id> --> ... <!-- /TIER-MANIFEST -->`
    /// blocks. Only `- \`Name\`` bullet lines inside a block count — prose
    /// or table cells outside the markers are ignored, so a rationale
    /// paragraph mentioning another product's name in backticks can't be
    /// mistaken for a tier assignment.
    static func extractTierMembership(doc: String) -> [String: Set<String>] {
        var membership: [String: Set<String>] = [:]
        var searchStart = doc.startIndex

        while let startRange = doc.range(of: tierMarkerStart, range: searchStart..<doc.endIndex) {
            guard let idEndRange = doc.range(of: " -->", range: startRange.upperBound..<doc.endIndex) else { break }
            let tierID = String(doc[startRange.upperBound..<idEndRange.lowerBound])

            guard let endRange = doc.range(of: tierMarkerEnd, range: idEndRange.upperBound..<doc.endIndex) else { break }
            let block = doc[idEndRange.upperBound..<endRange.lowerBound]

            for rawLine in block.components(separatedBy: "\n") {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("- `") else { continue }
                let afterOpenBacktick = trimmed.dropFirst(3)
                guard let closeBacktick = afterOpenBacktick.firstIndex(of: "`") else { continue }
                let name = String(afterOpenBacktick[..<closeBacktick])
                membership[name, default: []].insert(tierID)
            }

            searchStart = endRange.upperBound
        }

        return membership
    }

    // MARK: - File I/O

    private static func readManifest() throws -> String {
        let url = try locateRepoFile(named: "Package.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func readReadinessDoc() throws -> String {
        let url = try locateRepoFile(named: "docs/PRODUCTION-READINESS.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Walks upward from this test file to find the repo root — identified
    /// by the presence of `Package.swift`, which only exists there — then
    /// resolves `relativePath` from that root. Mirrors
    /// `PackageTraitGateAuditTest.locatePackageManifest`.
    private static func locateRepoFile(named relativePath: String, filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir.appendingPathComponent(relativePath)
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "ProductionReadinessTierAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate repo root (Package.swift) from #filePath while resolving \(relativePath)",
        ])
    }
}
