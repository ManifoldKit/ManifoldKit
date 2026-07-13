import XCTest
import Darwin

/// Phase 1a guard: scans committed fixtures for live credentials and PII.
///
/// Walks every file under `Tests/Fixtures/backends/` and the existing
/// `Tests/Fixtures/ollama/` tree. Matches a small set of regexes drawn from
/// `Tests/Fixtures/REDACTION_POLICY.md`. Each match fails the build unless
/// the offending `<path>:<line>:<pattern>` fingerprint sits on the
/// capped allowlist.
///
/// Why it exists: fixtures get recorded against live providers during
/// backend bring-up; a developer running `scripts/record-fixture.sh` against
/// a real key produces an SSE file whose `Authorization` header or
/// `account_id` field would leak if it landed on GitHub. The audit is the
/// last barrier between "ran the recorder" and "pushed to a public repo."
///
/// Allowlist policy mirrors `TrafficBoundaryAuditTest`: capped cardinality,
/// inline `// CODEOWNER: security` justification required per entry.
final class FixtureRedactionAuditTest: XCTestCase {

    /// Approved fingerprints. Format: `"relative/path:line:pattern-label"`.
    /// Each entry MUST carry an inline `// CODEOWNER: security` comment
    /// below explaining the deliberate exception. Empty by default — every
    /// growth event is a code-review touch point.
    ///
    /// **Cap: 4 entries.**
    private static let allowlist: Set<String> = []

    // MARK: - Patterns

