import XCTest

/// Tripwire for **doc claims** — the assertions a doc makes about the world,
/// as opposed to its *form*.
///
/// ## Why this exists
///
/// The repo already audits documentation form: `DocsAudienceStatusAuditTest`
/// checks every doc carries an `**Audience:**` / `**Status:**` header, and
/// `DocSourcePathReferenceAuditTest` checks `Sources/…` link
/// targets resolve. Nothing checked whether a doc's *claims* were true — that
/// a symbol it names still exists, that a relative `.md` link it offers still
/// resolves, that a doc it ships is reachable at all.
///
/// Not covered: `<doc:Article>` links (59 in the corpus), multi-line
/// `` ``…`` `` spans, and relative links to non-Markdown targets — the last of
/// those is `DocSourcePathReferenceAuditTest`'s job for `Sources/…` paths.
///
/// That gap shipped a real defect. PR #2007 (2026-06-21) deleted the entire
/// wake-word subsystem from `ManifoldVoice` — `AppleWakeWordDetector`,
/// `WakeWordToast`, the `WakeWordDetector` protocol, `WakeWordDetection`, and
/// `VoiceConversationController.recentWakeWordDetection`. It correctly updated
/// the DocC catalog, but left `docs/QUICKSTART-VOICE.md` § 5 stating
/// *"`ManifoldVoice` ships ``AppleWakeWordDetector``"*, with a snippet calling
/// three symbols that no longer existed. That section sat in a doc listed in
/// the `docs/README.md` capability table for **five weeks** before an audit
/// found it.
///
/// It survived because every one of that file's Swift fences is tagged
/// `swift,no-build`, so the snippet-compile gate ran on the file and checked
/// nothing. A claim-level audit does not care about the `no-build` tag: it
/// reads prose and skipped snippets alike, which is exactly where the
/// compile gate is blind.
///
/// ## The four claims checked
///
/// Each is a pure function over a repo root, so the in-file sabotage tests
/// exercise the real detection logic against a planted temp tree.
///
/// 1. ``auditSymbolReferences(repoRoot:)`` — every identifier inside a DocC
///    symbol link (`` ``Symbol`` ``, `` ``Type/member`` ``) appears somewhere
///    in `Sources/**/*.swift`. This is deliberately a *token* check, not a
///    declaration check: it is looking for symbols that no longer exist at
///    all, and a weaker predicate means near-zero false positives. Measured
///    against the whole corpus at introduction: 2 violations, both real, none
///    spurious.
/// 2. ``auditRelativeLinks(repoRoot:)`` — every relative Markdown link to a
///    `.md` file resolves on disk.
/// 3. ``auditAnchors(repoRoot:)`` — every `file.md#anchor` cross-file link
///    resolves to a real heading, using GitHub's slug rules.
/// 4. ``auditIndexCoverage(repoRoot:)`` — every `docs/*.md` is referenced by
///    at least one other Markdown file, so a shipped doc is never
///    unreachable. Principle 9 promises "migration docs for every retired
///    API"; four migration docs were reachable from nowhere when this audit
///    was written, which satisfies the letter of that promise and none of its
///    purpose.
///
/// ## A note on the anchor slugger
///
/// GitHub replaces **each** space with a hyphen and does not collapse runs.
/// A heading like `### B1. Network ↔ device` therefore slugs to
/// `b1-network--device` (double hyphen — the `↔` is removed, its surrounding
/// spaces are not). A slugger that collapses whitespace reports six false
/// positives on this repo. ``githubSlug(_:)`` gets this right; do not
/// "simplify" it to a `\s+` collapse.
final class DocClaimsAuditTest: XCTestCase {

    /// Symbol names that legitimately appear in a DocC symbol link but are not
    /// declared in this package's `Sources/`. Add an entry ONLY for a symbol
    /// owned by another module (a companion package, an Apple framework) — a
    /// symbol that has simply been deleted must have its doc reference fixed,
    /// not silenced here.
    ///
    /// Keep this as short as possible.
    private static let allowedUnresolvedSymbols: Set<String> = [
        // manifold-llama companion package. `docs/THREAT_MODEL.md` documents
        // its `secureWipe()` because the threat model spans both repos. It
        // resolved "for free" until the index stopped harvesting comment
        // tokens — i.e. it was only ever passing by accident.
        "LlamaBackend",
    ]

    /// Docs deliberately reachable from no other Markdown file. Empty at
    /// introduction. A new entry needs a reason: "nothing links it yet" is a
    /// bug in the index, not a case for the allowlist.
    private static let allowedUnreferencedDocs: Set<String> = []

    // MARK: - The audit

