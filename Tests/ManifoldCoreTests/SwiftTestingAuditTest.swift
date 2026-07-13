import XCTest

/// Guards against regressions on issue #681: `@Suite` and `@Test` annotations
/// added to test targets that share a single `swift test` process invocation
/// with XCTest suites.
///
/// ## Why this matters
///
/// Running Swift Testing (`@Suite`/`@Test`) and XCTest suites in the same
/// `swift test` process triggers a libmalloc double-free SIGABRT. The CI
/// workflow (`.github/workflows/ci.yml`) therefore keeps `ManifoldInferenceTests`
/// (XCTest-only) and `ManifoldInferenceSwiftTestingTests` (Swift Testing-only)
/// in separate process invocations.
///
/// The default `Test — XCTest suites` step in CI invokes `swift test` once
/// across `ManifoldCoreTests`, `ManifoldUITests`, `ManifoldBackendsTests`, and
/// the other XCTest targets. Existing Swift Testing files in
/// `ManifoldBackendsTests` predate the discovery of #681 and are committed
/// as an approved baseline. They are CI-safe because the crash only manifests
/// when an XCTestCase subclass coexists in the same process with `@Suite`/`@Test`,
/// and these files use Swift Testing exclusively at file level. Adding more
/// `@Test` functions to a file already on the allowlist does not change that
/// safety property.
///
/// ## What this audit asserts
///
/// For every `.swift` file under the audited target directories:
///
/// 1. **No mixed-harness files.** A file must not contain both an
///    `XCTestCase` subclass declaration and a `@Suite`/`@Test` annotation.
///    A single such file would trip the libmalloc bug regardless of which
///    other files are linked into the same `swift test` invocation.
///
/// 2. **No new Swift Testing files in merged-filter targets.** A file using
///    `@Suite`/`@Test` must appear in `swiftTestingFilesAllowlist`. Adding
///    a new entry requires reviewer sign-off and one of:
///     - splitting the CI step so the new file runs in its own `swift test`
///       process (mirrors the `ManifoldInferenceSwiftTestingTests` pattern), or
///     - proof that the SIGABRT is fixed in the toolchain.
///
/// What this audit deliberately does **not** check is the count of
/// `@Suite`/`@Test` annotations per file. The earlier per-file count
/// baseline imposed PR friction (every new `@Test` required bumping a
/// hardcoded number) without strengthening the safety surface — see
/// the PR that introduced this design. Annotation count is irrelevant
/// to the crash mode; harness mixing in one process is what matters.
///
/// ## Updating the allowlist
///
/// To add a Swift Testing file to a merged-filter target, either split the
/// CI step or remove the target from `auditedTargetDirectories` (with a
/// matching CI change). Then add the path to `swiftTestingFilesAllowlist`.
///
/// DO NOT add entries solely to make this test pass without completing
/// those verification steps.
///
/// The detection logic lives in ``scan(testsRoot:auditedTargets:allowlist:excludedFileNames:)``
/// so the in-file sabotage test exercises the exact function the audit runs.
final class SwiftTestingAuditTest: XCTestCase {

    /// Files in the audited targets that are known to use Swift Testing
    /// exclusively (no XCTest subclass in the same file). Captured at the
    /// time issue #681 was addressed; growth past this baseline requires
    /// a CI-step split or a toolchain fix for the SIGABRT.
    ///
    /// Entries are file paths relative to `Tests/`.
    private static let swiftTestingFilesAllowlist: Set<String> = [
        "ManifoldBackendsTests/CloudBackendSSETests.swift",
        "ManifoldBackendsTests/CloudErrorSanitizerTests.swift",
        "ManifoldBackendsTests/CloudThinkingTokenTests.swift",
        "ManifoldBackendsTests/InferenceMetricTests.swift",
        "ManifoldBackendsTests/OllamaBackendTests.swift",
        "ManifoldBackendsTests/OpenAICompatEndpointTests.swift",
        "ManifoldBackendsTests/SecureBytesTests.swift",
        "ManifoldBackendsTests/SSECloudBackendAdapterRoutingTests.swift",
        "ManifoldBackendsTests/SSEExtractEventsTests.swift",
    ]

