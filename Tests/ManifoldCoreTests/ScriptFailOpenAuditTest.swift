import XCTest
import Darwin

/// Audit: shell scripts under `scripts/` must not fail open.
///
/// Machinery whose failure mode is *silence* — and `scripts/` is exactly
/// that class (gates, lints, canaries, benchmarks) — must not swallow the
/// errors it exists to surface: fail-open code cannot go red, so a green
/// run is indistinguishable from an inert one. The canonical in-repo
/// incident is the `| tail` exit-code mask that let a red `test.sh` run
/// read as green.
///
/// Four rules, scanned over every `scripts/**/*.sh`:
///
/// 1. **`set -euo pipefail`.** The canonical line must appear somewhere in
///    the file (position is not enforced — api-surface-baseline.sh's sits
///    at line 219 after a long preamble). A deliberate deviation
///    (report-all-failures sweeps that drop `-e`, sourced libraries that
///    set nothing) is approved by a `fail-open-ok: <reason>` marker on a
///    `set` line anywhere, or on a comment line in the first 80 lines
///    (the sourced-library case, which has no `set` line at all).
/// 2. **`set +e` must re-arm.** Every `set +e` needs a subsequent `set -e`
///    in the same file (the capture-exit-code idiom), or an annotation.
/// 3. **`|| true` / `|| :` must be justified.** Approved three ways:
///    - a `fail-open-ok: <reason>` marker on the line or within the three
///      lines above it;
///    - a **tolerant-command idiom**: the command whose status is being
///      discarded (the last pipeline segment before the `||`, after
///      stripping quoted strings) is one whose non-zero exit routinely
///      means "nothing found / already gone", e.g. `grep`, `kill`, `rm`,
///      `comm`, `head`; see ``tolerantCommands``;
///    - a `--version` probe.
///    **No idiom escape** exists for lines invoking a load-bearing
///    producer (`swift build|test|run`, `xcodebuild`, `git push`): masking
///    those is how a benchmark silently measures a stale binary. Only an
///    explicit annotation (or a fix) clears them.
/// 4. **A bare marker is itself a finding.** `fail-open-ok:` with no
///    reason text defeats the point — the reason *is* the suppression.
///
/// Deliberate non-goals: standalone `2>/dev/null` (with `set -e` enforced
/// it silences text, not exit status); heredoc/quoted-string false
/// positives beyond the quote-stripping heuristic (comment lines are
/// skipped; the codebase keeps `|| true` on code lines); staleness of
/// `fail-open-ok` markers (an orphaned reason is documentation, not a
/// hazard). Inline `bash` in `.github/workflows` is out of scope here —
/// workflow-level gates are covered by the review-loop "demonstrated red"
/// discipline in AGENTS.md, not a file audit.
///
/// The full detection pipeline lives in ``scan(scriptsRoot:)`` so the
/// in-file sabotage tests exercise the exact function the audit runs.
final class ScriptFailOpenAuditTest: XCTestCase {

    struct Offence: Equatable {
        let file: String
        let line: Int
        let rule: String
        let text: String
    }

    /// Commands whose non-zero exit is routinely "no result", not "the
    /// operation failed": search/compare tools (`grep` exits 1 on no
    /// match, `diff`/`comm` on difference), best-effort process/cleanup
    /// verbs (`kill` on already-exited, `rm` on already-gone), and
    /// text-pipeline terminals (`head` SIGPIPEs its producer by design).
    /// Adding a command widens the approved set globally — prefer a
    /// per-line `fail-open-ok:` for one-off cases.
    static let tolerantCommands: [String] = [
        "grep", "rg", "comm", "diff",
        "kill", "pkill", "wait", "rm", "mkdir",
        "ps", "nm", "otool", "strings", "strip", "find",
        "head", "tail", "sort", "uniq", "cut", "sed", "awk", "wc", "tr",
    ]

    func test_scriptsDirectoryContainsNoUnapprovedFailOpenIdioms() throws {
        let scriptsURL = try Self.locateScriptsDirectory()
        let offences = try Self.scan(scriptsRoot: scriptsURL)

        if !offences.isEmpty {
            let formatted = offences
                .map { "  \($0.file):\($0.line)  [\($0.rule)]  \($0.text)" }
                .joined(separator: "\n")
            XCTFail("""
                Fail-open shell idioms found in scripts/. Either fix the swallow \
                (a gate that cannot go red is not a gate) or, if the tolerance is \
                genuine, add `# fail-open-ok: <reason>` on or just above the line \
                — the reason is the point; a bare marker is itself flagged.

                \(formatted)
                """)
        }
    }

