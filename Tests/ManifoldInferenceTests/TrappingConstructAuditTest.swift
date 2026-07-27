import XCTest
import Darwin

/// Guards against trapping constructs (`fatalError`, `assertionFailure`,
/// `precondition`, `preconditionFailure`) used on a path that has a
/// recoverable fallback available.
///
/// AGENTS.md's Error handling rule was historically written as a list of two
/// identifiers ("Never use `assertionFailure`/`fatalError` for conditions
/// that have fallback logic") rather than as the property it stands for: a
/// construct that traps the process where a recovery path exists.
/// `precondition`/`preconditionFailure` trap exactly the same way — in
/// `precondition`'s case, in *release* builds too, not just `swift test` —
/// and had no audit coverage at all before this test. See the
/// `URLSessionProvider.pinned`/`.unpinned` fix in the same PR that adds this
/// audit: a "regulated runtime" network kill-switch that can be flipped at
/// any point during process lifetime was implemented with `precondition`,
/// so simply constructing a cloud backend while the switch was set crashed
/// the host app instead of failing the request.
///
/// The distinguishing test applied while triaging existing sites for this
/// PR — sharpened twice during review, see AGENTS.md's Error handling
/// section for the canonical statement: a trap is legitimate only when
/// ALL THREE hold — (a) the value is fixed once at construction, never
/// mutated afterward; (b) the value originates from code the programmer
/// wrote and controls directly, not from data that can enter the process
/// from outside their control (config, a defaults key, a runtime-filtered
/// list, public API a separate caller drives with its own data); and (c) a
/// trap here crashes the *developer's own process* (a build, a test run, a
/// CLI/fuzz tool they're driving directly), not a shipped app on someone
/// else's device. `URLSessionProvider.networkDisabled` fails (a) — it's a
/// runtime toggle flippable at any time. `RedirectGuardDelegate.hopCap`,
/// `FallbackBackend`'s empty-chain check, and `DocumentChunker`'s
/// chunkSize/overlap fail (b) and (c) together — each is public API fed
/// from host-app-controlled runtime data reachable from a shipped app's own
/// bootstrap path. `RotatingFuzzFactory` fails (b) alone (it's public API
/// on a published library a companion package can drive programmatically)
/// but correctly stays a trap because it passes (c) — `ManifoldFuzz` never
/// ships inside a consumer app, so a bad value only ever crashes the
/// developer's own fuzz process. See `trapping_construct_allowlist.txt` for
/// the full per-site reasoning.
///
/// ## Approval shape
///
/// Every match falls through to a path-based allowlist
/// (`trapping_construct_allowlist.txt`, next to this file), mirroring
/// `SilentCatchAuditTest`. Format: one fingerprint
/// (`relative/path.swift:trimmed line`) per line; `#`-prefixed lines and
/// blank lines are ignored. There are no idiom rules — unlike `try?`, these
/// four constructs are rare enough (13 allowlisted call sites across 9 files
/// as of this PR, all `precondition`/`preconditionFailure` — zero
/// `fatalError`/`assertionFailure` sites remain in `Sources/`) that a
/// blanket idiom would hide real regressions.
///
/// The full detection pipeline lives in ``scan(sourcesRoot:allowlist:)`` so
/// the in-file sabotage test exercises the exact function the audit runs.
final class TrappingConstructAuditTest: XCTestCase {

    /// The four constructs that trap the process — `assert(_:)` is
    /// deliberately excluded: it is a no-op in `-O` release builds (unlike
    /// `assertionFailure`, which still traps in `-Onone`/`swift test`), and
    /// is not part of the rule this audit enforces.
    static let trappingConstructs = ["fatalError", "assertionFailure", "preconditionFailure", "precondition"]

    private static let allowlist: Set<String> = {
        do {
            return try loadAllowlist()
        } catch {
            XCTFail("Failed to load trapping_construct_allowlist.txt: \(error)")
            return []
        }
    }()

    func test_sourcesDirectoryContainsNoUnapprovedTrappingConstructs() throws {
        let sourcesURL = try Self.locateSourcesDirectory()
        let swiftFiles = try Self.enumerateSwiftFiles(under: sourcesURL)
        XCTAssertFalse(swiftFiles.isEmpty, "Sources directory yielded no .swift files — path probably wrong")

        let (offenders, found) = try Self.scan(sourcesRoot: sourcesURL, allowlist: Self.allowlist)

        if !offenders.isEmpty {
            let formatted = offenders
                .map { "  \($0.file):\($0.line)  \($0.text)" }
                .joined(separator: "\n")
            XCTFail("""
                Unapproved trapping constructs (fatalError/assertionFailure/precondition/preconditionFailure) found in Sources/.
                If the trapped condition is a genuine programmer error fixed once at construction (never a live runtime toggle), add the fingerprint to Tests/ManifoldInferenceTests/trapping_construct_allowlist.txt with a one-line justification. Otherwise replace the trap with a recoverable path (throw, log + safe default, or a compile-time-enforced init parameter).

                \(formatted)
                """)
        }

        // Stale-allowlist check: every allowlist entry must still exist in
        // the source tree, or the list is drifting.
        let stale = Self.allowlist.subtracting(found)
        if !stale.isEmpty {
            let formatted = stale.sorted().joined(separator: "\n  ")
            XCTFail("""
                trapping_construct_allowlist.txt has stale entries that no longer exist in Sources/.
                Remove them:

                  \(formatted)
                """)
        }
    }