    func test_docClaimsResolve() throws {
        let repoRoot = try Self.locateRepoRoot()

        // ── Floors: prove the audit actually looked at something ──────────
        //
        // Every check below returns "no violations" for an empty corpus, so a
        // green run is only meaningful alongside evidence that the corpus was
        // found. Without these, relocating `Sources/` or `docs/` turns the whole
        // suite into a no-op that still reports success — the inert-machinery
        // failure mode (#2274, #2287) applied to the audit itself.
        //
        // Numbers are ~60% of measured values at introduction: 151 markdown
        // files, 970 symbol links, and 11,526 source tokens. That token figure
        // is AFTER comment/string-literal stripping — an earlier draft set the
        // floor from a 22,121 pre-stripping measurement and tripped
        // immediately. Low enough not to tick on ordinary editing, high enough
        // that a collapsed corpus fails.
        let corpusFiles = Self.markdownFiles(repoRoot: repoRoot)
        XCTAssertGreaterThan(
            corpusFiles.count, 90,
            "Only \(corpusFiles.count) Markdown files found — the corpus collapsed; every check below would vacuously pass"
        )
        // Per-directory floor, not just the aggregate: `docs/` supplies 71 of
        // the 151 corpus files, so an aggregate-only floor of 90 would stop
        // catching a vanished `docs/` the moment the DocC catalogs grow past
        // ~80 files. Three of the four checks read `docs/` specifically, so
        // assert on it directly.
        let docsCount = try FileManager.default
            .contentsOfDirectory(at: repoRoot.appendingPathComponent("docs"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "md" }.count
        XCTAssertGreaterThan(
            docsCount, 40,
            "Only \(docsCount) docs/*.md found — the link, anchor and orphan checks would vacuously pass"
        )
        let tokenCount = Self.sourceTokenIndex(repoRoot: repoRoot).count
        XCTAssertGreaterThan(
            tokenCount, 7_000,
            "Symbol index has only \(tokenCount) tokens — Sources/ did not resolve properly"
        )
        let symbolLinkCount = corpusFiles.reduce(0) { total, url in
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return total }
            return total + content.components(separatedBy: .newlines).reduce(0) { $0 + Self.symbolLinks(in: $1).count }
        }
        XCTAssertGreaterThan(
            symbolLinkCount, 500,
            "Only \(symbolLinkCount) DocC symbol links found across the corpus — extraction is broken"
        )

        var violations: [String] = []
        violations.append(contentsOf: try Self.auditSymbolReferences(repoRoot: repoRoot))
        violations.append(contentsOf: try Self.auditRelativeLinks(repoRoot: repoRoot))
        violations.append(contentsOf: try Self.auditAnchors(repoRoot: repoRoot))
        violations.append(contentsOf: try Self.auditIndexCoverage(repoRoot: repoRoot))

        if !violations.isEmpty {
            let formatted = violations.sorted().map { "  \($0)" }.joined(separator: "\n")
            XCTFail("""
                Documentation makes claims that no longer hold. Each line below is a
                symbol that does not exist, a link that does not resolve, or a doc
                nothing points at.

                Fix the doc. Do NOT add an allowlist entry to silence a freshly
                broken reference — the allowlists in this file are for symbols owned
                by another package, not for deletions the docs haven't caught up with.

                \(formatted)
                """)
        }
    }

    // MARK: - 1. Symbol references

    /// Every identifier inside a `` ``…`` `` DocC symbol link must appear as a
    /// token somewhere under `Sources/`.
    static func auditSymbolReferences(repoRoot: URL) throws -> [String] {
        let sourceTokens = sourceTokenIndex(repoRoot: repoRoot)
        // An empty index means `Sources/` could not be enumerated at all —
        // never legitimate in this repo. Reporting "every symbol is missing"
        // would be worse than useless, but so would returning no violations:
        // that is a silent pass on the exact anomaly that would make this
        // check inert, and an audit that can quietly succeed while blind is
        // the fail-open shape Principle 6 bans. Throw instead, so the failure
        // is impossible to mistake for a clean run.
        guard !sourceTokens.isEmpty else {
            throw NSError(domain: "DocClaimsAuditTest", code: 2, userInfo: [
                NSLocalizedDescriptionKey: """
                    Built an empty symbol index from \(repoRoot.path)/Sources — the \
                    symbol check would silently pass on every doc. This means the \
                    repo root resolved somewhere unexpected or Sources/ is \
                    unreadable; it is never a legitimate state.
                    """,
            ])
        }

        var violations: [String] = []
        for fileURL in markdownFiles(repoRoot: repoRoot) {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let relative = relativePath(fileURL, under: repoRoot)

            for (lineNumber, line) in content.components(separatedBy: .newlines).enumerated() {
                for link in symbolLinks(in: line) {
                    // Strip a trailing argument list — ``foo(_:bar:)`` names the
                    // symbol `foo`; the label tokens are not declarations.
                    let subject = link.split(separator: "(").first.map(String.init) ?? link
                    for identifier in identifiers(in: subject) {
                        if sourceTokens.contains(identifier) { continue }
                        if allowedUnresolvedSymbols.contains(identifier) { continue }
                        violations.append(
                            "\(relative):\(lineNumber + 1)  symbol ``\(link)`` — `\(identifier)` not found in Sources/"
                        )
                    }
                }
            }
        }
        return violations
    }

    // MARK: - 2. Relative links

