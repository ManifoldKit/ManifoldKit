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
///
/// ## Stale-plan expiry (#2226)
///
/// Presence of a `Status:` line only proves a plan *once* self-reported its
/// state — it says nothing about whether that self-report is still true. A
/// plan can sit at `Status: Awaiting sign-off` (or any other non-"Active"
/// value) for months with zero commits and still read as current work to
/// anyone skimming the directory. `testNoStaleNonActivePlan` closes that gap:
/// a plan whose `Status:` value does not start with "Active" *and* whose most
/// recent `git log` commit touching the file is older than
/// `staleNonActivePlanThresholdDays` fails the audit, forcing a human to
/// either delete the plan or explicitly revive it (bump status to Active, or
/// touch the file with a real update).
///
/// **Non-flakiness.** The age check uses `git log -1 --format=%ct -- <path>`
/// (commit time, not file mtime — mtime is unreliable across clones/CI
/// checkouts per the issue). A shallow clone, a detached/gitless checkout, or
/// any non-zero/unparseable `git` result yields `lastCommitDate(for:) ==
/// nil`, and `isStale` treats `nil` as "cannot determine age" → never stale.
/// The check can only ever suppress a false positive, never manufacture one
/// from missing history — CI does not go red because a runner's clone is
/// shallow.
final class AgentsMdPlansStatusAuditTest: XCTestCase {

    /// A non-"Active" plan whose most recent commit touching it is older
    /// than this many days fails the audit. Named constant per #2226's
    /// acceptance criteria (no magic number scattered inline) — retune here.
    static let staleNonActivePlanThresholdDays = 60

    // Allows an optional leading markdown blockquote marker (`> `) before the
    // `Status` marker — several plans state status inside a callout
    // blockquote (e.g. `> **Status:** v3 — ...`). Also allows a parenthetical
    // right after `Status` before the colon (e.g. `**Status (2026-06-24):**
    // design proposal`), so the colon isn't required to immediately follow
    // the word.
    private static let statusLinePattern = #"^\s*(>\s*)*(\*\*)?Status\b[^\n]*?:"#

    // Same anchor as statusLinePattern, but captures the free-text value
    // after the colon (and after an optional closing `**`) so callers can
    // decide whether the plan reads as "Active".
    private static let statusValuePattern = #"^\s*(>\s*)*(\*\*)?Status\b[^\n]*?:(\*\*)?\s*(.*)$"#

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

