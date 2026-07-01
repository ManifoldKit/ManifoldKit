import XCTest

/// Guards against regressions on issue #910: tests that read or write
/// `UserDefaults.standard` directly cannot run safely under
/// `swift test --parallel` because XCTest workers run in separate processes
/// and `UserDefaults.standard` is keyed by bundle ID, persisting to the same
/// on-disk plist across worker processes.
///
/// ## Why this matters
///
/// `swift test --parallel` cuts CI test wall time roughly in half by running
/// each XCTest target in its own worker process. The original block on this
/// (issue #756) was a small set of tests that read/wrote
/// `UserDefaults.standard`. Once those flake sources were eliminated, every
/// remaining `UserDefaults.standard` reference in `Tests/` is a latent
/// race waiting to break a future parallel run.
///
/// Production code already does the right thing: a quick
/// `grep -r "UserDefaults.standard" Sources/` returns nothing — every read or
/// write goes through an injected `UserDefaults` instance. Tests should
/// mirror that by allocating a per-suite `UserDefaults(suiteName:)` and
/// asserting against it.
///
/// ## What this test enforces
///
/// Every `.swift` file under `Tests/` must contain zero non-comment
/// occurrences of the string `UserDefaults.standard`. Comment lines and doc
/// comments are skipped so explanatory text (like the comment you're reading)
/// can still mention the API.
///
/// ## Fixing a violation
///
/// Replace the bare `.standard` access with the per-suite pattern already
/// used elsewhere in the codebase, e.g. in
/// `Tests/ManifoldHuggingFaceTests/BackgroundDownloadIntegrationTests.swift`:
///
///     suiteName = "com.manifoldkit.test.<area>.\(UUID().uuidString)"
///     testDefaults = UserDefaults(suiteName: suiteName)!
///     // …
///     // inject testDefaults into the SUT, assert against testDefaults
///     // tearDown: testDefaults?.removePersistentDomain(forName: suiteName)
///
/// DO NOT add an allowlist to silence this test. The whole point of the
/// audit is that one bare reference is enough to reintroduce the
/// cross-process race. (The only excluded files are this audit itself and
/// the sabotage-coverage suite, both of which contain the pattern purely as
/// inert text — see the exclusion set below.)
final class UserDefaultsStandardAuditTest: XCTestCase {

    func test_noDirectUserDefaultsStandardAccessInTests() throws {
        let testsURL = try Self.locateTestsDirectory()
        let swiftFiles = try Self.enumerateSwiftFiles(under: testsURL)

        // The audit file itself mentions the string in code paths (the
        // search needle below) and in error messages. Scope the audit to
        // every other file. AuditSabotageSuiteTests.swift is the second
        // exception: it is the sabotage-coverage suite that deliberately
        // embeds every audit's forbidden pattern (as string-literal payloads,
        // search needles, and error messages) to prove the audits still fire.
        // Neither exclusion silences a real violation — both files contain the
        // pattern only as inert text.
        let excludedFileNames: Set<String> = [
            (#filePath as NSString).lastPathComponent,
            "AuditSabotageSuiteTests.swift",
        ]

        var violations: [String] = []

        for fileURL in swiftFiles {
            if excludedFileNames.contains(fileURL.lastPathComponent) { continue }

            let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            let hits = Self.findNonCommentHits(of: "UserDefaults.standard", in: content)
            if !hits.isEmpty {
                let relativePath = Self.relativePath(of: fileURL, under: testsURL)
                for lineNumber in hits {
                    violations.append("\(relativePath):\(lineNumber)")
                }
            }
        }

        if !violations.isEmpty {
            let formatted = violations
                .map { "  \($0)" }
                .joined(separator: "\n")
            XCTFail("""
                Direct `UserDefaults.standard` access detected in test files.

                `UserDefaults.standard` is keyed by bundle ID and persists across
                XCTest worker processes, so any test that touches it races under
                `swift test --parallel` (see issue #910 and #756 for prior incidents).

                Replace each violation with a per-suite `UserDefaults(suiteName:)`
                instance and inject it into the SUT — see the doc comment in
                Tests/ManifoldCoreTests/UserDefaultsStandardAuditTest.swift for the
                approved pattern.

                Violations (file:line):
                \(formatted)
                """)
        }
    }

    // MARK: - Helpers

    /// Returns the 1-based line numbers in `content` where `needle` appears
    /// outside of `//`, `///`, and `*`-prefixed comment lines.
    private static func findNonCommentHits(of needle: String, in content: String) -> [Int] {
        var hits: [Int] = []
        let lines = content.components(separatedBy: "\n")
        for (index, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            // Skip comment lines.
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") {
                continue
            }
            if rawLine.contains(needle) {
                hits.append(index + 1)
            }
        }
        return hits
    }

    /// Walks upward from this test file to find the `Tests/` directory at
    /// the repo root. Mirrors `SwiftTestingAuditTest.locateTestsDirectory`.
    private static func locateTestsDirectory(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            let candidate = dir.appendingPathComponent("Tests")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "UserDefaultsStandardAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/ from #filePath",
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

    private static func relativePath(of fileURL: URL, under root: URL) -> String {
        let filePath = fileURL.path
        let rootPath = root.path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return fileURL.lastPathComponent
    }
}
