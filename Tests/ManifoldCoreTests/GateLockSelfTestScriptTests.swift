import XCTest
import os
import Darwin

/// Integration test for the machine-wide gate-lock serialization in
/// `scripts/test.sh` (2026-08-09 incident: six concurrent worker gates
/// wedged an xcodebuild for 2h via SwiftPM cache-lock contention).
///
/// `scripts/test.sh` has no unit-testable internals of its own — it is a
/// single bash file — so, following this repo's established pattern for
/// asserting shell-script *behavior* (`FuzzCIGateScriptTests`,
/// `ChangelogParserCheckScriptTests`, `SnippetSkipRatchetScriptTests`), this
/// test shells out to the script's hidden `--lock-selftest` verb and asserts
/// on its real exit code and output. `--lock-selftest` runs entirely against
/// an isolated temp lock file (never the production `/tmp/manifoldkit-gate.lock`)
/// and never invokes `swift test`, so this stays fast and cannot collide with
/// a real concurrent gate run — including the one this very `swift test`
/// invocation may itself be inside of.
///
/// `--lock-selftest` demonstrates, against the REAL `acquire_gate_lock` /
/// `release_gate_lock` functions (not a reimplementation):
///   (a) a second acquirer blocks on a live holder and reports
///       "waiting for gate lock held by PID <holder>", then acquires once
///       the holder releases;
///   (b) a lock file whose recorded holder PID is confirmed dead is
///       reclaimed loudly ("STALE LOCK RECLAIMED: holder PID <p> ..."),
///       never silently;
///   (c) a process that inherits `MANIFOLD_GATE_LOCK_OWNER_PID` from a
///       widowed ancestor (holder PID dead, or the lock no longer held by
///       it) does NOT trust the sentinel and skip acquisition — it
///       acquires the lock for real, under its own PID, logging that the
///       inherited sentinel was stale. This is the fix for the sentinel
///       over-inheritance hazard: without it, ANY descendant of a gate run
///       (an interactive shell, an agent session spawned underneath one)
///       that outlives the ancestor's gate would silently run every future
///       `scripts/test.sh` invocation completely unlocked;
///   (d) N concurrent waiters against a single dead-holder lock serialize
///       cleanly — no two of them ever hold the lock at once, and none of
///       them crash. This is the regression test for a real, independently
///       reviewed defect, and the one that took three attempts to actually
///       close: a bare `rm -rf` reclaim let every waiter that read the same
///       dead holder race the delete/recreate directly; a "capture, verify
///       content, restore if mismatched" reclaim closed that but opened a
///       *different* window — capturing anything, even briefly, lets a
///       third process win the now-vacant path before the capture can be
///       restored, silently orphaning a live holder's claim. The fix that
///       actually held under measurement serializes the whole "diagnose
///       dead, then delete" decision behind its own exclusive `mkdir`
///       mutex, so at most one process can ever be mid-reclaim for a given
///       generation of the lock. Verified with a ground-truth, real-time
///       concurrent-holder marker (not timestamp comparison, which has only
///       1s resolution on macOS and produced false positives under load) —
///       30/30 clean across three rounds of 10-way-parallel self-test runs,
///       16/16 clean at 16-way-parallel, vs. 7/10 real 2-3-way concurrent
///       holders with the mutex removed under the same load. The number of
///       rounds per self-test invocation is `MANIFOLD_GATE_SELFTEST_D_ROUNDS`
///       (default 1, matching what this suite actually runs in CI — see the
///       CI-cost note below); a human investigating reclaim contention can
///       opt into repeated rounds (a fresh mechanism review measured 1/6
///       reclaim rounds showing overlap under 6-way concurrency but 0/4
///       sequentially, so more rounds buys marginal sequential-detection
///       odds, never a guarantee) without this suite paying for it on every
///       CI run;
///   (e) the lock is actually WIRED into the real `--profile local`
///       three-invocation orchestration's PRE-RE-EXEC call site, not just a
///       correct-but-unused primitive. Scenarios (a)-(d) all exercise
///       `acquire_gate_lock`/`release_gate_lock` directly — deleting the
///       parent's acquire before the three-invocation re-exec, while
///       leaving the function itself untouched, left every one of them
///       green, because none of them ever reach that code path. This
///       scenario runs the real `--profile local` shape (re-exec,
///       exit-code propagation, the works) against a temp copy of the
///       script with a stub `swift` on PATH, and asserts the top-level
///       parent's PID is what the lock file shows throughout, exactly
///       three invocations ran, the lock was released exactly once, and
///       the lock file is gone at the end — that last assertion is also
///       what catches `release_gate_lock`'s `rm -f` being neutered, which
///       scenarios (a)-(d) cannot see either (the stale-reclaim path
///       silently covers for a lock that's never released);
///   (f) the lock is also wired into the OTHER `acquire_gate_lock` call
///       site — the fallthrough acquire reached by a bare invocation,
///       `--profile spike`, or a narrow `--filter` override, none of which
///       go through scenario (e)'s pre-re-exec path. A fresh mechanism
///       review found this gap directly: deleting only this call site
///       (leaving the `--profile local`/`ci` site from (e) untouched) left
///       scenarios (a)-(e) all green, because every child scenario (e)
///       spawns skips acquisition via the inherited sentinel and never
///       reaches this code path either. Runs a bare invocation (no
///       `--profile`, no `--filter`) of a temp copy of the script against
///       the same stub `swift`, and asserts a lock file appears carrying
///       that process's own PID and is gone once it exits.
///       `--profile spike` converges on this exact same call site (there
///       is only one fallthrough `acquire_gate_lock` in the whole script),
///       so this scenario structurally covers it too — relevant because
///       this same PR's AGENTS.md change widens when `--profile spike` is
///       permissible, sending more traffic through this path, not less.
///       Both (e) and (f) additionally prove the stub `swift` they depend
///       on is genuinely what `PATH` resolves to *before* launching a
///       nested run, and fail loudly if not — a silently-ineffective stub
///       would drive the REAL toolchain from inside a running `swift test`,
///       which is precisely the fail-open shape this whole PR exists to
///       remove;
///   (g) the self-test leaves the ENCLOSING run's `MANIFOLD_TEST_OUTPUT_FILE`
///       alone. Scenarios (e)/(f) are the only ones that reach
///       `scripts/test.sh`'s main path and therefore its
///       `swift test … | tee "$OUTPUT_FILE"`, and that variable is inherited
///       by default — so without a per-invocation override each of them
///       truncates whatever log the outer run is writing to. In CI that log
///       is the watchdog's liveness signal, and truncating it is what killed
///       this PR's two CI runs (see the incident note on
///       `test_lockSelfTest_allScenariosPass`). Asserts the log neither
///       shrank, lost progress lines, nor gained NUL bytes — and synthesises
///       a seeded stand-in when the variable is not inherited, so the check
///       is armed for a developer running `--lock-selftest` by hand and not
///       only inside CI.
///
/// Every `--lock-selftest-hold` subprocess this self-test spawns runs under
/// a short `MANIFOLD_GATE_LOCK_CEILING_SECS` override (20s, not the
/// production 3h default) — a self-test whose own sabotage-target code is
/// broken must fail fast and loud, not hang the whole gate for three hours.
/// `run(script:args:timeout:)` below adds a second, independent backstop on
/// the Swift side: if a subprocess still doesn't finish, it is killed and
/// the test fails explicitly rather than blocking `waitUntilExit()` forever.
final class GateLockSelfTestScriptTests: XCTestCase {