    /// Returns the free-text value following the first `Status:` marker
    /// found in the first `windowLines` lines of `content` (trimmed), or
    /// `nil` if no `Status:` line is present.
    static func statusValue(in content: String, windowLines: Int = 20) -> String? {
        guard let regex = try? NSRegularExpression(pattern: statusValuePattern) else {
            XCTFail("Failed to compile Status: value regex")
            return nil
        }
        let lines = content.components(separatedBy: "\n").prefix(windowLines)
        for line in lines {
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges >= 5 else { continue }
            let valueRange = match.range(at: 4)
            guard valueRange.location != NSNotFound else { continue }
            return nsLine.substring(with: valueRange).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// `true` when `statusValue` reads as "the plan is currently being
    /// worked on" — i.e. starts with "Active" (case-insensitive). Anything
    /// else (Awaiting sign-off, Reviewed, Reference snapshot, a rejection
    /// record, …) is a candidate for staleness expiry.
    static func isActiveStatus(_ statusValue: String) -> Bool {
        statusValue.lowercased().hasPrefix("active")
    }

    /// Last commit time touching `fileURL`, via `git log -1 --format=%ct`.
    /// Returns `nil` on any failure (git unavailable, no history, shallow
    /// clone, non-numeric output) — callers must treat `nil` as "cannot
    /// determine age", never as "definitely stale".
    static func lastCommitDate(for fileURL: URL, repoRoot: URL) -> Date? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.currentDirectoryURL = repoRoot
        process.arguments = ["git", "log", "-1", "--format=%ct", "--", fileURL.path]

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe() // discard

        do {
            try process.run()
        } catch {
            return nil
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty, let epochSeconds = TimeInterval(raw) else { return nil }
        return Date(timeIntervalSince1970: epochSeconds)
    }

    /// `true` if a non-"Active" plan's last commit predates the threshold.
    /// `lastCommitDate == nil` (unknown age) always returns `false` — the
    /// non-flakiness guarantee documented on the class.
    static func isStale(
        statusValue: String,
        lastCommitDate: Date?,
        referenceDate: Date = Date(),
        thresholdDays: Int = staleNonActivePlanThresholdDays
    ) -> Bool {
        guard !isActiveStatus(statusValue) else { return false }
        guard let lastCommitDate else { return false }
        let ageDays = referenceDate.timeIntervalSince(lastCommitDate) / 86400
        return ageDays > Double(thresholdDays)
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

    private static func locateRepoRoot(filePath: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(filePath)")
            .deletingLastPathComponent() // Tests/ManifoldInferenceTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // <repo>
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

    /// #2226: a non-"Active" plan whose last commit predates the threshold
    /// fails the audit. Reads real `git log` history for each plan file, so
    /// (per the class doc) a shallow clone or missing history degrades to
    /// "not flagged," never to a spurious failure.
    func testNoStaleNonActivePlan() throws {
        let plansURL = try Self.locatePlansDirectory()
        let repoRoot = Self.locateRepoRoot()

        let entries = try FileManager.default.contentsOfDirectory(
            at: plansURL,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        let planFiles = entries.filter {
            $0.pathExtension == "md" && $0.lastPathComponent != "README.md"
        }

        var stale: [String] = []
        for fileURL in planFiles {
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            guard let statusValue = Self.statusValue(in: content) else {
                // Missing Status: line entirely is testEveryTopLevelPlanHasStatusLine's job.
                continue
            }
            let lastCommit = Self.lastCommitDate(for: fileURL, repoRoot: repoRoot)
            if Self.isStale(statusValue: statusValue, lastCommitDate: lastCommit) {
                let ageDays = lastCommit.map { Int(Date().timeIntervalSince($0) / 86400) }
                stale.append("\(fileURL.lastPathComponent) (Status: \(statusValue.prefix(40)), last commit \(ageDays.map { "\($0)d ago" } ?? "unknown") ago)")
            }
        }

        if !stale.isEmpty {
            let formatted = stale.sorted().map { "  - \($0)" }.joined(separator: "\n")
            XCTFail("""
                The following docs/plans/*.md files are non-"Active" and have not been \
                touched in over \(Self.staleNonActivePlanThresholdDays) days — they read as \
                current work but are quietly stale:

                \(formatted)

                Either delete the plan (git history is the archive — docs/plans/README.md \
                rule 2) or explicitly revive it: bump Status: to Active, or make a real \
                update that touches the file.
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

    /// #2226 sabotage: exercises `isStale` (the real staleness predicate the
    /// audit runs) directly against planted status values and fabricated
    /// commit dates — no real git history needed, so this stays deterministic.
    func test_sabotage_staleNonActivePlanIsDetected() throws {
        let now = Date()
        let sixtyOneDaysAgo = now.addingTimeInterval(-61 * 86400)
        let fiftyNineDaysAgo = now.addingTimeInterval(-59 * 86400)
        let oneYearAgo = now.addingTimeInterval(-365 * 86400)

        // Non-active + stale (>60d) → flagged.
        XCTAssertTrue(
            Self.isStale(statusValue: "Awaiting sign-off (Rory)", lastCommitDate: sixtyOneDaysAgo, referenceDate: now),
            "Sabotage: expected a non-Active plan last touched 61 days ago to be flagged stale, but it was not detected"
        )
        XCTAssertTrue(
            Self.isStale(statusValue: "Reference snapshot, not a live gate", lastCommitDate: oneYearAgo, referenceDate: now),
            "Sabotage: expected a non-Active plan last touched a year ago to be flagged stale, but it was not detected"
        )

        // Acceptance criterion (a): Active regardless of age → never flagged.
        XCTAssertFalse(
            Self.isStale(statusValue: "Active — Phase 1 shipped, Phase 2 open.", lastCommitDate: oneYearAgo, referenceDate: now),
            "An Active plan must never be flagged stale regardless of last-commit age"
        )

        // Acceptance criterion (b): non-Active but within the window → not flagged.
        XCTAssertFalse(
            Self.isStale(statusValue: "Awaiting sign-off (Rory)", lastCommitDate: fiftyNineDaysAgo, referenceDate: now),
            "A non-Active plan committed within the threshold window must not be flagged stale"
        )

        // Non-flakiness: unknown last-commit date (nil, e.g. shallow clone) never flags.
        XCTAssertFalse(
            Self.isStale(statusValue: "Awaiting sign-off (Rory)", lastCommitDate: nil, referenceDate: now),
            "Sabotage: an unknown last-commit date (nil) must never be treated as stale — CI should not go red because a checkout's git history is unavailable"
        )

        // isActiveStatus / statusValue extraction sanity, since isStale composes them.
        XCTAssertTrue(Self.isActiveStatus("Active. D1–D3 executed via v0.69.0"))
        XCTAssertFalse(Self.isActiveStatus("~80% executed via v0.67.0"))
        XCTAssertEqual(
            Self.statusValue(in: "# Plan\n\n**Status:** Reviewed (3× adversarial personas)"),
            "Reviewed (3× adversarial personas)"
        )
    }
}
