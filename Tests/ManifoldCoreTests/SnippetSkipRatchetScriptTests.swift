import XCTest

/// Integration test for the policy half of `scripts/extract-snippets.sh` — the
/// three checks that need no compiler and therefore run in the **required**
/// `lint` job: the `no-build:<reason>` requirement, the per-doc ">=1 compiled
/// block" assertion, and the per-doc skip **ratchet**
/// (`scripts/snippet-skip-baseline.tsv`).
///
/// ## Why this test exists
///
/// The previous round of this work (#2383) shipped four new detection
/// behaviours with no test proving any of them fired: an adversarial review
/// reverted three and `swift test` stayed entirely green. The ratchet added in
/// this branch was heading for the same fate — verified only by shell probes
/// run by hand, none of which survive into the repo. A guard whose enforcement
/// exists only in a maintainer's terminal history is Principle 4's "rule
/// without a tripwire".
///
/// So: each policy is exercised end to end against a planted temp repo, by
/// running the **real script** (copied, not reimplemented — a replica would
/// drift, which is the mistake `AuditSabotageCoverageAuditTest`'s own history
/// records). Pattern follows `FuzzCIGateScriptTests`.
///
/// No `python3` / toolchain skip guard is needed: extraction is pure
/// awk/sed/grep text work and runs with the Swift toolchain absent from `PATH`
/// (verified — that property is what allows the `lint` promotion at all).
final class SnippetSkipRatchetScriptTests: XCTestCase {

    /// Exit code the script uses for a policy failure.
    private let policyFailure: Int32 = 2

    // MARK: - Ratchet

    func test_ratchet_rejectsANewBareNoBuildTag() throws {
        let repo = try plantRepo(
            baseline: "docs/GUIDE.md\t0\t0",
            guideBody: """
            ```swift
            let compiles = 1
            ```

            ```swift,no-build
            let bare = 2
            ```
            """
        )
        defer { try? FileManager.default.removeItem(at: repo) }

        let (status, output) = try runExtractor(in: repo)
        XCTAssertEqual(
            status, policyFailure,
            "A bare no-build beyond the baseline must fail. Output:\n\(output)"
        )
        XCTAssertTrue(
            output.contains("bare"), "The error must name the bare-tag budget. Output:\n\(output)"
        )
    }

    func test_ratchet_rejectsANewReasonedSkipBeyondBudget() throws {
        let repo = try plantRepo(
            baseline: "docs/GUIDE.md\t0\t0",
            guideBody: """
            ```swift
            let compiles = 1
            ```

            ```swift,no-build:planted fragment with a sufficiently long reason
            let fragment = 2
            ```
            """
        )
        defer { try? FileManager.default.removeItem(at: repo) }

        let (status, output) = try runExtractor(in: repo)
        XCTAssertEqual(
            status, policyFailure,
            """
            A skip is legitimate but must be declared — an undeclared increase \
            means the budget silently grows, which is the whole failure mode. \
            Output:
            \(output)
            """
        )
    }

    func test_ratchet_allowsSkipsWithinTheRecordedBudget() throws {
        let repo = try plantRepo(
            baseline: "docs/GUIDE.md\t1\t1",
            guideBody: """
            ```swift
            let compiles = 1
            ```

            ```swift,no-build
            let bare = 2
            ```
            """
        )
        defer { try? FileManager.default.removeItem(at: repo) }

        let (status, output) = try runExtractor(in: repo)
        XCTAssertEqual(
            status, 0,
            "Legacy debt recorded in the baseline must pass — a ratchet holds, it does not demand zero. Output:\n\(output)"
        )
    }

    // MARK: - Reason requirement

    func test_reasonRequirement_rejectsATooShortReason() throws {
        let repo = try plantRepo(
            baseline: "docs/GUIDE.md\t0\t1",
            guideBody: """
            ```swift
            let compiles = 1
            ```

            ```swift,no-build:wip
            let fragment = 2
            ```
            """
        )
        defer { try? FileManager.default.removeItem(at: repo) }

        let (status, output) = try runExtractor(in: repo)
        XCTAssertEqual(
            status, policyFailure,
            "`no-build:wip` is a marker, not a reason — a bare suppression with a token attached. Output:\n\(output)"
        )
    }

    // MARK: - Per-doc coverage

    func test_coverage_rejectsADocWhereEveryBlockIsSkipped() throws {
        // Bare count 0 ⇒ the doc counts as triaged, so the ">=1 compiled" rule
        // applies. Another doc supplies a compiled block so the global
        // "extracted nothing at all" guard is not what fires.
        let repo = try plantRepo(
            baseline: "docs/GUIDE.md\t0\t1\ndocs/OTHER.md\t0\t0",
            guideBody: """
            ```swift,no-build:planted fragment with a sufficiently long reason
            let fragment = 1
            ```
            """,
            otherBody: """
            ```swift
            let compiles = 1
            ```
            """
        )
        defer { try? FileManager.default.removeItem(at: repo) }

        let (status, output) = try runExtractor(in: repo)
        XCTAssertEqual(
            status, policyFailure,
            """
            A doc where every block is skipped makes the gate run on it and \
            verify nothing — full CI cost, zero signal. Output:
            \(output)
            """
        )
        XCTAssertTrue(
            output.contains("GUIDE.md"),
            "The error must name the offending doc. Output:\n\(output)"
        )
    }

    // MARK: - Fail-open guards (this round's fixes)