    /// Every relative Markdown link to a `.md` file must resolve on disk.
    static func auditRelativeLinks(repoRoot: URL) throws -> [String] {
        var violations: [String] = []
        for fileURL in markdownFiles(repoRoot: repoRoot) {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let base = fileURL.deletingLastPathComponent()
            let relative = relativePath(fileURL, under: repoRoot)

            for target in linkTargets(in: content) {
                guard let path = localMarkdownPath(from: target) else { continue }
                let resolved = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
                if !FileManager.default.fileExists(atPath: resolved.path) {
                    violations.append("\(relative)  broken link → \(target)")
                }
            }
        }
        return violations
    }

    // MARK: - 3. Anchors

    /// Every `file.md#anchor` cross-file link must resolve to a real heading.
    static func auditAnchors(repoRoot: URL) throws -> [String] {
        var headingCache: [String: Set<String>] = [:]

        var violations: [String] = []
        for fileURL in markdownFiles(repoRoot: repoRoot) {
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let base = fileURL.deletingLastPathComponent()
            let relative = relativePath(fileURL, under: repoRoot)

            for target in linkTargets(in: content) {
                let parts = target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2, !parts[1].isEmpty else { continue }
                guard let path = localMarkdownPath(from: String(parts[0])) else { continue }

                let resolved = URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL
                // A missing file is auditRelativeLinks' finding, not ours —
                // reporting it twice just doubles the noise.
                guard FileManager.default.fileExists(atPath: resolved.path) else { continue }

                let anchors: Set<String>
                if let cached = headingCache[resolved.path] {
                    anchors = cached
                } else {
                    anchors = headingAnchors(of: resolved)
                    headingCache[resolved.path] = anchors
                }

                let wanted = String(parts[1]).lowercased()
                if anchors.contains(wanted) { continue }
                // GitHub disambiguates repeated headings with `-1`, `-2`, …
                // Accept such a suffix only when the base heading genuinely
                // occurs more than once: accepting it unconditionally lets
                // `#foo-7` resolve against a single `## Foo`, which 404s.
                if let range = wanted.range(of: #"-\d+$"#, options: .regularExpression) {
                    let base = String(wanted[wanted.startIndex..<range.lowerBound])
                    let suffix = Int(wanted[range].dropFirst()) ?? Int.max
                    if anchors.contains(base), suffix < headingOccurrences(of: base, in: resolved) {
                        continue
                    }
                }
                violations.append("\(relative)  broken anchor → \(target)")
            }
        }
        return violations
    }

    // MARK: - 4. Index coverage

