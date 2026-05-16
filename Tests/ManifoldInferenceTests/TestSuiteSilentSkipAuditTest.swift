import XCTest

/// Guards against the `try? XCTSkip*` / `try? XCTUnwrap` footgun.
///
/// These XCTest helpers signal their effect by **throwing**. `XCTSkipUnless`
/// throws `XCTSkip` so the runner marks the test skipped; `XCTUnwrap` throws
/// when the optional is nil so the test fails with a clear diagnostic.
/// Wrapping either in `try?` swallows the throw and turns a load-bearing
/// signal into a no-op:
///
/// - `try? XCTSkipUnless(...)` in `setUp` runs the test even when the gate
///   condition is false. The 50-cycle `SessionDiscardOrderingTests` stress
///   test silently ran in every per-PR CI invocation this way until it
///   started stalling the parallel test stream past the 30-min step cap.
/// - `try? XCTUnwrap(opt)` makes the test report success when `opt` is nil;
///   the follow-up assertion sees `nil` and may pass anyway depending on
///   what it compares to.
///
/// Both patterns are pure footguns — neither has a legitimate use. The
/// `Sources/`-scope `SilentCatchAuditTest` already covers production code;
/// this test extends the coverage to `Tests/` with no allowlist.
final class TestSuiteSilentSkipAuditTest: XCTestCase {

    private static let forbiddenPatterns: [String] = [
        "try? XCTSkip",
        "try? XCTUnwrap",
        "try? XCTFail",
    ]

    func test_testsDirectoryContainsNoSilentXCTSkipOrUnwrap() throws {
        let testsURL = try Self.locateTestsDirectory()
        var offenders: [(file: String, line: Int, text: String)] = []

        let swiftFiles = try Self.enumerateSwiftFiles(under: testsURL)
        XCTAssertFalse(swiftFiles.isEmpty, "Tests directory yielded no .swift files — path probably wrong")

        for fileURL in swiftFiles {
            // Skip this file — it deliberately mentions the forbidden tokens.
            if fileURL.lastPathComponent == "TestSuiteSilentSkipAuditTest.swift" { continue }

            let relativePath = fileURL.path.replacingOccurrences(of: testsURL.path + "/", with: "")
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: "\n")
            for (index, rawLine) in lines.enumerated() {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") || line.hasPrefix("///") || line.hasPrefix("*") { continue }
                for pattern in Self.forbiddenPatterns where line.contains(pattern) {
                    offenders.append((file: relativePath, line: index + 1, text: line))
                    break
                }
            }
        }

        if !offenders.isEmpty {
            let formatted = offenders
                .map { "  \($0.file):\($0.line)  \($0.text)" }
                .joined(separator: "\n")
            XCTFail("""
                Forbidden silent-skip / silent-unwrap pattern found in Tests/.
                These swallow the throw that XCTSkip/XCTUnwrap rely on. Use `try` (not `try?`) and make the enclosing function `throws`:

                \(formatted)
                """)
        }
    }

    // MARK: - Helpers

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
        throw NSError(domain: "TestSuiteSilentSkipAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/ from #filePath"
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
