import XCTest

/// Integration test for `scripts/migration-index-check.sh`. Spawns the real
/// script via `Process` against planted fixture trees, using its own
/// `--index FILE` / `--docs-dir DIR` seams so no test ever reads or depends
/// on the real `docs/` tree.
///
/// ## Why this file exists
///
/// The script has two modes (see its own header comment). The completeness
/// half is deliberately mirrored by the authoritative Swift tripwire,
/// `MigrationIndexAuditTest`, which runs every PR. The `--release` half —
/// which fails when any index row still says `next` in the Release column —
/// has no such mirror and is release-gated only (see
/// `MigrationIndexAuditTest`'s header for why it must stay out of the
/// per-PR suite). That leaves `--release` mode as the least-exercised code
/// path in the repo despite being the one that actually gates a release: it
/// runs, at most, once per release cycle, on whatever the release operator's
/// machine happens to do. This file is that mode's regression coverage.
///
/// ## Assertion policy
///
/// Every assertion below checks a specific substring in the script's
/// output (an offending filename, an error phrase) rather than the exit
/// code alone. An exit-code-only assertion would still pass if the script
/// reported the wrong row, reported none of several offending rows, or
/// reddened for an unrelated reason — see the mutation analysis in this
/// PR's description for what each assertion is load-bearing against.
final class MigrationIndexCheckScriptTests: XCTestCase {

    // MARK: - Locating the script

    private func repoRoot() -> URL? {
        // #filePath is .../Tests/ManifoldCoreTests/MigrationIndexCheckScriptTests.swift
        // repo root is two levels above Tests/.
        let thisFile = URL(fileURLWithPath: #filePath)
        let candidate = thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = candidate.appendingPathComponent("scripts/migration-index-check.sh")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        return candidate
    }

    // MARK: - Running the script

    private func run(scriptRoot: URL, args: [String]) throws -> (status: Int32, output: String) {
        let script = scriptRoot.appendingPathComponent("scripts/migration-index-check.sh")

        // Output goes to a temp file, not a Pipe — see
        // ChangelogParserCheckScriptTests's identical comment: a Pipe read
        // via `readDataToEndOfFile()` before `waitUntilExit()` can truncate
        // under the real parallel test run. A temp file has no pipe buffer
        // to race against.
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-index-check-test-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outURL) }
        let outHandle = try FileHandle(forWritingTo: outURL)
        defer { try? outHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + args
        process.standardOutput = outHandle
        process.standardError = outHandle
        try process.run()
        process.waitUntilExit()

        let data = (try? Data(contentsOf: outURL)) ?? Data()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    // MARK: - Fixture tree

    private struct Fixture {
        let root: URL
        let indexFile: URL
        let docsDir: URL
    }

    /// Builds a throwaway `docs/`-shaped tree: an index file named
    /// `MIGRATION-INDEX.md` (matching the real repo's basename, so the
    /// script's self-exclusion of the index from its own completeness scan
    /// is exercised the same way it is in production) with one table row
    /// per entry in `rows`, plus a blank `MIGRATION-*.md` file for every
    /// name in `notes`. Caller owns cleanup.
    private func makeFixture(rows: [(release: String, note: String)], notes: [String]) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-index-check-fixture-\(UUID().uuidString)")
        let docsDir = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)

        var lines = [
            "# Migration index",
            "",
            "| Release | Migration note | What changed |",
            "|---------|----------------|--------------|",
        ]
        lines += rows.map { "| \($0.release) | [`\($0.note)`](\($0.note)) | What changed |" }
        let indexFile = docsDir.appendingPathComponent("MIGRATION-INDEX.md")
        try (lines.joined(separator: "\n") + "\n").write(to: indexFile, atomically: true, encoding: .utf8)

        for note in notes {
            try "# \(note)\n".write(to: docsDir.appendingPathComponent(note), atomically: true, encoding: .utf8)
        }