    /// Targets whose `.swift` files must obey the rules above.
    private static let auditedTargetDirectories: [String] = [
        "ManifoldCoreTests",
        "ManifoldUITests",
        "ManifoldBackendsTests",
    ]

    func test_noUnapprovedSwiftTestingGrowthInMergedFilterTargets() throws {
        let testsURL = try Self.locateTestsDirectory()

        // The audit file mentions `XCTestCase` and `@Suite`/`@Test` in code
        // paths and error message strings, not as real declarations. Skip it
        // the same way `UserDefaultsStandardAuditTest` skips itself.
        let auditFileName = (#filePath as NSString).lastPathComponent

        let result = Self.scan(
            testsRoot: testsURL,
            auditedTargets: Self.auditedTargetDirectories,
            allowlist: Self.swiftTestingFilesAllowlist,
            excludedFileNames: [auditFileName]
        )
        let violations = result.violations
        let observedSwiftTestingFiles = result.observed

        if !violations.isEmpty {
            let formatted = violations
                .map { "  \($0)" }
                .joined(separator: "\n")
            XCTFail("""
                Swift Testing harness violations detected in merged-filter CI targets.

                The default `Test — XCTest suites` CI step links ManifoldCoreTests, ManifoldUITests,
                and ManifoldBackendsTests into a single `swift test` process. Mixing XCTestCase with
                @Suite/@Test inside that process triggers a libmalloc double-free SIGABRT (#681).

                See issue #681 and .github/workflows/ci.yml for context.

                Violations:
                \(formatted)

                To resolve:
                  1. Split the file so each harness is in its own source file (for mixed-harness
                     violations), or
                  2. Move the new Swift Testing file to a target that runs in its own `swift test`
                     process (mirrors ManifoldInferenceSwiftTestingTests), then add it to
                     swiftTestingFilesAllowlist with reviewer sign-off.
                """)
        }

        // Stale-allowlist check: every allowlisted path must still exist
        // and still use Swift Testing, or the list has drifted.
        let stale = Self.swiftTestingFilesAllowlist.subtracting(observedSwiftTestingFiles)
        if !stale.isEmpty {
            let formatted = stale.sorted().joined(separator: "\n  ")
            XCTFail("""
                swiftTestingFilesAllowlist has stale entries — files that no longer exist or no
                longer use @Suite/@Test. Remove them:

                  \(formatted)
                """)
        }
    }

    // MARK: - Sabotage (exercises the same `scan(...)` the audit runs)

    /// Plants a mixed-harness file (XCTestCase + @Test in one file) and a
    /// Swift-Testing-only file not on the allowlist, in a temp tree shaped
    /// like `Tests/`, and asserts the REAL `scan(...)` flags both — and
    /// that allowlisting the second file exempts it.
    func test_sabotage_detectsMixedHarnessAndUnapprovedGrowth() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-testing-sabotage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let targetDir = tmp.appendingPathComponent("ManifoldBackendsTests", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        try """
        import XCTest
        import Testing
        final class MixedHarness: XCTestCase {
            func test_old() {}
        }
        @Test func newStyle() {}
        """.write(to: targetDir.appendingPathComponent("MixedHarness.swift"), atomically: true, encoding: .utf8)

        try """
        import Testing
        @Suite struct NewSuite {
            @Test func example() {}
        }
        """.write(to: targetDir.appendingPathComponent("NewSuiteOnly.swift"), atomically: true, encoding: .utf8)

        let result = Self.scan(
            testsRoot: tmp,
            auditedTargets: ["ManifoldBackendsTests"],
            allowlist: [],
            excludedFileNames: []
        )
        XCTAssertTrue(
            result.violations.contains { $0.contains("MixedHarness.swift") && $0.contains("trips the libmalloc SIGABRT") },
            "The planted mixed-harness file must be flagged; got \(result.violations)"
        )
        XCTAssertTrue(
            result.violations.contains { $0.contains("NewSuiteOnly.swift") && $0.contains("without being allowlisted") },
            "The planted unapproved Swift Testing file must be flagged; got \(result.violations)"
        )

        // Allowlisting the Swift-Testing-only file exempts it from growth
        // violations (the mixed-harness file is never exemptable).
        let allowlisted = Self.scan(
            testsRoot: tmp,
            auditedTargets: ["ManifoldBackendsTests"],
            allowlist: ["ManifoldBackendsTests/NewSuiteOnly.swift"],
            excludedFileNames: []
        )
        XCTAssertFalse(
            allowlisted.violations.contains { $0.contains("NewSuiteOnly.swift") },
            "An allowlisted Swift Testing file must not be flagged for growth"
        )
        XCTAssertTrue(
            allowlisted.observed.contains("ManifoldBackendsTests/NewSuiteOnly.swift"),
            "The allowlisted file must still appear in observed Swift Testing files"
        )
    }

    // MARK: - Detection

    /// Full audit pipeline: walk the audited targets under `testsRoot`,
    /// skip `excludedFileNames`, and flag mixed-harness files plus
    /// unapproved Swift Testing growth against `allowlist`. Returns the
    /// violation strings and the set of observed Swift Testing files (so
    /// the main test's stale-allowlist check can compare against it). Both
    /// the audit and the sabotage test call this.
    static func scan(
        testsRoot: URL,
        auditedTargets: [String],
        allowlist: Set<String>,
        excludedFileNames: Set<String>
    ) -> (violations: [String], observed: Set<String>) {
        var violations: [String] = []
        var observedSwiftTestingFiles: Set<String> = []

        for targetName in auditedTargets {
            let targetURL = testsRoot.appendingPathComponent(targetName)
            let swiftFiles = (try? Self.enumerateSwiftFiles(under: targetURL)) ?? []

            for fileURL in swiftFiles {
                if excludedFileNames.contains(fileURL.lastPathComponent) { continue }

                let relativePath = "\(targetName)/\(fileURL.lastPathComponent)"
                let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""

                let usesSwiftTesting = Self.containsSwiftTestingAnnotation(in: content)
                let usesXCTestCase = Self.containsXCTestCaseSubclass(in: content)

                if usesSwiftTesting && usesXCTestCase {
                    violations.append("""
                        \(relativePath): file declares an XCTestCase subclass AND uses @Suite/@Test — \
                        this file alone trips the libmalloc SIGABRT (#681). Split the file so each \
                        harness lives in its own source file.
                        """.trimmingCharacters(in: .whitespacesAndNewlines))
                    continue
                }

                if usesSwiftTesting {
                    observedSwiftTestingFiles.insert(relativePath)
                    if !allowlist.contains(relativePath) {
                        violations.append("""
                            \(relativePath): introduces @Suite/@Test in a merged-filter CI target without \
                            being allowlisted in SwiftTestingAuditTest.swiftTestingFilesAllowlist.
                            """.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            }
        }

        return (violations, observedSwiftTestingFiles)
    }

    // MARK: - Helpers

    /// `true` when `content` contains at least one `@Suite` or `@Test`
    /// occurrence outside of a `//`, `///`, or `*`-prefixed comment line.
    private static func containsSwiftTestingAnnotation(in content: String) -> Bool {
        for rawLine in content.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") {
                continue
            }
            if trimmed.contains("@Suite") || trimmed.contains("@Test") {
                return true
            }
        }
        return false
    }

    /// `true` when `content` contains a class declaration whose inheritance
    /// list names `XCTestCase`. Single-line declarations only — Swift permits
    /// declarations split across lines but the codebase uses the single-line
    /// form throughout.
    ///
    /// The pattern matches both direct subclasses and protocol-composition
    /// shapes such as `class FooTests: XCTestCase, MyProtocol`. It does not
    /// catch indirect subclasses (`class FooTests: MyBaseTestCase` where
    /// `MyBaseTestCase: XCTestCase`); we accept that as a reviewable
    /// false negative since BCK does not currently use such intermediates.
    private static func containsXCTestCaseSubclass(in content: String) -> Bool {
        let pattern = #"^\s*(?:final\s+|public\s+|internal\s+|private\s+|fileprivate\s+|open\s+)*class\s+\w+(?:<[^>]+>)?\s*:[^{]*\bXCTestCase\b"#
        for rawLine in content.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") {
                continue
            }
            if rawLine.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// Walks upward from the test file to find the repo root, then returns
    /// the `Tests/` subdirectory. Uses `#filePath` to stay cross-platform
    /// and free of shell dependencies.
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
        throw NSError(domain: "SwiftTestingAuditTest", code: 1, userInfo: [
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
}
