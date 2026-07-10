import XCTest

/// Guards the arch-plan 4.4 split (wave2 P2, PR #2195): `ManifoldTestSupport`
/// must stay free of the persistence stack, and the persistence-dependent
/// test mocks must stay in the dedicated `ManifoldPersistenceTestSupport`
/// target.
///
/// ## Why this matters
///
/// Before the split, `ManifoldTestSupport` unconditionally depended on
/// `ManifoldPersistenceSwiftData` even though only 3 of its ~41 files needed
/// it — so the "zero-dependency" leaf test suites (Hardware/Secrets/
/// Networking) and both companion repos (manifold-mlx / manifold-llama)
/// linked the whole SwiftData/persistence stack to get one mock. The split
/// is only worth anything while that edge stays severed: one convenience
/// `import ManifoldPersistenceSwiftData` added back to a `ManifoldTestSupport`
/// source file (plus the manifest dep to make it compile) silently
/// re-imposes the persistence stack on every downstream consumer.
///
/// ## What this test enforces
///
/// 1. `Package.swift`'s `ManifoldTestSupport` target declaration does NOT
///    list `ManifoldPersistenceSwiftData` (or `ManifoldPersistenceTestSupport`,
///    which would be a dependency cycle) among its dependencies.
/// 2. No file under `Sources/ManifoldTestSupport/` imports `SwiftData` or
///    `ManifoldPersistenceSwiftData` (top-level, `@testable`, or
///    `@_exported` forms).
/// 3. `Sources/ManifoldPersistenceTestSupport/` exists, is non-empty, and
///    `Package.swift` declares the `ManifoldPersistenceTestSupport` target.
///    (Sentinel against an "accidental" merge that deletes the split.)
///
/// ## Fixing a violation
///
/// Do not add persistence edges back to `ManifoldTestSupport`. A test
/// helper that needs SwiftData / `ManifoldPersistenceSwiftData` belongs in
/// `Sources/ManifoldPersistenceTestSupport/` (which already depends on
/// `ManifoldTestSupport`, so it can build on the pure-engine mocks).
///
/// Mirrors `ContractTestSupportSplitAuditTest` (the #1409 XCTest-edge
/// tripwire) — same mechanism, adjacent invariant.
final class PersistenceTestSupportSplitAuditTest: XCTestCase {

    private static let bannedModules = ["SwiftData", "ManifoldPersistenceSwiftData"]

    func test_manifoldTestSupportTarget_hasNoPersistenceDependency() throws {
        let manifest = try Self.manifestText()
        let block = try XCTUnwrap(
            Self.targetBlock(named: "ManifoldTestSupport", in: manifest),
            "Package.swift must declare a target named ManifoldTestSupport."
        )

        for banned in ["\"ManifoldPersistenceSwiftData\"", "\"ManifoldPersistenceTestSupport\""] {
            XCTAssertFalse(
                block.contains(banned),
                """
                The ManifoldTestSupport target must not depend on \(banned) —
                the arch-plan 4.4 split exists so pure-engine consumers
                (companion repos, leaf test suites) don't link the persistence
                stack. Persistence-dependent helpers belong in
                ManifoldPersistenceTestSupport. See this file's doc comment.
                """
            )
        }
    }

    func test_manifoldTestSupportSources_doNotImportPersistence() throws {
        let supportDir = try Self.repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("ManifoldTestSupport")

        let enumerator = FileManager.default.enumerator(atPath: supportDir.path)
        var offenders: [String] = []
        while let relative = enumerator?.nextObject() as? String {
            guard relative.hasSuffix(".swift") else { continue }
            let url = supportDir.appendingPathComponent(relative)
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if Self.isBannedImportLine(trimmed) {
                    offenders.append("\(relative): \(trimmed)")
                    break
                }
            }
        }

