import XCTest

/// Guards against regressions on issue #681: `@Suite` and `@Test` annotations
/// added to test targets that share a single `swift test` process invocation
/// with XCTest suites.
///
/// ## Why this matters
///
/// Running Swift Testing (`@Suite`/`@Test`) and XCTest suites in the same
/// `swift test` process triggers a libmalloc double-free SIGABRT. The CI
/// workflow (`.github/workflows/ci.yml`) therefore keeps `BaseChatInferenceTests`
/// (XCTest-only) and `BaseChatInferenceSwiftTestingTests` (Swift Testing-only)
/// in separate process invocations. That split is expensive — it adds a full
/// compile-and-link step to every CI run.
///
/// The "Core + UI + Backends" step merges three targets into one invocation:
///
///     scripts/test.sh --filter BaseChatCoreTests \
///                     --filter BaseChatUITests \
///                     --filter BaseChatBackendsTests \
///                     --disable-default-traits
///
/// `BaseChatCoreTests` and `BaseChatUITests` are XCTest-only. The small set of
/// Swift Testing files in `BaseChatBackendsTests` was migrated before the crash
/// was understood and are committed as an approved baseline. No further growth
/// is allowed unless the CI step is explicitly split.
///
/// ## Allowlist format
///
/// ``allowedAnnotationCountPerFile`` maps
/// `"<TargetDir>/<Filename.swift>"` → maximum number of `@Suite` + `@Test`
/// occurrences (excluding comment lines) the file is permitted to contain.
///
/// Raising a limit or adding a new entry requires human review and a matching
/// CI-step split (or proof that the SIGABRT is fixed in the Swift toolchain).
///
/// ## Updating the allowlist
///
/// If you add Swift Testing annotations to an already-allowlisted file and the
/// count exceeds its threshold, bump the threshold here after verifying:
///
/// 1. The new tests don't mix XCTest and Swift Testing in the same file.
/// 2. The CI step for that target is still process-isolated.
/// 3. A reviewer has sign-off on the bump.
///
/// DO NOT add entries or raise limits solely to make this test pass without
/// completing those verification steps.
final class SwiftTestingAuditTest: XCTestCase {

    /// Per-file upper bound on `@Suite` + `@Test` annotation count.
    ///
    /// Files not listed here must contain zero such annotations.
    /// Counts were captured at the time issue #681 was addressed and represent
    /// the approved baseline for the "Core + UI + Backends" CI merge step.
    private static let allowedAnnotationCountPerFile: [String: Int] = [
        // BaseChatCoreTests — this file itself contains the annotation keywords
        // in string literals and code paths (error messages, the countAnnotations
        // implementation), not as real Swift Testing entry points. The count is
        // capped at the exact number of occurrences at the time of writing so
        // that adding new message copy here triggers the same reviewer gate.
        "BaseChatCoreTests/SwiftTestingAuditTest.swift": 10,

        // BaseChatBackendsTests — existing Swift Testing files committed before
        // the libmalloc SIGABRT was understood. These files are CI-safe because
        // they use Swift Testing exclusively (no XCTest in the same file) and
        // the target binary as a whole is still mixed; the crash only manifests
        // when a single XCTestCase subclass co-exists in the same process with
        // a @Suite — which is the risk we're guarding against here.
        "BaseChatBackendsTests/CloudBackendSSETests.swift": 22,
        "BaseChatBackendsTests/CloudErrorSanitizerTests.swift": 23,
        "BaseChatBackendsTests/CloudThinkingTokenTests.swift": 8,
        "BaseChatBackendsTests/OllamaBackendTests.swift": 68,
        "BaseChatBackendsTests/OpenAICompatEndpointTests.swift": 20,
        "BaseChatBackendsTests/SecureBytesTests.swift": 11,
        "BaseChatBackendsTests/SSEExtractEventsTests.swift": 5,
    ]

