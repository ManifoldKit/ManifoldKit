import XCTest
import Darwin

/// Audit: MockURLProtocol stub state is process-wide, so suites must not
/// clobber or collide with each other under `swift test --parallel`.
///
/// Enforces the AGENTS.md test convention that was previously stated but
/// untripwired: "Never call `MockURLProtocol.reset()` across suites …
/// Use UUID-based hostnames per suite to isolate stubs instead."
///
/// Two rules over `Tests/**/*.swift`:
///
/// 1. **No `MockURLProtocol.reset()` call sites.** `reset()` clears every
///    suite's stubs, not just the caller's — under the parallel runner a
///    teardown `reset()` yanks stubs out from under concurrently running
///    tests. Use `unstub(url:)` per registered URL instead.
/// 2. **Files that register stubs use UUID-based hostnames.** A file
///    calling `MockURLProtocol.stub`/`stubSequence` must construct its
///    URLs with `UUID(` somewhere in the file — fixed hostnames collide
///    across suites that stub the same host.
///
/// Both rules skip comment lines (the convention is widely *cited* in
/// comments) and honor a per-file burn-down allowlist for the two legacy
/// OAuth/hardening suites whose ~200 semantic hostname literals
/// (`auth.example.com`, metadata-endpoint IPs) are load-bearing security
/// fixtures — migrating them is tracked by the allowlist entries below,
/// which the stale check forces out once a file is migrated.
///
/// The detection pipeline lives in ``scan(testsRoot:allowlist:)`` so the
/// in-file sabotage test exercises the exact function the audit runs.
final class MockURLProtocolIsolationAuditTest: XCTestCase {

    /// Burn-down allowlist: files exempt from both rules, with the reason
    /// they are still allowed. Shrink this list; never grow it.
    static let allowlist: Set<String> = [
        // ~1600-line OAuth-flow suite; hostnames (auth./resource./token.
        // example.com) are semantic fixtures keyed into SSRF resolver
        // stubs. Migration is a dedicated change, not a drive-by.
        "AuthMCPOAuthAuthorizationTests.swift",
        // SSRF/metadata-endpoint hardening suite; literal hosts and IPs
        // (169.254.169.254, printer.local) are the point of the tests.
        "MCPHardeningTests.swift",
    ]

    func test_testsDirectoryHasNoMockURLProtocolIsolationViolations() throws {
        let testsURL = try Self.locateTestsDirectory()
        let (offences, matchedAllowlist) = try Self.scan(
            testsRoot: testsURL,
            allowlist: Self.allowlist
        )

        if !offences.isEmpty {
            let formatted = offences
                .map { "  \($0.file):\($0.line)  [\($0.rule)]  \($0.text)" }
                .joined(separator: "\n")
            XCTFail("""
                MockURLProtocol isolation violations found. Stub state is \
                process-wide: use a unique UUID-based hostname per suite and \
                `unstub(url:)` in teardown — never `reset()`.

                \(formatted)
                """)
        }

        // Stale-allowlist check: once a legacy file is migrated (or
        // renamed away), its entry must be removed.
        let stale = Self.allowlist.subtracting(matchedAllowlist)
        if !stale.isEmpty {
            XCTFail("""
                MockURLProtocolIsolationAuditTest.allowlist has entries that no \
                longer violate any rule (migrated or renamed) — remove them:

                  \(stale.sorted().joined(separator: "\n  "))
                """)
        }
    }

    // MARK: - Sabotage (exercises the same `scan(testsRoot:allowlist:)` the audit runs)

