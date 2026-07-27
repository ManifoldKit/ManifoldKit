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
/// PR: is the trapped value fixed once at construction (a wiring/config
/// mistake — "genuine programmer error", stays as a trap), or can it change
/// during the process's lifetime after the trapping code was already reached
/// once safely (a live runtime condition with a fallback — must not trap)?
/// `URLSessionProvider.networkDisabled` is documented as flippable at any
/// time; every other precondition site in `Sources/` at the time of writing
/// gates a value fixed once at object construction, matching the safe
/// "stays" bucket. See `trapping_construct_allowlist.txt` for the per-site
/// reasoning.
///
/// ## Approval shape
///
/// Every match falls through to a path-based allowlist
/// (`trapping_construct_allowlist.txt`, next to this file), mirroring
/// `SilentCatchAuditTest`. Format: one fingerprint
/// (`relative/path.swift:trimmed line`) per line; `#`-prefixed lines and
/// blank lines are ignored. There are no idiom rules — unlike `try?`, these
/// four constructs are rare enough (17 non-fatalError sites, one file, as of
/// this PR) that a blanket idiom would hide real regressions.
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
                let fingerprint = "\(relativePath):\(line)"
                found.insert(fingerprint)
                if !allowlist.contains(fingerprint) {
                    offenders.append((file: relativePath, line: index + 1, text: line))
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
