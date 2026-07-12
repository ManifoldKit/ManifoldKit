import XCTest
import Foundation

/// Tripwire for `docs/plans/README.md`'s rule that every active plan carries
/// a `Status:` line near the top.
///
/// `docs/plans/` mixes in-flight design plans with (historically) closed-out
/// ones, and nothing distinguished current direction from history for an
/// agent or contributor skimming the directory listing. The 2026-07 hygiene
/// pass deleted the fully-executed/superseded plans outright (git history is
/// the archive — see `docs/plans/README.md`) and requires every surviving
/// plan to self-report its state via a `Status:` line in the first ~20
/// lines. This test fails when a tracked `docs/plans/*.md` file (other than
/// `README.md`) is missing one, so the rule can't silently rot the way the
/// directory itself did.
///
/// Scope deliberately excludes `docs/plans/runs/` (gitignored, ephemeral
/// per-run output — see `.gitignore`) and `README.md` (the policy doc itself,
/// not a plan).
final class AgentsMdPlansStatusAuditTest: XCTestCase {

    // Allows an optional leading markdown blockquote marker (`> `) before the
    // `Status` marker — several plans state status inside a callout
    // blockquote (e.g. `> **Status:** v3 — ...`). Also allows a parenthetical
    // right after `Status` before the colon (e.g. `**Status (2026-06-24):**
    // design proposal`), so the colon isn't required to immediately follow
    // the word.
    private static let statusLinePattern = #"^\s*(>\s*)*(\*\*)?Status\b[^\n]*?:"#

    /// Returns `true` if any of the first `windowLines` lines of `content`
    /// matches a `Status:` (optionally bold-wrapped) prefix.
    static func hasStatusLine(in content: String, windowLines: Int = 20) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: statusLinePattern) else {
            XCTFail("Failed to compile Status: line regex")
            return false
        }
        let lines = content.components(separatedBy: "\n").prefix(windowLines)
        for line in lines {
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            if regex.firstMatch(in: line, range: range) != nil {
                return true
            }
        }
        return false
    }

    private static func locatePlansDirectory(filePath: StaticString = #filePath) throws -> URL {
        // Tests/ManifoldInferenceTests/AgentsMdPlansStatusAuditTest.swift → repo root is 3 up.
        let here = URL(fileURLWithPath: "\(filePath)")
        let repoRoot = here
            .deletingLastPathComponent() // Tests/ManifoldInferenceTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // <repo>
        let plansURL = repoRoot.appendingPathComponent("docs/plans")
        guard FileManager.default.fileExists(atPath: plansURL.path) else {
            throw XCTSkip("docs/plans not found at \(plansURL.path)")
        }
        return plansURL
    }

    func testEveryTopLevelPlanHasStatusLine() throws {
        let plansURL = try Self.locatePlansDirectory()

        let entries = try FileManager.default.contentsOfDirectory(
            at: plansURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        )

        let planFiles = entries.filter {
            $0.pathExtension == "md" && $0.lastPathComponent != "README.md"
        }

        XCTAssertFalse(
            planFiles.isEmpty,
            "Expected at least one plan file directly under docs/plans/ — path or filter probably wrong"
        )

        var missing: [String] = []
        for fileURL in planFiles {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            if !Self.hasStatusLine(in: content) {
                missing.append(fileURL.lastPathComponent)
            }
        }

        if !missing.isEmpty {
            let formatted = missing.sorted().map { "  - \($0)" }.joined(separator: "\n")
            XCTFail("""
                The following docs/plans/*.md files are missing a `Status:` line in their \
                first ~20 lines (see docs/plans/README.md rule 1):

                \(formatted)

                Add a line like `**Status:** Active — <one clause>` near the top, or delete \
                the file if the plan is fully executed/superseded (git history is the archive).
                """)
        }
    }

    // MARK: - Sabotage (self-contained; see AuditSabotageCoverageAuditTest)

    /// Verifies the detection logic actually fires: a plan file with no
    /// `Status:` line in its first 20 lines must be flagged, and one that has
    /// one (in either bare or bold-wrapped form) must not be.
    func test_sabotage_missingStatusLineIsDetected() throws {
        let missingStatus = """
            # Some plan with no status line

            This plan has a lot of prose but never says what state it's in,
            across many lines, well past the twenty-line lookback window that
            the real audit uses to scan for a `Status:` marker up top.
            """
        XCTAssertFalse(
            Self.hasStatusLine(in: missingStatus),
            "Sabotage: expected a plan with no Status: line to be flagged as missing one, but it was not detected"
        )

        let bareStatus = """
            # Some plan

            Status: Active — still being executed.
            """
        XCTAssertTrue(
            Self.hasStatusLine(in: bareStatus),
            "A bare `Status:` line should satisfy the audit"
        )

        let boldStatus = """
            # Some plan

            **Status:** Active — still being executed.
            """
        XCTAssertTrue(
            Self.hasStatusLine(in: boldStatus),
            "A bold-wrapped `**Status:**` line should satisfy the audit"
        )
    }
}
