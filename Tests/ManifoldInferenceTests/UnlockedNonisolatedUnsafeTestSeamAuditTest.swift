import XCTest
import Foundation

/// Guards against regression on issue #2094: `nonisolated(unsafe) static var`
/// declarations in `Sources/` that are not demonstrably safe — either a
/// small, reviewed exception (a genuinely write-once-before-any-reader
/// flag) or a backing store whose every access goes through a lock in the
/// same file.
///
/// `nonisolated(unsafe)` is not itself one of CLAUDE.md's six documented
/// Swift 6 concurrency gotchas (it's now the 7th), so an unguarded static
/// test-injection seam had no other checklist protection — three real ones
/// shipped before this audit existed: `DNSRebindingGuard._resolverForTesting`,
/// `RedirectGuardDelegate._synchronousResolverForTesting`, and four hooks on
/// `GenerationQueue`. All three are now lock-guarded via a computed property
/// + private backing store and no longer appear here.
///
/// The test walks every `.swift` file under `Sources/` and flags every
/// `nonisolated(unsafe) static var` declaration whose fingerprint isn't in
/// `unlocked_nonisolated_unsafe_allowlist.txt` (sitting next to this file).
/// Each allowlist entry carries a one-line justification recorded at review
/// time — this audit does not attempt to mechanically *prove*
/// lock-correctness (that would be a fragile regex exercise); it makes sure
/// every occurrence was actually looked at by a human once, and that new
/// ones can't slip in silently.
///
/// Approval shape mirrors `SilentCatchAuditTest`: a fingerprint
/// (`relative/path.swift:trimmed line`) either appears in the allowlist or
/// the build fails. A stale-allowlist check fails the other direction too,
/// so removed declarations get their allowlist line cleaned up.
///
/// The scan lives in ``scan(sourcesRoot:allowlist:)`` so the in-file
/// sabotage test exercises the exact function the audit runs.
final class UnlockedNonisolatedUnsafeTestSeamAuditTest: XCTestCase {

    /// Lazily loaded set of approved fingerprints from
    /// `unlocked_nonisolated_unsafe_allowlist.txt`, resolved via `#filePath`
    /// the same way `SilentCatchAuditTest` resolves its allowlist.
    private static let allowlist: Set<String> = {
        do {
            return try loadAllowlist()
        } catch {
            XCTFail("Failed to load unlocked_nonisolated_unsafe_allowlist.txt: \(error)")
            return []
        }
    }()

    func test_sourcesDirectoryContainsNoUnapprovedUnlockedTestSeams() throws {
        let sourcesURL = try Self.locateSourcesDirectory()
        let swiftFiles = try Self.enumerateSwiftFiles(under: sourcesURL)
        XCTAssertFalse(swiftFiles.isEmpty, "Sources directory yielded no .swift files — path probably wrong")

        let (offenders, found) = try Self.scan(sourcesRoot: sourcesURL, allowlist: Self.allowlist)

        if !offenders.isEmpty {
            let formatted = offenders
                .map { "  \($0.file):\($0.line)  \($0.text)" }
                .joined(separator: "\n")
            XCTFail("""
                Unapproved `nonisolated(unsafe) static var` declarations found in Sources/.
                Either guard every read/write through a Lock/actor in the same file, or add the fingerprint to Tests/ManifoldInferenceTests/unlocked_nonisolated_unsafe_allowlist.txt with a one-line justification and reviewer sign-off.

                \(formatted)
                """)
        }

        // Stale-allowlist check: every allowlist entry must still exist in
        // the source tree, or the list is drifting (mirrors SilentCatchAuditTest).
        let stale = Self.allowlist.subtracting(found)
        if !stale.isEmpty {
            let formatted = stale.sorted().joined(separator: "\n  ")
            XCTFail("""
                unlocked_nonisolated_unsafe_allowlist.txt has stale entries that no longer exist in Sources/.
                Remove them:

                  \(formatted)
                """)
        }
    }

    // MARK: - Sabotage (exercises the same `scan(sourcesRoot:allowlist:)` the audit runs)

    /// Plants a temp source tree containing an unlocked
    /// `nonisolated(unsafe) static var` test-injection seam and asserts the
    /// REAL scan flags it — and that a fingerprint allowlist entry exempts it.
    func test_sabotage_scanFlagsPlantedUnlockedSeam() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("unlocked-seam-sabotage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = tmp.appendingPathComponent("ManifoldSomeModule", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let declaration = "nonisolated(unsafe) static var _resolverForTesting: ((String) -> [String]?)? = nil"
        try """
        import Foundation

        enum BadSeam {
            \(declaration)
        }
        """.write(to: root.appendingPathComponent("BadSeam.swift"), atomically: true, encoding: .utf8)

        let (offenders, found) = try Self.scan(sourcesRoot: tmp, allowlist: [])
        XCTAssertEqual(offenders.count, 1, "The planted unlocked seam must be flagged")
        XCTAssertEqual(offenders.first?.file, "ManifoldSomeModule/BadSeam.swift")

        let fingerprint = "ManifoldSomeModule/BadSeam.swift:\(declaration)"
        XCTAssertTrue(found.contains(fingerprint), "The planted seam must appear in `found`")

        let (exempted, _) = try Self.scan(sourcesRoot: tmp, allowlist: [fingerprint])
        XCTAssertTrue(exempted.isEmpty, "An allowlisted fingerprint must exempt the matching declaration")
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
                guard Self.lineDeclaresNonisolatedUnsafeStaticVar(line) else { continue }
                let fingerprint = "\(relativePath):\(line)"
                found.insert(fingerprint)
                if !allowlist.contains(fingerprint) {
                    offenders.append((file: relativePath, line: index + 1, text: line))
                }
            }
        }

        return (offenders, found)
    }

    // MARK: - Allowlist loading

    /// Reads `unlocked_nonisolated_unsafe_allowlist.txt` from beside this
    /// source file. Format matches `SilentCatchAuditTest`'s allowlist:
    /// blank lines and `#`-prefixed lines are ignored.
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

    /// URL of `unlocked_nonisolated_unsafe_allowlist.txt` next to this test
    /// source file.
    private static func allowlistURL(filePath: StaticString = #filePath) -> URL {
        URL(fileURLWithPath: "\(filePath)")
            .deletingLastPathComponent()
            .appendingPathComponent("unlocked_nonisolated_unsafe_allowlist.txt")
    }

    // MARK: - Helpers

    /// Matches a line that declares a `nonisolated(unsafe) static var` —
    /// comments describing the pattern in prose (rather than declaring it)
    /// are excluded the same way `SilentCatchAuditTest` excludes comment
    /// lines from its `try?` scan.
    private static func lineDeclaresNonisolatedUnsafeStaticVar(_ line: String) -> Bool {
        guard !line.hasPrefix("//"), !line.hasPrefix("*"), !line.hasPrefix("///") else { return false }
        return line.contains("nonisolated(unsafe)") && line.contains("static var")
    }

    /// Walks upward from the test file to find the repo root, then returns
    /// the `Sources/` subdirectory. Mirrors `SilentCatchAuditTest`.
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
        throw NSError(domain: "UnlockedNonisolatedUnsafeTestSeamAuditTest", code: 1, userInfo: [
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
}