    private struct SubprocessTimeoutError: Error, CustomStringConvertible {
        let description: String
    }

    /// `scripts/test.sh` is unconditionally present in this repo — a
    /// missing script here means the test bundle's path derivation is
    /// broken, not that there's legitimately nothing to test. `XCTFail`
    /// (not `XCTSkip`) is the honest response: a skip here would silently
    /// zero out this suite's entire gate-lock coverage without anyone
    /// noticing, exactly the "test that can disappear" hazard this repo's
    /// conventions warn against.
    private func repoRoot() -> URL? {
        // #filePath is .../Tests/ManifoldCoreTests/GateLockSelfTestScriptTests.swift
        // repo root is two levels above Tests/.
        let thisFile = URL(fileURLWithPath: #filePath)
        let candidate = thisFile.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = candidate.appendingPathComponent("scripts/test.sh")
        guard FileManager.default.fileExists(atPath: script.path) else { return nil }
        return candidate
    }

    /// Runs `script` with `args`, bounded by `timeout` (default 60s — the
    /// shell side's own 20s self-test ceiling plus headroom for process
    /// spawn/scheduling overhead on a loaded machine). Reading the pipe on
    /// a background queue and racing it against a `DispatchSemaphore`
    /// timeout means a wedged subprocess (e.g. the shell-side ceiling
    /// itself failing to fire) cannot block this test indefinitely — it
    /// gets killed and the test fails with an explicit reason instead of
    /// hanging `waitUntilExit()` forever.
    private func run(
        script: URL,
        args: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval = 60
    ) throws -> (status: Int32, output: String, childOutputFile: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + args
        // XCTest itself may be running inside scripts/test.sh --profile local,
        // where this inherited path is CI's live watchdog log. Every nested
        // script invocation must get a unique private log, including the
        // normal, sabotage, timeout, mismatch, and stuck-child paths below.
        let childOutputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifoldkit-gate-lock-child-output-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: childOutputFile) }
        var childEnvironment = ProcessInfo.processInfo.environment.merging(
            environment, uniquingKeysWith: { _, new in new }
        )
        childEnvironment["MANIFOLD_TEST_OUTPUT_FILE"] = childOutputFile.path
        process.environment = childEnvironment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        let readSemaphore = DispatchSemaphore(value: 0)
        // The pipe is drained on a background queue and read back on this
        // one, so the buffer genuinely crosses a concurrency boundary. A
        // plain captured `var` compiles with a Swift 6
        // `#SendableClosureCaptures` warning and is a real (if narrow) race:
        // on the timeout path below this thread reads the buffer while the
        // background read may still be in flight. `OSAllocatedUnfairLock`
        // (the repo's established shape — see `CloudImageEncoding._encodeHook`)
        // makes the handoff actually synchronised rather than annotating the
        // race away with `@unchecked Sendable`.
        let capturedData = OSAllocatedUnfairLock<Data>(initialState: Data())
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            capturedData.withLock { $0 = data }
            readSemaphore.signal()
        }

        guard readSemaphore.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = readSemaphore.wait(timeout: .now() + 5)  // brief grace for terminate() to land
            let message = "scripts/test.sh \(args.joined(separator: " ")) did not complete within \(timeout)s — killed to avoid hanging the test run"
            XCTFail(message)
            throw SubprocessTimeoutError(description: message)
        }

        process.waitUntilExit()
        let output = capturedData.withLock { String(data: $0, encoding: .utf8) ?? "" }
        return (process.terminationStatus, output, childOutputFile)
    }

    private func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        // `kill(pid, 0)` remains successful for a zombie until its parent
        // reaps it. It cannot execute or receive a signal, so classify it as
        // terminated for the fixture's orphan-safety assertions.
        if kill(pid, 0) == 0 {
            return psValue(pid: pid, field: "stat")?.trimmingCharacters(in: .whitespaces).hasPrefix("Z") != true
        }
        return errno == EPERM
    }

    private struct StubProcessIdentity {
        let pid: pid_t
        let startIdentity: String
        let stubCommandPath: String
    }

    private func recordedStubIdentity(at record: URL) -> StubProcessIdentity? {
        guard let text = try? String(contentsOf: record, encoding: .utf8),
              let lines = Optional(text.split(whereSeparator: \.isNewline)),
              lines.count >= 3,
              let pid = pid_t(String(lines[0])),
              !lines[1].isEmpty,
              !lines[2].isEmpty else { return nil }
        return StubProcessIdentity(
            pid: pid,
            startIdentity: String(lines[1]),
            stubCommandPath: String(lines[2])
        )
    }

    private func psValue(pid: pid_t, field: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "\(field)="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let value = output.trimmingCharacters(in: .newlines)
        return value.isEmpty ? nil : value
    }

    private func processSnapshot(pid: pid_t) -> (startIdentity: String, command: String)? {
        guard let startIdentity = psValue(pid: pid, field: "lstart"),
              let command = psValue(pid: pid, field: "command") else { return nil }
        return (startIdentity, command)
    }

    private func recordedStubIsStillOwned(_ identity: StubProcessIdentity) -> Bool {
        guard isProcessAlive(identity.pid),
              let snapshot = processSnapshot(pid: identity.pid) else { return false }
        return snapshot.startIdentity == identity.startIdentity
            && snapshot.command.contains(identity.stubCommandPath)
    }

    private func cleanupRecordedStubIfStillOwned(
        _ identity: StubProcessIdentity,
        signal: (pid_t) -> Void
    ) {
        // Signal only after PID + start identity + unique stub path agree.
        // A dead/reused or deliberately mismatched record is left alone.
        guard recordedStubIsStillOwned(identity) else { return }
        signal(identity.pid)
    }

    /// Runs all seven self-test scenarios (waiting on a live holder;
    /// reclaiming a dead holder's lock; rejecting a widowed sentinel;
    /// concurrent-reclaim serialization; the lock actually being wired into
    /// each of its two real call sites; the enclosing run's watchdog log
    /// being left intact) in one process invocation —
    /// `--lock-selftest` itself reports PASS/FAIL per scenario and exits
    /// non-zero if any fails, so this is one real, non-vacuous assertion on
    /// the gate the PR adds, satisfying the "guards ship with a
    /// demonstrated red" / "sabotage the real detection pipeline"
    /// discipline: reverting the serialization, the stale-PID reclaim, or
    /// either of the two real `acquire_gate_lock` call sites makes this test
    /// fail, not just some replica of it. Reverting the reclaim MUTEX is
    /// deliberately NOT on that list: scenario D characterises the design
    /// under contention and is load-dependent, not a guaranteed detector — a
    /// fresh mechanism review measured 18/18 clean sequential rounds against
    /// the mutex forced off (both a coarse "guard always true" sabotage and
    /// true pre-mutex v1 semantics), because `swift test` runs this suite
    /// once, sequentially, and the race needs real concurrent contention to
    /// open a window. The same sabotage reds 1/5 under real 5-way parallel
    /// load with a genuine overlap, confirming D is a real detector whose
    /// window depends on contention this single-process CI shape does not
    /// provide — see the in-script comment on scenario D and the PR body's
    /// "Reclaim race" section for the full account. Passes `timeout: 120`
    /// (not the default 60s) — this runs on a machine that may simultaneously
    /// be compiling/building for a real gate elsewhere, far heavier than
    /// five bash subprocesses, so keeping headroom over the measured cost
    /// costs nothing and this suite does not set
    /// `MANIFOLD_GATE_SELFTEST_D_ROUNDS`, so it always runs scenario D's
    /// cheap 1-round default (~18s locally) rather than the heavier
    /// repeated-round shape a human can opt into by hand — see the note on
    /// (d) above and the CI-incident writeup below.
    ///
    /// **Two CI runs died on this suite, and the explanation that first
    /// looked obvious was wrong. Recording the real one here, because the
    /// wrong one is the more natural inference and cost two CI runs.**
    ///
    /// Both runs were killed by `ci-test-with-watchdog.sh` — "no test
    /// progress for ~240s", SIGABRT — with this method the last thing named
    /// in the log. The natural reading is "this method is slow, or blocks,
    /// and a resource-constrained runner pushed it past the threshold". That
    /// reading is **refuted by the runs' own numbers**: run 1 used scenario
    /// D's 3-round x 8-waiter shape (~36-40s locally) and stalled 231.6s;
    /// run 2 used the 1-round x 4-waiter shape (12.1s locally, 3x cheaper)
    /// and stalled 228.9s. **Cutting the configured work 3x moved the stall
    /// by two seconds.** Nothing about this suite's workload was ever the
    /// variable. Nor does this method block for minutes — it completes in
    /// ~15s; it was the last test to *complete* before the counter froze,
    /// which SwiftPM's completion-ordered `[N/M] Testing …` lines make look
    /// like "the last test to start".
    ///
    /// The actual cause was an environment leak, not a cost. CI exports
    /// `MANIFOLD_TEST_OUTPUT_FILE` (the watchdog's own liveness log) and
    /// every descendant inherits it — including the nested `scripts/test.sh`
    /// invocations scenarios (e)/(f) spawn, whose `swift test … | tee
    /// "$OUTPUT_FILE"` **truncated the live watchdog log mid-run**. The
    /// watchdog only re-arms when the log's progress-line count exceeds its
    /// previous high-water mark, so a truncation that destroys those counted
    /// lines makes the count restart near zero and climb from there. It is a
    /// bounded stall, not a permanent wedge: roughly `high_water ÷ line_rate`
    /// seconds. In run 2 the high-water mark was 3,809 lines and only 2,656
    /// accumulated before the abort — it simply could not catch up inside
    /// 243s. **Corollary worth keeping: a clobber early in a run, against a
    /// low high-water mark, self-heals and never fires the watchdog at all,
    /// so a green run is not evidence this class of bug is absent.**
    ///
    /// Scenario (g) is the regression test; `scripts/test.sh`'s
    /// `run_gate_lock_selftest` carries the mechanism detail. The 1-round
    /// default stays — it is the right default for a human running this by
    /// hand — but it is a cost choice, **not** a fix for the CI failure, and
    /// must not be read as one. Restoring 3 rounds would not reintroduce the
    /// CI stall; removing scenario (g)'s guard would.
    func test_lockSelfTest_allScenariosPass() throws {
        guard let root = repoRoot() else {
            XCTFail("scripts/test.sh not found from test bundle location — path derivation is broken, not legitimately absent")
            return
        }
        let script = root.appendingPathComponent("scripts/test.sh")
        let result = try run(script: script, args: ["--lock-selftest"], timeout: 120)

        XCTAssertEqual(result.status, 0, "lock self-test must exit 0 when all scenarios pass:\n\(result.output)")
        XCTAssertTrue(
            result.output.contains("scenario A: PASS"),
            "second-acquirer-waits scenario must report PASS:\n\(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("scenario B: PASS"),
            "stale-lock-reclaim scenario must report PASS:\n\(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("scenario C: PASS"),
            "widowed-sentinel-not-trusted scenario must report PASS:\n\(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("scenario D: PASS"),
            "concurrent-reclaim (N waiters against one dead-holder lock, repeated across multiple rounds) scenario must report PASS:\n\(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("scenario E: PASS"),
            "the lock-is-actually-wired-into---profile-local's-pre-re-exec-acquire scenario must report PASS:\n\(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("stub `swift` verified in effect at"),
            "scenarios E/F must prove the stub `swift` is actually what PATH resolves to before running a nested scripts/test.sh — a silently-ineffective stub would drive the real toolchain instead:\n\(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("scenario G: PASS"),
            "the enclosing run's MANIFOLD_TEST_OUTPUT_FILE must be left intact — clobbering it is what made CI's watchdog SIGABRT a healthy run:\n\(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("scenario F: PASS"),
            "the lock-is-actually-wired-into-the-fallthrough-acquire (bare invocation / --profile spike) scenario must report PASS:\n\(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("waiting for gate lock held by PID"),
            "the waiting acquirer must print the required progress message shape:\n\(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("STALE LOCK RECLAIMED: holder PID"),
            "reclaiming a dead holder's lock must be loud, never silent:\n\(result.output)"
        )
        XCTAssertTrue(
            result.output.contains("inherited MANIFOLD_GATE_LOCK_OWNER_PID=") && result.output.contains("is stale"),
            "an inherited-but-widowed sentinel must be reported as stale, never trusted silently:\n\(result.output)"
        )
        XCTAssertTrue(result.output.contains("RESULT: PASS"), "overall self-test result line missing:\n\(result.output)")
    }

    /// The XCTest subprocess is itself nested under the full local gate in
    /// CI. It must override that enclosing gate's live watchdog log rather
    /// than inheriting it: if this runner-side assignment is removed, the
    /// child reports the outer path here and this tripwire fails before a
    /// real gate can be clobbered (#2476/#2481).
    func test_lockSelfTest_childUsesPrivateOutputFileInsteadOfEnclosingGateLog() throws {
        guard let root = repoRoot() else {
            XCTFail("scripts/test.sh not found from test bundle location — path derivation is broken, not legitimately absent")
            return
        }
        let enclosingLog = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifoldkit-gate-lock-enclosing-output-\(UUID().uuidString).log")
        let sentinel = "outer gate log must remain private\n"
        try sentinel.write(to: enclosingLog, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: enclosingLog) }

        let result = try run(
            script: root.appendingPathComponent("scripts/test.sh"),
            args: ["--lock-selftest"],
            environment: ["MANIFOLD_TEST_OUTPUT_FILE": enclosingLog.path],
            timeout: 120
        )

        XCTAssertEqual(result.status, 0, "the private child log path must preserve a healthy lock self-test:\n\(result.output)")
        XCTAssertNotEqual(result.childOutputFile.path, enclosingLog.path, "the child must never inherit the enclosing gate log path")
        XCTAssertTrue(result.output.contains("enclosing log inherited '" + result.childOutputFile.path + "' intact"), "scenario G must report the unique child path it actually observed, not the enclosing path:\n\(result.output)")
        XCTAssertEqual(try String(contentsOf: enclosingLog, encoding: .utf8), sentinel, "the child must leave the enclosing gate log untouched")
    }

    /// Scenario F's ready/release barrier is intentionally a real
    /// end-to-end contract rather than a timing-sensitive observer. Remove
    /// only the fallthrough call site from a temporary copy and assert the
    /// actual self-test reports both scenario F and its aggregate result as
    /// failed. The stub still reaches its ready marker, so this is a direct
    /// proof that the failure is the missing lock owner — not a flaky sample
    /// that happened to miss a fast successful invocation (#2479).
    func test_lockSelfTest_fallthroughAcquireSabotageFailsDeterministically() throws {
        guard let root = repoRoot() else {
            XCTFail("scripts/test.sh not found from test bundle location — path derivation is broken, not legitimately absent")
            return
        }
        let script = root.appendingPathComponent("scripts/test.sh")
        let source = try String(contentsOf: script, encoding: .utf8)
        let fallthroughCallSite = """
        # FALLTHROUGH_GATE_LOCK_ACQUIRE: scenario F's sabotage test removes exactly
        # this call site and must make --lock-selftest fail deterministically.
        acquire_gate_lock
        """
        XCTAssertTrue(source.contains(fallthroughCallSite), "fallthrough acquire marker missing; sabotage would not target the intended call site")
        let sabotaged = source.replacingOccurrences(
            of: fallthroughCallSite,
            with: "# FALLTHROUGH_GATE_LOCK_ACQUIRE: deliberately removed by XCTest sabotage.\n"
        )

        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifoldkit-gate-lock-fallthrough-sabotage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        let sabotagedScript = sandbox.appendingPathComponent("test.sh")
        try sabotaged.write(to: sabotagedScript, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: sabotagedScript.path
        )

        let result = try run(script: sabotagedScript, args: ["--lock-selftest"], timeout: 120)
        XCTAssertNotEqual(result.status, 0, "removing only the fallthrough acquire must fail the real self-test:\n\(result.output)")
        XCTAssertTrue(result.output.contains("scenario F: FAIL"), "the fallthrough sabotage must fail scenario F specifically:\n\(result.output)")
        XCTAssertTrue(result.output.contains("handshake_ready=1"), "the sabotaged run must reach the stable handshake, not fail on an observer race:\n\(result.output)")
        XCTAssertTrue(result.output.contains("lock_owner=<missing>"), "the sabotaged run must report the missing owner explicitly:\n\(result.output)")
        XCTAssertTrue(result.output.contains("RESULT: FAIL"), "the aggregate self-test must fail when scenario F fails:\n\(result.output)")
    }

    /// A missing ready marker is a degraded handshake path, not a reason to
    /// wait indefinitely or silently accept a bare invocation. The in-script
    /// stub seam is limited to the self-test and gives this XCTest a bounded
    /// way to prove timeout reporting stays loud.
    func test_lockSelfTest_fallthroughHandshakeTimeoutIsReported() throws {
        guard let root = repoRoot() else {
            XCTFail("scripts/test.sh not found from test bundle location — path derivation is broken, not legitimately absent")
            return
        }
        let script = root.appendingPathComponent("scripts/test.sh")
        let result = try run(
            script: script,
            args: ["--lock-selftest"],
            environment: ["MANIFOLD_GATE_SELFTEST_F_STUB_MODE": "withhold-ready"],
            timeout: 120
        )

        XCTAssertNotEqual(result.status, 0, "a missing scenario F ready marker must fail the self-test:\n\(result.output)")
        XCTAssertTrue(result.output.contains("scenario F: deliberately withholding the ready signal"), "the degraded stub path must announce itself:\n\(result.output)")
        XCTAssertTrue(result.output.contains("scenario F: FAIL"), "the missing-ready path must fail scenario F:\n\(result.output)")
        XCTAssertTrue(result.output.contains("handshake_ready=0 (timed out waiting 5s for ready marker)"), "the handshake timeout must be reported explicitly:\n\(result.output)")
        XCTAssertTrue(result.output.contains("RESULT: FAIL"), "the aggregate self-test must fail on a handshake timeout:\n\(result.output)")
    }

    /// The observer's post-release cleanup is an error path too: if the
    /// nested bare invocation ignores its release signal and TERM, scenario F
    /// must finish its bounded KILL/reap attempt and print both its own and
    /// the aggregate failure. This seam specifically prevents an unguarded
    /// `wait` under `set -e` from hanging or aborting the self-test before
    /// either result line is emitted.
    func test_lockSelfTest_fallthroughStuckChildIsBoundedAndReported() throws {
        guard let root = repoRoot() else {
            XCTFail("scripts/test.sh not found from test bundle location — path derivation is broken, not legitimately absent")
            return
        }
        let script = root.appendingPathComponent("scripts/test.sh")
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifoldkit-gate-lock-stuck-child-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let stubPIDRecord = sandbox.appendingPathComponent("stub.pid")
        defer {
            // Keep a failing future regression test from leaking a fixture;
            // this is deliberately only the PID recorded by its own stub.
            if let identity = recordedStubIdentity(at: stubPIDRecord) {
                cleanupRecordedStubIfStillOwned(identity) { pid in
                    _ = kill(pid, SIGKILL)
                }
            }
        }
        let result = try run(
            script: script,
            args: ["--lock-selftest"],
            environment: [
                "MANIFOLD_GATE_SELFTEST_F_STUB_MODE": "ignore-release",
                "MANIFOLD_GATE_SELFTEST_F_STUB_PID_RECORD_FILE": stubPIDRecord.path,
            ],
            timeout: 120
        )
        guard let recordedIdentity = recordedStubIdentity(at: stubPIDRecord) else {
            XCTFail("the stuck-child fixture did not record its own PID")
            return
        }

        XCTAssertNotEqual(result.status, 0, "a scenario F child that ignores release and TERM must fail the self-test:\n\(result.output)")
        XCTAssertTrue(result.output.contains("scenario F: deliberately ignoring observer release and TERM until cleanup"), "the stuck-child fixture must announce itself:\n\(result.output)")
        XCTAssertTrue(result.output.contains("scenario F: FAIL"), "the bounded cleanup path must reach scenario F's explicit failure:\n\(result.output)")
        XCTAssertTrue(result.output.contains("exit_timeout=1"), "the post-release exit timeout must be reported:\n\(result.output)")
        XCTAssertTrue(result.output.contains("exit=137"), "the KILLed lock-owning parent must report its real wait status rather than silently converting it to success:\n\(result.output)")
        XCTAssertTrue(result.output.contains("reap_status=reaped-after-KILL"), "the TERM/KILL reaping result must be reported instead of an unbounded wait:\n\(result.output)")
        XCTAssertTrue(result.output.contains("stub_reap_status=reaped-after-force-exit"), "the observer must retain the force-exit marker until the orphaned stub is gone:\n\(result.output)")
        XCTAssertTrue(result.output.contains("stub_invocations=1/1"), "the two stuck-child diagnostic lines must not be counted as two stub launches; the old log-line count produced CI's false-red:\n\(result.output)")
        XCTAssertTrue(result.output.contains("lock_cleanup=reclaimed-validated-dead-parent lock_gone=1"), "KILL bypasses the nested owner's EXIT trap, so Scenario F must reclaim only its validated dead private owner record before deleting the fixture root:\n\(result.output)")
        XCTAssertFalse(isProcessAlive(recordedIdentity.pid), "the exact PID recorded by the fixture stub must be gone once --lock-selftest returns")
        XCTAssertTrue(result.output.contains("RESULT: FAIL"), "the bounded cleanup path must reach the aggregate failure:\n\(result.output)")
    }

    /// One stub process may emit several diagnostics. Scenario F used to
    /// count `[stub-swift]` log lines as launches, so this deliberately
    /// harmless second line made the scenario (and aggregate self-test) fail
    /// with `stub_invocations=2/1`. The dedicated PID record must keep the
    /// real self-test green; replacing it with the old log-line count is a
    /// deterministic demonstrated-red for this guard.
    func test_lockSelfTest_fallthroughDiagnosticOutputIsNotAnInvocation() throws {
        guard let root = repoRoot() else {
            XCTFail("scripts/test.sh not found from test bundle location — path derivation is broken, not legitimately absent")
            return
        }
        let result = try run(
            script: root.appendingPathComponent("scripts/test.sh"),
            args: ["--lock-selftest"],
            environment: ["MANIFOLD_GATE_SELFTEST_F_STUB_MODE": "extra-diagnostic"],
            timeout: 120
        )

        XCTAssertEqual(result.status, 0, "extra stub diagnostics are not extra invocations and must not fail the self-test:\n\(result.output)")
        XCTAssertTrue(result.output.contains("scenario F: deliberately emitting an extra diagnostic line"), "the demonstrated-red fixture did not reach its extra-output seam:\n\(result.output)")
        XCTAssertTrue(result.output.contains("scenario F: PASS"), "scenario F must use the dedicated invocation record rather than its log lines:\n\(result.output)")
    }

    /// A numeric PID can be reused after the fixture exits. This seam writes
    /// the real PID with an intentionally wrong start identity, holds until
    /// the observer reports that mismatch, and records any TERM it receives.
    /// The observer must fail loudly and release the fixture without ever
    /// signalling the uncorroborated PID.
    func test_lockSelfTest_identityMismatchRefusesToSignalRecordedPID() throws {
        guard let root = repoRoot() else {
            XCTFail("scripts/test.sh not found from test bundle location — path derivation is broken, not legitimately absent")
            return
        }
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifoldkit-gate-lock-identity-mismatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }
        let stubPIDRecord = sandbox.appendingPathComponent("stub.pid")
        let termSeen = sandbox.appendingPathComponent("term-seen")
        defer {
            if let identity = recordedStubIdentity(at: stubPIDRecord) {
                cleanupRecordedStubIfStillOwned(identity) { pid in
                    _ = kill(pid, SIGKILL)
                }
            }
        }

        let result = try run(
            script: root.appendingPathComponent("scripts/test.sh"),
            args: ["--lock-selftest"],
            environment: [
                "MANIFOLD_GATE_SELFTEST_F_STUB_MODE": "identity-mismatch",
                "MANIFOLD_GATE_SELFTEST_F_STUB_PID_RECORD_FILE": stubPIDRecord.path,
                "MANIFOLD_GATE_SELFTEST_F_TERM_SEEN_FILE": termSeen.path,
            ],
            timeout: 120
        )
        guard let recordedIdentity = recordedStubIdentity(at: stubPIDRecord) else {
            XCTFail("the identity-mismatch fixture did not record its own PID")
            return
        }

        XCTAssertNotEqual(result.status, 0, "an uncorroborated scenario F PID must fail the self-test:\n\(result.output)")
        XCTAssertTrue(result.output.contains("deliberately reporting a mismatched process identity"), "the identity-mismatch fixture must announce itself:\n\(result.output)")
        XCTAssertTrue(result.output.contains("stub_reap_status=identity-mismatch-reaped-after-force-exit"), "the mismatch must be reported rather than signalled:\n\(result.output)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: termSeen.path), "the identity-mismatch fixture must not receive TERM")
        XCTAssertFalse(isProcessAlive(recordedIdentity.pid), "the identity-mismatch fixture must exit after force cleanup")
        XCTAssertTrue(result.output.contains("scenario F: FAIL") && result.output.contains("RESULT: FAIL"), "identity mismatch must fail scenario F and the aggregate self-test:\n\(result.output)")

        guard let currentSnapshot = processSnapshot(pid: getpid()) else {
            XCTFail("could not inspect this XCTest process for the cleanup mismatch seam")
            return
        }
        let mismatchedCurrentProcess = StubProcessIdentity(
            pid: getpid(),
            startIdentity: "deliberately-wrong-start-identity",
            stubCommandPath: currentSnapshot.command
        )
        var didAttemptSignal = false
        cleanupRecordedStubIfStillOwned(mismatchedCurrentProcess) { _ in
            didAttemptSignal = true
        }
        XCTAssertFalse(didAttemptSignal, "cleanup must refuse a live PID whose recorded start identity does not match")
    }

    /// `MANIFOLD_GATE_NO_LOCK=1` is the documented opt-out for a deliberate
    /// parallel run — verify it actually bypasses acquisition rather than
    /// silently no-op'ing some other way. This asserts the actual EFFECT
    /// (no lock file is ever created at the path the opt-out run was given),
    /// not just the announcement string: a sabotage that makes the opt-out
    /// announce itself and then take the lock anyway would still pass an
    /// announcement-only check, defeating the point of testing "skips",
    /// not "mentions".
    func test_noLockOptOut_skipsSerialization() throws {
        guard let root = repoRoot() else {
            XCTFail("scripts/test.sh not found from test bundle location — path derivation is broken, not legitimately absent")
            return
        }
        let script = root.appendingPathComponent("scripts/test.sh")

        let lockFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifoldkit-gate-optout-selftest-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: lockFile) }

        let result = try run(
            script: script,
            args: ["--lock-selftest-hold", "0"],
            environment: [
                "MANIFOLD_GATE_NO_LOCK": "1",
                "MANIFOLD_GATE_LOCK_FILE": lockFile.path,
            ]
        )
        let output = result.output

        XCTAssertEqual(result.status, 0, "the opt-out path must still succeed:\n\(output)")
        XCTAssertTrue(
            output.contains("MANIFOLD_GATE_NO_LOCK=1"),
            "the opt-out must announce itself rather than silently skipping:\n\(output)"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: lockFile.path),
            "the opt-out must actually skip acquisition — no lock file should ever be created at \(lockFile.path):\n\(output)"
        )
    }
}