    /// Every `docs/*.md` must be referenced by at least one other Markdown file.
    static func auditIndexCoverage(repoRoot: URL) throws -> [String] {
        let docsDir = repoRoot.appendingPathComponent("docs")
        // Throw rather than `return []`: an unreadable docs/ would otherwise
        // report "no orphans" while having looked at nothing.
        let entries = try FileManager.default.contentsOfDirectory(
            at: docsDir, includingPropertiesForKeys: nil
        )

        let candidates = entries
            .filter { $0.pathExtension == "md" }
            .filter { $0.lastPathComponent != "README.md" }   // the index itself

        // Concatenate every OTHER markdown file once, then test each basename
        // against it. A plain mention counts as a reference: the check is
        // "can a reader find this doc at all", not "is it linked correctly"
        // (auditRelativeLinks owns link correctness).
        var corpusByFile: [String: String] = [:]
        for fileURL in markdownFiles(repoRoot: repoRoot) {
            corpusByFile[fileURL.standardizedFileURL.path] =
                (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        }

        var violations: [String] = []
        for doc in candidates {
            let name = doc.lastPathComponent
            if allowedUnreferencedDocs.contains(name) { continue }
            let selfPath = doc.standardizedFileURL.path
            let referenced = corpusByFile.contains { path, content in
                path != selfPath && content.contains(name)
            }
            if !referenced {
                violations.append("docs/\(name)  is referenced by no other Markdown file (orphaned)")
            }
        }
        return violations
    }

    // MARK: - Sabotage (each exercises the REAL detection function)

    /// Plants a doc naming a symbol that exists and one that does not, and
    /// asserts ``auditSymbolReferences(repoRoot:)`` flags only the missing one.
    func test_sabotage_auditSymbolReferencesDetectsDeletedSymbol() throws {
        let tmp = try Self.makeTempRoot("doc-claims-symbol")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sourcesDir = tmp.appendingPathComponent("Sources/ManifoldPlanted", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        try "public struct PlantedRealType { public var plantedMember: Int = 0 }"
            .write(to: sourcesDir.appendingPathComponent("Planted.swift"), atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("docs"), withIntermediateDirectories: true
        )
        try """
        The framework ships ``PlantedTotallyDeletedType`` for this.
        It also ships ``PlantedRealType`` and ``PlantedRealType/plantedMember``.
        """.write(to: tmp.appendingPathComponent("docs/planted.md"), atomically: true, encoding: .utf8)

        let violations = try Self.auditSymbolReferences(repoRoot: tmp)
        XCTAssertTrue(
            violations.contains { $0.contains("PlantedTotallyDeletedType") },
            "The planted reference to a nonexistent symbol must be flagged; got \(violations)"
        )
        XCTAssertFalse(
            violations.contains { $0.contains("PlantedRealType") },
            "A symbol that exists in Sources/ must not be flagged; got \(violations)"
        )
    }

    /// A repo root with no readable `Sources/` must make
    /// ``auditSymbolReferences(repoRoot:)`` **throw**, not quietly return zero
    /// violations.
    ///
    /// This guards a fail-open that shipped in the first draft of this file:
    /// the guard returned `[]`, so if the root ever resolved somewhere without
    /// a `Sources/` directory the symbol check would pass every doc while
    /// verifying nothing — indistinguishable from a clean run, which is
    /// precisely how inert machinery survives (#2274, #2287).
    func test_sabotage_auditSymbolReferencesThrowsOnEmptySourceIndex() throws {
        let tmp = try Self.makeTempRoot("doc-claims-empty-index")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // A doc naming a symbol that exists nowhere — the audit would report it
        // if it could see any sources at all.
        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("docs"), withIntermediateDirectories: true
        )
        try "Ships ``PlantedTotallyDeletedType``."
            .write(to: tmp.appendingPathComponent("docs/planted.md"), atomically: true, encoding: .utf8)

        XCTAssertThrowsError(
            try Self.auditSymbolReferences(repoRoot: tmp),
            "An unreadable/absent Sources/ must throw, not return zero violations"
        )
    }

    /// Plants a broken and a working relative `.md` link and asserts
    /// ``auditRelativeLinks(repoRoot:)`` flags only the broken one.
    func test_sabotage_auditRelativeLinksDetectsMissingTarget() throws {
        let tmp = try Self.makeTempRoot("doc-claims-links")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let docsDir = tmp.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        try "# Real".write(to: docsDir.appendingPathComponent("REAL.md"), atomically: true, encoding: .utf8)
        try """
        See [the real doc](REAL.md) and [the missing doc](TOTALLY-MISSING.md).
        Also [an external link](https://example.com/thing.md) which must be ignored.
        """.write(to: docsDir.appendingPathComponent("planted.md"), atomically: true, encoding: .utf8)

        let violations = try Self.auditRelativeLinks(repoRoot: tmp)
        XCTAssertTrue(
            violations.contains { $0.contains("TOTALLY-MISSING.md") },
            "The planted broken link must be flagged; got \(violations)"
        )
        XCTAssertFalse(
            violations.contains { $0.contains("REAL.md") },
            "A resolvable link must not be flagged; got \(violations)"
        )
        XCTAssertFalse(
            violations.contains { $0.contains("example.com") },
            "An external URL must not be treated as a relative path; got \(violations)"
        )
    }

    /// Plants a broken and a working cross-file anchor — including a heading
    /// whose slug contains a double hyphen — and asserts
    /// ``auditAnchors(repoRoot:)`` flags only the broken one.
    func test_sabotage_auditAnchorsDetectsMissingHeading() throws {
        let tmp = try Self.makeTempRoot("doc-claims-anchors")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let docsDir = tmp.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        try """
        # Target
        ## Planted Heading
        ### B1. Network ↔ device
        ### `planted_snake` escape hatch
        ## Solo

        ```bash
        # Fenced Not A Heading
        ```

        ~~~text
        # Tilde Fenced Not A Heading
        ~~~
        """.write(to: docsDir.appendingPathComponent("TARGET.md"), atomically: true, encoding: .utf8)
        try """
        Good: [a](TARGET.md#planted-heading).
        Double-hyphen slug: [b](TARGET.md#b1-network--device).
        Underscore kept: [c](TARGET.md#planted_snake-escape-hatch).
        Bad: [d](TARGET.md#no-such-heading).
        Fenced: [e](TARGET.md#fenced-not-a-heading).
        Tilde-fenced: [f](TARGET.md#tilde-fenced-not-a-heading).
        Bogus dup suffix: [g](TARGET.md#solo-3).
        """.write(to: docsDir.appendingPathComponent("planted.md"), atomically: true, encoding: .utf8)

        let violations = try Self.auditAnchors(repoRoot: tmp)
        XCTAssertTrue(
            violations.contains { $0.contains("no-such-heading") },
            "The planted broken anchor must be flagged; got \(violations)"
        )
        XCTAssertFalse(
            violations.contains { $0.contains("planted-heading") },
            "A resolvable anchor must not be flagged; got \(violations)"
        )
        XCTAssertFalse(
            violations.contains { $0.contains("b1-network--device") },
            """
            A heading slug with a double hyphen (from a removed non-word \
            character between two spaces) must resolve — a whitespace-collapsing \
            slugger reports this as broken. Got \(violations)
            """
        )
        // Fence-awareness. Without it, `# Fenced Not A Heading` inside a
        // ```bash block becomes a real anchor and these links resolve here
        // while 404ing on GitHub. Measured on this repo: 44 heading-shaped
        // lines live inside fenced blocks. Reverting the fence tracking must
        // turn these two red.
        XCTAssertTrue(
            violations.contains { $0.contains("fenced-not-a-heading") },
            "A heading-shaped line inside a ``` fence is not an anchor — a link to it must be flagged; got \(violations)"
        )
        XCTAssertTrue(
            violations.contains { $0.contains("tilde-fenced-not-a-heading") },
            "Same for ~~~ fences; got \(violations)"
        )
        // Duplicate-heading suffixes. GitHub only mints `-N` when a heading
        // actually repeats, so `#solo-3` against a single `## Solo` 404s.
        // Accepting any `-\d+$` unconditionally (the pre-fix behaviour) makes
        // this pass.
        XCTAssertTrue(
            violations.contains { $0.contains("solo-3") },
            "`#solo-3` against a single `## Solo` must be flagged; got \(violations)"
        )
        XCTAssertFalse(
            violations.contains { $0.contains("planted_snake") },
            """
            An intra-word underscore must survive slugging — GitHub keeps it. \
            A slugger that strips `_` along with the code ticks turns \
            `os_log` into `oslog` and wrongly flags every link to such a \
            heading. Got \(violations)
            """
        )
    }

    /// The symbol index must not accept a name that survives only inside a
    /// comment or a string literal.
    ///
    /// Without this, one `// Foo was removed in vX` line keeps `Foo` valid
    /// forever — and the repo was in exactly that state: `DefaultBackends`
    /// (retired) survived as a token in 9 files and `StructuredHistoryReceiver`
    /// (removed) in 1, all doc comments, so a doc claiming either existed
    /// passed. Removals that leave a "this used to be X" comment are precisely
    /// the removals whose docs go stale, so the blind spot pointed the same
    /// direction as the failure mode.
    func test_sabotage_sourceIndexIgnoresCommentAndStringTokens() throws {
        let tmp = try Self.makeTempRoot("doc-claims-comment-residue")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let sourcesDir = tmp.appendingPathComponent("Sources/ManifoldPlanted", isDirectory: true)
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        try """
        // PlantedInLineComment was removed in v9.9.9 — historical note only.
        /* PlantedInBlockComment also removed. */
        public struct PlantedRealDecl {
            let label = "PlantedInStringLiteral"
            let raw = #"say "PlantedInRawString" now"#
        }
        """.write(to: sourcesDir.appendingPathComponent("Planted.swift"), atomically: true, encoding: .utf8)

        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("docs"), withIntermediateDirectories: true
        )
        try """
        Ships ``PlantedInLineComment``, ``PlantedInBlockComment``,
        ``PlantedInStringLiteral``, ``PlantedInRawString`` and ``PlantedRealDecl``.
        """.write(to: tmp.appendingPathComponent("docs/planted.md"), atomically: true, encoding: .utf8)

        let violations = try Self.auditSymbolReferences(repoRoot: tmp)
        for ghost in ["PlantedInLineComment", "PlantedInBlockComment", "PlantedInStringLiteral", "PlantedInRawString"] {
            XCTAssertTrue(
                violations.contains { $0.contains(ghost) },
                "`\(ghost)` exists only in a comment or string literal and must be flagged; got \(violations)"
            )
        }
        XCTAssertFalse(
            violations.contains { $0.contains("PlantedRealDecl") },
            "A real declaration must still resolve; got \(violations)"
        )
    }