    // MARK: - Sabotage (exercises the same `scan(scriptsRoot:)` the audit runs)

    /// Plants a temp scripts tree containing one violation of each rule
    /// plus idiom-approved and annotation-approved lines, and asserts the
    /// REAL detection pipeline flags exactly the violations.
    func test_sabotage_scanFlagsPlantedViolations() throws {
        let tmp = try Self.makeSabotageTempDirectory(
            name: "script-fail-open-sabotage-\(UUID().uuidString)"
        )
        defer {
            do { try FileManager.default.removeItem(at: tmp) } catch {
                // Best-effort temp cleanup; nothing to assert on.
            }
        }

        // Rule 1: missing set header entirely.
        try """
        #!/usr/bin/env bash
        echo "no set line at all"
        """.write(to: tmp.appendingPathComponent("no-header.sh"), atomically: true, encoding: .utf8)

        // Rule 2: set +e never re-armed. Rule 3: hard-tier and plain
        // unapproved swallows alongside idiom- and marker-approved ones.
        // Rule 4: a bare marker with no reason.
        try """
        #!/usr/bin/env bash
        set -euo pipefail
        set +e
        swift build --product Foo 2>&1 | tail -1 || true
        mystery-command --flag || true
        grep -c "pattern" file.txt || true
        important-step || true  # fail-open-ok: partial results are still scored below
        another-step || true  # fail-open-ok:
        """.write(to: tmp.appendingPathComponent("swallows.sh"), atomically: true, encoding: .utf8)

        // Fully clean control file (deviant header, properly annotated).
        try """
        #!/usr/bin/env bash
        set -uo pipefail  # fail-open-ok: NOT -e — reports every lane's failure at the end
        set +e
        run-thing
        rc=$?
        set -e
        exit $rc
        """.write(to: tmp.appendingPathComponent("clean.sh"), atomically: true, encoding: .utf8)

        let offences = try Self.scan(scriptsRoot: tmp)

        func hits(_ rule: String, _ file: String) -> [Offence] {
            offences.filter { $0.rule == rule && $0.file == file }
        }

        XCTAssertEqual(hits("set-header", "no-header.sh").count, 1,
                       "A script with no set header must be flagged; got \(offences)")
        XCTAssertEqual(hits("set-plus-e", "swallows.sh").count, 1,
                       "set +e without a later set -e must be flagged; got \(offences)")
        XCTAssertTrue(offences.contains { $0.rule == "masked-load-bearing" && $0.text.contains("swift build") },
                      "`swift build … || true` must be flagged with no idiom escape; got \(offences)")
        XCTAssertTrue(offences.contains { $0.rule == "unapproved-or-true" && $0.text.contains("mystery-command") },
                      "A non-idiom `|| true` must be flagged; got \(offences)")
        XCTAssertFalse(offences.contains { $0.text.contains("grep -c") },
                       "grep is a tolerant idiom — `grep … || true` must NOT be flagged")
        XCTAssertFalse(offences.contains { $0.text.contains("important-step") },
                       "A reasoned fail-open-ok marker must exempt its line")
        XCTAssertTrue(offences.contains { $0.rule == "bare-suppression" && $0.text.contains("another-step") },
                      "A fail-open-ok marker with no reason must itself be flagged; got \(offences)")
        XCTAssertFalse(offences.contains { $0.file == "clean.sh" },
                       "The annotated-deviant-header + re-armed set +e file must be clean; got \(offences)")
    }

    /// The marker lookback must reach three lines up, and the hard tier
    /// must not be satisfiable by a tolerant idiom on the same line.
    func test_sabotage_markerLookbackAndHardTierPrecedence() throws {
        let tmp = try Self.makeSabotageTempDirectory(
            name: "script-fail-open-sabotage2-\(UUID().uuidString)"
        )
        defer {
            do { try FileManager.default.removeItem(at: tmp) } catch {
                // Best-effort temp cleanup; nothing to assert on.
            }
        }

        try """
        #!/usr/bin/env bash
        set -euo pipefail
        # fail-open-ok: multi-line statement — no match is a valid outcome
        result=$(some-producer \\
            --flag value \\
            || true)
        xcodebuild -scheme Foo 2>&1 | grep -E "ok" || true
        pin="$(printf '%s' "$content" | grep -m1 'a|b' || true)"
        """.write(to: tmp.appendingPathComponent("lookback.sh"), atomically: true, encoding: .utf8)

        let offences = try Self.scan(scriptsRoot: tmp)

        XCTAssertFalse(offences.contains { $0.text.contains("|| true)") },
                       "A marker three lines above a continuation `|| true` must exempt it; got \(offences)")
        XCTAssertTrue(offences.contains { $0.rule == "masked-load-bearing" && $0.text.contains("xcodebuild") },
                      "The grep idiom must NOT clear a line that masks xcodebuild; got \(offences)")
        XCTAssertFalse(offences.contains { $0.text.contains("pin=") },
                       """
                       The quoted-command-substitution shape `x="$(… | grep 'a|b' || true)"` \
                       must resolve to the grep idiom, not a false positive; got \(offences)
                       """)
    }

