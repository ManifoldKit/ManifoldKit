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
/// ## When this actually runs (read before trusting a green PR)
///
/// This audit enumerates `Tests/**` from disk at runtime. That is a filesystem
/// dependency the Tier 2 selective-CI resolver (`scripts/affected-suites.sh`,
/// issue #1590) cannot see: it reasons about the static SwiftPM import graph,
/// and `ManifoldCoreTests` (this file's target) does not depend on whatever
/// target a new audit file lands in. So on a `pull_request` run, this audit
/// executes only if `ManifoldCoreTests` happens to be in the affected set —
/// which, for the PR shape it exists to police (a new `*Audit*.swift` added to
/// some *other* test target), it usually is not.
///
/// **A green PR check is therefore not evidence that this audit passed.** It
/// may simply not have run. This was proven live on PR #2212: the audit fails
/// on that head (`swift test --filter AuditSabotageCoverageAuditTest` → exit 1),
/// while its PR CI went green having run only `ManifoldPersistenceSwiftDataTests`.
///
/// What *is* guaranteed: `merge_group` is not `pull_request`, so the resolver
/// emits FULL there (`affected-suites.sh`, event-name gate) and the queue runs
/// this audit on every PR before the squash. Nothing merges without it. The cost
/// of the gap is therefore red-at-queue latency, not a merged hole — the same
/// accepted trade-off documented at the `Compute test mode` step in
/// `.github/workflows/ci.yml`, of which this audit is one instance.
///
/// Do not restate a per-PR guarantee here without checking the resolver first:
/// the previous version of this comment claimed "a new audit without a sabotage
/// test fails CI in the PR that adds it", which is false and is why #2212 was
/// authored, reviewed, and read as compliant while carrying a failing audit.
/// See issue #2290.
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
