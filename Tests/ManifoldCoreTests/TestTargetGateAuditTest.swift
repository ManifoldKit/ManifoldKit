import XCTest

/// Guards against a real `swift test` target existing on disk but never
/// running anywhere — the "orphan test target" bug class.
///
/// ## Why this matters
///
/// `ManifoldSnapshotTests` and `ManifoldTelemetryOTLPTests` were real
/// `.testTarget`s in `Package.swift`, compiled fine, and had never once
/// appeared in `scripts/test.sh`'s XCTest filter lists or any
/// `.github/workflows/*.yml` job (`git log -S ManifoldSnapshotTests --
/// scripts/test.sh` returns nothing). Consequence: 5 `ChatViewControlTests`
/// assertions rotted silently for a month — `main` stayed green the entire
/// time because nothing ever executed them. This is Principle 5 in the
/// repo's `AGENTS.md`: "a test that cannot be shown to fail is not
/// coverage." `TestSuiteSilentSkipAuditTest` catches a skipped test *inside*
/// a suite that does run; nothing previously caught a whole suite that never
/// runs at all.
///
/// ## What this test enforces
///
/// Every `.testTarget` declared in `Package.swift` must either:
/// 1. Have its name appear as a bare entry inside one of `scripts/test.sh`'s
///    array-literal filter lists (`PROFILE_CI_XCTEST_FILTERS`,
///    `PROFILE_LOCAL_XCTEST_FILTERS`, …) or as a scalar filter assignment
///    (`PROFILE_SWIFT_TESTING_FILTER=...`) — i.e. it is actually executed by
///    the local/CI gate shape, or
/// 2. Be listed in `knownUngatedTargets` below with a stated reason.
///
/// `scripts/test.sh`'s array parser (``Self.gatedTargetNames(scriptContent:)``)
/// is intentionally generic: it locates any `VARNAME=(` ... `)` block (bash
/// array literal, one bare identifier per line) or `VARNAME="Identifier"`
/// scalar assignment, skips comment lines and array-expansion references
/// (`"${OTHER[@]}"`), and unions every identifier-shaped token it finds. It
/// does not hardcode `PROFILE_CI_XCTEST_FILTERS` / `PROFILE_LOCAL_XCTEST_FILTERS`
/// by name, so a future filter-list variable (or reordering the existing
/// ones) is picked up automatically — no test update required. CI runners
/// ship Bash 3.2; this parser only reads the file as text, so the Bash
/// version is irrelevant.
///
/// ``testTargetNames(packageManifest:)`` and
/// ``gatedTargetNames(scriptContent:)`` are pure `static func`s so the
/// in-file sabotage test exercises the exact functions the audit runs.
final class TestTargetGateAuditTest: XCTestCase {

    /// Test targets that deliberately never run in `scripts/test.sh`'s
    /// XCTest filter lists, each with a reason. Adding an entry here is a
    /// deliberate, reviewed decision — not a way to silence this audit.
    private static let knownUngatedTargets: [String: String] = [
        "ManifoldE2ETests":
            "Requires a live Ollama server at localhost:11434; run by hand " +
            "(`swift test --filter ManifoldE2ETests`), not part of the " +
            "local/CI gate. See AGENTS.md § Running tests.",
        "ManifoldMCPE2ETests":
            "Gated behind the RUN_MCP_E2E=1 env var (npx/network subprocess " +
            "tests) — runs only in nightly-slow-tests.yml, never per-PR. " +
            "See scripts/test.sh's MCP_FILTER_REQUESTED handling and " +
            "nightly-slow-tests.yml.",
        "ManifoldFuzzTests":
            "ManifoldFuzz is a dev tool, not a published library product " +
            "(see AGENTS.md § Targets). Its campaign runs via scripts/fuzz.sh " +
            "on a weekly-only cadence (fuzz-weekly.yml), not swift test.",
    ]