    /// Plants a temp tree with a `reset()` caller, a fixed-hostname stub
    /// file, a comment-only mention, and a clean UUID-hostname file, and
    /// asserts the real pipeline flags exactly the violations.
    func test_sabotage_scanFlagsPlantedViolations() throws {
        let tmp = try Self.makeSabotageTempDirectory(
            name: "mockurl-isolation-sabotage-\(UUID().uuidString)"
        )
        defer {
            do { try FileManager.default.removeItem(at: tmp) } catch {
                // Best-effort temp cleanup; nothing to assert on.
            }
        }

        try """
        final class ResetterTests: XCTestCase {
            override func tearDown() {
                MockURLProtocol.reset()
            }
        }
        """.write(to: tmp.appendingPathComponent("ResetterTests.swift"), atomically: true, encoding: .utf8)

        try """
        final class FixedHostTests: XCTestCase {
            func test_x() {
                let url = URL(string: "https://example.com/api")!
                MockURLProtocol.stub(url: url, response: .immediate(data: Data(), statusCode: 200))
            }
        }
        """.write(to: tmp.appendingPathComponent("FixedHostTests.swift"), atomically: true, encoding: .utf8)

        try """
        /// Never call `MockURLProtocol.reset()` across suites — comment only.
        final class CleanTests: XCTestCase {
            func test_x() {
                let url = URL(string: "https://host-\\(UUID().uuidString).test/api")!
                MockURLProtocol.stub(url: url, response: .immediate(data: Data(), statusCode: 200))
                MockURLProtocol.unstub(url: url)
            }
        }
        """.write(to: tmp.appendingPathComponent("CleanTests.swift"), atomically: true, encoding: .utf8)

        let (offences, _) = try Self.scan(testsRoot: tmp, allowlist: [])

        XCTAssertTrue(
            offences.contains { $0.rule == "reset-call" && $0.file == "ResetterTests.swift" },
            "A real reset() call site must be flagged; got \(offences)"
        )
        XCTAssertTrue(
            offences.contains { $0.rule == "fixed-hostname" && $0.file == "FixedHostTests.swift" },
            "A stub-registering file without UUID hostnames must be flagged; got \(offences)"
        )
        XCTAssertFalse(
            offences.contains { $0.file == "CleanTests.swift" },
            "A comment-only reset() mention in a UUID-hostname file must NOT be flagged; got \(offences)"
        )

        // The allowlist must exempt a named file — and report it as matched.
        let (exempted, matched) = try Self.scan(
            testsRoot: tmp,
            allowlist: ["ResetterTests.swift", "FixedHostTests.swift"]
        )
        XCTAssertFalse(
            exempted.contains { $0.file == "ResetterTests.swift" || $0.file == "FixedHostTests.swift" },
            "Allowlisted files must be exempt; got \(exempted)"
        )
        XCTAssertEqual(
            matched, ["ResetterTests.swift", "FixedHostTests.swift"],
            "Matched allowlist entries feed the stale check"
        )
    }

    // MARK: - Detection

    struct Offence: Equatable {
        let file: String
        let line: Int
        let rule: String
        let text: String
    }

    /// Returns unapproved offences plus the set of allowlist entries that
    /// actually matched a violating file (for the stale-allowlist check).
    static func scan(
        testsRoot: URL,
        allowlist: Set<String>
    ) throws -> (offences: [Offence], matchedAllowlist: Set<String>) {
        var offences: [Offence] = []
        var matchedAllowlist: Set<String> = []

        for fileURL in try Self.enumerateSwiftFiles(under: testsRoot) {
            let fileName = fileURL.lastPathComponent
            if fileName == "MockURLProtocolIsolationAuditTest.swift" { continue }
            let content = try String(contentsOf: fileURL, encoding: .utf8)
            let lines = content.components(separatedBy: "\n")

            var fileOffences: [Offence] = []
            var registersStubs = false
            var containsUUID = false

            for (index, rawLine) in lines.enumerated() {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") {
                    continue
                }
                if trimmed.contains("UUID(") { containsUUID = true }
                if trimmed.contains("MockURLProtocol.stub") { registersStubs = true }
                if trimmed.contains("MockURLProtocol.reset()") {
                    fileOffences.append(Offence(
                        file: fileName, line: index + 1, rule: "reset-call", text: trimmed
                    ))
                }
            }

            if registersStubs, !containsUUID {
                fileOffences.append(Offence(
                    file: fileName, line: 1, rule: "fixed-hostname",
                    text: "registers MockURLProtocol stubs but builds no UUID-based hostname"
                ))
            }

            if fileOffences.isEmpty { continue }
            if allowlist.contains(fileName) {
                matchedAllowlist.insert(fileName)
            } else {
                offences.append(contentsOf: fileOffences)
            }
        }

        return (offences.sorted { ($0.file, $0.line) < ($1.file, $1.line) }, matchedAllowlist)
    }

    // MARK: - Helpers

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
        return result.sorted { $0.path < $1.path }
    }

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
        throw NSError(domain: "MockURLProtocolIsolationAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/ from #filePath",
        ])
    }

    /// Fully-resolved temp directory (see SilentCatchAuditTest for the
    /// /var → /private/var APFS-firmlink rationale).
    private static func makeSabotageTempDirectory(name: String) throws -> URL {
        let unresolved = FileManager.default.temporaryDirectory
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: unresolved, withIntermediateDirectories: true)
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(unresolved.path, &buffer) != nil else { return unresolved }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }
}
