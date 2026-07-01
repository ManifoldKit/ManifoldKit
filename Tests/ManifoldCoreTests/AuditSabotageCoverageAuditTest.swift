import XCTest
import Foundation

/// Meta-audit: "who watches the watchers" for the sabotage suite itself.
///
/// `ManifoldAuditSabotageSuiteTests` exists to verify that every file-walking
/// audit test actually catches known violations — but nothing enforced that
/// a *new* audit test also gets a matching sabotage case. By the 2026-07-01
/// review (issue #2095), coverage had organically drifted to 35% (7 of 20
/// audits), including the two audits backing CLAUDE.md's most-cited rules
/// (`SilentCatchAuditTest`, `UserDefaultsStandardAuditTest`). This test
/// closes that loop: it enumerates every `Tests/**/*Audit*.swift` file and
/// requires each to be "covered" by one of two mechanisms:
///
/// 1. **External sabotage coverage** — `AuditSabotageSuiteTests.swift`
///    mentions the audit's class name (every existing case does this, in a
///    doc comment or `// MARK:` naming the audit it exercises).
/// 2. **Self-contained sabotage coverage** — the audit file itself defines
///    at least one test method with "sabotage" in its name (case-
///    insensitive), the pattern `TrafficBoundaryAuditTest` uses for its own
///    inline `test_sabotage_ruleN_...` checks.
///
/// A new `*Audit*.swift` file satisfying neither fails this test — the
/// author must add sabotage coverage in the same PR, the same way adding a
/// new production audit already requires updating its own doc comment.
///
/// Deliberately not itself sabotage-covered: testing "does this
/// coverage-checker detect an uncovered audit" would need another layer of
/// temp-dir indirection for a check that's already a thin, direct file scan
/// — diminishing returns past this point.
final class AuditSabotageCoverageAuditTest: XCTestCase {

    func test_everyAuditTestHasSabotageCoverage() throws {
        let testsURL = try Self.locateTestsDirectory()
        let auditFiles = try Self.enumerateSwiftFiles(under: testsURL)
            .filter { $0.lastPathComponent.contains("Audit") }
            .filter { $0.lastPathComponent != "AuditSabotageSuiteTests.swift" }
            .filter { $0.lastPathComponent != "AuditSabotageCoverageAuditTest.swift" }

        XCTAssertFalse(auditFiles.isEmpty, "Expected to find at least one *Audit*.swift file under Tests/ — path probably wrong")

        let sabotageSuiteURL = testsURL
            .appendingPathComponent("ManifoldAuditSabotageSuiteTests")
            .appendingPathComponent("AuditSabotageSuiteTests.swift")
        let sabotageSuiteContent = (try? String(contentsOf: sabotageSuiteURL, encoding: .utf8)) ?? ""
        XCTAssertFalse(sabotageSuiteContent.isEmpty, "Could not read AuditSabotageSuiteTests.swift at \(sabotageSuiteURL.path) — path probably wrong")

        var uncovered: [String] = []
        for fileURL in auditFiles {
            let className = fileURL.deletingPathExtension().lastPathComponent
            let externallyCovered = sabotageSuiteContent.contains(className)
            let selfCovered = (try? Self.containsSelfSabotageTest(at: fileURL)) ?? false
            if !externallyCovered && !selfCovered {
                uncovered.append(className)
            }
        }

        if !uncovered.isEmpty {
            let formatted = uncovered.sorted().map { "  - \($0)" }.joined(separator: "\n")
            XCTFail("""
                The following audit tests have no sabotage coverage — nothing verifies
                they actually fire when the violation they check for is reintroduced:

                \(formatted)

                Add a matching case to Tests/ManifoldAuditSabotageSuiteTests/AuditSabotageSuiteTests.swift
                (mentioning the audit's class name), or add a self-contained
                `test_sabotage...`-named method to the audit's own file (see
                TrafficBoundaryAuditTest for the established self-contained pattern).
                """)
        }
    }

    // MARK: - Helpers

    /// `true` if `fileURL` declares at least one test method (a `func `
    /// declaration) whose name contains "sabotage" (case-insensitive).
    private static func containsSelfSabotageTest(at fileURL: URL) throws -> Bool {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        for rawLine in content.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("func ") else { continue }
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