    /// Counts falling below the recorded budget must fail, or the budget becomes
    /// permanent headroom a later PR can spend silently — the difference between
    /// a ratchet and a high-water mark.
    func test_ratchet_rejectsCountsFallingBelowTheBudget() throws {
        let repo = try plantRepo(
            baseline: "docs/GUIDE.md\t2\t2",
            guideBody: """
            ```swift
            let compiles = 1
            ```
            """
        )
        defer { try? FileManager.default.removeItem(at: repo) }

        let (status, output) = try runExtractor(in: repo)
        XCTAssertEqual(status, policyFailure, "A drained budget must be lowered. Output:\n\(output)")
        XCTAssertTrue(output.contains("FELL"), "The error must say the counts fell. Output:\n\(output)")
    }

    /// A non-numeric count must fail loudly. `[[ x -gt "13\r" ]]` raises an
    /// arithmetic error, `[[ ]]` returns false, and `set -e` does not fire inside
    /// an `if` condition — so one CRLF-saved TSV silently disabled the whole
    /// ratchet at exit 0 with no annotation, which is the worst available failure:
    /// an inert guard that looks green.
    func test_baseline_rejectsANonNumericCount() throws {
        let repo = try plantRepo(
            baseline: "docs/GUIDE.md\tx\t1",
            guideBody: """
            ```swift
            let compiles = 1
            ```
            """
        )
        defer { try? FileManager.default.removeItem(at: repo) }

        let (status, output) = try runExtractor(in: repo)
        XCTAssertEqual(status, policyFailure, "Junk in a count column must fail. Output:\n\(output)")
        XCTAssertTrue(
            output.contains("not a number"),
            "The error must name the malformed value. Output:\n\(output)"
        )
    }

    /// The bare counter must survive an `OUT_DIR` containing a space. Built so
    /// only the bare arm can catch it: the total stays flat, so a counter that
    /// silently reads 0 produces a green run.
    func test_bareCounter_survivesAnOutputPathContainingSpaces() throws {
        let repo = try plantRepo(
            baseline: "docs/GUIDE.md\t0\t1",
            guideBody: """
            ```swift
            let compiles = 1
            ```

            ```swift,no-build
            let bare = 2
            ```
            """
        )
        defer { try? FileManager.default.removeItem(at: repo) }

        let (status, output) = try runExtractor(in: repo, outDirectoryName: "out dir with spaces")
        XCTAssertEqual(status, policyFailure, "Output:\n\(output)")
        XCTAssertTrue(
            output.contains("bare"),
            """
            The BARE arm must fire, not just the total arm. With an unquoted \
            `$(find …)` the bare count read 0 and only the total arm caught \
            anything — so a change leaving the total flat slipped through. \
            Output:
            \(output)
            """
        )
    }

    /// A row for a doc that no longer exists must fail. Nothing consults such a
    /// row, so it survives forever — and recreating the doc later lets its stale
    /// budget grant skips with no TSV diff and no annotation.
    func test_baseline_rejectsARowForADocThatDoesNotExist() throws {
        let repo = try plantRepo(
            baseline: "docs/GUIDE.md\t0\t0\ndocs/NEVER-EXISTED.md\t99\t99",
            guideBody: """
            ```swift
            let compiles = 1
            ```
            """
        )
        defer { try? FileManager.default.removeItem(at: repo) }

        let (status, output) = try runExtractor(in: repo)
        XCTAssertEqual(status, policyFailure, "A stale row must fail. Output:\n\(output)")
        XCTAssertTrue(
            output.contains("NEVER-EXISTED") || output.contains("does not match the tree"),
            "The error must surface the stale row. Output:\n\(output)"
        )
    }

    // MARK: - Harness

    /// Builds a minimal repo the script can run against: its own copy of the
    /// script (so `REPO_ROOT`, derived from `BASH_SOURCE`, resolves to the temp
    /// tree), a baseline, and one or two docs.
    private func plantRepo(
        baseline: String,
        guideBody: String,
        otherBody: String? = nil
    ) throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("snippet-ratchet-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        // `Sources/` is walked for DocC articles; an empty dir keeps that loop happy.
        try fm.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)

        let realScript = try Self.locateRepoRoot()
            .appendingPathComponent("scripts/extract-snippets.sh")
        try fm.copyItem(at: realScript, to: root.appendingPathComponent("scripts/extract-snippets.sh"))

        try ("# Per-doc snippet-skip budget\n# path\tbare\ttotal\n" + baseline + "\n")
            .write(to: root.appendingPathComponent("scripts/snippet-skip-baseline.tsv"),
                   atomically: true, encoding: .utf8)

        try ("# Guide\n\n" + guideBody + "\n")
            .write(to: root.appendingPathComponent("docs/GUIDE.md"), atomically: true, encoding: .utf8)
        if let otherBody {
            try ("# Other\n\n" + otherBody + "\n")
                .write(to: root.appendingPathComponent("docs/OTHER.md"), atomically: true, encoding: .utf8)
        }
        return root
    }

    /// `outDirectoryName` exists so a test can force a path containing a space —
    /// the bare counter used to word-split on an unquoted `$(find …)` and read 0.
    private func runExtractor(
        in repo: URL,
        outDirectoryName: String = "out"
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            repo.appendingPathComponent("scripts/extract-snippets.sh").path,
            "--out", repo.appendingPathComponent(outDirectoryName).path,
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Read before waiting: a full pipe buffer would deadlock the child.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private static func locateRepoRoot(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "SnippetSkipRatchetScriptTests", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Package.swift from #filePath",
        ])
    }
}