    /// Targets whose `.swift` files must not exceed their allowlisted
    /// annotation counts (and must contain zero if not allowlisted).
    private static let auditedTargetDirectories: [String] = [
        "BaseChatCoreTests",
        "BaseChatUITests",
        "BaseChatBackendsTests",
    ]

    func test_noUnapprovedSwiftTestingGrowthInMergedFilterTargets() throws {
        let testsURL = try Self.locateTestsDirectory()
        var violations: [String] = []

        for targetName in Self.auditedTargetDirectories {
            let targetURL = testsURL.appendingPathComponent(targetName)
            let swiftFiles = (try? Self.enumerateSwiftFiles(under: targetURL)) ?? []

            for fileURL in swiftFiles {
                let relativePath = "\(targetName)/\(fileURL.lastPathComponent)"
                let content = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
                let count = Self.countAnnotations(in: content)

                let limit = Self.allowedAnnotationCountPerFile[relativePath] ?? 0

                if count > limit {
                    if limit == 0 {
                        violations.append("""
                            \(relativePath): found \(count) @Suite/@Test annotation(s) — file is not allowlisted (limit 0).
                            """.trimmingCharacters(in: .whitespacesAndNewlines))
                    } else {
                        violations.append("""
                            \(relativePath): found \(count) @Suite/@Test annotation(s) — exceeds allowlisted limit of \(limit).
                            """.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            }
        }

        if !violations.isEmpty {
            let formatted = violations
                .map { "  \($0)" }
                .joined(separator: "\n")
            XCTFail("""
                Swift Testing (@Suite/@Test) growth detected in merged-filter CI targets.

                Adding Swift Testing annotations to BaseChatCoreTests, BaseChatUITests, or
                BaseChatBackendsTests beyond the committed baseline risks a libmalloc double-free
                SIGABRT when the three targets share a single swift test process invocation.

                See issue #681 and .github/workflows/ci.yml for context.

                Violations:
                \(formatted)

                To resolve:
                  1. Confirm the new tests do not mix XCTest and Swift Testing in one file.
                  2. Split the CI merge step so the new Swift Testing target runs in its own
                     process invocation (mirrors the BaseChatInferenceSwiftTestingTests pattern).
                  3. Raise the per-file limit (or add a new entry) in
                     SwiftTestingAuditTest.allowedAnnotationCountPerFile with reviewer sign-off.
                """)
        }

        // Stale-allowlist check: every allowlisted file must still exist and
        // actually contain annotations, or the list has drifted.
        for (relativePath, limit) in Self.allowedAnnotationCountPerFile {
            let parts = relativePath.split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let targetName = String(parts[0])
            let fileName = String(parts[1])
            let fileURL = testsURL
                .appendingPathComponent(targetName)
                .appendingPathComponent(fileName)

            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                XCTFail("""
                    SwiftTestingAuditTest.allowedAnnotationCountPerFile has a stale entry: \
                    "\(relativePath)" no longer exists. Remove it.
                    """)
                continue
            }

            let actual = Self.countAnnotations(in: content)
            if actual == 0 && limit > 0 {
                XCTFail("""
                    SwiftTestingAuditTest.allowedAnnotationCountPerFile has a stale entry: \
                    "\(relativePath)" has limit \(limit) but contains 0 @Suite/@Test annotations. \
                    Remove the entry or reduce the limit to 0.
                    """)
            }
        }
    }

    // MARK: - Helpers

    /// Counts the number of `@Suite` and `@Test` annotation occurrences in
    /// `content`, excluding lines that are comments.
    private static func countAnnotations(in content: String) -> Int {
        let lines = content.components(separatedBy: "\n")
        var count = 0
        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            // Skip comment lines.
            guard !trimmed.hasPrefix("//"), !trimmed.hasPrefix("///"), !trimmed.hasPrefix("*") else {
                continue
            }
            // Count each annotation keyword separately so a line with both
            // (unusual, but possible in generated code) is not double-counted.
            if trimmed.contains("@Suite") { count += 1 }
            if trimmed.contains("@Test") { count += 1 }
        }
        return count
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
