import XCTest
import Foundation

/// Tripwire for the `docs/*.md` freshness-metadata convention: every
/// top-level doc (architecture notes, migration guides, positioning,
/// quickstarts, …) carries a one-line `**Audience:**` and `**Status:**`
/// header near the top so an AI assistant or a human skimming the directory
/// can tell current guidance from historical record without opening every
/// file.
///
/// This mirrors `AgentsMdPlansStatusAuditTest`'s `Status:` convention for
/// `docs/plans/*.md`, one level up — see that file for the precedent this
/// was modeled on. The two conventions are deliberately kept as separate
/// tests: plans use a single free-text `Status:` line (no controlled
/// vocabulary — "Awaiting sign-off (Rory)" is valid), while `docs/*.md`
/// headers are a fixed two-value enum on both fields, because these files
/// are meant to be filtered/queried, not just skimmed.
///
/// Values: `Audience: consumer` (app developers using ManifoldKit as a
/// dependency) or `Audience: contributor` (people changing ManifoldKit
/// itself). `Status: living` (actively accurate) or `Status: historical`
/// (describes a past decision or a completed one-time migration — still
/// worth keeping, but not the current source of truth for new work). See
/// `Tests/README.md` § "Documentation freshness headers" for the full
/// convention writeup.
///
/// Scope: `docs/*.md` only (not `docs/plans/**`, which has its own
/// `Status:`-only convention and audit) and not subdirectories under
/// `docs/` other than `plans/` — there are none today, but this test only
/// walks the top level so a future subdirectory doesn't silently need the
/// same headers without a deliberate decision.
final class DocsAudienceStatusAuditTest: XCTestCase {

    static let validAudiences: Set<String> = ["consumer", "contributor"]
    static let validStatuses: Set<String> = ["living", "historical"]

    // Leading `**`, the label, an optional `**` immediately after the label
    // (unusual but tolerated), the colon, an optional `**` after the colon
    // (the common case — `**Audience:** consumer`), then the value word.
    private static let audiencePattern = #"^\s*(\*\*)?Audience(\*\*)?\s*:\s*(\*\*)?\s*(\w+)"#
    private static let statusPattern = #"^\s*(\*\*)?Status(\*\*)?\s*:\s*(\*\*)?\s*(\w+)"#

    struct HeaderCheckResult {
        var hasAudience: Bool
        var audienceValid: Bool
        var hasStatus: Bool
        var statusValid: Bool

        var isValid: Bool { hasAudience && audienceValid && hasStatus && statusValid }
    }

    /// Scans the first `windowLines` lines of `content` for `Audience:` and
    /// `Status:` header lines and validates their values against the fixed
    /// two-value vocabularies.
    static func checkHeaders(in content: String, windowLines: Int = 15) -> HeaderCheckResult {
        guard let audienceRegex = try? NSRegularExpression(pattern: audiencePattern),
              let statusRegex = try? NSRegularExpression(pattern: statusPattern) else {
            XCTFail("Failed to compile Audience:/Status: header regexes")
            return HeaderCheckResult(hasAudience: false, audienceValid: false, hasStatus: false, statusValid: false)
        }

        var hasAudience = false
        var audienceValid = false
        var hasStatus = false
        var statusValid = false

        let lines = content.components(separatedBy: "\n").prefix(windowLines)
        for line in lines {
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)

            if let match = audienceRegex.firstMatch(in: line, range: range), match.numberOfRanges >= 5 {
                hasAudience = true
                let value = nsLine.substring(with: match.range(at: 4)).lowercased()
                if validAudiences.contains(value) { audienceValid = true }
            }
            if let match = statusRegex.firstMatch(in: line, range: range), match.numberOfRanges >= 5 {
                hasStatus = true
                let value = nsLine.substring(with: match.range(at: 4)).lowercased()
                if validStatuses.contains(value) { statusValid = true }
            }
        }