        return Fixture(root: root, indexFile: indexFile, docsDir: docsDir)
    }

    /// Boilerplate every fixture-based test shares: locate the repo, build
    /// the fixture, tear it down afterwards.
    private func withFixture(
        rows: [(release: String, note: String)],
        notes: [String],
        _ body: (URL, Fixture) throws -> Void
    ) throws {
        guard let root = repoRoot() else {
            throw XCTSkip("migration-index-check.sh not found from test bundle location")
        }
        let fixture = try makeFixture(rows: rows, notes: notes)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try body(root, fixture)
    }

    // MARK: - `--release` mode: the untested half

    /// A release-ready index — every row has a real version, every note
    /// exists — must pass.
    func test_release_passesWhenAllRowsHaveRealVersionsAndNotesExist() throws {
        try withFixture(
            rows: [("v0.1.0", "MIGRATION-a.md"), ("v0.2.0", "MIGRATION-b.md")],
            notes: ["MIGRATION-a.md", "MIGRATION-b.md"]
        ) { root, fixture in
            let (status, output) = try run(scriptRoot: root, args: [
                "--release", "--index", fixture.indexFile.path, "--docs-dir", fixture.docsDir.path,
            ])

            XCTAssertEqual(status, 0, "a release-ready index must pass: \(output)")
            XCTAssertTrue(
                output.contains("no pending \"next\" rows remain"),
                "expected the release-mode success marker, got: \(output)"
            )
        }
    }

    /// One row still saying `next` must fail the release, and the failure
    /// must name that row's note filename specifically — not just report a
    /// generic non-zero exit.
    func test_release_failsAndNamesOffendingRow_whenOneRowSaysNext() throws {
        try withFixture(
            rows: [("next", "MIGRATION-a.md"), ("v0.2.0", "MIGRATION-b.md")],
            notes: ["MIGRATION-a.md", "MIGRATION-b.md"]
        ) { root, fixture in
            let (status, output) = try run(scriptRoot: root, args: [
                "--release", "--index", fixture.indexFile.path, "--docs-dir", fixture.docsDir.path,
            ])

            XCTAssertEqual(status, 1, "a pending `next` row must fail the release gate: \(output)")
            XCTAssertTrue(
                output.contains("MIGRATION-a.md"),
                "the failure must name the specific offending note's filename, got: \(output)"
            )
            XCTAssertFalse(
                output.contains("Flip each") && output.contains("MIGRATION-b.md"),
                "the already-released row must not be listed among the offenders, got: \(output)"
            )
        }
    }

    /// A pending row must be caught however its cell is decorated.
    ///
    /// Regression test for a fail-open found in review: detection was exact
    /// string equality against `next`, while `docs/MIGRATION-INDEX.md`'s own
    /// "Adding a note" section tells authors to put `next` in the Release
    /// column — where it renders backticked. An author copying the instruction
    /// literally wrote a cell the gate could not see, so a release could ship
    /// with an un-flipped row: the exact defect the gate exists to catch,
    /// missed by following the documented instructions. Each spelling below is
    /// a form a real author plausibly writes.
    func test_release_catchesPendingRowRegardlessOfCellDecoration() throws {
        for decorated in ["`next`", "**next**", "_next_", "Next", "NEXT", " next "] {
            try withFixture(
                rows: [(decorated, "MIGRATION-a.md"), ("v0.2.0", "MIGRATION-b.md")],
                notes: ["MIGRATION-a.md", "MIGRATION-b.md"]
            ) { root, fixture in
                let (status, output) = try run(scriptRoot: root, args: [
                    "--release", "--index", fixture.indexFile.path, "--docs-dir", fixture.docsDir.path,
                ])

                XCTAssertEqual(
                    status, 1,
                    "a pending row written as \(decorated) must still fail the release gate: \(output)"
                )
                XCTAssertTrue(
                    output.contains("MIGRATION-a.md"),
                    "the failure must name the note whose row reads \(decorated), got: \(output)"
                )
            }
        }
    }

    /// A real version must NOT be mistaken for pending just because the
    /// normalisation above strips decoration — the counterpart to the test
    /// above, so normalising cannot degrade into "everything looks pending".
    func test_release_passesWhenDecoratedCellHoldsARealVersion() throws {
        try withFixture(
            rows: [("`v0.76.0`", "MIGRATION-a.md"), ("**v0.75.0**", "MIGRATION-b.md")],
            notes: ["MIGRATION-a.md", "MIGRATION-b.md"]
        ) { root, fixture in
            let (status, output) = try run(scriptRoot: root, args: [
                "--release", "--index", fixture.indexFile.path, "--docs-dir", fixture.docsDir.path,
            ])

            XCTAssertEqual(
                status, 0,
                "decorated cells holding real versions are not pending rows: \(output)"
            )
            XCTAssertTrue(
                output.contains("no pending \"next\" rows remain"),
                "expected the release-mode success marker rather than a bare exit 0, got: \(output)"
            )
        }
    }

    /// Several rows saying `next` at once must ALL be named, not just the
    /// first — a script that stops after the first offender would leave a
    /// release operator fixing one row, re-running, and finding another.
    func test_release_namesAllOffendingRows_whenSeveralSayNext() throws {
        try withFixture(
            rows: [
                ("next", "MIGRATION-a.md"),
                ("next", "MIGRATION-b.md"),
                ("v0.3.0", "MIGRATION-c.md"),
            ],
            notes: ["MIGRATION-a.md", "MIGRATION-b.md", "MIGRATION-c.md"]
        ) { root, fixture in
            let (status, output) = try run(scriptRoot: root, args: [
                "--release", "--index", fixture.indexFile.path, "--docs-dir", fixture.docsDir.path,
            ])

            XCTAssertEqual(status, 1, "multiple pending rows must still fail the release gate: \(output)")
            XCTAssertTrue(
                output.contains("2 migration-index row(s) still say"),
                "expected the count of pending rows in the summary line, got: \(output)"
            )
            XCTAssertTrue(output.contains("MIGRATION-a.md"), "first offender must be named, got: \(output)")
            XCTAssertTrue(output.contains("MIGRATION-b.md"), "second offender must be named too, got: \(output)")
            XCTAssertFalse(
                output.contains("Flip each") && output.contains("MIGRATION-c.md"),
                "the already-released row must not be listed among the offenders, got: \(output)"
            )
        }
    }

    /// `--release` must still enforce completeness — a note absent from the
    /// index fails even when no row says `next`, i.e. the release check is
    /// additive to the completeness check, not a replacement for it.
    func test_release_stillEnforcesCompleteness_whenNoteMissingFromIndex() throws {
        try withFixture(
            rows: [("v0.1.0", "MIGRATION-a.md")],
            notes: ["MIGRATION-a.md", "MIGRATION-orphan.md"]
        ) { root, fixture in
            let (status, output) = try run(scriptRoot: root, args: [
                "--release", "--index", fixture.indexFile.path, "--docs-dir", fixture.docsDir.path,
            ])

            XCTAssertEqual(status, 1, "release mode must still enforce completeness: \(output)")
            XCTAssertTrue(
                output.contains("missing a row"),
                "expected the completeness diagnostic, got: \(output)"
            )
            XCTAssertTrue(
                output.contains("MIGRATION-orphan.md"),
                "the completeness failure must name the unindexed note, got: \(output)"
            )
        }
    }

    /// Bare mode (no `--release`) must pass on a fixture whose rows all say
    /// `next` as long as it's otherwise complete — this pins the two modes
    /// apart: the `next` rule is release-only and must not leak into the
    /// per-PR-safe completeness check.
    func test_bareMode_passesEvenWhenAllRowsSayNext() throws {
        try withFixture(
            rows: [("next", "MIGRATION-a.md"), ("next", "MIGRATION-b.md")],
            notes: ["MIGRATION-a.md", "MIGRATION-b.md"]
        ) { root, fixture in
            let (status, output) = try run(scriptRoot: root, args: [
                "--index", fixture.indexFile.path, "--docs-dir", fixture.docsDir.path,
            ])

            XCTAssertEqual(
                status, 0,
                "bare mode must not enforce the `next`-row rule — that's release-only: \(output)"
            )
            XCTAssertTrue(
                output.contains("have an index row"),
                "expected the bare-mode (completeness-only) success marker, got: \(output)"
            )
            XCTAssertFalse(
                output.contains("still say"),
                "bare mode must never mention pending `next` rows at all, got: \(output)"
            )
        }
    }

    // MARK: - Fail-closed paths

    /// A missing index file must fail closed with a named diagnostic, not a
    /// silent pass.
    func test_missingIndexFile_failsClosed() throws {
        guard let root = repoRoot() else {
            throw XCTSkip("migration-index-check.sh not found from test bundle location")
        }
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("migration-index-check-missing-\(UUID().uuidString)")
        let docsDir = scratch.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let missingIndex = docsDir.appendingPathComponent("MIGRATION-INDEX.md")

        let (status, output) = try run(scriptRoot: root, args: [
            "--index", missingIndex.path, "--docs-dir", docsDir.path,
        ])

        XCTAssertEqual(status, 1, "a missing index file must fail closed, not pass silently: \(output)")
        XCTAssertTrue(
            output.contains("Migration index not found"),
            "expected the explicit missing-index diagnostic, got: \(output)"
        )
    }

    /// An index file that exists but whose table parses to zero rows must
    /// also fail closed — a table-shape drift that breaks the row parser
    /// must never look identical to "nothing to check".
    func test_zeroRowIndex_failsClosed() throws {
        try withFixture(rows: [], notes: []) { root, fixture in
            try "# Migration index\n\nNo table here, just prose.\n"
                .write(to: fixture.indexFile, atomically: true, encoding: .utf8)

            let (status, output) = try run(scriptRoot: root, args: [
                "--index", fixture.indexFile.path, "--docs-dir", fixture.docsDir.path,
            ])

            XCTAssertEqual(status, 1, "a zero-row parse must fail closed, not silently pass: \(output)")
            XCTAssertTrue(
                output.contains("Parsed zero rows"),
                "expected the explicit zero-row diagnostic, got: \(output)"
            )
        }
    }

    // MARK: - Usage error

    /// An unknown flag must exit with the documented usage-error code (2),
    /// distinct from both the pass (0) and violations-found (1) codes.
    func test_unknownFlag_exitsWithUsageError() throws {
        guard let root = repoRoot() else {
            throw XCTSkip("migration-index-check.sh not found from test bundle location")
        }

        let (status, output) = try run(scriptRoot: root, args: ["--bogus-flag"])

        XCTAssertEqual(status, 2, "an unknown flag must exit 2 (usage error), not 0 or 1: \(output)")
        XCTAssertTrue(
            output.contains("Unknown argument"),
            "expected the explicit unknown-argument diagnostic, got: \(output)"
        )
    }
}
