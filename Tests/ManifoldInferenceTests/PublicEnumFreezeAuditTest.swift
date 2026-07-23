import XCTest
import Foundation

/// Guards against issue #2208: a public enum shipping with no stated growth
/// policy. `GenerationEvent`'s "Vocabulary freeze (1.0)" doc-comment block
/// (added ahead of this audit) and `ToolResultPart`'s "Vocabulary growth
/// (1.x)" block are both acceptable answers to "what happens when this enum
/// needs a new case?" — an enum with neither is the thing this audit exists
/// to catch, because it means nobody has decided yet, and the decision
/// tends to get made under pressure during a breaking-change review instead
/// of up front.
///
/// The test walks every `.swift` file under `Sources/` and flags every
/// `public enum` / `public indirect enum` declaration that is neither:
/// (a) preceded by a doc comment containing a "Vocabulary freeze" or
///     "Vocabulary growth" marker, nor
/// (b) listed in `public_enum_freeze_allowlist.txt` (sitting next to this
///     file) — the "assessed but deliberately not yet annotated" set.
///
/// The #2208 sweep seeded the allowlist with every public enum that existed
/// before this audit landed, documenting-and-freezing eight of them
/// (`MessagePart`, `Message`, `ToolChoice`, `ToolExecutionEvent`,
/// `InferenceError`, `ChatError.Kind`, `ChatError.Recovery`,
/// `WebSearchRuntimeError`) plus the pre-existing `GenerationEvent` and
/// `ToolResultPart` markers, so those ten are exempt via marker rather than
/// allowlist. Everything else in the allowlist is unassessed, not
/// cleared — a future PR touching one should add the marker and remove the
/// allowlist line, not leave both.
///
/// The scan lives in ``scan(sourcesRoot:allowlist:)`` so the in-file
/// sabotage test exercises the exact function the audit runs. Approval shape
/// mirrors `UnlockedNonisolatedUnsafeTestSeamAuditTest`: a fingerprint
/// (`relative/path.swift:trimmed declaration line`) either carries a marker,
/// appears in the allowlist, or fails the build.
final class PublicEnumFreezeAuditTest: XCTestCase {

    private static let allowlist: Set<String> = {
        do {
            return try loadAllowlist()
        } catch {
            XCTFail("Failed to load public_enum_freeze_allowlist.txt: \(error)")
            return []
        }
    }()

    func test_sourcesDirectoryContainsNoUnassessedPublicEnums() throws {
        let sourcesURL = try Self.locateSourcesDirectory()
        let swiftFiles = try Self.enumerateSwiftFiles(under: sourcesURL)
        XCTAssertFalse(swiftFiles.isEmpty, "Sources directory yielded no .swift files — path probably wrong")

        let (offenders, found) = try Self.scan(sourcesRoot: sourcesURL, allowlist: Self.allowlist)

        if !offenders.isEmpty {
            let formatted = offenders
                .map { "  \($0.file):\($0.line)  \($0.text)" }
                .joined(separator: "\n")
            XCTFail("""
                Public enum(s) found in Sources/ with no stated growth policy.
                Either add a "Vocabulary freeze (1.0)" or "Vocabulary growth (1.x)" doc-comment
                block above the declaration (see GenerationEvent.swift / ToolResultPart in
                ToolTypes.swift for the canonical wording), or add the fingerprint to
                Tests/ManifoldInferenceTests/public_enum_freeze_allowlist.txt with a one-line
                note that it's deliberately unassessed.

                \(formatted)
                """)
        }

        // Stale-allowlist check: every allowlist entry must still exist in
        // the source tree, or the list is drifting (mirrors
        // UnlockedNonisolatedUnsafeTestSeamAuditTest / SilentCatchAuditTest).
        let stale = Self.allowlist.subtracting(found)
        if !stale.isEmpty {
            let formatted = stale.sorted().joined(separator: "\n  ")
            XCTFail("""
                public_enum_freeze_allowlist.txt has stale entries that no longer exist in Sources/.
                Remove them:

                  \(formatted)
                """)
        }
    }

    // MARK: - Sabotage (exercises the same `scan(sourcesRoot:allowlist:)` the audit runs)

