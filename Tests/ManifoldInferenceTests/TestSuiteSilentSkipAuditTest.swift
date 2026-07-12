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
/// this test extends the coverage to `Tests/`. The only excluded file is
/// this audit itself, which contains the tokens purely as inert text (see
/// the exclusion set below).
///
/// The detection loop lives in ``offenders(testsRoot:excludedFileNames:)``
/// so the in-file sabotage test exercises the exact function the audit runs.
final class TestSuiteSilentSkipAuditTest: XCTestCase {

    private static let forbiddenPatterns: [String] = [
        "try? XCTSkip",
        "try? XCTUnwrap",
        "try? XCTFail",
    ]

    func test_testsDirectoryContainsNoSilentXCTSkipOrUnwrap() throws {
        let testsURL = try Self.locateTestsDirectory()
        let swiftFiles = try Self.enumerateSwiftFiles(under: testsURL)
        XCTAssertFalse(swiftFiles.isEmpty, "Tests directory yielded no .swift files — path probably wrong")

        // The excluded file contains the forbidden tokens only as inert text
        // (needles, messages, and a concatenation-built sabotage payload) —
        // excluding it silences no real violation. (The retired external
        // sabotage suite was a second exclusion until 2026-07.)
        let excludedFileNames: Set<String> = [
            "TestSuiteSilentSkipAuditTest.swift",
        ]

        let offenders = try Self.offenders(testsRoot: testsURL, excludedFileNames: excludedFileNames)

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

    // MARK: - Sabotage (exercises the same `offenders(testsRoot:excludedFileNames:)` the audit runs)

    /// Plants a temp tree containing a `try? XCTSkipUnless(...)` swallow and
    /// asserts the REAL detection loop flags it — and that adding the
    /// planted file's name to `excludedFileNames` exempts it. The payload
    /// is built by string concatenation so this audit's own repo-wide scan
    /// of `Tests/` never sees the contiguous forbidden token in THIS file.
    func test_sabotage_offendersFlagsPlantedSilentSkip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("silent-skip-sabotage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let payload = "try? " + "XCTSkipUnless(false)"
        try """
        import XCTest

        final class BadSkipTests: XCTestCase {
            func testSomething() throws {
                \(payload)
            }
        }
        """.write(to: tmp.appendingPathComponent("BadSkip.swift"), atomically: true, encoding: .utf8)

        let offenders = try Self.offenders(testsRoot: tmp, excludedFileNames: [])
        XCTAssertEqual(offenders.count, 1, "The planted try? XCTSkipUnless must be flagged")
        XCTAssertEqual(offenders.first?.file, "BadSkip.swift")

        let exempted = try Self.offenders(testsRoot: tmp, excludedFileNames: ["BadSkip.swift"])
        XCTAssertTrue(exempted.isEmpty, "An excluded file name must exempt its contents")
    }

    // MARK: - Detection

    static func offenders(
        testsRoot: URL,
        excludedFileNames: Set<String>
    ) throws -> [(file: String, line: Int, text: String)] {
        var offenders: [(file: String, line: Int, text: String)] = []
        let swiftFiles = try Self.enumerateSwiftFiles(under: testsRoot)

        for fileURL in swiftFiles {
            if excludedFileNames.contains(fileURL.lastPathComponent) { continue }

            let relativePath = fileURL.path.replacingOccurrences(of: testsRoot.path + "/", with: "")
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
        return offenders
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