    // MARK: - Detection

    static func scan(scriptsRoot: URL) throws -> [Offence] {
        var offences: [Offence] = []
        for fileURL in try Self.enumerateShellScripts(under: scriptsRoot) {
            let relativePath = fileURL.path.replacingOccurrences(of: scriptsRoot.path + "/", with: "")
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: "\n")
            offences.append(contentsOf: Self.checkFile(relativePath: relativePath, lines: lines))
        }
        return offences.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
    }

    static func checkFile(relativePath: String, lines: [String]) -> [Offence] {
        var offences: [Offence] = []

        // Rule 1: canonical set line anywhere, or an annotated deviation —
        // a marker on a `set` line anywhere, or on a full comment line in
        // the first 80 lines (sourced libraries have no `set` line at all).
        // Eligibility stays narrow so an unrelated inline `fail-open-ok`
        // deep in the file cannot accidentally satisfy this rule.
        let hasCanonicalSetLine = lines.contains {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("set -euo pipefail")
        }
        if !hasCanonicalSetLine {
            let annotatedSetLine = lines.contains { line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("set ")
                    && Self.markerReason(in: line) != nil
            }
            let annotatedHeaderComment = lines.prefix(80).contains { line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("#")
                    && Self.markerReason(in: line) != nil
            }
            if !annotatedSetLine, !annotatedHeaderComment {
                offences.append(Offence(
                    file: relativePath, line: 1, rule: "set-header",
                    text: "no `set -euo pipefail` (or annotated deviation) anywhere in the file"
                ))
            }
        }

        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            // Rule 4: a marker with no reason, anywhere in the file.
            if rawLine.contains(Self.marker), Self.markerReason(in: rawLine) == nil {
                offences.append(Offence(
                    file: relativePath, line: index + 1, rule: "bare-suppression", text: trimmed
                ))
                continue
            }

            if trimmed.hasPrefix("#") { continue }

            // Rule 2: set +e must be re-armed later in the file.
            if trimmed.range(of: #"^set \+e\b"#, options: .regularExpression) != nil {
                let rearmed = lines[(index + 1)...].contains {
                    $0.trimmingCharacters(in: .whitespaces)
                        .range(of: #"^set -e\b"#, options: .regularExpression) != nil
                }
                if !rearmed, !Self.isAnnotated(lines: lines, index: index) {
                    offences.append(Offence(
                        file: relativePath, line: index + 1, rule: "set-plus-e", text: trimmed
                    ))
                }
                continue
            }

            // Rule 3: `|| true` / `|| :`.
            guard trimmed.range(of: Self.orTruePattern, options: .regularExpression) != nil else {
                continue
            }
            if Self.isAnnotated(lines: lines, index: index) { continue }
            if trimmed.range(of: Self.loadBearingPattern, options: .regularExpression) != nil {
                offences.append(Offence(
                    file: relativePath, line: index + 1, rule: "masked-load-bearing", text: trimmed
                ))
                continue
            }
            if Self.matchesTolerantIdiom(trimmed) { continue }
            offences.append(Offence(
                file: relativePath, line: index + 1, rule: "unapproved-or-true", text: trimmed
            ))
        }

        return offences
    }

    // MARK: - Helpers

    static let marker = "fail-open-ok:"

    /// `|| true` or `|| :` (the latter followed by a statement boundary).
    static let orTruePattern = #"\|\|\s*true\b|\|\|\s*:\s*($|[);])"#

    /// Producers whose failure must never be swallowed: a masked build or
    /// test run turns every downstream consumer into a liar (stale binary
    /// benchmarked, red suite summarized as green).
    static let loadBearingPattern = #"\b(swift\s+(build|test|run)|xcodebuild|git\s+push)\b"#

    /// `true` when the status being discarded belongs to a tolerant
    /// command: after stripping quoted strings (so a `|` inside a grep
    /// pattern doesn't break segment detection), the last pipeline
    /// segment before the `||` starts with a tolerant command — or the
    /// line is a `--version` probe.
    static func matchesTolerantIdiom(_ line: String) -> Bool {
        let stripped = Self.strippingQuotedSegments(from: line)
        guard let orRange = stripped.range(of: #"\|\|\s*(true\b|:)"#, options: .regularExpression) else {
            return false
        }
        let beforeOr = String(stripped[stripped.startIndex..<orRange.lowerBound])
        if beforeOr.contains("--version") || beforeOr.contains(" -version") { return true }
        let alternation = Self.tolerantCommands.joined(separator: "|")
        // The tolerant command must be the last status-bearing segment:
        // no `|` may sit between it and the `||`.
        let pattern = #"\b("# + alternation + #")\b[^|]*$"#
        return beforeOr.range(of: pattern, options: .regularExpression) != nil
    }

    /// Removes quoted substrings so shell metacharacters inside patterns
    /// (`grep -E 'a|b'`) don't confuse the segment logic, while keeping
    /// command text inside `$( … )` substitutions visible even when the
    /// substitution itself sits inside double quotes — the ubiquitous
    /// `var="$(cmd 'a|b' || true)"` shape. A small context stack, not a
    /// real shell parser: backticks, `$((…))` arithmetic, and pathological
    /// paren nesting are out of scope (documented heuristic; unterminated
    /// quotes conservatively drop the tail, i.e. less text to idiom-match).
    static func strippingQuotedSegments(from line: String) -> String {
        enum Context { case command, singleQuote, doubleQuote }
        var stack: [Context] = [.command]
        var result = ""
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            switch stack[stack.count - 1] {
            case .singleQuote:
                if ch == "'" { stack.removeLast() }
            case .doubleQuote:
                if ch == "\\", i + 1 < chars.count {
                    i += 2
                    continue
                }
                if ch == "\"" {
                    stack.removeLast()
                } else if ch == "$", i + 1 < chars.count, chars[i + 1] == "(" {
                    stack.append(.command)
                    i += 2
                    continue
                }
            case .command:
                if ch == "\\", i + 1 < chars.count {
                    result.append(ch)
                    result.append(chars[i + 1])
                    i += 2
                    continue
                }
                if ch == "'" {
                    stack.append(.singleQuote)
                } else if ch == "\"" {
                    stack.append(.doubleQuote)
                } else if ch == "$", i + 1 < chars.count, chars[i + 1] == "(" {
                    stack.append(.command)
                    i += 2
                    continue
                } else if ch == ")", stack.count > 1 {
                    stack.removeLast()
                } else {
                    result.append(ch)
                }
            }
            i += 1
        }
        return result
    }

    /// A reasoned marker on the line itself or within the three lines above.
    static func isAnnotated(lines: [String], index: Int) -> Bool {
        let lookback = max(0, index - 3)
        for i in lookback...index where Self.markerReason(in: lines[i]) != nil {
            return true
        }
        return false
    }

    /// The reason text following `fail-open-ok:`, or nil when the marker
    /// is absent or bare (< 3 non-whitespace characters of reason).
    static func markerReason(in line: String) -> String? {
        guard let range = line.range(of: Self.marker) else { return nil }
        let reason = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        guard reason.filter({ !$0.isWhitespace }).count >= 3 else { return nil }
        return reason
    }

    static func enumerateShellScripts(under root: URL) throws -> [URL] {
        var result: [URL] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        for case let url as URL in enumerator where url.pathExtension == "sh" {
            result.append(url)
        }
        return result.sorted { $0.path < $1.path }
    }

    /// Walks upward from this file to the repo root (the directory that
    /// contains both `Package.swift` and `scripts/`).
    private static func locateScriptsDirectory(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let scripts = dir.appendingPathComponent("scripts")
            let manifest = dir.appendingPathComponent("Package.swift")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: manifest.path),
               FileManager.default.fileExists(atPath: scripts.path, isDirectory: &isDir),
               isDir.boolValue {
                return scripts
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "ScriptFailOpenAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate scripts/ from #filePath",
        ])
    }

    /// Fully-resolved temp directory (see SilentCatchAuditTest for the
    /// /var → /private/var APFS-firmlink rationale).
    private static func makeSabotageTempDirectory(name: String) throws -> URL {
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(unresolved.path, &buffer) != nil else { return unresolved }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }
}
