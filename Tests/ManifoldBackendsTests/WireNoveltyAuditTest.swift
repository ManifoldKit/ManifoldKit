import XCTest
import Darwin
import ManifoldBackendTestKit
@testable import ManifoldInference

/// Phase 1a guard: scans every committed `expected.jsonl` fixture for JSON
/// keys not in `FixtureComparator.knownKeys`.
///
/// Catches the failure mode where a backend silently grows its wire format
/// (e.g. Anthropic adds a `cache_creation_input_tokens` field to the usage
/// block) but the comparator parses the row as a no-op because the field
/// is unknown. Without this audit, a fixture quietly stops exercising the
/// new field.
///
/// On hit: append the new key to `FixtureComparator.knownKeys` AND, if the
/// key is genuinely provider-quirky, to `WireNoveltyAuditTest.allowlist`
/// with a `// CODEOWNER: security` comment justifying the carve-out.
final class WireNoveltyAuditTest: XCTestCase {

    /// Fingerprints (file:line:key) that are deliberately tolerated.
    /// Empty by default — the expected workflow is to teach the comparator
    /// the new key rather than allowlist its appearance.
    ///
    /// Each entry MUST sit beside an inline `// CODEOWNER: security`
    /// comment explaining why the field is provider-specific noise rather
    /// than a wire-contract addition.
    private static let allowlist: Set<String> = []

    func test_fixturesContainNoUnknownWireKeys() throws {
        let fixturesRoot = try Self.locateFixturesDirectory()
        let allNovelties = try Self.novelties(fixturesRoot: fixturesRoot, allowlist: Self.allowlist)

        if allNovelties.isEmpty { return }
        XCTFail("""
            WireNoveltyAuditTest detected JSON keys in fixtures that the FixtureComparator does not understand:

              \(allNovelties.joined(separator: "\n  "))

            Fix:
              - Preferred: add the key to FixtureComparator.knownKeys and update the projection logic so the new field round-trips.
              - Fallback: add the fingerprint to WireNoveltyAuditTest.allowlist with `// CODEOWNER: security` justification.
            """)
    }

    // MARK: - Detection

    /// Full audit pipeline: walk the fixture roots, run the REAL
    /// `FixtureComparator` over each `expected.jsonl`, and apply the
    /// fingerprint allowlist. Both the audit and the sabotage test call
    /// this, so the check can never drift from what the comparator
    /// actually understands.
    static func novelties(fixturesRoot: URL, allowlist: Set<String>) throws -> [String] {
        var allNovelties: [String] = []
        for fileURL in try Self.enumerateFixtureFiles(under: fixturesRoot) {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            var cmp = FixtureComparator()
            let relativePath = fileURL.path.replacingOccurrences(
                of: fixturesRoot.path + "/", with: ""
            )
            _ = cmp.parse(jsonlContents: contents, sourcePath: relativePath)
            for entry in cmp.noveltyLog where !allowlist.contains(entry) {
                allNovelties.append(entry)
            }
        }
        return allNovelties
    }

    // MARK: - Sabotage (exercises the same `novelties(fixturesRoot:allowlist:)` the audit runs)

    /// Plants an `expected.jsonl` row carrying a key `FixtureComparator`
    /// does not know and asserts the REAL pipeline flags it with the exact
    /// `relativePath:line:key` fingerprint — not just a substring match,
    /// which would stay green even if `fixturesRoot`-relative path
    /// derivation silently broke (see `makeSabotageTempDirectory` doc).
    func test_sabotage_pipelineFlagsUnknownWireKey() throws {
        let tmp = try Self.makeSabotageTempDirectory(
            name: "wire-novelty-sabotage-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fixtureDir = tmp.appendingPathComponent("backends/claude", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        try """
        {"event":"token","text":"Hello","totally_unknown_field_xyz":"boom"}
        """.write(to: fixtureDir.appendingPathComponent("expected.jsonl"), atomically: true, encoding: .utf8)

        let novelties = try Self.novelties(fixturesRoot: tmp, allowlist: [])
        XCTAssertEqual(novelties, ["backends/claude/expected.jsonl:1:totally_unknown_field_xyz"])
    }

    /// Builds a fresh, UUID-suffixed temp directory and returns it fully
    /// resolved via POSIX `realpath()`. `/var` (macOS's temp-dir root) is an
    /// APFS firmlink to `/private/var`, not a classic symlink — so
    /// `URL.resolvingSymlinksInPath()` leaves it untouched while
    /// `FileManager`'s directory enumerator returns the fully-resolved
    /// `/private/var/...` form for every child it walks. Without this,
    /// string-prefix stripping of `root.path` against an enumerated child's
    /// `.path` silently fails to match (the prefixes differ), corrupting
    /// every relative-path fingerprint this sabotage test asserts against.
    private static func makeSabotageTempDirectory(name: String) throws -> URL {
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(unresolved.path, &buffer) != nil else { return unresolved }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    // MARK: - Helpers (mirror FixtureRedactionAuditTest)

    private static func locateFixturesDirectory(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Tests/Fixtures")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "WireNoveltyAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/Fixtures/"
        ])
    }

    private static func enumerateFixtureFiles(under root: URL) throws -> [URL] {
        let interestingRoots = ["backends", "ollama"]
        var result: [URL] = []
        for subdir in interestingRoots {
            let dir = root.appendingPathComponent(subdir)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            guard let enumerator = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                result.append(url)
            }
        }
        return result
    }
}
