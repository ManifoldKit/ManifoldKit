import XCTest
import Foundation

/// Guards against regression on issue #2307 (`docs/UI-REFRESH-2026.md` §7 /
/// `docs/UI-REFRESH-2026-PLAN.md` §1.4): raw palette-`Color` literals used in
/// style positions (`.foregroundStyle`, `.foregroundColor`, `.tint`,
/// `.background`, `.fill`, `.stroke`) across the three modules the 2026 UI
/// refresh themes — `Sources/ManifoldUI`, `Sources/ManifoldUIModelManagement`,
/// `Sources/ManifoldVoice`.
///
/// The token refactor replaces every one of these literals with a
/// `ManifoldTheme` read (`accent`/`statusOK`/`statusWarn`/`statusError`/…).
/// This audit is the tripwire that keeps a *new* hardcoded literal from
/// creeping back in once a file has been migrated — mirroring
/// `SilentCatchAuditTest`'s allowlist/idiom shape.
///
/// ## Detection
///
/// A line is flagged when it contains both:
/// 1. one of the style-modifier calls (``styleModifiers``), and
/// 2. a raw palette-color token — `Color.<name>` or bare `.<name>` (not
///    preceded by an identifier character, so `.background` itself, or part
///    of another identifier, never matches) — for one of ``paletteColorNames``.
///
/// Deliberately **not** flagged: SwiftUI's semantic hierarchical styles
/// (`.primary`/`.secondary`/`.tertiary`/`.quaternary`/`.fill`) — those already
/// adapt to the system appearance the way a token is supposed to, and are not
/// part of the ~65-literal migration inventory (§1.3).
///
/// This line-based heuristic also catches literals returned from small
/// switch-based helper functions (`DownloadableModelRow.speedTint(_:)`, etc.)
/// even though the `return .green` line itself has no modifier call on it —
/// those functions exist *only* to feed a style call elsewhere, and §1.3
/// explicitly lists them as migration sites.
///
/// ## Taxonomy / allowlist
///
/// Three-way taxonomy per spec §7 / plan §1.3-1.4:
///
/// - **(a) migrate-later** — themeable colors not yet routed through
///   `ManifoldTheme`. Temporary: `HardcodedColorAuditTestAllowlist.txt`
///   fingerprints (`relative/path.swift:trimmed line`, mirroring
///   `SilentCatchAuditTest`'s scheme). The migration tranches
///   (`T1-migrate-ui`/`-mmgmt`/`-voice`) remove entries as they land tokens.
/// - **(b) functional/data** — colors chosen by hashing/data, not theme
///   intent (`MessageBubbleView.agentColor(for:)`'s UUID-hash palette).
///   Permanent: ``categoryBSymbols`` (file + enclosing-function-name pair).
/// - **(c) diagnostic-only** — dev/debug-only views never migrated.
///   Permanent, per-file: ``categoryCFiles``.
final class HardcodedColorAuditTest: XCTestCase {

    /// Style-modifier calls that put a `ShapeStyle` argument in a rendered
    /// position.
    static let styleModifiers = [
        ".foregroundStyle(", ".foregroundColor(", ".tint(",
        ".background(", ".fill(", ".stroke(",
    ]

    /// Raw SwiftUI palette `Color` case names. Deliberately excludes
    /// `.primary`/`.secondary`/`.tertiary`/`.quaternary`/`.fill`/`.accentColor`
    /// — those are semantic/hierarchical, not literals, and are not part of
    /// the migration inventory.
    static let paletteColorNames = [
        "red", "orange", "yellow", "green", "blue",
        "purple", "pink", "indigo", "teal", "mint", "cyan", "brown", "gray",
        "white", "black",
    ]

    /// (file basename, enclosing function name) pairs exempted as
    /// functional/data colors (taxonomy category b). The color isn't a theme
    /// decision — it's derived from a hash so two different items render
    /// visually distinct — so it stays literal by design.
    static let categoryBSymbols: Set<Fingerprint2> = [
        Fingerprint2(file: "MessageBubbleView.swift", function: "agentColor"),
    ]