    func test_everyTestTargetIsGatedOrExplicitlyAllowlisted() throws {
        let repoRoot = try Self.locateRepoRoot()
        let packageManifest = try String(
            contentsOf: repoRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let scriptContent = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/test.sh"),
            encoding: .utf8
        )

        let violations = Self.ungatedTargets(
            packageManifest: packageManifest,
            scriptContent: scriptContent,
            allowlist: Self.knownUngatedTargets
        )

        if !violations.isEmpty {
            let formatted = violations.map { "  - \($0)" }.joined(separator: "\n")
            XCTFail("""
                The following `.testTarget`(s) in Package.swift never appear in
                scripts/test.sh's filter lists, so nothing ever runs them —
                they can rot silently forever (see ManifoldSnapshotTests /
                ManifoldTelemetryOTLPTests, which did exactly this for a month).

                \(formatted)

                Either add the target to scripts/test.sh's PROFILE_CI_XCTEST_FILTERS
                (or another filter list actually exercised by --profile local/ci),
                or add it to `knownUngatedTargets` in this test with a stated
                reason (e.g. requires live infrastructure, gated behind an env
                var, dev-only harness).
                """)
        }
    }

    // MARK: - Sabotage (exercises the same detection functions the audit runs)

    /// Plants a `.testTarget` in a fake manifest that is absent from a fake
    /// `scripts/test.sh` and asserts the REAL detection function flags it —
    /// then adds it to the script's array and asserts it's clean, and
    /// finally shows the allowlist path also clears the violation without
    /// touching the script.
    func test_sabotage_ungatedTargetsFlagsPlantedOrphanTarget() {
        let manifest = """
            .testTarget(
                name: "ManifoldPlantedOrphanTests",
                dependencies: ["ManifoldCore"]
            ),
            """

        let scriptWithoutEntry = """
            PROFILE_CI_XCTEST_FILTERS=(
                ManifoldCoreTests
                ManifoldRuntimeTests
            )
            """

        let violations = Self.ungatedTargets(
            packageManifest: manifest,
            scriptContent: scriptWithoutEntry,
            allowlist: [:]
        )
        XCTAssertTrue(
            violations.contains { $0.contains("ManifoldPlantedOrphanTests") },
            "The planted orphan test target must be flagged; got \(violations)"
        )

        let scriptWithEntry = """
            PROFILE_CI_XCTEST_FILTERS=(
                ManifoldCoreTests
                ManifoldRuntimeTests
                ManifoldPlantedOrphanTests
            )
            """
        let clean = Self.ungatedTargets(
            packageManifest: manifest,
            scriptContent: scriptWithEntry,
            allowlist: [:]
        )
        XCTAssertTrue(
            clean.isEmpty,
            "Adding the target to a filter array must clear the violation; got \(clean)"
        )

        let allowlisted = Self.ungatedTargets(
            packageManifest: manifest,
            scriptContent: scriptWithoutEntry,
            allowlist: ["ManifoldPlantedOrphanTests": "planted for sabotage test"]
        )
        XCTAssertTrue(
            allowlisted.isEmpty,
            "An allowlisted target must clear the violation without touching the script; got \(allowlisted)"
        )
    }

    /// Proves the array parser actually skips comment lines and
    /// `"${OTHER[@]}"` inheritance references rather than accidentally
    /// treating them as identifiers (which would either crash or silently
    /// mask real gaps behind a bogus entry).
    func test_sabotage_gatedTargetNamesIgnoresCommentsAndArrayExpansions() {
        let script = """
            PROFILE_CI_XCTEST_FILTERS=(
                ManifoldCoreTests
                # ManifoldNotActuallyThereTests -- this is prose, not an entry
                ManifoldRuntimeTests
            )
            PROFILE_LOCAL_XCTEST_FILTERS=(
                "${PROFILE_CI_XCTEST_FILTERS[@]}"
                ManifoldKitTests
            )
            """

        let names = Self.gatedTargetNames(scriptContent: script)
        XCTAssertTrue(names.contains("ManifoldCoreTests"))
        XCTAssertTrue(names.contains("ManifoldRuntimeTests"))
        XCTAssertTrue(names.contains("ManifoldKitTests"))
        XCTAssertFalse(
            names.contains("ManifoldNotActuallyThereTests"),
            "A commented-out identifier must not be treated as a gated entry"
        )
        XCTAssertFalse(
            names.contains { $0.contains("[@]") || $0.contains("$") },
            "An array-expansion reference must never be treated as a target name"
        )
    }

    // MARK: - Detection