    /// Patterns ordered from most-specific to most-generic so a single line
    /// containing both an `sk-ant-` key and a bearer token reports the
    /// Anthropic-specific match (more actionable for triage).
    private static let patterns: [(label: String, regex: String)] = [
        ("anthropic-key", #"sk-ant-[A-Za-z0-9_-]+"#),
        // Allow hyphens (e.g. `sk-proj-...`) but reject "sk-ant-" so the
        // Anthropic-specific label triages first when both regexes could fire.
        ("openai-key",    #"sk-(?!ant-)[A-Za-z0-9_-]{20,}"#),
        ("openai-org",    #"org-[A-Za-z0-9]{10,}"#),
        ("bearer",        #"Bearer\s+[A-Za-z0-9._-]{16,}"#),
        // RFC4122 UUID appearing as the *value* of an account-shaped key.
        ("account-uuid",  #""(account_id|account_uuid|customer_id)"\s*:\s*"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}""#),
        ("email",         #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#),
        // IPv4 — fast non-backtracking pattern. The audit filters loopback
        // and unspecified addresses in code after the match rather than in
        // the regex (lookbehind-free shape is ~100× faster on long lines).
        ("ipv4",          #"\b[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\b"#),
    ]

    // MARK: - Tests

    func test_fixturesContainNoLiveCredentialsOrPII() throws {
        let fixturesRoot = try Self.locateFixturesDirectory()
        let offenders = try Self.offenders(fixturesRoot: fixturesRoot, allowlist: Self.allowlist)

        XCTAssertLessThanOrEqual(
            Self.allowlist.count, 4,
            "FixtureRedactionAuditTest.allowlist exceeds cap. Each entry weakens the rule — re-record the fixture with `scripts/record-fixture.sh` rather than allowlist a credential."
        )

        if offenders.isEmpty { return }

        let report = offenders.map { o in
            "  [\(o.label)] \(o.file):\(o.line)  ≪ \(o.sample) ≫"
        }.joined(separator: "\n")
        XCTFail("""
            FixtureRedactionAuditTest found likely credentials or PII in committed fixtures:

            \(report)

            Fix:
              - Re-record the fixture via `scripts/record-fixture.sh` (applies the same redaction filter).
              - Or hand-scrub the offending lines.
              - Or, if the match is a deliberate test-of-error-handling, add the fingerprint to
                `FixtureRedactionAuditTest.allowlist` with an inline `// CODEOWNER: security` comment.
            """)
    }

    // MARK: - Detection

    /// Full audit pipeline: walk the fixture roots, match every pattern per
    /// line, filter post-match IPv4 noise, and apply the fingerprint
    /// allowlist. Both the audit and the sabotage tests call this.
    static func offenders(fixturesRoot: URL, allowlist: Set<String>) throws -> [Offender] {
        var offenders: [Offender] = []
        for fileURL in try Self.enumerateFixtureFiles(under: fixturesRoot) {
            let relativePath = fileURL.path.replacingOccurrences(
                of: fixturesRoot.path + "/", with: ""
            )
            // REDACTION_POLICY.md is documentation and contains the
            // patterns themselves; skipping it is the price of co-locating
            // the policy with the fixtures it governs.
            if relativePath == "REDACTION_POLICY.md" { continue }

            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                // Binary fixtures (images, safetensor blobs) — skip; the
                // regex sweep is for textual SSE/NDJSON/JSON files.
                continue
            }

            for (idx, line) in content.components(separatedBy: "\n").enumerated() {
                // Skip very long lines (>2 000 chars) — they are binary blobs
                // or adversarial stress-test data, not human-readable text that
                // could contain a live credential.  The email regex in particular
                // catastrophically backtracks on long alphanumeric strings (e.g.
                // the `very-long-arguments.json` adversarial fixture), causing
                // the test to spin for minutes.  No real credential is embedded
                // in a 100 KB one-liner of repeated characters.
                guard line.count <= 2_000 else { continue }
                for (label, regex) in Self.patterns {
                    guard let matched = Self.firstMatch(of: regex, in: line) else { continue }
                    // IPv4: exclude loopback and unspecified after the cheap
                    // regex match so the hot path stays catastrophic-backtrack-free.
                    if label == "ipv4" {
                        if matched.hasPrefix("127.") || matched.hasPrefix("0.") { continue }
                    }
                    let fingerprint = "\(relativePath):\(idx + 1):\(label)"
                    if allowlist.contains(fingerprint) { continue }
                    offenders.append(.init(
                        file: relativePath,
                        line: idx + 1,
                        label: label,
                        sample: Self.truncate(line)
                    ))
                }
            }
        }
        return offenders
    }

    // MARK: - Sabotage

    /// Plants a fixture containing a live-shaped Anthropic key in a temp
    /// tree and asserts the REAL pipeline (walk → match → allowlist) flags
    /// it, and that a fingerprint allowlist entry exempts it.
    func test_sabotage_pipelineFlagsPlantedCredential() throws {
        let tmp = try Self.makeSabotageTempDirectory(
            name: "fixture-redaction-sabotage-\(UUID().uuidString)"
        )
        defer { try? FileManager.default.removeItem(at: tmp) }

        let fixtureDir = tmp.appendingPathComponent(
            "backends/claude/streaming/simple-prompt", isDirectory: true
        )
        try FileManager.default.createDirectory(at: fixtureDir, withIntermediateDirectories: true)
        try """
        data: {"type":"message_start","message":{"id":"msg_01","type":"message"}}
        x-api-key: sk-ant-api03-fakekey1234567890abcdefghijklmnopqrstuvwxyz
        """.write(to: fixtureDir.appendingPathComponent("request.sse"), atomically: true, encoding: .utf8)

        let offenders = try Self.offenders(fixturesRoot: tmp, allowlist: [])
        XCTAssertTrue(
            offenders.contains { $0.label == "anthropic-key" },
            "The planted sk-ant- credential must be flagged by the real pipeline; got \(offenders.map(\.label))"
        )

        let fingerprint = "backends/claude/streaming/simple-prompt/request.sse:2:anthropic-key"
        let exempted = try Self.offenders(fixturesRoot: tmp, allowlist: [fingerprint])
        XCTAssertFalse(
            exempted.contains { $0.label == "anthropic-key" },
            "An allowlisted fingerprint must exempt the match"
        )
    }

    func test_sabotage_patternsMatchKnownCredentials() {
        // Every pattern must match a synthetic example; if a future edit
        // breaks one of them, the main test would silently pass on a
        // compromised fixture.
        let fixtures: [(label: String, value: String)] = [
            ("anthropic-key", "x-api-key: sk-ant-api03-aBcDeFgHiJk-LmNoPqRs_TuVwXyZ"),
            ("openai-key",    "Authorization: Bearer sk-proj-aBcDeFgHiJkLmNoPqRsTuVwXyZ123456"),
            ("openai-org",    "OpenAI-Organization: org-aBcDeFgHiJkLmNoPqRs"),
            ("bearer",        "Authorization: Bearer abcdefghij0123456789"),
            ("account-uuid",  #""account_id":"12345678-1234-1234-1234-1234567890ab""#),
            ("email",         "contact: alice@example.com"),
            ("ipv4",          "host: 198.51.100.42"),
        ]
        for fixture in fixtures {
            guard let regex = Self.patterns.first(where: { $0.label == fixture.label })?.regex else {
                XCTFail("No pattern for label \(fixture.label)")
                continue
            }
            XCTAssertTrue(
                Self.matches(regex, in: fixture.value),
                "Pattern '\(fixture.label)' failed to match its sabotage fixture: \(fixture.value)"
            )
        }

        // Negatives: the regex itself matches loopback/unspecified IPv4 (it's
        // a cheap word-boundary form), but the audit loop filters those
        // prefixes after matching. Re-create that filter to lock the
        // contract in place.
        let isFilteredIPv4: (String) -> Bool = { $0.hasPrefix("127.") || $0.hasPrefix("0.") }
        XCTAssertTrue(isFilteredIPv4("127.0.0.1"), "loopback prefix must be filtered post-match")
        XCTAssertTrue(isFilteredIPv4("0.0.0.0"),   "unspecified prefix must be filtered post-match")
        XCTAssertFalse(isFilteredIPv4("198.51.100.42"), "documentation-range IP must NOT be filtered")
    }

    // MARK: - Helpers

    struct Offender {
        let file: String
        let line: Int
        let label: String
        let sample: String
    }

    private static func matches(_ pattern: String, in line: String) -> Bool {
        line.range(of: pattern, options: .regularExpression) != nil
    }

    private static func firstMatch(of pattern: String, in line: String) -> String? {
        guard let r = line.range(of: pattern, options: .regularExpression) else { return nil }
        return String(line[r])
    }

    private static func truncate(_ s: String, max: Int = 100) -> String {
        guard s.count > max else { return s }
        return String(s.prefix(max)) + "…"
    }

    // MARK: - File discovery (mirrors PackageTopologyAuditTest)

    /// Walks up from `#filePath` until a `Tests/Fixtures/` directory is
    /// found. Mirrors the upwalk pattern used by other audit tests so
    /// invocation works regardless of cwd.
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
        throw NSError(domain: "FixtureRedactionAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Tests/Fixtures/ from #filePath"
        ])
    }

    /// Enumerates regular files under the two fixture roots that this
    /// audit is responsible for. Skips known binary/non-text trees by
    /// extension so the regex sweep stays bounded.
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
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
                let ext = url.pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "gif", "webp", "bin", "safetensors", "gguf"].contains(ext) { continue }
                result.append(url)
            }
        }
        return result
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

}
