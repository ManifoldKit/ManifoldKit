import XCTest
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
        var allNovelties: [String] = []

        for fileURL in try Self.enumerateFixtureFiles(under: fixturesRoot) {
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            var cmp = FixtureComparator()
            let relativePath = fileURL.path.replacingOccurrences(
                of: fixturesRoot.path + "/", with: ""
            )
            _ = cmp.parse(jsonlContents: contents, sourcePath: relativePath)
            for entry in cmp.noveltyLog where !Self.allowlist.contains(entry) {
                allNovelties.append(entry)
            }
        }

        if allNovelties.isEmpty { return }
        XCTFail("""
            WireNoveltyAuditTest detected JSON keys in fixtures that the FixtureComparator does not understand:

              \(allNovelties.joined(separator: "\n  "))

            Fix:
              - Preferred: add the key to FixtureComparator.knownKeys and update the projection logic so the new field round-trips.
              - Fallback: add the fingerprint to WireNoveltyAuditTest.allowlist with `// CODEOWNER: security` justification.
            """)
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
