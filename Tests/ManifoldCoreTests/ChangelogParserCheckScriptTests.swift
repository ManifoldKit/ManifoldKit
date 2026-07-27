import XCTest

/// Integration test for `scripts/changelog-parser-check.sh` /
/// `scripts/changelog-parser-check/check.mjs` (#2380). Spawns the real
/// script (Node + a real `npm ci` against the pinned `release-please`
/// dependency) against a **synthetic fixture repository** built per test
/// with known commits, via the script's `--repo` seam.
///
/// The fixture is not a stylistic preference — it is the only shape that
/// runs in CI. An earlier version of this file anchored its ranges on this
/// repo's real tags (`v0.74.0^..v0.74.0`), and every test in it red-ed on
/// its first real CI run with `BASE_TAG 'v0.74.0^' does not resolve to a
/// commit`: ci.yml's `test` job checks out with `fetch-depth: 2` and no
/// tags, so no tag-anchored range resolves there at all. Skipping when the
/// tag is missing would have made the file inert in exactly the environment
/// that matters (and is banned outright — `TestSuiteSilentSkipAuditTest`),
/// so the script gained the seam instead.
///
/// The fixture copies this repo's **real** `release-please-config.json`, so
/// the visible-vs-hidden changelog-sections types under test are the ones
/// that actually ship — only the commit history is synthetic.
///
/// Coverage:
/// * the #2380 defect itself — a `fix:` commit whose body contains the
///   parser-hostile nested-parenthesis construct must be REJECTED (this is
///   the gate's whole reason to exist, and nothing exercised it before);
/// * a clean releasable commit must PASS (so the red above isn't vacuous);
/// * `checked === 0` must be a hard failure in whole-range mode but an
///   expected, visible pass in `--per-pr` mode. Getting that backwards
///   would red every release PR and every Dependabot PR outright.
final class ChangelogParserCheckScriptTests: XCTestCase {

    private func repoRoot() -> URL? {
        // #filePath is .../Tests/ManifoldCoreTests/ChangelogParserCheckScriptTests.swift
        // repo root is two levels above Tests/.
        let thisFile = URL(fileURLWithPath: #filePath)
        let candidate = thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = candidate.appendingPathComponent("scripts/changelog-parser-check.sh")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        return candidate
    }

    private func toolingAvailable() -> Bool {
        for tool in ["node", "npm", "git"] {
            let which = Process()
            which.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            which.arguments = ["which", tool]
            which.standardOutput = Pipe()
            which.standardError = Pipe()
            guard (try? which.run()) != nil else { return false }
            which.waitUntilExit()
            if which.terminationStatus != 0 { return false }
        }
        return true
    }

    /// Skipping on absent tooling is a developer-machine convenience only. On
    /// CI it must be a hard failure: the runner image is *supposed* to have
    /// node/npm (lint.yml installs Node 24), so their absence means the gate
    /// is not being exercised — and because the parallel runner folds XCTSkip
    /// into the passed count, a skip there is indistinguishable from a pass.
    /// That is precisely the inert-but-green shape this file's header objects
    /// to, and it would have applied to the file's own precondition.
    private func requireTooling() throws {
        guard !toolingAvailable() else { return }
        if ProcessInfo.processInfo.environment["CI"] != nil {
            XCTFail("node/npm/git must be present on CI — a skip here would silently stop exercising the changelog parser gate")
            throw XCTSkip("tooling missing on CI (already failed above)")
        }
        throw XCTSkip("node/npm/git not on PATH (local run)")
    }

    // MARK: - Fixture repository

    /// The parser-hostile construct from #2380's confirmed root cause: an
    /// identifier immediately followed by NESTED parentheses. This is the
    /// verbatim guilty line from PR #2375's squashed body (line 124), which
    /// release-please silently dropped from the 0.74.0 changelog.
    ///
    /// The construct is position-sensitive, which is why this fixture uses
    /// the line verbatim rather than a paraphrase: `rawParser` throws only
    /// when such a line STARTS a body line. Indenting it, bulleting it, or
    /// putting any words in front all parse fine — an earlier draft of this
    /// fixture indented the line for readability and the "hostile" case
    /// passed, making the test assert nothing. Verified against
    /// `@conventional-commits/parser` as pinned.
    private static let parserHostileBody = """
    The fuzz CI gate previously ignored its own findings. It now calls
    exit(FuzzReport.exitCode(for: report)).
    """

    private struct Fixture {
        let root: URL
        /// Non-conventional initial commit — the base of every range below.
        let base: String
        /// A commit of the config's hidden type, non-breaking, so a range
        /// ending here matches zero releasable commits.
        let hiddenOnly: String
        /// A `fix:` commit whose body breaks release-please's parser.
        let hostile: String
        /// A `fix:` commit that parses cleanly.
        let clean: String
        /// A BREAKING commit of the *hidden* type whose body breaks the
        /// parser. release-please publishes breaking hidden-type commits
        /// (⚠ BREAKING CHANGES + the version bump), so dropping one is the
        /// worst variant of #2380 — the gate must not filter it out by type.
        let breakingHiddenHostile: String
        /// The hidden type actually read from the copied config, so a config
        /// edit that un-hides it changes the fixture instead of breaking the
        /// tests with a diagnostic that points at the wrong file.
        let hiddenType: String
    }

    /// Reads the first hidden `changelog-sections` type out of the real
    /// config. Fails loudly rather than defaulting: if nothing is hidden, the
    /// zero-releasable-commits scenarios below cannot be constructed at all,
    /// and silently substituting a guess would make them assert something
    /// other than what they claim.
    private func hiddenType(in configURL: URL) throws -> String {
        let data = try Data(contentsOf: configURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let packages = json?["packages"] as? [String: Any]
        let root = packages?["."] as? [String: Any]
        let sections = root?["changelog-sections"] as? [[String: Any]]
        let hidden = sections?.first { ($0["hidden"] as? Bool) == true }
        guard let type = hidden?["type"] as? String else {
            throw NSError(domain: "fixture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "release-please-config.json has no hidden changelog-sections type; the zero-releasable-commit scenarios in this file cannot be built without one"
            ])
        }
        return type
    }

    /// Builds a throwaway git repository. Caller owns cleanup.
    private func makeFixture(realRepoRoot: URL) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("changelog-parser-check-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // The real config, not a stub: the visible/hidden type split this
        // gate scopes itself by must be the one that actually ships.
        try FileManager.default.copyItem(
            at: realRepoRoot.appendingPathComponent("release-please-config.json"),
            to: root.appendingPathComponent("release-please-config.json")
        )

        func run(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            // Identity and signing are set per-invocation: the ambient git
            // config (or a 1Password-backed signing key) must not decide
            // whether this fixture can be built.
            process.arguments = ["git", "-C", root.path,
                                 "-c", "user.name=ManifoldKit Test",
                                 "-c", "user.email=test@example.invalid",
                                 "-c", "commit.gpgsign=false"] + args
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "fixture", code: Int(process.terminationStatus), userInfo: [
                    NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed in fixture"
                ])
            }
        }

