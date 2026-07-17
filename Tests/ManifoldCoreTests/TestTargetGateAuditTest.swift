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
/// ## The two-list trap (why checking scripts/test.sh alone is not enough)
///
/// `scripts/test.sh` is the LOCAL pre-push gate's source of truth
/// (`PROFILE_CI_XCTEST_FILTERS` / `PROFILE_LOCAL_XCTEST_FILTERS`). Per-PR CI
/// does **not** invoke `scripts/test.sh`'s profile machinery at all — the
/// real per-PR gate is a second, independently hand-maintained `--filter`
/// list embedded directly in `.github/workflows/ci.yml`'s `run:` steps (the
/// big XCTest batch, the `ManifoldBackendsTests` step, the Swift Testing
/// step, the `ManifoldServerTests` job, the `@ToolSchema` macro job). These
/// two lists are NOT generated from one another — a target can be added to
/// one and forgotten in the other. An earlier version of this audit checked
/// only `scripts/test.sh`, so it would have happily certified a target as
/// "gated" while CI never executed it — the *exact* failure mode this audit
/// exists to catch, just moved one layer up. The audit therefore checks BOTH
/// lists independently and reports which one a target is missing from.
///
/// ## What this test enforces
///
/// Every `.testTarget` declared in `Package.swift` must, unless listed in
/// `knownUngatedTargets` with a stated reason:
/// 1. Appear as a bare entry inside one of `scripts/test.sh`'s array-literal
///    filter lists or as a scalar filter assignment
///    (``gatedTargetNames(scriptContent:)``), AND
/// 2. Appear as a `--filter <Name>` argument somewhere in
///    `.github/workflows/ci.yml` (``ciFilterTargetNames(workflowContent:)``)
///    — i.e. some CI job actually executes it, not merely lists its name in
///    a script nothing invokes.
///
/// Both parsers are intentionally generic / text-based rather than tied to a
/// specific variable name or YAML structure:
/// - `gatedTargetNames` locates any `VARNAME=(` ... `)` block (bash array
///   literal, one bare identifier per line) or `VARNAME="Identifier"` scalar
///   assignment, skipping comment lines and array-expansion references
///   (`"${OTHER[@]}"`). It does not hardcode `PROFILE_CI_XCTEST_FILTERS` /
///   `PROFILE_LOCAL_XCTEST_FILTERS` by name, so a new filter-list variable
///   (or reordering the existing ones) is picked up automatically.
/// - `ciFilterTargetNames` scans the workflow file one LINE at a time
///   (never splitting a `run:` step across multiple lines the way a
///   YAML/step-oriented parser would) for `--filter <Identifier>` tokens,
///   skipping any line that is entirely a comment. `ci.yml`'s main XCTest
///   batch is one very long single-line `run:` command with ~19 `--filter`
///   flags on it, and its own line has no `#` prefix, so per-line scanning
///   still captures every flag on it in one pass — a step-oriented parser
///   that tried to model job/step boundaries would need constant updates as
///   steps are added/reordered, which per-line scanning avoids. The comment
///   skip exists because ci.yml carries prose like `# - Run \`swift test
///   --filter ManifoldE2ETests\` on physical hardware.` — without it, a
///   `--filter` token mentioned in a comment reads as CI-execution evidence
///   for a target CI never actually runs.
///
/// CI runners ship Bash 3.2; both parsers only read files as text (no
/// `bash`/`yq`/`jq` invoked), so toolchain availability is irrelevant.
///
/// Regex compilation failures in the detection functions are treated as
/// programmer error (`fatalError`), not silently swallowed into an empty
/// result — the whole point of this audit is that its own failure mode must
/// be loud, never a silent green pass. All patterns here are static literals
/// that always compile; `fatalError` only fires if one of them is edited into
/// something invalid, which should never survive review, let alone reach CI.
///
/// ``testTargetNames(packageManifest:)``, ``gatedTargetNames(scriptContent:)``,
/// and ``ciFilterTargetNames(workflowContent:)`` are pure `static func`s so
/// the in-file sabotage tests exercise the exact functions the audit runs.
final class TestTargetGateAuditTest: XCTestCase {

    /// Test targets that deliberately never execute in CI, each with a
    /// reason. Adding an entry here is a deliberate, reviewed decision — not
    /// a way to silence this audit.
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