        XCTAssertTrue(
            offenders.isEmpty,
            """
            Sources/ManifoldTestSupport/ must not import SwiftData or
            ManifoldPersistenceSwiftData — persistence-dependent test helpers
            belong in Sources/ManifoldPersistenceTestSupport/ (arch-plan 4.4
            split). Offenders: \(offenders)
            """
        )
    }

    func test_persistenceTestSupport_targetAndSourcesExist() throws {
        let repoRoot = try Self.repoRoot()
        let dir = repoRoot
            .appendingPathComponent("Sources")
            .appendingPathComponent("ManifoldPersistenceTestSupport")

        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir)
        XCTAssertTrue(exists && isDir.boolValue,
                      "Sources/ManifoldPersistenceTestSupport/ must exist as a directory (arch-plan 4.4 split).")

        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(contents.filter { $0.hasSuffix(".swift") }.isEmpty,
                       "Sources/ManifoldPersistenceTestSupport/ must contain at least one Swift file.")

        let manifest = try Self.manifestText()
        XCTAssertNotNil(
            Self.targetBlock(named: "ManifoldPersistenceTestSupport", in: manifest),
            "Package.swift must declare a target named ManifoldPersistenceTestSupport. See this file's doc comment."
        )
    }

    // MARK: - Sabotage self-checks
    //
    // Self-contained sabotage coverage (the TrafficBoundaryAuditTest
    // pattern, enforced by AuditSabotageCoverageAuditTest): verify the
    // detection helpers actually fire on the violations they guard against,
    // using in-memory fixtures. Also verified live once at introduction
    // (PR #2195): re-adding the ManifoldPersistenceSwiftData dep to
    // Package.swift and an `import SwiftData` line to TestHelpers.swift made
    // both real checks fail; reverting made them pass.

    func test_sabotage_manifestCheck_catchesReaddedDependency() throws {
        func fixtureManifest(testSupportDeps: [String]) -> String {
            let deps = testSupportDeps.map { "\"\($0)\"," }.joined(separator: "\n                ")
            return """
            let package = Package(
                targets: [
                    .target(
                        name: "ManifoldTestSupport",
                        dependencies: [
                            \(deps)
                        ],
                        path: "Sources/ManifoldTestSupport"
                    ),
                    .testTarget(
                        name: "ManifoldTestSupportTests",
                        dependencies: ["ManifoldTestSupport"]
                    ),
                ]
            )
            """
        }

        let sabotagedManifest = fixtureManifest(
            testSupportDeps: ["ManifoldRuntime", "ManifoldPersistenceSwiftData", "ManifoldInference"]
        )
        let block = try XCTUnwrap(
            Self.targetBlock(named: "ManifoldTestSupport", in: sabotagedManifest),
            "Block extraction should find the ManifoldTestSupport target"
        )
        XCTAssertTrue(block.contains("\"ManifoldPersistenceSwiftData\""),
                      "Sabotaged manifest must trip the dependency check")
        // Exact-name matching: the extracted block must be the target itself,
        // not the ManifoldTestSupportTests block that merely references it.
        XCTAssertTrue(block.contains("path: \"Sources/ManifoldTestSupport\""),
                      "Extraction must return the ManifoldTestSupport target block, not the test target")

        let cleanManifest = fixtureManifest(
            testSupportDeps: ["ManifoldRuntime", "ManifoldInference"]
        )
        let cleanBlock = try XCTUnwrap(Self.targetBlock(named: "ManifoldTestSupport", in: cleanManifest))
        XCTAssertFalse(cleanBlock.contains("\"ManifoldPersistenceSwiftData\""),
                       "Clean manifest must not trip the dependency check")
    }

    func test_sabotage_importScan_catchesPersistenceImports() {
        let offendingLines = [
            "import SwiftData",
            "import ManifoldPersistenceSwiftData",
            "@testable import ManifoldPersistenceSwiftData",
            "@_exported import SwiftData",
            "import struct SwiftData.ModelConfiguration",
        ]
        for line in offendingLines {
            XCTAssertTrue(Self.isBannedImportLine(line),
                          "Import scan should trip on: \(line)")
        }

        let innocentLines = [
            "import Foundation",
            "import ManifoldRuntime",
            "import ManifoldTestSupport",
            // Comment mentions of the banned module names must stay inert.
            "// NOTE: makeInMemoryContainer() (needs SwiftData + ManifoldPersistenceSwiftData)",
            "let container = try ModelContainerFactory.makeInMemoryContainer()",
        ]
        for line in innocentLines {
            XCTAssertFalse(Self.isBannedImportLine(line),
                           "Import scan must not trip on: \(line)")
        }
    }

    // MARK: - Helpers

    /// `true` when a trimmed source line is an import of a banned persistence
    /// module. Token-wise match so `import SwiftData`, `@testable import
    /// SwiftData`, and `@_exported import SwiftData` all trip, and scoped
    /// forms (`import struct SwiftData.X`) are caught by the prefix check.
    /// Comment lines are excluded so prose mentions of the module names
    /// (e.g. the relocation NOTE in TestHelpers.swift) stay inert.
    private static func isBannedImportLine(_ trimmed: String) -> Bool {
        guard !trimmed.hasPrefix("//") else { return false }
        let tokens = trimmed.split(separator: " ").map(String.init)
        guard tokens.contains("import") else { return false }
        return tokens.contains(where: { token in
            bannedModules.contains(token)
                || bannedModules.contains(where: { token.hasPrefix($0 + ".") })
        })
    }

    /// Extracts the `.target(...)` / `.testTarget(...)` block declaring the
    /// given exact target name, by brace matching from the declaration to the
    /// matching close paren (same mechanism as
    /// `ContractTestSupportSplitAuditTest`). Exact-name match: the search
    /// needle includes the closing quote, so "ManifoldTestSupport" does not
    /// match the "ManifoldTestSupportTests" block.
    private static func targetBlock(named name: String, in manifest: String) -> String? {
        let needle = "name: \"\(name)\""
        var searchRange = manifest.startIndex..<manifest.endIndex
        for opener in [".target(", ".testTarget(", ".executableTarget("] {
            searchRange = manifest.startIndex..<manifest.endIndex
            while let declRange = manifest.range(of: opener, range: searchRange) {
                var depth = 1
                var index = declRange.upperBound
                while index < manifest.endIndex, depth > 0 {
                    let char = manifest[index]
                    if char == "(" { depth += 1 }
                    if char == ")" { depth -= 1 }
                    index = manifest.index(after: index)
                }
                let block = String(manifest[declRange.lowerBound..<index])
                if block.contains(needle) {
                    return block
                }
                searchRange = index..<manifest.endIndex
            }
        }
        return nil
    }

    private static func manifestText() throws -> String {
        let packageURL = try repoRoot().appendingPathComponent("Package.swift")
        return try String(contentsOf: packageURL, encoding: .utf8)
    }

    private static func repoRoot() throws -> URL {
        // This test file lives at Tests/ManifoldCoreTests/<this>.swift.
        // Walk up two directories to reach the package root.
        let thisFile = URL(fileURLWithPath: #filePath)
        return thisFile
            .deletingLastPathComponent()  // ManifoldCoreTests/
            .deletingLastPathComponent()  // Tests/
            .deletingLastPathComponent()  // repo root
    }
}