    /// A DocC `Extensions/Foo.md` file must NOT vouch for the symbol `Foo`.
    ///
    /// Indexing symbol-extension filenames is circular validation: it answers
    /// "does `Foo` exist?" with "yes, a doc file is named after it", so
    /// deleting the type while leaving its extension file behind keeps every
    /// doc claiming ``Foo`` green. Article names (non-`Extensions/`) are a
    /// legitimate link target and must still resolve.
    func test_sabotage_docCExtensionFilenameDoesNotVouchForSymbol() throws {
        let tmp = try Self.makeTempRoot("doc-claims-extension-residue")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let catalog = tmp.appendingPathComponent("Sources/ManifoldPlanted/ManifoldPlanted.docc", isDirectory: true)
        try FileManager.default.createDirectory(
            at: catalog.appendingPathComponent("Extensions"), withIntermediateDirectories: true
        )
        try "# ``PlantedDeletedType``".write(
            to: catalog.appendingPathComponent("Extensions/PlantedDeletedType.md"),
            atomically: true, encoding: .utf8
        )
        try "# Planted Article".write(
            to: catalog.appendingPathComponent("PlantedArticle.md"), atomically: true, encoding: .utf8
        )
        try "public struct PlantedAnchorDecl {}".write(
            to: tmp.appendingPathComponent("Sources/ManifoldPlanted/Planted.swift"),
            atomically: true, encoding: .utf8
        )

        try FileManager.default.createDirectory(
            at: tmp.appendingPathComponent("docs"), withIntermediateDirectories: true
        )
        try "See ``PlantedDeletedType`` and ``PlantedArticle``."
            .write(to: tmp.appendingPathComponent("docs/planted.md"), atomically: true, encoding: .utf8)

        let violations = try Self.auditSymbolReferences(repoRoot: tmp)
        XCTAssertTrue(
            violations.contains { $0.contains("PlantedDeletedType") },
            "An Extensions/ filename must not vouch for its own symbol; got \(violations)"
        )
        XCTAssertFalse(
            violations.contains { $0.contains("PlantedArticle") },
            "A DocC article name is a legitimate link target and must resolve; got \(violations)"
        )
    }