    // MARK: - Sabotage (exercises the same `scan(sourcesRoot:allowlist:)` the audit runs)

    /// Plants a temp source tree containing one violation of each of the
    /// four trapping constructs, plus a comment merely mentioning
    /// `fatalError(` in prose (must NOT be flagged — comments are excluded),
    /// and asserts the REAL detection pipeline flags exactly the code-level
    /// violations — plus that an allowlist fingerprint exempts the one it
    /// names.
    func test_sabotage_scanFlagsPlantedViolations() throws {
        let tmp = try Self.makeSabotageTempDirectory(
            name: "trapping-construct-sabotage-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = tmp.appendingPathComponent("ManifoldSomeModule", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        import Foundation

        // Historically this used to call fatalError( ) here, before #0000.
        struct Widget {
            var isDisabledAtRuntime = false

            func loadPinned() -> Int {
                precondition(!isDisabledAtRuntime, "widget disabled")
                return 1
            }

            func fetch() -> Int {
                guard isDisabledAtRuntime == false else {
                    preconditionFailure("widget disabled")
                }
                return 2
            }

            func capabilities() -> Int {
                fatalError("Widget must override capabilities")
            }

            func assertReady() {
                assertionFailure("widget not ready")
            }
        }
        """.write(to: root.appendingPathComponent("BadTrap.swift"), atomically: true, encoding: .utf8)

        let (offenders, found) = try Self.scan(sourcesRoot: tmp, allowlist: [])

        XCTAssertTrue(
            offenders.contains { $0.text.contains("precondition(!isDisabledAtRuntime") },
            "The unapproved precondition( must be flagged; got \(offenders)"
        )
        XCTAssertTrue(
            offenders.contains { $0.text.contains("preconditionFailure(\"widget disabled\")") },
            "The unapproved preconditionFailure( must be flagged; got \(offenders)"
        )
        XCTAssertTrue(
            offenders.contains { $0.text.contains("fatalError(\"Widget must override capabilities\")") },
            "The unapproved fatalError( must be flagged; got \(offenders)"
        )
        XCTAssertTrue(
            offenders.contains { $0.text.contains("assertionFailure(\"widget not ready\")") },
            "The unapproved assertionFailure( must be flagged; got \(offenders)"
        )
        XCTAssertFalse(
            offenders.contains { $0.text.contains("Historically this used to call fatalError") },
            "A comment merely mentioning fatalError( in prose must NOT be flagged"
        )

        let fingerprint = "ManifoldSomeModule/BadTrap.swift:precondition(!isDisabledAtRuntime, \"widget disabled\")"
        XCTAssertTrue(found.contains(fingerprint), "The unapproved precondition must appear in `found`")

        let (exempted, _) = try Self.scan(sourcesRoot: tmp, allowlist: [fingerprint])
        XCTAssertFalse(
            exempted.contains { $0.text.contains("precondition(!isDisabledAtRuntime") },
            "An allowlisted fingerprint must exempt the matching precondition"
        )
        // The other three violations are untouched by the one-fingerprint
        // allowlist — proves the allowlist is per-line, not per-file.
        XCTAssertTrue(
            exempted.contains { $0.text.contains("fatalError(\"Widget must override capabilities\")") },
            "Allowlisting one fingerprint must not exempt unrelated violations in the same file"
        )
    }

    /// Two multi-line `precondition(` calls whose OPENING line is identical
    /// bare text ("precondition(") but whose actual condition (the next
    /// line) differs must fingerprint differently — otherwise allowlisting
    /// one silently exempts every future bare-opener `precondition(` in the
    /// same file, a blanket exemption the stale-allowlist check would never
    /// catch (found in review of this PR).
    func test_sabotage_bareMultilineOpenersFingerprintDistinctly() throws {
        let tmp = try Self.makeSabotageTempDirectory(
            name: "trapping-construct-multiline-sabotage-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = tmp.appendingPathComponent("ManifoldSomeModule", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try """
        import Foundation

        struct TwoCallers {
            init(a: [Int], b: [Int]) {
                precondition(
                    a.count == b.count,
                    "a and b must align"
                )
            }

            init(c: [Int]) {
                precondition(
                    !c.isEmpty,
                    "c must not be empty"
                )
            }
        }
        """.write(to: root.appendingPathComponent("TwoCallers.swift"), atomically: true, encoding: .utf8)

        let (offenders, found) = try Self.scan(sourcesRoot: tmp, allowlist: [])
        XCTAssertEqual(offenders.count, 2, "both bare-opener preconditions must be flagged as distinct offenders")

        let firstFingerprint = "ManifoldSomeModule/TwoCallers.swift:precondition( a.count == b.count,"
        XCTAssertTrue(found.contains(firstFingerprint), "expected fingerprint not found; got \(found)")

        // Allowlisting only the first must NOT exempt the second.
        let (exempted, _) = try Self.scan(sourcesRoot: tmp, allowlist: [firstFingerprint])
        XCTAssertEqual(exempted.count, 1, "allowlisting one bare-opener call must not exempt the other")
        XCTAssertTrue(exempted.contains { $0.text.contains("c.isEmpty") })
    }

    // MARK: - Detection

    static func scan(
        sourcesRoot: URL,
        allowlist: Set<String>
    ) throws -> (offenders: [(file: String, line: Int, text: String)], found: Set<String>) {
        var found: Set<String> = []
        var offenders: [(file: String, line: Int, text: String)] = []

        let swiftFiles = try Self.enumerateSwiftFiles(under: sourcesRoot)

        for fileURL in swiftFiles {
            let relativePath = fileURL.path.replacingOccurrences(of: sourcesRoot.path + "/", with: "")
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: "\n")

            for (index, rawLine) in lines.enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard let construct = Self.lineTrappingConstruct(line) else { continue }
                _ = construct
                // A multi-line call whose opening line is JUST the bare
                // "construct(" (no argument content yet) would otherwise
                // fingerprint identically to every other bare opening of the
                // same construct in the file — a blanket, file-wide
                // exemption that a later, unrelated multi-line call could
                // silently inherit. Fold in the next non-blank line (which,
                // for every real call site of this shape, carries the actual
                // condition) so the fingerprint is specific to this call.
                var fingerprintText = line
                if Self.isBareConstructOpener(line, construct: construct) {
                    var peek = index + 1
                    while peek < lines.count {
                        let next = lines[peek].trimmingCharacters(in: .whitespaces)
                        if next.isEmpty { peek += 1; continue }
                        fingerprintText = "\(line) \(next)"
                        break
                    }
                }
                let fingerprint = "\(relativePath):\(fingerprintText)"
                found.insert(fingerprint)
                if !allowlist.contains(fingerprint) {
                    offenders.append((file: relativePath, line: index + 1, text: fingerprintText))
                }
            }
        }

        return (offenders, found)
    }

    /// Returns the trapping construct name found at the start of a call
    /// site on `line`, or `nil` if none applies. Excludes comment lines and
    /// requires the identifier to be a standalone word immediately followed
    /// by `(` (optionally with whitespace) — so a prose mention like
    /// "calls fatalError( ) here" inside a `//` comment is excluded by the
    /// comment check, and an identifier merely containing one of these
    /// names as a substring (e.g. a hypothetical `myFatalErrorHandler(`)
    /// is excluded by the word-boundary anchor.
    private static func lineTrappingConstruct(_ line: String) -> String? {
        guard !line.hasPrefix("//"), !line.hasPrefix("*"), !line.hasPrefix("///") else { return nil }
        for name in trappingConstructs {
            let pattern = #"(^|[^A-Za-z0-9_])"# + name + #"\s*\("#
            if line.range(of: pattern, options: .regularExpression) != nil {
                return name
            }
        }
        return nil
    }

    /// `true` when `line`, trimmed, is exactly `construct(` — the opening
    /// line of a multi-line call with no argument content on the same line
    /// (e.g. `precondition(` alone, condition and message on following
    /// lines). See the blanket-exemption note at the call site above.
    private static func isBareConstructOpener(_ line: String, construct: String) -> Bool {
        line == "\(construct)("
    }

    // MARK: - Allowlist loading

    static func loadAllowlist(filePath: StaticString = #filePath) throws -> Set<String> {
        let url = allowlistURL(filePath: filePath)
        let content = try String(contentsOf: url, encoding: .utf8)
        var entries: Set<String> = []
        for rawLine in content.components(separatedBy: "\n") {
            var line = rawLine
            if line.hasSuffix("\r") { line.removeLast() }
            while let last = line.last, last == " " || last == "\t" {
                line.removeLast()
            }
            let leading = line.drop(while: { $0 == " " || $0 == "\t" })
            if leading.isEmpty { continue }
            if leading.first == "#" { continue }
            entries.insert(line)
        }
        return entries
    }

    private static func allowlistURL(filePath: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(filePath)")
            .deletingLastPathComponent()
            .appendingPathComponent("trapping_construct_allowlist.txt")
    }

    // MARK: - Helpers

    private static func locateSourcesDirectory(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Sources")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "TrappingConstructAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Sources/ from #filePath"
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

    /// See `SilentCatchAuditTest`'s identical helper for why `realpath()` is
    /// needed here (APFS firmlink `/var` → `/private/var`).
    private static func makeSabotageTempDirectory(name: String) throws -> URL {
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(unresolved.path, &buffer) != nil else { return unresolved }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

}
