import XCTest

/// Tripwire for `docs/MIGRATION-INDEX.md` **completeness**: every retired or
/// breaking-changed API ships a migration note (Principle 9), and every note
/// must have a row in the index — "start here when a version bump breaks
/// your build" is a lie the moment a shipped note is missing from it.
///
/// ## What this does and does NOT enforce
///
/// The index makes two promises, and this audit checks exactly one of them:
///
/// 1. **Completeness** (enforced here): every `docs/MIGRATION-*.md` — other
///    than `MIGRATION-INDEX.md` itself — appears as a row in the table.
/// 2. **Release accuracy** (NOT enforced here, on purpose): a row's Release
///    column names the actual release that shipped the note; rows are added
///    with `next` and are supposed to be flipped once that release ships.
///    As of this writing, **8 rows on `main` correctly say `next`** — real,
///    unreleased notes awaiting their version. An in-suite audit asserting
///    "no row says `next`" would fail this whole suite on every ordinary PR
///    for a reason unrelated to that PR's change; it would also make it
///    impossible to ever land a migration note before a release ships,
///    which is the normal and desired order (the note ships in the same PR
///    as the change; the version bump comes later). That rule is
///    **release-gated, not per-PR**: `scripts/migration-index-check.sh
///    --release` enforces it at release time (see `AGENTS.md` § "Release
///    workflow" / "Pre-bump ... gate" conventions), the same way
///    `scripts/demo-apps-build.sh` and `scripts/companion-canary-check.sh`
///    are release-time-only gates rather than in-suite tests. Do not
///    "helpfully" add the `next`-row rule to this file — it would either be
///    permanently red or would need its own allowlist that immediately
///    defeats the point.
///
/// ## Relationship to other audits
///
/// This is **not** `DocClaimsAuditTest.auditIndexCoverage` — that check
/// (mirrored for docs-only PRs by `scripts/lint-doc-claims.sh`) only proves
/// a `docs/*.md` file is *mentioned by some* other Markdown file, and a
/// migration note that's merely linked from prose elsewhere in
/// `MIGRATION-INDEX.md` (without an actual table row) already satisfies
/// that. This audit is stricter and narrower: it parses the table itself
/// and asserts a real row exists, keyed on the exact filename.
///
/// `scripts/migration-index-check.sh` is a cheap Bash mirror of the
/// completeness half only, for release-time / ad hoc use — see that
/// script's header for the drift-guard relationship. This file is the
/// authoritative tripwire; if the table's row shape changes, update both in
/// the same commit.
///
/// ``completenessViolations(repoRoot:)`` is a pure function over a repo
/// root so the in-file sabotage tests exercise the real detection logic
/// against a planted temp tree.
final class MigrationIndexAuditTest: XCTestCase {

    func test_migrationIndexIsComplete() throws {
        let repoRoot = try Self.locateRepoRoot()
        let violations = try Self.completenessViolations(repoRoot: repoRoot)

        if !violations.isEmpty {
            let formatted = violations.sorted().map { "  - \($0)" }.joined(separator: "\n")
            XCTFail("""
                docs/MIGRATION-INDEX.md is missing a row for the following migration \
                note(s). Add a row with the release that ships the note (`next` if \
                unreleased yet) and a one-line summary of what changed — see
                docs/MIGRATION-INDEX.md's own "Adding a note" section.

                \(formatted)
                """)
        }
    }

    // MARK: - Sabotage (exercises the same detection function the audit runs)

    /// Plants an index referencing one note and two `docs/MIGRATION-*.md`
    /// files — one referenced by the index, one not — and asserts
    /// ``completenessViolations(repoRoot:)`` flags only the unreferenced
    /// one. Also plants `MIGRATION-INDEX.md` itself in `docs/` and asserts
    /// it is never flagged against itself (it is the index, not a note).
    func test_sabotage_completenessViolationsDetectsMissingIndexRow() throws {
        let tmp = try Self.makeTempRoot("migration-index-missing-row")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let docsDir = tmp.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)

        try """
        # Migration index

        | Release | Migration note | What changed |
        |---------|----------------|--------------|
        | next | [`MIGRATION-planted-covered.md`](MIGRATION-planted-covered.md) | Covered note. |
        """.write(to: docsDir.appendingPathComponent("MIGRATION-INDEX.md"), atomically: true, encoding: .utf8)