    /// The full audit: every declared `.testTarget` name in `packageManifest`
    /// must be in `gatedTargetNames(scriptContent:)` or `allowlist`. Returns
    /// human-readable violation strings, empty when clean.
    static func ungatedTargets(
        packageManifest: String,
        scriptContent: String,
        allowlist: [String: String]
    ) -> [String] {
        let declaredTargets = Self.testTargetNames(packageManifest: packageManifest)
        let gatedNames = Self.gatedTargetNames(scriptContent: scriptContent)

        var violations: [String] = []
        for target in declaredTargets.sorted() {
            if gatedNames.contains(target) { continue }
            if allowlist[target] != nil { continue }
            violations.append("`\(target)` — not in any scripts/test.sh filter list and not in knownUngatedTargets")
        }
        return violations
    }

    /// Extracts every `.testTarget(name: "X", ...)` name declared in a
    /// Package.swift manifest. Whitespace/newlines between `.testTarget(` and
    /// `name:` are tolerated (this manifest always splits them across two
    /// lines, but the regex doesn't depend on that).
    static func testTargetNames(packageManifest: String) -> Set<String> {
        var found: Set<String> = []
        let pattern = #"\.testTarget\(\s*name:\s*"([A-Za-z_][A-Za-z0-9_]*)""#
        let ns = packageManifest as NSString
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        regex.enumerateMatches(in: packageManifest, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let m = match, m.numberOfRanges >= 2 else { return }
            found.insert(ns.substring(with: m.range(at: 1)))
        }
        return found
    }

    /// Parses `scriptContent` for every bare identifier that appears either
    /// (a) as a line inside a multi-line bash array literal
    /// (`VARNAME=(` ... a line that is exactly `)`), or (b) as the quoted
    /// value of a single-line scalar assignment (`VARNAME="Identifier"`).
    /// Comment lines (trimmed line starts with `#`) and array-expansion
    /// references (a line containing `[@]`) are skipped. Deliberately does
    /// NOT hardcode `PROFILE_CI_XCTEST_FILTERS` / `PROFILE_LOCAL_XCTEST_FILTERS`
    /// by name — any array or scalar assignment shaped this way is picked up,
    /// so adding a new filter-list variable (or reordering the existing
    /// ones) needs no update here.
    static func gatedTargetNames(scriptContent: String) -> Set<String> {
        var names: Set<String> = []
        var insideArrayLiteral = false

        let arrayOpenPattern = try? NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_]*=\($"#)
        let scalarPattern = try? NSRegularExpression(
            pattern: #"^[A-Za-z_][A-Za-z0-9_]*="([A-Za-z_][A-Za-z0-9_]*)"$"#
        )
        let identifierPattern = try? NSRegularExpression(pattern: #"^[A-Za-z_][A-Za-z0-9_]*$"#)

        for rawLine in scriptContent.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if insideArrayLiteral {
                if line == ")" {
                    insideArrayLiteral = false
                    continue
                }
                if line.hasPrefix("#") { continue }
                if line.contains("[@]") { continue }
                if Self.matches(identifierPattern, line) {
                    names.insert(line)
                }
                continue
            }

            if Self.matches(arrayOpenPattern, line) {
                insideArrayLiteral = true
                continue
            }

            if let scalarValue = Self.firstCaptureGroup(scalarPattern, line) {
                names.insert(scalarValue)
            }
        }

        return names
    }

    // MARK: - Regex helpers

    private static func matches(_ regex: NSRegularExpression?, _ line: String) -> Bool {
        guard let regex else { return false }
        let range = NSRange(location: 0, length: (line as NSString).length)
        return regex.firstMatch(in: line, range: range) != nil
    }

    private static func firstCaptureGroup(_ regex: NSRegularExpression?, _ line: String) -> String? {
        guard let regex else { return nil }
        let ns = line as NSString
        guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    // MARK: - Repo-root discovery

    /// Mirrors `DocSourcePathReferenceAuditTest.locateRepoRoot` /
    /// `PackageTraitGateAuditTest.locatePackageManifest`.
    private static func locateRepoRoot(filePath: StaticString = #filePath) throws -> URL {
        var dir = URL(fileURLWithPath: "\(filePath)").deletingLastPathComponent()
        while dir.path != "/" {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        throw NSError(domain: "TestTargetGateAuditTest", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Could not locate Package.swift from #filePath",
        ])
    }
}