    func test_everyTestTargetIsGatedInScriptAndExecutedByCI() throws {
        let repoRoot = try Self.locateRepoRoot()
        let packageManifest = try String(
            contentsOf: repoRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let scriptContent = try String(
            contentsOf: repoRoot.appendingPathComponent("scripts/test.sh"),
            encoding: .utf8
        )
        let workflowContent = try String(
            contentsOf: repoRoot.appendingPathComponent(".github/workflows/ci.yml"),
            encoding: .utf8
        )

        let violations = Self.ungatedOrCIInvisibleTargets(
            packageManifest: packageManifest,
            scriptContent: scriptContent,
            workflowContent: workflowContent,
            allowlist: Self.knownUngatedTargets
        )

        if !violations.isEmpty {
            let formatted = violations.map { "  - \($0)" }.joined(separator: "\n")
            XCTFail("""
                The following `.testTarget`(s) in Package.swift are not both
                (a) listed in scripts/test.sh's filter lists AND (b) actually
                executed by a `--filter` in .github/workflows/ci.yml. Either
                condition alone is not coverage — see
                ManifoldSnapshotTests/ManifoldTelemetryOTLPTests, which sat in
                neither list for a month while main stayed green.

                \(formatted)

                Fix by adding the target to BOTH scripts/test.sh's
                PROFILE_CI_XCTEST_FILTERS and a `--filter` in the appropriate
                ci.yml job, or add it to `knownUngatedTargets` in this test
                with a stated reason (e.g. requires live infrastructure,
                gated behind an env var, dev-only harness).
                """)
        }
    }

    // MARK: - Sabotage (exercises the same detection functions the audit runs)

    /// Plants a `.testTarget` absent from both a fake `scripts/test.sh` and a
    /// fake `ci.yml` and asserts the REAL detection function flags it as
    /// missing from both. Then adds it to each list independently and shows
    /// each fixes its half of the violation. Finally shows the allowlist
    /// path clears the violation without touching either file.
    func test_sabotage_ungatedOrCIInvisibleTargetsFlagsPlantedOrphanTarget() {
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
        let workflowWithoutEntry = """
            run: scripts/ci-test-with-watchdog.sh --filter ManifoldCoreTests --filter ManifoldRuntimeTests --skip-update --parallel
            """

        let violations = Self.ungatedOrCIInvisibleTargets(
            packageManifest: manifest,
            scriptContent: scriptWithoutEntry,
            workflowContent: workflowWithoutEntry,
            allowlist: [:]
        )
        XCTAssertTrue(
            violations.contains { $0.contains("ManifoldPlantedOrphanTests") },
            "The planted orphan test target must be flagged when absent from both files; got \(violations)"
        )

        let scriptWithEntry = """
            PROFILE_CI_XCTEST_FILTERS=(
                ManifoldCoreTests
                ManifoldRuntimeTests
                ManifoldPlantedOrphanTests
            )
            """
        let clean = Self.ungatedOrCIInvisibleTargets(
            packageManifest: manifest,
            scriptContent: scriptWithEntry,
            workflowContent: workflowWithoutEntry,
            allowlist: [:]
        )
        XCTAssertFalse(
            clean.isEmpty,
            "Adding the target to scripts/test.sh alone must NOT clear the violation — it still never executes in CI"
        )
        XCTAssertTrue(
            clean.contains { $0.contains("ManifoldPlantedOrphanTests") && $0.contains("CI") },
            "The remaining violation must call out that CI never executes it; got \(clean)"
        )

        let workflowWithEntry = """
            run: scripts/ci-test-with-watchdog.sh --filter ManifoldCoreTests --filter ManifoldRuntimeTests --filter ManifoldPlantedOrphanTests --skip-update --parallel
            """
        let fullyGated = Self.ungatedOrCIInvisibleTargets(
            packageManifest: manifest,
            scriptContent: scriptWithEntry,
            workflowContent: workflowWithEntry,
            allowlist: [:]
        )
        XCTAssertTrue(
            fullyGated.isEmpty,
            "Present in both scripts/test.sh and ci.yml must clear the violation entirely; got \(fullyGated)"
        )

        let allowlisted = Self.ungatedOrCIInvisibleTargets(
            packageManifest: manifest,
            scriptContent: scriptWithoutEntry,
            workflowContent: workflowWithoutEntry,
            allowlist: ["ManifoldPlantedOrphanTests": "planted for sabotage test"]
        )
        XCTAssertTrue(
            allowlisted.isEmpty,
            "An allowlisted target must clear the violation without touching either file; got \(allowlisted)"
        )
    }

    /// The case that matters most: a target listed in scripts/test.sh (so it
    /// LOOKS gated) but absent from every `--filter` in ci.yml, so nothing in
    /// CI ever actually runs it. This is precisely today's real-world bug
    /// shape — the earlier version of this audit, which checked only
    /// scripts/test.sh, would have certified this target as covered.
    func test_sabotage_targetInScriptButAbsentFromCIIsFlaggedAsCIInvisible() {
        let manifest = """
            .testTarget(
                name: "ManifoldRottingInCIOnlyTests",
                dependencies: ["ManifoldCore"]
            ),
            """
        let scriptWithEntry = """
            PROFILE_CI_XCTEST_FILTERS=(
                ManifoldCoreTests
                ManifoldRottingInCIOnlyTests
            )
            """
        // A realistic ci.yml shape: a long single-line watchdog `run:` command
        // that simply never grew a --filter for the new target.
        let workflowMissingEntry = """
            - name: Test — XCTest suites [full]
              run: scripts/ci-test-with-watchdog.sh --filter ManifoldCoreTests --filter ManifoldUITests --skip-update --parallel
            """

        let violations = Self.ungatedOrCIInvisibleTargets(
            packageManifest: manifest,
            scriptContent: scriptWithEntry,
            workflowContent: workflowMissingEntry,
            allowlist: [:]
        )
        XCTAssertTrue(
            violations.contains { $0.contains("ManifoldRottingInCIOnlyTests") },
            "A target present in scripts/test.sh but missing every ci.yml --filter must be flagged; got \(violations)"
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

    /// Proves `ciFilterTargetNames` correctly extracts every `--filter`
    /// argument out of a single very long one-line `run:` command (the real
    /// shape of ci.yml's main XCTest batch step) rather than requiring one
    /// flag per line.
    func test_sabotage_ciFilterTargetNamesParsesLongSingleLineRunCommand() {
        let workflow = """
              - name: Test — XCTest suites [full]
                run: scripts/ci-test-with-watchdog.sh --filter ManifoldCoreTests --filter ManifoldRuntimeTests --filter ManifoldUITests --skip-update --parallel
              - name: Test — Server suite
                run: scripts/test.sh --filter ManifoldServerTests --traits Server --skip-update
            """

        let names = Self.ciFilterTargetNames(workflowContent: workflow)
        XCTAssertEqual(
            names,
            ["ManifoldCoreTests", "ManifoldRuntimeTests", "ManifoldUITests", "ManifoldServerTests"],
            "Every --filter argument across both steps must be captured, including all flags on one long line"
        )
    }

    /// A `--filter` token embedded in a COMMENT line (prose like ci.yml's
    /// real `# - Run \`swift test --filter ManifoldE2ETests\` on physical
    /// hardware.`) must NOT be treated as CI-execution evidence, while a
    /// genuine `run:` step's `--filter` on another line must still be
    /// captured. Without the comment guard, the parser would certify a
    /// target as CI-executed purely because someone wrote its name in a
    /// comment or TODO — a false negative inside this false-negative
    /// detector.
    func test_sabotage_ciFilterTargetNamesIgnoresCommentLines() {
        let workflow = """
              # - Run `swift test --filter ManifoldGhostTests` on physical hardware.
              - name: Test — XCTest suites [full]
                run: scripts/ci-test-with-watchdog.sh --filter ManifoldCoreTests --skip-update --parallel
            """

        let names = Self.ciFilterTargetNames(workflowContent: workflow)
        XCTAssertFalse(
            names.contains("ManifoldGhostTests"),
            "A --filter token inside a comment line must never count as CI execution; got \(names)"
        )
        XCTAssertTrue(
            names.contains("ManifoldCoreTests"),
            "A genuine run: step's --filter must still be captured alongside the comment guard; got \(names)"
        )
    }

    // MARK: - Detection

    /// The full audit: every declared `.testTarget` name in `packageManifest`
    /// must be BOTH in `gatedTargetNames(scriptContent:)` AND in
    /// `ciFilterTargetNames(workflowContent:)`, unless allowlisted. Returns
    /// human-readable violation strings (empty when clean) that name which
    /// half of the check failed.
    static func ungatedOrCIInvisibleTargets(
        packageManifest: String,
        scriptContent: String,
        workflowContent: String,
        allowlist: [String: String]
    ) -> [String] {
        let declaredTargets = Self.testTargetNames(packageManifest: packageManifest)
        let scriptGated = Self.gatedTargetNames(scriptContent: scriptContent)
        let ciInvoked = Self.ciFilterTargetNames(workflowContent: workflowContent)

        var violations: [String] = []
        for target in declaredTargets.sorted() {
            if allowlist[target] != nil { continue }
            let inScript = scriptGated.contains(target)
            let inCI = ciInvoked.contains(target)
            switch (inScript, inCI) {
            case (true, true):
                continue
            case (true, false):
                violations.append(
                    "`\(target)` — listed in scripts/test.sh but NEVER executed by any --filter in " +
                    "ci.yml. CI-invisible: this is the ManifoldSnapshotTests/ManifoldTelemetryOTLPTests bug shape."
                )
            case (false, true):
                violations.append(
                    "`\(target)` — executed by a --filter in ci.yml but missing from scripts/test.sh, " +
                    "so the local pre-push gate never exercises it before push."
                )
            case (false, false):
                violations.append(
                    "`\(target)` — not in scripts/test.sh and not executed by any --filter in ci.yml."
                )
            }
        }
        return violations
    }

    /// Extracts every `.testTarget(name: "X", ...)` name declared in a
    /// Package.swift manifest. Whitespace/newlines between `.testTarget(` and
    /// `name:` are tolerated (this manifest always splits them across two
    /// lines, but the regex doesn't depend on that).
    static func testTargetNames(packageManifest: String) -> Set<String> {
        let regex = Self.requiredRegex(#"\.testTarget\(\s*name:\s*"([A-Za-z_][A-Za-z0-9_]*)""#)
        var found: Set<String> = []
        let ns = packageManifest as NSString
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

        let arrayOpenPattern = Self.requiredRegex(#"^[A-Za-z_][A-Za-z0-9_]*=\($"#)
        let scalarPattern = Self.requiredRegex(#"^[A-Za-z_][A-Za-z0-9_]*="([A-Za-z_][A-Za-z0-9_]*)"$"#)
        let identifierPattern = Self.requiredRegex(#"^[A-Za-z_][A-Za-z0-9_]*$"#)

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

    /// Extracts every `--filter <Identifier>` argument anywhere in a
    /// `.github/workflows/*.yml` file's raw text. A per-line regex scan
    /// (not a YAML/step-oriented parser): `ci.yml`'s main XCTest batch step
    /// is a single very long `run:` line carrying ~19 `--filter` flags, so
    /// anchoring per-YAML-node would miss most of them — but each line is
    /// still scanned on its own (not the whole file as one blob) so a
    /// comment line can be excluded before matching. A `--filter` flag
    /// always precedes its argument directly (`ci-test-with-watchdog.sh`/
    /// `scripts/test.sh` both use `--filter <value>`, never
    /// `--filter=<value>`, anywhere in this repo's workflows).
    ///
    /// Comment lines (trimmed line starts with `#`) are skipped, mirroring
    /// `gatedTargetNames`'s comment guard. Without this, prose like
    /// `# - Run \`swift test --filter ManifoldE2ETests\` on physical
    /// hardware.` (a real line in ci.yml) reads as a genuine CI-execution
    /// signal for a target CI never actually runs — the exact "listed but
    /// not executed" bug this audit exists to catch, reproduced one layer up
    /// inside the audit's own ci.yml parser. `#` can legitimately appear
    /// inside a `run:` shell command's arguments, so "trimmed line starts
    /// with #" (not "line contains #") is the conservative rule: it only
    /// excludes a line that is ENTIRELY a YAML/prose comment, never a
    /// `run:` step whose shell command happens to contain a `#` mid-line.
    static func ciFilterTargetNames(workflowContent: String) -> Set<String> {
        let regex = Self.requiredRegex(#"--filter\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        var found: Set<String> = []
        for rawLine in workflowContent.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            let ns = line as NSString
            regex.enumerateMatches(in: line, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let m = match, m.numberOfRanges >= 2 else { return }
                found.insert(ns.substring(with: m.range(at: 1)))
            }
        }
        return found
    }

    // MARK: - Regex helpers

    /// Compiles a static regex pattern, crashing loudly on failure rather
    /// than degrading to an empty match set. Every pattern passed here is a
    /// hardcoded literal that always compiles; a failure here means one was
    /// edited into something invalid — a programmer error with no sane
    /// recovery, not a data problem the audit should silently paper over by
    /// reporting zero violations.
    private static func requiredRegex(_ pattern: String) -> NSRegularExpression {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            fatalError("TestTargetGateAuditTest: static regex pattern failed to compile: \(pattern)")
        }
        return regex
    }

    private static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        let range = NSRange(location: 0, length: (line as NSString).length)
        return regex.firstMatch(in: line, range: range) != nil
    }

    private static func firstCaptureGroup(_ regex: NSRegularExpression, _ line: String) -> String? {
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