        try "# Covered".write(
            to: docsDir.appendingPathComponent("MIGRATION-planted-covered.md"), atomically: true, encoding: .utf8
        )
        try "# Orphan".write(
            to: docsDir.appendingPathComponent("MIGRATION-planted-orphan.md"), atomically: true, encoding: .utf8
        )

        let violations = try Self.completenessViolations(repoRoot: tmp)
        XCTAssertTrue(
            violations.contains { $0.contains("MIGRATION-planted-orphan.md") },
            "A migration note absent from the index table must be flagged; got \(violations)"
        )
        XCTAssertFalse(
            violations.contains { $0.contains("MIGRATION-planted-covered.md") },
            "A migration note with an index row must not be flagged; got \(violations)"
        )
        // Match on the violation's SUBJECT, not the whole message. Every
        // violation reads "docs/<name> has no row in docs/MIGRATION-INDEX.md",
        // so a `contains("MIGRATION-INDEX.md")` check matches the trailing
        // reference in every message and can never pass — it asserted nothing
        // about the index being exempt and failed on a correct result.
        XCTAssertFalse(
            violations.contains { $0.hasPrefix("docs/MIGRATION-INDEX.md ") },
            "The index file itself must never be required to reference itself; got \(violations)"
        )
    }

    /// A note mentioned only inside ANOTHER row's "What changed" cell has no
    /// row of its own and must still be flagged.
    ///
    /// Regression test for a fail-open found in review: the parser used to
    /// take every `MIGRATION-*.md` match on a `|`-prefixed line, so the
    /// perfectly natural "Superseded by `MIGRATION-x.md`" phrasing silently
    /// registered `MIGRATION-x.md` as covered. The audit passed on exactly
    /// the defect it exists to catch.
    func test_sabotage_completenessViolationsIgnoresNotesNamedInsideAnotherRowsProse() throws {
        let tmp = try Self.makeTempRoot("migration-index-prose-mention")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let docsDir = tmp.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)

        // One row, for alpha, whose prose cell also names beta. Only alpha
        // has a row; beta does not.
        try """
        # Migration index

        | Release | Migration note | What changed |
        |---------|----------------|--------------|
        | v0.76.0 | [`MIGRATION-alpha.md`](MIGRATION-alpha.md) | Supersedes `MIGRATION-beta.md`. |
        """.write(to: docsDir.appendingPathComponent("MIGRATION-INDEX.md"), atomically: true, encoding: .utf8)

        try "# Alpha".write(
            to: docsDir.appendingPathComponent("MIGRATION-alpha.md"), atomically: true, encoding: .utf8
        )
        try "# Beta".write(
            to: docsDir.appendingPathComponent("MIGRATION-beta.md"), atomically: true, encoding: .utf8
        )

        let violations = try Self.completenessViolations(repoRoot: tmp)
        XCTAssertTrue(
            violations.contains { $0.contains("MIGRATION-beta.md") },
            """
            A note named only inside another row's prose has no row of its own \
            and must be flagged; got \(violations)
            """
        )
        XCTAssertFalse(
            violations.contains { $0.contains("MIGRATION-alpha.md") },
            "The note the row is actually about must not be flagged; got \(violations)"
        )
    }

    /// A filename merely mentioned in the second cell is not an index row;
    /// that cell must contain the actual Markdown link to the migration note.
    /// This is the counterpart to the summary-prose sabotage above: choosing
    /// the first filename anywhere in a row incorrectly accepts both forms.
    func test_sabotage_completenessViolationsRejectsProseOnlyMigrationNoteCell() throws {
        let tmp = try Self.makeTempRoot("migration-index-unlinked-note-cell")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let docsDir = tmp.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        try """
        # Migration index

        | Release | Migration note | What changed |
        |---------|----------------|--------------|
        | v0.76.0 | [`MIGRATION-covered.md`](MIGRATION-covered.md) | A real row. |
        | v0.76.0 | See MIGRATION-prose-only.md for details. | Missing the required link. |
        """.write(to: docsDir.appendingPathComponent("MIGRATION-INDEX.md"), atomically: true, encoding: .utf8)
        try "# Covered".write(
            to: docsDir.appendingPathComponent("MIGRATION-covered.md"), atomically: true, encoding: .utf8
        )
        try "# Prose only".write(
            to: docsDir.appendingPathComponent("MIGRATION-prose-only.md"), atomically: true, encoding: .utf8
        )

        let violations = try Self.completenessViolations(repoRoot: tmp)
        XCTAssertTrue(
            violations.contains { $0.contains("MIGRATION-prose-only.md") },
            "An unlinked prose mention in the Migration note cell must not count as a row; got \(violations)"
        )
        XCTAssertFalse(
            violations.contains { $0.contains("MIGRATION-covered.md") },
            "A real second-cell link must continue to count as a row; got \(violations)"
        )
    }

    /// A row may cross-link another migration note for context, but only its
    /// first Migration note-cell link is the row it owns. This pins the Swift
    /// parser to Bash's `BASH_REMATCH` first-match semantics.
    func test_sabotage_completenessViolationsIgnoresSecondMigrationLinkInNoteCell() throws {
        let tmp = try Self.makeTempRoot("migration-index-note-cell-cross-link")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let docsDir = tmp.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        try """
        # Migration index

        | Release | Migration note | What changed |
        |---------|----------------|--------------|
        | v0.76.0 | [`MIGRATION-primary.md`](MIGRATION-primary.md), see [`MIGRATION-cross-link.md`](MIGRATION-cross-link.md). | One owned row. |
        """.write(to: docsDir.appendingPathComponent("MIGRATION-INDEX.md"), atomically: true, encoding: .utf8)
        try "# Primary".write(
            to: docsDir.appendingPathComponent("MIGRATION-primary.md"), atomically: true, encoding: .utf8
        )
        try "# Cross-link".write(
            to: docsDir.appendingPathComponent("MIGRATION-cross-link.md"), atomically: true, encoding: .utf8
        )

        let violations = try Self.completenessViolations(repoRoot: tmp)
        XCTAssertFalse(
            violations.contains { $0.contains("MIGRATION-primary.md") },
            "The first migration-note link owns the row; got \(violations)"
        )
        XCTAssertTrue(
            violations.contains { $0.contains("MIGRATION-cross-link.md") },
            "A second cross-link must not count as its own index row; got \(violations)"
        )
    }

    /// A repo root with no readable `docs/MIGRATION-INDEX.md` must make
    /// ``completenessViolations(repoRoot:)`` **throw**, not quietly return
    /// zero violations — the sibling of `DocClaimsAuditTest`'s
    /// unreadable-`docs/` sabotage test, same fail-open shape (#2274,
    /// #2287) applied to this audit.
    func test_sabotage_completenessViolationsThrowsOnUnreadableIndex() throws {
        let tmp = try Self.makeTempRoot("migration-index-unreadable")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // docs/ exists but has no MIGRATION-INDEX.md at all — the same
        // observable state as an unreadable one.
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("docs"), withIntermediateDirectories: true
        )

        XCTAssertThrowsError(
            try Self.completenessViolations(repoRoot: tmp),
            "A missing/unreadable docs/MIGRATION-INDEX.md must throw, not report zero violations"
        )
    }

    /// An index file that exists but whose table cannot be parsed (zero
    /// `MIGRATION-*.md` references found) must also **throw** — a zero-match
    /// parse reading as "nothing to check" is a known failure mode in this
    /// repo (a table-shape edit silently turning this audit into a no-op).
    func test_sabotage_completenessViolationsThrowsOnZeroRowParse() throws {
        let tmp = try Self.makeTempRoot("migration-index-zero-rows")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let docsDir = tmp.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        try "# Migration index\n\nNo table here, just prose.\n".write(
            to: docsDir.appendingPathComponent("MIGRATION-INDEX.md"), atomically: true, encoding: .utf8
        )

        XCTAssertThrowsError(
            try Self.completenessViolations(repoRoot: tmp),
            "An index whose table parses to zero rows must throw, not silently pass"
        )
    }

    // MARK: - Detection

    /// Every `docs/MIGRATION-*.md` (other than `MIGRATION-INDEX.md` itself)
    /// that has no row in `docs/MIGRATION-INDEX.md`'s table.
    static func completenessViolations(repoRoot: URL) throws -> [String] {
        let indexURL = repoRoot.appendingPathComponent("docs/MIGRATION-INDEX.md")
        guard let indexContent = try? String(contentsOf: indexURL, encoding: .utf8) else {
            throw NSError(domain: "MigrationIndexAuditTest", code: 1, userInfo: [
                NSLocalizedDescriptionKey: """
                    Could not read \(indexURL.path) — docs/MIGRATION-INDEX.md is missing \
                    or unreadable. This must never silently report zero violations.
                    """,
            ])
        }

        let indexedNames = try indexedMigrationNoteNames(indexContent: indexContent, indexURL: indexURL)

        let docsDir = repoRoot.appendingPathComponent("docs")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: docsDir, includingPropertiesForKeys: nil
        ) else {
            throw NSError(domain: "MigrationIndexAuditTest", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not enumerate \(docsDir.path) — this must never silently report zero violations.",
            ])
        }

        let migrationNotes = entries
            .map { $0.lastPathComponent }
            .filter { $0.hasPrefix("MIGRATION-") && $0.hasSuffix(".md") }
            .filter { $0 != "MIGRATION-INDEX.md" }

        var violations: [String] = []
        for name in migrationNotes.sorted() where !indexedNames.contains(name) {
            violations.append("docs/\(name) has no row in docs/MIGRATION-INDEX.md")
        }
        return violations
    }

    /// Every `MIGRATION-*.md` filename referenced from a table row (a line
    /// starting with `|`) in `indexContent`. Throws if none are found — the
    /// table is never legitimately empty (the index promises to be the
    /// complete list), so a zero-match parse means the row shape drifted
    /// out from under this parser, not that there is nothing to check.
    private static func indexedMigrationNoteNames(indexContent: String, indexURL: URL) throws -> Set<String> {
        var names = Set<String>()
        for line in indexContent.components(separatedBy: .newlines) {
            guard line.hasPrefix("|") else { continue }
            for name in migrationNoteReferences(in: line) {
                names.insert(name)
            }
        }

        guard !names.isEmpty else {
            throw NSError(domain: "MigrationIndexAuditTest", code: 3, userInfo: [
                NSLocalizedDescriptionKey: """
                    Parsed zero MIGRATION-*.md references from \(indexURL.path)'s table \
                    rows. Either the table is genuinely empty (never legitimate — the \
                    index promises to be the complete migration-note list) or this \
                    audit's row parser has drifted from the table's real shape. Treated \
                    as fatal, never a silent pass.
                    """,
            ])
        }
        return names
    }

    /// The `MIGRATION-*.md` filename a single table row is *about*: the
    /// Markdown-link destination in its second (`Migration note`) cell.
    ///
    /// A row's "What changed" cell can legitimately name another note
    /// ("Superseded by `MIGRATION-x.md`"), which is a natural way to write
    /// this table. Taking every match would treat that mention as though
    /// `MIGRATION-x.md` had its own row, so the audit would pass while the
    /// note it is supposed to protect has no row at all — failing open on the
    /// precise defect it exists to catch. Selecting the actual table cell,
    /// then taking only its first Markdown link target, rejects a malformed
    /// second cell, prose-only mentions, and unrelated cross-links. This must
    /// remain in lockstep with `scripts/migration-index-check.sh` or the
    /// release gate can red where the per-PR audit was green.
    private static func migrationNoteReferences(in line: String) -> [String] {
        let cells = line.components(separatedBy: "|")
        guard cells.count >= 4,
              cells[0].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        let noteCell = cells[2]
        return Array(matches(of: #"\]\((MIGRATION-[A-Za-z0-9._-]+\.md)\)"#, in: noteCell).prefix(1))
    }

    /// The first capture group of every match of `pattern` in `text`.
    private static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    // MARK: - Paths

    private static func makeTempRoot(_ prefix: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private static func locateRepoRoot(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "MigrationIndexAuditTest", code: 4, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Package.swift from #filePath",
        ])
    }
}