        func head() throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "-C", root.path, "rev-parse", "HEAD"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func commit(_ message: String, marker: String) throws -> String {
            try marker.write(
                to: root.appendingPathComponent("file.txt"),
                atomically: true,
                encoding: .utf8
            )
            try run(["add", "."])
            try run(["commit", "--no-gpg-sign", "-m", message])
            return try head()
        }

        let hidden = try hiddenType(in: root.appendingPathComponent("release-please-config.json"))

        try run(["init", "-b", "main"])
        let base = try commit("initial fixture commit (deliberately non-conventional)", marker: "0")
        let hiddenOnly = try commit("\(hidden)(main): release 0.0.1", marker: "1")
        let hostile = try commit(
            "fix(fuzz): gate the CI fuzz job on its own findings\n\n\(Self.parserHostileBody)",
            marker: "2"
        )
        let clean = try commit(
            "fix(runtime): bound tool-continuation stalls with a stream idle timeout\n\nA stalled continuation now surfaces as a timeout error instead of hanging.",
            marker: "3"
        )
        let breakingHiddenHostile = try commit(
            "\(hidden)(deps)!: drop the legacy shim\n\n\(Self.parserHostileBody)",
            marker: "4"
        )

        return Fixture(
            root: root,
            base: base,
            hiddenOnly: hiddenOnly,
            hostile: hostile,
            clean: clean,
            breakingHiddenHostile: breakingHiddenHostile,
            hiddenType: hidden
        )
    }

    // scripts/changelog-parser-check.sh always re-runs `npm ci` against the
    // one shared scripts/changelog-parser-check/ directory on every
    // invocation (by design — see that script's header). Under
    // `swift test --parallel`, XCTest can run this file's methods
    // concurrently, and two `npm ci` processes writing node_modules/ in the
    // same directory at once corrupt each other's install — this is exactly
    // the shape of "local gate skips --parallel; CI runs it and reds on a
    // race the local run never sees" (reproduced live once: all of this
    // file's tests failed together on the first real CI run, each getting a
    // truncated/interleaved npm-warning-only output instead of the script's
    // real stdout). A process-wide lock serializes this file's script
    // invocations regardless of how the runner schedules the test methods.
    private static let scriptInvocationLock = NSLock()

    private func run(root: URL, args: [String]) throws -> (status: Int32, output: String) {
        Self.scriptInvocationLock.lock()
        defer { Self.scriptInvocationLock.unlock() }

        // Output goes to a temp FILE, not a Pipe. A Pipe read via
        // `readDataToEndOfFile()` before `waitUntilExit()` is fine in
        // isolation, but under the real CI run (hundreds of other Process
        // instances spawned concurrently across the full parallel test
        // suite, not just this file's own methods) it reproducibly
        // truncated output at the same point every time -- captured output
        // ending mid-way through npm's own startup warnings, before either
        // npm or node had written anything else. A temp file has no pipe
        // buffer to race against; reading it after `waitUntilExit()`
        // returns is unconditionally safe.
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("changelog-parser-check-test-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outURL) }
        let outHandle = try FileHandle(forWritingTo: outURL)
        defer { try? outHandle.close() }

        let script = root.appendingPathComponent("scripts/changelog-parser-check.sh")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + args
        process.currentDirectoryURL = root
        process.standardOutput = outHandle
        process.standardError = outHandle
        try process.run()
        process.waitUntilExit()

        let data = (try? Data(contentsOf: outURL)) ?? Data()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    /// Boilerplate every test shares: locate the repo, confirm the tooling,
    /// build the fixture, and tear it down afterwards.
    private func withFixture(_ body: (URL, Fixture) throws -> Void) throws {
        guard let root = repoRoot() else {
            throw XCTSkip("changelog-parser-check.sh not found from test bundle location")
        }
        try requireTooling()
        let fixture = try makeFixture(realRepoRoot: root)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try body(root, fixture)
    }

    // MARK: - The #2380 defect itself

    /// The gate's reason to exist: a releasable commit whose body contains
    /// the nested-parenthesis construct must be REJECTED, because
    /// release-please would silently drop it from the changelog.
    func test_parserHostileReleasableCommit_isRejected() throws {
        try withFixture { root, fixture in
            let (status, output) = try run(root: root, args: [
                "--repo", fixture.root.path, fixture.hiddenOnly, fixture.hostile,
            ])

            XCTAssertEqual(status, 1, "a commit release-please cannot parse must red the gate: \(output)")
            XCTAssertTrue(
                output.contains("would silently DROP"),
                "expected the #2380 diagnostic naming the dropped commit, got: \(output)"
            )
            XCTAssertTrue(
                output.contains("gate the CI fuzz job on its own findings"),
                "the diagnostic must name the offending commit's subject so it can be reworded, got: \(output)"
            )
        }
    }

    /// The counterweight to the test above: an ordinary `fix:` commit must
    /// pass. Without this, the rejection could come from the gate reddening
    /// on everything rather than on the defect.
    func test_cleanReleasableCommit_passes() throws {
        try withFixture { root, fixture in
            let (status, output) = try run(root: root, args: [
                "--repo", fixture.root.path, fixture.hostile, fixture.clean,
            ])

            XCTAssertEqual(status, 0, "a cleanly-parsing releasable commit must pass: \(output)")
            XCTAssertTrue(
                output.contains("parse cleanly"),
                "expected the success line naming the checked count, got: \(output)"
            )
        }
    }

    // MARK: - Zero-match handling, per mode

    /// A range containing only a non-breaking commit of the config's hidden
    /// type (`chore(main): release 0.0.1` as the config stands), so zero
    /// releasable commits match. This is the exact shape of a release-please
    /// PR (#2352 motivated the flag), which this gate must never red.
    func test_perPR_hiddenTypeOnlyRange_exitsZero() throws {
        try withFixture { root, fixture in
            let (status, output) = try run(root: root, args: [
                "--per-pr", "--repo", fixture.root.path, fixture.base, fixture.hiddenOnly,
            ])

            XCTAssertEqual(status, 0, "a hidden-type-only per-PR range must pass, not red the release PR it belongs to: \(output)")
            XCTAssertTrue(
                output.contains("no releasable commits") || output.contains("nothing to parse"),
                "expected the explicit 'nothing to parse' message, got: \(output)"
            )
        }
    }

    /// The identical range WITHOUT --per-pr must still fail closed --
    /// zero releasable commits in a whole-range (release-branch) sweep
    /// means the header regex or visible-types list broke, not that
    /// nothing shipped. This is the guard the fix must not weaken.
    func test_wholeRange_zeroReleasableCommits_stillFailsClosed() throws {
        try withFixture { root, fixture in
            let (status, output) = try run(root: root, args: [
                "--repo", fixture.root.path, fixture.base, fixture.hiddenOnly,
            ])

            XCTAssertEqual(status, 1, "whole-range mode must still fail closed on zero matched commits: \(output)")
            XCTAssertTrue(
                output.contains("header regex or visible-types list is likely broken"),
                "expected the fail-closed diagnostic, got: \(output)"
            )
        }
    }

    // MARK: - Seam integrity

    /// A `--repo` that isn't a git repository must fail loudly. A gate
    /// pointed at the wrong tree would otherwise report a confusing
    /// "no commits found in range" — or, worse, quietly check nothing.
    func test_repoSeam_rejectsNonRepositoryPath() throws {
        guard let root = repoRoot() else {
            throw XCTSkip("changelog-parser-check.sh not found from test bundle location")
        }
        try requireTooling()

        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("changelog-parser-check-not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let (status, output) = try run(root: root, args: ["--repo", empty.path, "HEAD~1", "HEAD"])

        XCTAssertEqual(status, 1, "a non-repository --repo must fail, not check nothing: \(output)")
        XCTAssertTrue(
            output.contains("is not a git repository"),
            "expected the explicit non-repository diagnostic, got: \(output)"
        )
    }

    // MARK: - Breaking hidden-type commits are in scope

    /// The worst variant of #2380, and the one the type filter used to hide.
    /// A BREAKING commit of a hidden type (`chore(deps)!:`) IS published by
    /// release-please — verified against the pinned version, it renders a
    /// `### ⚠ BREAKING CHANGES` entry plus a `### Chores` bullet, and it
    /// drives the version bump. So when its body defeats the parser, the
    /// release loses the breaking notice AND the bump. Scoping the gate to
    /// visible types only would report that as clean.
    func test_breakingHiddenTypeCommit_isInScopeAndRejected() throws {
        try withFixture { root, fixture in
            let (status, output) = try run(root: root, args: [
                "--repo", fixture.root.path, fixture.clean, fixture.breakingHiddenHostile,
            ])

            XCTAssertEqual(
                status, 1,
                "a breaking \(fixture.hiddenType)!: commit whose body defeats the parser must red the gate — it is published AND drives the bump: \(output)"
            )
            XCTAssertTrue(
                output.contains("would silently DROP"),
                "expected the #2380 diagnostic for the breaking hidden-type commit, got: \(output)"
            )
            XCTAssertTrue(
                output.contains("drop the legacy shim"),
                "the diagnostic must name the breaking commit's subject, got: \(output)"
            )
        }
    }

    /// Same commit, per-PR mode: the `--per-pr` relaxation applies ONLY to
    /// the zero-match case, never to a commit that genuinely fails to parse.
    func test_perPR_stillRedsOnHostileCommit() throws {
        try withFixture { root, fixture in
            let (status, output) = try run(root: root, args: [
                "--per-pr", "--repo", fixture.root.path, fixture.hiddenOnly, fixture.hostile,
            ])

            XCTAssertEqual(
                status, 1,
                "--per-pr must not soften a real parse failure — it only relaxes the zero-match case: \(output)"
            )
            XCTAssertTrue(
                output.contains("would silently DROP"),
                "expected the #2380 diagnostic in per-PR mode too, got: \(output)"
            )
        }
    }

    // MARK: - Sabotage

    /// In-file sabotage per Principle 4, replacing an earlier version that
    /// asserted `perPRStatus != wholeRangeStatus` on the zero-match range —
    /// which the two positive tests above already strictly imply, so it could
    /// not catch a regression they wouldn't. This plants the real hazard
    /// instead: the `--per-pr` relaxation escaping its intended scope.
    ///
    /// Both invocations use the SAME hostile range and must BOTH red. If a
    /// future edit widens the zero-match relaxation into a general
    /// "per-PR mode is lenient", this fails while every other test still
    /// passes — that combination is the regression, and nothing else here
    /// detects it.
    func test_sabotage_perPRLeniency_mustNotExtendBeyondZeroMatch() throws {
        try withFixture { root, fixture in
            let (perPRStatus, perPROutput) = try run(root: root, args: [
                "--per-pr", "--repo", fixture.root.path, fixture.hiddenOnly, fixture.hostile,
            ])
            let (wholeRangeStatus, _) = try run(root: root, args: [
                "--repo", fixture.root.path, fixture.hiddenOnly, fixture.hostile,
            ])

            XCTAssertEqual(
                perPRStatus, wholeRangeStatus,
                "on a range containing a genuinely unparseable commit the two modes must AGREE (both red); a divergence here means --per-pr started swallowing real defects: \(perPROutput)"
            )
            XCTAssertEqual(perPRStatus, 1, "and the agreed verdict must be red, not a shared pass: \(perPROutput)")
        }
    }
}
