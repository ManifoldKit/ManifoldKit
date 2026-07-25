import XCTest

/// Tripwire for **doc claims** — the assertions a doc makes about the world,
/// as opposed to its *form*.
///
/// ## Why this exists
///
/// The repo already audits documentation form: `DocsAudienceStatusAuditTest`
/// checks every doc carries an `**Audience:**` / `**Status:**` header (56/56
/// compliant), and `DocSourcePathReferenceAuditTest` checks `Sources/…` link
/// targets resolve. Nothing checked whether a doc's *claims* were true — that
/// a symbol it names still exists, that a link it offers still resolves, that
/// a doc it ships is reachable at all.
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
    /// Empty at introduction: the whole corpus resolved cleanly once the
    /// wake-word references were removed. Keep it that way if you can.
    private static let allowedUnresolvedSymbols: Set<String> = []

    /// Docs deliberately reachable from no other Markdown file. Empty at
    /// introduction. A new entry needs a reason: "nothing links it yet" is a
    /// bug in the index, not a case for the allowlist.
    private static let allowedUnreferencedDocs: Set<String> = []

    // MARK: - The audit

    func test_docClaimsResolve() throws {
        let repoRoot = try Self.locateRepoRoot()

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
        // An empty index means we failed to find Sources/ at all — reporting
        // "every symbol is missing" would be worse than useless, so bail loudly
        // rather than emitting thousands of phantom violations.
        guard !sourceTokens.isEmpty else { return [] }

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
                // GitHub disambiguates repeated headings with a `-1`, `-2` …
                // suffix. Accept those when the base heading exists.
                if let range = wanted.range(of: #"-\d+$"#, options: .regularExpression),
                   anchors.contains(String(wanted[wanted.startIndex..<range.lowerBound])) {
                    continue
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
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: docsDir, includingPropertiesForKeys: nil
        ) else { return [] }

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
        """.write(to: docsDir.appendingPathComponent("TARGET.md"), atomically: true, encoding: .utf8)
        try """
        Good: [a](TARGET.md#planted-heading).
        Double-hyphen slug: [b](TARGET.md#b1-network--device).
        Bad: [c](TARGET.md#no-such-heading).
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
            for token in identifiers(in: content) {
                tokens.insert(token)
            }
        }
        return tokens
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
        for line in content.components(separatedBy: .newlines) {
            guard let heading = matches(of: #"^#{1,6}\s+(.*)$"#, in: line).first else { continue }
            // Strip inline formatting GitHub drops before slugging: link
            // syntax (keeping the label), code ticks, bold/italic markers.
            var text = heading
            text = replacing(#"\[([^\]]*)\]\([^)]*\)"#, with: "$1", in: text)
            text = replacing("[`*_]", with: "", in: text)
            anchors.insert(githubSlug(text))
        }
        return anchors
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