    /// Diagnostic-only view files exempted entirely (taxonomy category c).
    /// These are dev/debug surfaces (`docs/UI-REFRESH-2026-PLAN.md` §1.3)
    /// never in scope for the visual refresh.
    static let categoryCFiles: Set<String> = [
        "ArchitectView.swift",
        "DiagnosticsView.swift",
        "EventTimelineView.swift",
        "PromptInspectorView.swift",
        "ContextSlotInspectorView.swift",
    ]

    struct Fingerprint2: Hashable {
        let file: String
        let function: String
    }

    /// Lazily loaded set of approved (category-a) fingerprints from
    /// `HardcodedColorAuditTestAllowlist.txt`, next to this file.
    private static let allowlist: Set<String> = {
        do {
            return try loadAllowlist()
        } catch {
            XCTFail("Failed to load HardcodedColorAuditTestAllowlist.txt: \(error)")
            return []
        }
    }()

    static let scannedModules = ["ManifoldUI", "ManifoldUIModelManagement", "ManifoldVoice"]

    func test_scannedModulesContainNoUnapprovedHardcodedColors() throws {
        let sourcesRoot = try Self.locateSourcesDirectory()
        var allOffenders: [(file: String, line: Int, text: String)] = []
        var allFound: Set<String> = []

        for module in Self.scannedModules {
            let moduleRoot = sourcesRoot.appendingPathComponent(module, isDirectory: true)
            guard FileManager.default.fileExists(atPath: moduleRoot.path) else {
                XCTFail("Expected module directory Sources/\(module) to exist")
                continue
            }
            let (offenders, found) = try Self.scan(moduleRoot: moduleRoot, allowlist: Self.allowlist)
            allOffenders.append(contentsOf: offenders)
            allFound.formUnion(found)
        }

        if !allOffenders.isEmpty {
            let formatted = allOffenders
                .map { "  \($0.file):\($0.line)  \($0.text)" }
                .joined(separator: "\n")
            XCTFail("""
                Unapproved hardcoded color literals found. Route these through \
                ManifoldTheme, or add the fingerprint to \
                Tests/ManifoldUITests/HardcodedColorAuditTestAllowlist.txt with \
                a taxonomy-category comment and reviewer sign-off.

                \(formatted)
                """)
        }

        let stale = Self.allowlist.subtracting(allFound)
        if !stale.isEmpty {
            let formatted = stale.sorted().joined(separator: "\n  ")
            XCTFail("""
                HardcodedColorAuditTestAllowlist.txt has stale entries that no \
                longer exist in Sources/. Remove them (this is expected as \
                migration tranches land — that's the point):

                  \(formatted)
                """)
        }
    }

    // MARK: - Sabotage (exercises the same `scan(moduleRoot:allowlist:)` the audit runs)