    /// Plants a temp source tree containing a public enum with no growth-policy
    /// marker and asserts the REAL scan flags it — and that a doc-comment marker
    /// or an allowlist fingerprint each independently exempt it.
    func test_sabotage_scanFlagsPlantedUnassessedPublicEnum() throws {
        let tmp = try Self.makeSabotageTempDirectory(
            name: "public-enum-freeze-sabotage-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = tmp.appendingPathComponent("ManifoldSomeModule", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let declaration = "public enum BadVocabulary: Sendable {"
        try """
        import Foundation

        /// No growth-policy statement above this enum at all.
        \(declaration)
            case one
            case two
        }
        """.write(to: root.appendingPathComponent("BadVocabulary.swift"), atomically: true, encoding: .utf8)

        let (offenders, found) = try Self.scan(sourcesRoot: tmp, allowlist: [])
        XCTAssertEqual(offenders.count, 1, "The planted unassessed public enum must be flagged")
        XCTAssertEqual(offenders.first?.file, "ManifoldSomeModule/BadVocabulary.swift")

        let fingerprint = "ManifoldSomeModule/BadVocabulary.swift:\(declaration)"
        XCTAssertTrue(found.contains(fingerprint), "The planted enum must appear in `found`")

        // An allowlist entry exempts it.
        let (exempted, _) = try Self.scan(sourcesRoot: tmp, allowlist: [fingerprint])
        XCTAssertTrue(exempted.isEmpty, "An allowlisted fingerprint must exempt the matching declaration")

        // A "Vocabulary freeze" doc-comment block above the declaration also exempts it.
        let markedRoot = tmp.appendingPathComponent("ManifoldMarkedModule", isDirectory: true)
        try FileManager.default.createDirectory(at: markedRoot, withIntermediateDirectories: true)
        try """
        import Foundation

        /// Some enum.
        ///
        /// ## Vocabulary freeze (1.0)
        ///
        /// Frozen as of 1.0.
        \(declaration)
            case one
            case two
        }
        """.write(to: markedRoot.appendingPathComponent("MarkedVocabulary.swift"), atomically: true, encoding: .utf8)
        let (markedOffenders, _) = try Self.scan(sourcesRoot: markedRoot, allowlist: [])
        XCTAssertTrue(markedOffenders.isEmpty, "A doc-commented 'Vocabulary freeze' marker must exempt the declaration")
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
                guard Self.lineDeclaresPublicEnum(line) else { continue }
                let fingerprint = "\(relativePath):\(line)"
                found.insert(fingerprint)

                if Self.hasGrowthPolicyMarker(precedingLine: index, in: lines) { continue }
                if allowlist.contains(fingerprint) { continue }

                offenders.append((file: relativePath, line: index + 1, text: line))
            }
        }

        return (offenders, found)
    }

    /// Whether the doc comment immediately above `lineIndex` (walking upward
    /// through contiguous `///` / blank / attribute lines) contains a
    /// "Vocabulary freeze" or "Vocabulary growth" marker.
    private static func hasGrowthPolicyMarker(precedingLine lineIndex: Int, in lines: [String]) -> Bool {
        var i = lineIndex - 1
        while i >= 0 {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("///") {
                if trimmed.contains("Vocabulary freeze") || trimmed.contains("Vocabulary growth") {
                    return true
                }
                i -= 1
                continue
            }
            if trimmed.hasPrefix("@") {
                // Attribute line (e.g. `@available(...)`) between the doc
                // comment and the declaration — keep walking up.
                i -= 1
                continue
            }
            // Any other line ends the doc-comment block for this declaration.
            break
        }
        return false
    }

    // MARK: - Allowlist loading

    /// Reads `public_enum_freeze_allowlist.txt` from beside this source
    /// file. Format matches `UnlockedNonisolatedUnsafeTestSeamAuditTest`'s
    /// allowlist: blank lines and `#`-prefixed lines are ignored.
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
            .appendingPathComponent("public_enum_freeze_allowlist.txt")
    }

    // MARK: - Helpers

    private static func lineDeclaresPublicEnum(_ line: String) -> Bool {
        guard !line.hasPrefix("//"), !line.hasPrefix("*"), !line.hasPrefix("///") else { return false }
        guard line.contains("public enum ") || line.contains("public indirect enum ") else { return false }
        // Exclude the marker's own prose (e.g. this file's doc comments,
        // which never start with "public enum" once trimmed) — the prefix
        // check on the trimmed line already prevents doc-comment matches,
        // this guard just rules out mid-sentence mentions of the phrase.
        return line.hasPrefix("public enum ") || line.hasPrefix("public indirect enum ")
    }

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
        throw NSError(domain: "PublicEnumFreezeAuditTest", code: 1, userInfo: [
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

    /// Builds a fresh, UUID-suffixed temp directory resolved via POSIX
    /// `realpath()` — mirrors `UnlockedNonisolatedUnsafeTestSeamAuditTest`'s
    /// helper; see its doc comment for why the `/var` firmlink matters here.
    private static func makeSabotageTempDirectory(name: String) throws -> URL {
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(unresolved.path, &buffer) != nil else { return unresolved }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }
}