        return HeaderCheckResult(
            hasAudience: hasAudience,
            audienceValid: audienceValid,
            hasStatus: hasStatus,
            statusValid: statusValid
        )
    }

    private static func locateDocsDirectory(filePath: StaticString = #filePath) throws -> URL {
        // Tests/ManifoldInferenceTests/DocsAudienceStatusAuditTest.swift → repo root is 3 up.
        let here = URL(fileURLWithPath: "\(filePath)")
        let repoRoot = here
            .deletingLastPathComponent() // Tests/ManifoldInferenceTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // <repo>
        let docsURL = repoRoot.appendingPathComponent("docs")
        guard FileManager.default.fileExists(atPath: docsURL.path) else {
            throw XCTSkip("docs/ not found at \(docsURL.path)")
        }
        return docsURL
    }

    func testEveryTopLevelDocHasValidAudienceAndStatusHeaders() throws {
        let docsURL = try Self.locateDocsDirectory()

        let entries = try FileManager.default.contentsOfDirectory(
            at: docsURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        )

        // Top-level *.md only — docs/plans/ has its own Status:-only
        // convention and audit (AgentsMdPlansStatusAuditTest).
        let docFiles = entries.filter { $0.pathExtension == "md" }

        XCTAssertFalse(
            docFiles.isEmpty,
            "Expected at least one doc file directly under docs/ — path or filter probably wrong"
        )

        var missing: [String] = []
        for fileURL in docFiles {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let result = Self.checkHeaders(in: content)
            if !result.isValid {
                var reasons: [String] = []
                if !result.hasAudience { reasons.append("missing Audience:") }
                else if !result.audienceValid { reasons.append("invalid Audience value (want consumer|contributor)") }
                if !result.hasStatus { reasons.append("missing Status:") }
                else if !result.statusValid { reasons.append("invalid Status value (want living|historical)") }
                missing.append("\(fileURL.lastPathComponent) — \(reasons.joined(separator: ", "))")
            }
        }

        if !missing.isEmpty {
            let formatted = missing.sorted().map { "  - \($0)" }.joined(separator: "\n")
            XCTFail("""
                The following docs/*.md files are missing (or have an invalid value for) an \
                `Audience:` / `Status:` header in their first ~15 lines (see Tests/README.md \
                § "Documentation freshness headers"):

                \(formatted)

                Add two lines near the top, right after the H1 title:
                  **Audience:** consumer|contributor
                  **Status:** living|historical
                """)
        }
    }

    // MARK: - Sabotage (self-contained; see AuditSabotageCoverageAuditTest)

    /// Verifies the detection logic actually fires: a doc with no headers is
    /// flagged, one with both valid headers is not, and one with an invalid
    /// value (typo / wrong vocabulary) is flagged just like a missing one.
    func test_sabotage_missingOrInvalidHeadersAreDetected() throws {
        let missingHeaders = """
            # Some doc with no headers

            This doc has a lot of prose but never says who it's for or
            whether it's still accurate, across many lines, well past the
            fifteen-line lookback window the real audit uses.
            """
        let missingResult = Self.checkHeaders(in: missingHeaders)
        XCTAssertFalse(
            missingResult.isValid,
            "Sabotage: expected a doc with no Audience:/Status: headers to be flagged, but it was not detected"
        )

        let validHeaders = """
            # Some doc

            **Audience:** consumer
            **Status:** living

            Body text follows.
            """
        XCTAssertTrue(
            Self.checkHeaders(in: validHeaders).isValid,
            "A doc with valid bold-wrapped Audience:/Status: headers should satisfy the audit"
        )

        let bareHeaders = """
            # Some doc

            Audience: contributor
            Status: historical
            """
        XCTAssertTrue(
            Self.checkHeaders(in: bareHeaders).isValid,
            "A doc with valid bare (non-bold) Audience:/Status: headers should satisfy the audit"
        )

        let invalidValues = """
            # Some doc

            **Audience:** everyone
            **Status:** current
            """
        let invalidResult = Self.checkHeaders(in: invalidValues)
        XCTAssertFalse(
            invalidResult.isValid,
            "Sabotage: expected out-of-vocabulary Audience:/Status: values ('everyone'/'current') to be flagged, but they were not detected"
        )
        XCTAssertTrue(invalidResult.hasAudience && !invalidResult.audienceValid, "Invalid Audience value should be recognized as present-but-invalid")
        XCTAssertTrue(invalidResult.hasStatus && !invalidResult.statusValid, "Invalid Status value should be recognized as present-but-invalid")
    }
}