    /// Plants a temp module tree containing an unapproved hardcoded color
    /// (must be flagged), a category-b-style symbol match (must NOT be
    /// flagged once its function name is allowlisted), a category-c file
    /// (must NOT be flagged when its filename is allowlisted), and a
    /// semantic-hierarchical style (`.secondary`, must never be flagged),
    /// and asserts the REAL detection pipeline gets exactly this right.
    func test_sabotage_scanFlagsPlantedHardcodedColors() throws {
        let tmp = try Self.makeSabotageTempDirectory(
            name: "hardcoded-color-sabotage-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        try """
        import SwiftUI

        struct BadgeView: View {
            var body: some View {
                Text("bad")
                    .foregroundStyle(.orange)
            }
        }

        struct SemanticView: View {
            var body: some View {
                Text("fine")
                    .foregroundStyle(.secondary)
            }
        }

        struct HashPalette {
            static func agentColor(for id: UUID) -> Color {
                let palette: [Color] = [.blue, .purple]
                return palette[0]
            }
        }
        """.write(to: tmp.appendingPathComponent("Planted.swift"), atomically: true, encoding: .utf8)

        // Unapproved + semantic-exempt, no category allowlists applied.
        let (offendersBare, foundBare) = try Self.scan(
            moduleRoot: tmp, allowlist: [],
            categoryBSymbols: [], categoryCFiles: []
        )
        XCTAssertTrue(
            offendersBare.contains { $0.text.contains(".foregroundStyle(.orange)") },
            "The unapproved .orange foregroundStyle must be flagged; got \(offendersBare)"
        )
        XCTAssertFalse(
            offendersBare.contains { $0.text.contains(".foregroundStyle(.secondary)") },
            "A semantic .secondary style must NEVER be flagged"
        )
        XCTAssertTrue(
            offendersBare.contains { $0.text.contains("let palette: [Color] = [.blue, .purple]") },
            "Without a category-b symbol allowlist entry, the hash-palette line must be flagged too"
        )

        let fingerprint = "Planted.swift:.foregroundStyle(.orange)"
        XCTAssertTrue(foundBare.contains(fingerprint), "The unapproved literal must appear in `found`")

        // Path-based (category a) allowlist exempts the named fingerprint.
        let (exempted, _) = try Self.scan(
            moduleRoot: tmp, allowlist: [fingerprint],
            categoryBSymbols: [], categoryCFiles: []
        )
        XCTAssertFalse(
            exempted.contains { $0.text.contains(".foregroundStyle(.orange)") },
            "An allowlisted fingerprint must exempt the matching literal"
        )

        // Category-b symbol allowlist exempts the hash-palette line by
        // (file, enclosing function) — the badge/orange line is untouched.
        let (categoryBExempted, _) = try Self.scan(
            moduleRoot: tmp, allowlist: [],
            categoryBSymbols: [Fingerprint2(file: "Planted.swift", function: "agentColor")],
            categoryCFiles: []
        )
        XCTAssertFalse(
            categoryBExempted.contains { $0.text.contains("let palette: [Color] = [.blue, .purple]") },
            "A category-b symbol allowlist entry must exempt its function's literals"
        )
        XCTAssertTrue(
            categoryBExempted.contains { $0.text.contains(".foregroundStyle(.orange)") },
            "The category-b allowlist must not exempt an unrelated function"
        )

        // Category-c file allowlist exempts the whole file.
        let (categoryCExempted, _) = try Self.scan(
            moduleRoot: tmp, allowlist: [],
            categoryBSymbols: [], categoryCFiles: ["Planted.swift"]
        )
        XCTAssertTrue(categoryCExempted.isEmpty, "A category-c file allowlist entry must exempt the whole file")
    }

    // MARK: - Detection

    /// Full scan of every `.swift` file under `moduleRoot`. Returns the
    /// unapproved offenders alongside every fingerprint `found`, so a
    /// now-stale allowlist entry (literal migrated away) surfaces.
    static func scan(
        moduleRoot: URL,
        allowlist: Set<String>,
        categoryBSymbols: Set<Fingerprint2> = HardcodedColorAuditTest.categoryBSymbols,
        categoryCFiles: Set<String> = HardcodedColorAuditTest.categoryCFiles
    ) throws -> (offenders: [(file: String, line: Int, text: String)], found: Set<String>) {
        var found: Set<String> = []
        var offenders: [(file: String, line: Int, text: String)] = []

        let swiftFiles = try Self.enumerateSwiftFiles(under: moduleRoot)

        for fileURL in swiftFiles {
            let basename = fileURL.lastPathComponent
            if categoryCFiles.contains(basename) { continue }

            let relativePath = fileURL.path.replacingOccurrences(of: moduleRoot.path + "/", with: "")
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: "\n")

            // Tracks the innermost function whose body the scanner is
            // currently inside, via brace-depth bookkeeping (not just "the
            // most recently seen `func` line" — that would leak the scope
            // past the function's closing brace into whatever computed
            // property/function follows it).
            var braceDepth = 0
            var activeFunction: (name: String, depth: Int)?

            for (index, rawLine) in lines.enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                let isComment = line.hasPrefix("//") || line.hasPrefix("*") || line.hasPrefix("///")

                if !isComment, let name = Self.functionName(in: line) {
                    activeFunction = (name: name, depth: braceDepth)
                }

                if !isComment, Self.lineHasHardcodedColor(line) {
                    let exempted = activeFunction.map { active in
                        categoryBSymbols.contains(Fingerprint2(file: basename, function: active.name))
                    } ?? false
                    if !exempted {
                        let fingerprint = "\(relativePath):\(line)"
                        found.insert(fingerprint)
                        if !allowlist.contains(fingerprint) {
                            offenders.append((file: relativePath, line: index + 1, text: line))
                        }
                    }
                }

                let opens = line.filter { $0 == "{" }.count
                let closes = line.filter { $0 == "}" }.count
                braceDepth += opens - closes
                if let active = activeFunction, braceDepth <= active.depth {
                    activeFunction = nil
                }
            }
        }

        return (offenders, found)
    }

    /// `true` when `line` contains both a style-modifier call and a raw
    /// palette-color token.
    private static func lineHasHardcodedColor(_ line: String) -> Bool {
        guard Self.lineContainsPaletteColorToken(line) else { return false }
        // Direct style-call literal: `.foregroundStyle(.orange)`.
        if Self.styleModifiers.contains(where: { line.contains($0) }) { return true }
        // A `return`/`case ...: return` line — the shape every color-verdict
        // helper (`fitTint`/`speedTint`/`badgeColor`, `typeBadge`'s tuple,
        // `indicatorColor`/`color(for ratio:)`) uses to hand a literal back
        // to its caller without a style-modifier call on the same line.
        if line.contains("return") { return true }
        // A `[Color]` array literal — the hash-palette shape
        // (`agentColor(for:)`'s `let palette: [Color] = [...]`).
        if line.contains("[Color]") { return true }
        return false
    }

    /// Matches `Color.<name>` or a bare `.<name>` token for one of
    /// ``paletteColorNames``, where the bare form is not preceded by an
    /// identifier character (so `.background` never matches part of itself,
    /// and `.greenLight` — not a real case name here, but the principle
    /// holds — would not match `green` either since `\b` requires a
    /// non-identifier boundary on both sides).
    private static func lineContainsPaletteColorToken(_ line: String) -> Bool {
        for name in Self.paletteColorNames {
            let pattern = #"(Color\."# + name + #"\b)|((?<![A-Za-z0-9_.])\."# + name + #"\b)"#
            if line.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// Extracts the identifier after `func ` on a line that declares a
    /// function (any access-level/static/private prefix), used to track the
    /// enclosing function for the category-b symbol allowlist. Not
    /// scope-precise (does not track closing braces), but sufficient for the
    /// flat, one-function-per-region shape every category-b site uses today.
    private static func functionName(in line: String) -> String? {
        guard let range = line.range(of: #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#, options: .regularExpression) else {
            return nil
        }
        let match = String(line[range])
        guard let nameRange = match.range(of: #"[A-Za-z_][A-Za-z0-9_]*\("#, options: .regularExpression) else {
            // No trailing `(` captured on this line (shouldn't happen for a
            // normal declaration); fall back to the text after `func `.
            return match.replacingOccurrences(of: "func", with: "").trimmingCharacters(in: .whitespaces)
        }
        return String(match[nameRange]).replacingOccurrences(of: "(", with: "")
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
            .appendingPathComponent("HardcodedColorAuditTestAllowlist.txt")
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
        throw NSError(domain: "HardcodedColorAuditTest", code: 1, userInfo: [
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

    /// See `SilentCatchAuditTest`'s identical helper for the `/private/var`
    /// realpath rationale.
    private static func makeSabotageTempDirectory(name: String) throws -> URL {
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(unresolved.path, &buffer) != nil else { return unresolved }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }
}
