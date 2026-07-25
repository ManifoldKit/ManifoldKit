import XCTest

/// Integration test for `scripts/changelog-parser-check.sh` /
/// `scripts/changelog-parser-check/check.mjs` (#2380). Spawns the real
/// script (Node + a real `npm ci` against the pinned `release-please`
/// dependency) over real commit ranges from this repo's own git history —
/// no synthetic fixture, since the script has no seam for pointing it at
/// an arbitrary repo (`REPO_ROOT` is always derived from the script's own
/// location). Network access is required (npm registry); skips rather than
/// fails when the tooling isn't present, matching
/// `FuzzCIGateScriptTests`'s convention for environment-dependent script
/// tests.
///
/// Covers the review finding this exists to guard: `checked === 0` must be
/// a hard failure in whole-range mode (a real release always ships at
/// least one releasable commit) but an expected, visible pass in `--per-pr`
/// mode (a release-please PR is exactly one hidden `chore(main): release`
/// commit; a Dependabot PR is `chore(deps): bump …`, also hidden). Getting
/// this backwards would make the per-PR check red every release PR and
/// every Dependabot PR outright.
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
        for tool in ["node", "npm"] {
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

    // scripts/changelog-parser-check.sh always re-runs `npm ci` against the
    // one shared scripts/changelog-parser-check/ directory on every
    // invocation (by design — see that script's header). Under
    // `swift test --parallel`, XCTest can run this file's methods
    // concurrently, and two `npm ci` processes writing node_modules/ in the
    // same directory at once corrupt each other's install — this is exactly
    // the shape of "local gate skips --parallel; CI runs it and reds on a
    // race the local run never sees" (reproduced live once: all three tests
    // failed together on the first real CI run of this file, each getting a
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
        // suite, not just this file's own three methods) it reproducibly
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

    /// `v0.74.0` (`chore(main): release 0.74.0`) is the release-please
    /// commit itself -- `chore` is a hidden changelog-sections type, so its
    /// own one-commit range against its own parent matches zero releasable
    /// commits. This is the exact shape of PR #2352, the release PR this
    /// gate must never red.
    func test_perPR_choreOnlyRange_exitsZero() throws {
        guard let root = repoRoot() else { throw XCTSkip("changelog-parser-check.sh not found from test bundle location") }
        guard toolingAvailable() else { throw XCTSkip("node/npm not on PATH") }

        let (status, output) = try run(root: root, args: ["--per-pr", "v0.74.0^", "v0.74.0"])

        XCTAssertEqual(status, 0, "a chore-only per-PR range must pass, not red the release PR it belongs to: \(output)")
        XCTAssertTrue(
            output.contains("no releasable commits") || output.contains("nothing to parse"),
            "expected the explicit 'nothing to parse' message, got: \(output)"
        )
    }

    /// The identical range WITHOUT --per-pr must still fail closed --
    /// zero releasable commits in a whole-range (release-branch) sweep
    /// means the header regex or visible-types list broke, not that
    /// nothing shipped. This is the guard the fix must not weaken.
    func test_wholeRange_zeroReleasableCommits_stillFailsClosed() throws {
        guard let root = repoRoot() else { throw XCTSkip("changelog-parser-check.sh not found from test bundle location") }
        guard toolingAvailable() else { throw XCTSkip("node/npm not on PATH") }

        let (status, output) = try run(root: root, args: ["v0.74.0^", "v0.74.0"])

        XCTAssertEqual(status, 1, "whole-range mode must still fail closed on zero matched commits: \(output)")
        XCTAssertTrue(
            output.contains("header regex or visible-types list is likely broken"),
            "expected the fail-closed diagnostic, got: \(output)"
        )
    }

    // MARK: - Sabotage

    /// Plants the exact regression this test suite exists to catch: if
    /// `--per-pr` mode's zero-match guard were wrongly wired to ALSO fail
    /// closed (i.e. the fix reverted), `test_perPR_choreOnlyRange_exitsZero`
    /// above would fail with status 1 instead of 0. Asserting that
    /// directly here, rather than only trusting the positive test, follows
    /// this repo's in-file sabotage convention (Principle 4): a positive
    /// assertion alone can be satisfied by code that never runs the
    /// checked path at all.
    func test_sabotage_perPRZeroMatch_wouldFailIfGuardStillHardFails() throws {
        guard let root = repoRoot() else { throw XCTSkip("changelog-parser-check.sh not found from test bundle location") }
        guard toolingAvailable() else { throw XCTSkip("node/npm not on PATH") }

        let (perPRStatus, _) = try run(root: root, args: ["--per-pr", "v0.74.0^", "v0.74.0"])
        let (wholeRangeStatus, _) = try run(root: root, args: ["v0.74.0^", "v0.74.0"])

        XCTAssertNotEqual(
            perPRStatus, wholeRangeStatus,
            "the whole point of --per-pr is that it disagrees with whole-range mode on an identical zero-match range -- if these ever converge, the mode flag stopped doing anything"
        )
    }
}
