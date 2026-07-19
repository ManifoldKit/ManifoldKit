import XCTest
import Foundation

/// Meta-audit: "who watches the watchers" for the in-file sabotage tests.
///
/// Every file-walking / predicate audit must carry a `func test_sabotage...`
/// method **in its own file** that exercises the audit's real detection
/// function against a planted violation (see docs/QA-PRACTICES.md § 3). This
/// test closes the loop: it enumerates every `Tests/**/*Audit*.swift` file and
/// fails if any lacks such a method — so an audit can never ship without the
/// tripwire-proof that it actually fires.
///
/// ## History
///
/// Sabotage coverage originally lived in a separate nightly
/// `ManifoldAuditSabotageSuiteTests` target whose cases *reimplemented* each
/// audit's detection logic inline (SwiftPM forbids `@testable import` of test
/// targets). That proved the replica fired, not the shipped audit, and
/// replicas measurably drifted from their audits. The 2026-07 audit-hardening
/// pass converted every audit to the in-file pattern
/// (`TrafficBoundaryAuditTest`'s `test_sabotage_rule1..7` precedent) and
/// retired the suite; this meta-audit was tightened in the same pass —
/// a doc-comment *mention* of an audit no longer counts as coverage, only a
/// real `func test_sabotage...` declaration does.
///
/// ## When this actually runs
///
/// This audit enumerates `Tests/**` from disk at runtime — a filesystem
/// dependency the Tier 2 selective-CI resolver (`scripts/affected-suites.sh`)
/// cannot see from the import graph alone. Since #2290 / #2326 the resolver
/// **force-includes `ManifoldCoreTests`** (this target) whenever any
/// `Sources/**` or `Tests/**` path is in the affected set, so a new
/// `*Audit*.swift` without a `test_sabotage…` method fails on the PR head,
/// not only at `merge_group`.
///
/// `merge_group` still runs FULL as a belt-and-suspenders backstop. Do not
/// remove the force-include without restoring an equivalent fail-earlier path
/// (see issue #2290 — forcing `ManifoldBackendsTests` is not an option; it
/// routes to a full-bundle compile and can make selective slower than full).
///
/// Deliberately not itself sabotage-covered by a *file-planting* test:
/// testing "does this coverage-checker detect an uncovered audit" only needs
/// the content predicate, which `test_sabotage_predicateRequiresTestPrefixedMethod`
/// exercises directly on synthetic file contents.
final class AuditSabotageCoverageAuditTest: XCTestCase {

    func test_everyAuditTestHasSabotageCoverage() throws {
        let testsURL = try Self.locateTestsDirectory()
        let auditFiles = try Self.enumerateSwiftFiles(under: testsURL)
            .filter { $0.lastPathComponent.contains("Audit") }
            .filter { $0.lastPathComponent != "AuditSabotageCoverageAuditTest.swift" }

        XCTAssertFalse(auditFiles.isEmpty, "Expected to find at least one *Audit*.swift file under Tests/ — path probably wrong")

        var uncovered: [String] = []
        for fileURL in auditFiles {
            let className = fileURL.deletingPathExtension().lastPathComponent
            let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            if !Self.containsSelfSabotageTest(fileContent: content) {
                uncovered.append(className)
            }
        }

        if !uncovered.isEmpty {
            let formatted = uncovered.sorted().map { "  - \($0)" }.joined(separator: "\n")
            XCTFail("""
                The following audit tests have no in-file sabotage coverage — nothing
                verifies they actually fire when the violation they check for is
                reintroduced:

                \(formatted)

                Add a `func test_sabotage...` method to the audit's own file that
                calls the audit's real detection function against a planted
                violation (see docs/QA-PRACTICES.md § 3; SessionConstructionAuditTest
                is the simplest converted shape).
                """)
        }
    }

    // MARK: - Sabotage (exercises the same coverage predicate the audit runs)

    /// The coverage predicate must demand a real `func test_sabotage...`
    /// declaration — a doc-comment mention or a non-test helper with
    /// "sabotage" in its name must NOT count. (The pre-2026-07 version
    /// accepted a bare substring mention anywhere in the old suite file,
    /// which was satisfiable by a comment.)
    func test_sabotage_predicateRequiresTestPrefixedMethod() {
        XCTAssertTrue(
            Self.containsSelfSabotageTest(fileContent: """
                final class FooAuditTest: XCTestCase {
                    func test_sabotage_detectsViolation() throws {}
                }
                """),
            "A test_sabotage-prefixed method must count as coverage"
        )
        XCTAssertFalse(
            Self.containsSelfSabotageTest(fileContent: """
                // This audit is sabotage-covered elsewhere, honest.
                final class FooAuditTest: XCTestCase {
                    func makeSabotageFixture() -> String { "" }
                    func test_mainAudit() throws {}
                }
                """),
            "A comment mention or non-test sabotage-named helper must NOT count as coverage"
        )
    }

    // MARK: - Helpers

    /// `true` if `fileContent` declares at least one test method whose name
    /// starts with `test_` and contains "sabotage" (case-insensitive) —
    /// i.e. `func test_sabotage...`. Helper functions with "sabotage" in the
    /// name and prose mentions deliberately do not qualify.
    static func containsSelfSabotageTest(fileContent: String) -> Bool {
        for rawLine in fileContent.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("func test_") else { continue }
            if trimmed.lowercased().contains("sabotage") { return true }
        }
        return false
    }

    private static func locateTestsDirectory(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Tests")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "AuditSabotageCoverageAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/ from #filePath",
        ])
    }

    private static func enumerateSwiftFiles(under root: URL) throws -> [URL] {
        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            result.append(url)
        }
        return result
    }
}