    /// An unreadable `docs/` must make ``auditIndexCoverage(repoRoot:)`` throw.
    ///
    /// It returned `[]` before — "no orphans" from a directory it never read,
    /// the sibling of the symbol-index fail-open and green in exactly the same
    /// way.
    func test_sabotage_auditIndexCoverageThrowsOnUnreadableDocs() throws {
        let tmp = try Self.makeTempRoot("doc-claims-docs-unreadable")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // No docs/ directory at all — the same observable state as unreadable.
        XCTAssertThrowsError(
            try Self.auditIndexCoverage(repoRoot: tmp),
            "An absent/unreadable docs/ must throw, not report zero orphans"
        )
    }

    /// Plants a referenced and an unreferenced doc and asserts
    /// ``auditIndexCoverage(repoRoot:)`` flags only the orphan.
    func test_sabotage_auditIndexCoverageDetectsOrphanedDoc() throws {
        let tmp = try Self.makeTempRoot("doc-claims-index")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let docsDir = tmp.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docsDir, withIntermediateDirectories: true)
        try "# Index\nSee [linked](PLANTED-LINKED.md)."
            .write(to: docsDir.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "# Linked".write(to: docsDir.appendingPathComponent("PLANTED-LINKED.md"), atomically: true, encoding: .utf8)
        try "# Orphan".write(to: docsDir.appendingPathComponent("PLANTED-ORPHAN.md"), atomically: true, encoding: .utf8)

        let violations = try Self.auditIndexCoverage(repoRoot: tmp)
        XCTAssertTrue(
            violations.contains { $0.contains("PLANTED-ORPHAN.md") },
            "The planted orphaned doc must be flagged; got \(violations)"
        )
        XCTAssertFalse(
            violations.contains { $0.contains("PLANTED-LINKED.md") },
            "A referenced doc must not be flagged; got \(violations)"
        )
    }

    // MARK: - Corpus

    /// The Markdown surface these audits walk: root-level docs, everything
    /// under `docs/`, and every DocC catalog article.
    ///
    /// Enumeration is deliberately explicit rather than a walk from the repo
    /// root: this repository keeps agent worktrees under `.claude/worktrees/`
    /// and Xcode output under `DerivedData/`, each of which contains a full
    /// second copy of the tree. A naive recursive walk would audit those
    /// copies too.
    static func markdownFiles(repoRoot: URL) -> [URL] {
        var files: [URL] = []
        let fm = FileManager.default

        if let rootEntries = try? fm.contentsOfDirectory(at: repoRoot, includingPropertiesForKeys: nil) {
            files.append(contentsOf: rootEntries.filter { $0.pathExtension == "md" })
        }

        for subdirectory in ["docs", "Sources"] {
            let dir = repoRoot.appendingPathComponent(subdirectory)
            guard let enumerator = fm.enumerator(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "md" {
                files.append(url)
            }
        }
        return files
    }

    /// Every identifier-shaped token appearing anywhere under `Sources/`.
    ///
    /// Built once per audit call. A token check (rather than a declaration
    /// parse) is the point: the audit is looking for symbols that no longer
    /// exist *at all*, and the loose predicate keeps false positives at zero.
    static func sourceTokenIndex(repoRoot: URL) -> Set<String> {
        let sourcesDir = repoRoot.appendingPathComponent("Sources")
        guard let enumerator = FileManager.default.enumerator(
            at: sourcesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        var tokens = Set<String>()
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for token in identifiers(in: strippingCommentsAndStringLiterals(content)) {
                tokens.insert(token)
            }
        }

        // A DocC link may legitimately target something that is not a Swift
        // declaration: a module (``ManifoldVoice``) or another article
        // (``BuildingAChatUI``). Those names live in the directory layout, not
        // in any `.swift` body — before comment-stripping they leaked into the
        // index via `import` lines and prose in comments, which is not a
        // guarantee worth relying on. Add them deliberately instead.
        if let moduleEntries = try? FileManager.default.contentsOfDirectory(
            at: sourcesDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) {
            for entry in moduleEntries {
                tokens.insert(entry.lastPathComponent)          // module name
            }
        }
        if let articleEnumerator = FileManager.default.enumerator(
            at: sourcesDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in articleEnumerator where url.pathExtension == "md" {
                // DocC catalogs only, and NOT `Extensions/` — the exclusion is
                // the whole point. An `Extensions/Foo.md` file is the
                // documentation *for* the symbol `Foo`, so indexing its
                // basename makes the audit answer "does `Foo` exist?" with
                // "yes, because a doc file is named after it". That is circular,
                // and it is the same half-done-removal shape this audit exists
                // to catch with the halves swapped: delete the type, leave the
                // extension file, and every doc claiming ``Foo`` still passes.
                // `ChatViewModel` and `InferenceService` — two of the most
                // referenced types in the corpus — were vouched for this way.
                //
                // Restricting to `.docc` also drops 13 non-catalog files
                // (fixture READMEs, ATTRIBUTION) whose basenames were becoming
                // valid "symbols" (`photosynthesis`, `chlorophyll`, `backend-a`).
                let path = url.path
                guard path.contains(".docc/"), !path.contains(".docc/Extensions/") else { continue }
                tokens.insert(url.deletingPathExtension().lastPathComponent)  // article name
            }
        }
        return tokens
    }

    /// Removes `//` line comments, `/* … */` block comments, and string
    /// literals from Swift source before tokenising.
    ///
    /// Without this the index is defeated by comment residue, which is the
    /// dominant real-world case rather than a corner: a removal that leaves
    /// behind a "this used to be `X`" doc comment keeps `X` in the index
    /// forever, so a doc still claiming `X` exists passes. Measured on this
    /// repo at the time of writing, `DefaultBackends` (retired) survived as a
    /// token in **9** files and `StructuredHistoryReceiver` (removed — the type
    /// that reddened the companion canary on 2026-07-20) in 1, all of them doc
    /// comments. Removals that leave such a comment are exactly the removals
    /// whose docs go stale, so the blind spot lined up precisely with the
    /// failure mode.
    ///
    /// Handles line/block comments (nested), `"…"` with escapes, `"""…"""`,
    /// and raw strings (`#"…"#`, `##"…"##`). Raw strings matter for
    /// correctness, not completeness: an embedded quote inside `#"…"#` used to
    /// end string state early, so a dead symbol after it re-entered the index —
    /// an **under**-strip, which is a silent pass, the one direction this
    /// function must never fail in. (Zero such literals exist in `Sources/`
    /// today; it was guarded before it could bite.)
    ///
    /// Known and deliberate: string *interpolation* is over-stripped, so
    /// `"\(RealType.name)"` does not contribute `RealType`. That is the safe
    /// direction — a false positive is loud and fixable — and harmless in
    /// practice because the index is a union over ~700 files, where any live
    /// type is declared somewhere outside a string.
    static func strippingCommentsAndStringLiterals(_ source: String) -> String {
        var out = ""
        out.reserveCapacity(source.count)

        var iterator = source.startIndex
        var blockDepth = 0
        var inLineComment = false
        var inString = false
        var inMultilineString = false
        var rawStringHashes = 0   // >0 while inside #"…"# / ##"…"##

        while iterator < source.endIndex {
            let remaining = source[iterator...]

            if inLineComment {
                if source[iterator] == "\n" { inLineComment = false; out.append("\n") }
                iterator = source.index(after: iterator); continue
            }
            if blockDepth > 0 {
                if remaining.hasPrefix("*/") {
                    blockDepth -= 1
                    iterator = source.index(iterator, offsetBy: 2); continue
                }
                if remaining.hasPrefix("/*") {
                    blockDepth += 1
                    iterator = source.index(iterator, offsetBy: 2); continue
                }
                if source[iterator] == "\n" { out.append("\n") }
                iterator = source.index(after: iterator); continue
            }
            if rawStringHashes > 0 {
                // Terminates on `"` followed by exactly the opening hash count.
                if source[iterator] == "\"" {
                    let closer = "\"" + String(repeating: "#", count: rawStringHashes)
                    if remaining.hasPrefix(closer) {
                        rawStringHashes = 0
                        iterator = source.index(iterator, offsetBy: closer.count); continue
                    }
                }
                iterator = source.index(after: iterator); continue
            }
            if inMultilineString {
                if remaining.hasPrefix("\"\"\"") {
                    inMultilineString = false
                    iterator = source.index(iterator, offsetBy: 3); continue
                }
                iterator = source.index(after: iterator); continue
            }
            if inString {
                if source[iterator] == "\\" {
                    // Skip the escape and whatever it escapes.
                    iterator = source.index(iterator, offsetBy: min(2, source.distance(from: iterator, to: source.endIndex)))
                    continue
                }
                if source[iterator] == "\"" { inString = false }
                iterator = source.index(after: iterator); continue
            }

            if source[iterator] == "#" {
                // Count hashes; `#"` (any number) opens a raw string.
                var hashes = 0
                var probe = iterator
                while probe < source.endIndex, source[probe] == "#" {
                    hashes += 1; probe = source.index(after: probe)
                }
                if probe < source.endIndex, source[probe] == "\"" {
                    rawStringHashes = hashes
                    iterator = source.index(after: probe); continue
                }
            }
            if remaining.hasPrefix("//") { inLineComment = true; iterator = source.index(iterator, offsetBy: 2); continue }
            if remaining.hasPrefix("/*") { blockDepth = 1; iterator = source.index(iterator, offsetBy: 2); continue }
            if remaining.hasPrefix("\"\"\"") { inMultilineString = true; iterator = source.index(iterator, offsetBy: 3); continue }
            if source[iterator] == "\"" { inString = true; iterator = source.index(after: iterator); continue }

            out.append(source[iterator])
            iterator = source.index(after: iterator)
        }
        return out
    }

    // MARK: - Extraction

    /// The contents of every `` ``…`` `` DocC symbol link on a line.
    static func symbolLinks(in line: String) -> [String] {
        matches(of: "``([^`\n]+)``", in: line)
    }

    /// Markdown inline-link targets — the `TARGET` in `](TARGET)`.
    static func linkTargets(in content: String) -> [String] {
        matches(of: #"\]\(([^)\s]+)\)"#, in: content)
    }

    /// Identifier-shaped tokens in `text`.
    static func identifiers(in text: String) -> [String] {
        matches(of: "([A-Za-z_][A-Za-z0-9_]*)", in: text)
    }

    /// The path portion of `target` if it is a relative link to a local `.md`
    /// file, else `nil` (external URLs, mailto, in-page anchors, non-Markdown).
    static func localMarkdownPath(from target: String) -> String? {
        let path = String(target.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
        guard !path.isEmpty else { return nil }              // pure in-page anchor
        guard !path.contains("://"), !path.hasPrefix("mailto:") else { return nil }
        guard path.lowercased().hasSuffix(".md") else { return nil }
        return path
    }

    /// The set of anchors GitHub would generate for `fileURL`'s headings.
    static func headingAnchors(of fileURL: URL) -> Set<String> {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        var anchors = Set<String>()
        // Fence tracking is required, not cosmetic: `# comment` lines inside a
        // ```bash block are not headings, and GitHub does not create anchors
        // for them. Measured on this repo, 44 heading-shaped lines live inside
        // fenced blocks (`# Pin to one model` in FUZZING.md, `# project.yml`,
        // …). Harvesting them makes a link to a phantom anchor resolve, so the
        // check would pass where GitHub 404s.
        var openFence: String? = nil
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = openFence {
                if trimmed.hasPrefix(fence) { openFence = nil }
                continue
            }
            if trimmed.hasPrefix("```") { openFence = "```"; continue }
            if trimmed.hasPrefix("~~~") { openFence = "~~~"; continue }
            guard let heading = matches(of: #"^#{1,6}\s+(.*)$"#, in: line).first else { continue }
            // Strip inline formatting GitHub drops before slugging: link
            // syntax (keeping the label), code ticks, bold/italic asterisks.
            //
            // Underscores are deliberately NOT stripped. GitHub slugs the
            // *rendered* text, so `_emphasis_` would lose its underscores —
            // but an intra-word underscore is kept, and this repo's headings
            // carry plenty of those (`os_log`, `@_exported`, `prefill_progress`)
            // and no underscore-emphasis at all. Stripping `_` would slug
            // `` `os_log` content escape `` to `oslog-…` and wrongly flag any
            // link to it.
            var text = heading
            text = replacing(#"\[([^\]]*)\]\([^)]*\)"#, with: "$1", in: text)
            text = replacing("[`*]", with: "", in: text)
            anchors.insert(githubSlug(text))
        }
        return anchors
    }

    /// How many headings in `fileURL` slug to `slug` — GitHub only mints a
    /// `-N` suffix when a heading repeats.
    static func headingOccurrences(of slug: String, in fileURL: URL) -> Int {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { return 0 }
        var count = 0
        var openFence: String? = nil
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = openFence {
                if trimmed.hasPrefix(fence) { openFence = nil }
                continue
            }
            if trimmed.hasPrefix("```") { openFence = "```"; continue }
            if trimmed.hasPrefix("~~~") { openFence = "~~~"; continue }
            guard let heading = matches(of: #"^#{1,6}\s+(.*)$"#, in: line).first else { continue }
            var text = heading
            text = replacing(#"\[([^\]]*)\]\([^)]*\)"#, with: "$1", in: text)
            text = replacing("[`*]", with: "", in: text)
            if githubSlug(text) == slug { count += 1 }
        }
        return count
    }

    /// GitHub's heading-slug algorithm: lowercase, drop everything that is not
    /// a word character / whitespace / hyphen, then replace **each** remaining
    /// space with a hyphen.
    ///
    /// The per-space replacement is load-bearing — see the type-level note.
    static func githubSlug(_ heading: String) -> String {
        let lowered = heading.trimmingCharacters(in: .whitespaces).lowercased()
        let stripped = lowered.unicodeScalars.filter { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || CharacterSet.whitespaces.contains(scalar)
                || scalar == "-"
                || scalar == "_"
        }
        return String(String.UnicodeScalarView(stripped))
            .replacingOccurrences(of: " ", with: "-")
    }

    // MARK: - Regex helpers

    /// The first capture group of every match of `pattern` in `text`.
    static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[r])
        }
    }

    private static func replacing(_ pattern: String, with template: String, in text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template
        )
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
        throw NSError(domain: "DocClaimsAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Package.swift from #filePath",
        ])
    }

    static func relativePath(_ url: URL, under root: URL) -> String {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return path
    }
}
