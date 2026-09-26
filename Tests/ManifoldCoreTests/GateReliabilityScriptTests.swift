import XCTest
import Darwin

/// Regression coverage for the local/CI gate reliability plumbing. These
/// tests execute the real shell entrypoints against disposable fake children;
/// no Swift build, GitHub workflow, or persistent power setting is started.
final class GateReliabilityScriptTests: XCTestCase {
    private struct RunResult {
        let status: Int32
        let output: String
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifold-gate-reliability-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func run(
        _ executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        timeout: TimeInterval = 15,
        signalAfterReady: URL? = nil,
        signal: Int32 = SIGTERM,
        context: String = ""
    ) throws -> RunResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment, uniquingKeysWith: { _, new in new }
        )
        // A file preserves partial diagnostics even when a descendant keeps
        // stdout open or a busy global queue delays a pipe-draining callback.
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("gate-fixture-output-\(UUID().uuidString).log")
        try Data().write(to: outputURL)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer {
            try? outputHandle.close()
            try? FileManager.default.removeItem(at: outputURL)
        }
        process.standardOutput = outputHandle
        process.standardError = outputHandle
        let exitDone = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitDone.signal() }
        try process.run()

        if let signalAfterReady {
            let deadline = Date().addingTimeInterval(5)
            while !FileManager.default.fileExists(atPath: signalAfterReady.path), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.02)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: signalAfterReady.path), "child must start before cancellation")
            XCTAssertEqual(Darwin.kill(process.processIdentifier, signal), 0)
        }

        guard exitDone.wait(timeout: .now() + timeout) == .success else {
            let output = try String(contentsOf: outputURL, encoding: .utf8)
            var state = "parentPID=\(process.processIdentifier) alive=\(Darwin.kill(process.processIdentifier, 0) == 0)"
            if let signalAfterReady {
                let child = (try? String(contentsOf: signalAfterReady, encoding: .utf8)) ?? "missing"
                let group = (try? String(contentsOfFile: signalAfterReady.path + ".group", encoding: .utf8)) ?? "missing"
                state += " childPID=\(child.trimmingCharacters(in: .whitespacesAndNewlines)) groupPID=\(group.trimmingCharacters(in: .whitespacesAndNewlines))"
                // Only this isolated fixture's recorded group is eligible for
                // cleanup. Never send a signal to the XCTest caller's group.
                if let groupPID = Int32(group.trimmingCharacters(in: .whitespacesAndNewlines)),
                   groupPID > 0, groupPID != Darwin.getpgrp(),
                   let childPID = Int32(child.trimmingCharacters(in: .whitespacesAndNewlines)),
                   Darwin.getpgid(childPID) == groupPID {
                    _ = Darwin.kill(-groupPID, SIGKILL)
                }
            }
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            _ = exitDone.wait(timeout: .now() + 2)
            let details = "\(context) \(executable.lastPathComponent) did not finish within \(timeout)s after \(signalAfterReady == nil ? "launch" : "ready + signal \(signal)"). \(state)\nOutput:\n\(output)"
            XCTFail(details)
            throw NSError(domain: "GateReliabilityScriptTests", code: 1, userInfo: [NSLocalizedDescriptionKey: details])
        }
        process.waitUntilExit()
        return RunResult(
            status: process.terminationStatus,
            output: try String(contentsOf: outputURL, encoding: .utf8)
        )
    }

    func test_watchdogAcceptsUnicodeBuildProgressButRejectsSilenceAndChatter() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = root.appendingPathComponent("fixture-runner.sh")
        try writeExecutable(
            """
            #!/bin/bash
            set -euo pipefail
            case "${WATCHDOG_FIXTURE_MODE:?}" in
              progress)
                i=1
                while [ "$i" -le 8 ]; do
                  printf '[%s\u{2009}/\u{2009}8] ManifoldSecretsTests-product\\n' "$i" >> "$MANIFOLD_TEST_OUTPUT_FILE"
                  sleep 0.5
                  i=$((i + 1))
                done
                ;;
              chatter)
                i=1
                while [ "$i" -le 20 ]; do
                  printf '[heartbeat] still talking %s\\n' "$i" >> "$MANIFOLD_TEST_OUTPUT_FILE"
                  sleep 0.2
                  i=$((i + 1))
                done
                ;;
              stalled) exec sleep 4 ;;
              *) exit 64 ;;
            esac
            """,
            to: runner
        )

        let wrapper = repoRoot().appendingPathComponent("scripts/ci-test-with-watchdog.sh")
        func exercise(_ mode: String) throws -> RunResult {
            let log = root.appendingPathComponent("\(mode).log")
            return try run(
                wrapper,
                environment: [
                    "MANIFOLD_WATCHDOG_SELFTEST_CHILD": "1",
                    "MANIFOLD_WATCHDOG_TEST_RUNNER": runner.path,
                    "WATCHDOG_FIXTURE_MODE": mode,
                    "MANIFOLD_TEST_OUTPUT_FILE": log.path,
                    "WATCHDOG_LOG": log.path,
                    "WATCHDOG_DIAGNOSTICS_DIR": root.path,
                    "WATCHDOG_POLL_INTERVAL": "0.2",
                    "STALL_SECONDS": "2",
                ]
            )
        }

        let progress = try exercise("progress")
        XCTAssertEqual(progress.status, 0, progress.output)

        let stalled = try exercise("stalled")
        XCTAssertEqual(stalled.status, 124, stalled.output)
        XCTAssertTrue(stalled.output.contains("aborted by stall watchdog"), stalled.output)

        let chatter = try exercise("chatter")
        XCTAssertEqual(chatter.status, 124, chatter.output)
        XCTAssertTrue(chatter.output.contains("aborted by stall watchdog"), chatter.output)
    }

    func test_sleepAssertionCleansUpOnSuccessFailureAndSignalAndSkipsNonMacOS() throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fakeCaffeinate = root.appendingPathComponent("caffeinate")
        try writeExecutable(
            """
            #!/bin/bash
            set -euo pipefail
            printf 'started pid=%s args=%s\\n' "$$" "$*" >> "$MANIFOLD_FAKE_CAFFEINATE_RECORD"
            trap 'printf "stopped pid=%s\\n" "$$" >> "$MANIFOLD_FAKE_CAFFEINATE_RECORD"; exit 0' HUP INT TERM
            while :; do sleep 0.1; done
            """,
            to: fakeCaffeinate
        )
        let script = repoRoot().appendingPathComponent("scripts/test.sh")
        let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"

        for (mode, expectedStatus) in [("success", Int32(0)), ("failure", Int32(23)), ("signal", Int32(143))] {
            let record = root.appendingPathComponent("\(mode).record")
            let result = try run(
                script,
                arguments: ["--sleep-assertion-selftest", mode],
                environment: [
                    "MANIFOLD_SLEEP_ASSERTION_SELFTEST": "1",
                    "MANIFOLD_SLEEP_ASSERTION_SELFTEST_PLATFORM": "Darwin",
                    "MANIFOLD_SLEEP_ASSERTION_SELFTEST_CAFFEINATE_BIN": fakeCaffeinate.path,
                    "MANIFOLD_SLEEP_ASSERTION_SELFTEST_CHILD_READY_FILE": record.path,
                    "MANIFOLD_FAKE_CAFFEINATE_RECORD": record.path,
                    "PATH": "\(root.path):\(originalPath)",
                ]
            )
            XCTAssertEqual(result.status, expectedStatus, "\(mode): \(result.output)")
            let lifecycle = try String(contentsOf: record, encoding: .utf8)
            XCTAssertTrue(lifecycle.contains("args=-i -w "), "\(mode): \(lifecycle)")
            XCTAssertTrue(lifecycle.contains("stopped pid="), "\(mode): \(lifecycle)")
        }

        let nonMacRecord = root.appendingPathComponent("nonmac.record")
        let nonMac = try run(
            script,
            arguments: ["--sleep-assertion-selftest", "success"],
            environment: [
                "MANIFOLD_SLEEP_ASSERTION_SELFTEST": "1",
                "MANIFOLD_SLEEP_ASSERTION_SELFTEST_PLATFORM": "Linux",
                "MANIFOLD_SLEEP_ASSERTION_SELFTEST_CAFFEINATE_BIN": fakeCaffeinate.path,
                "MANIFOLD_FAKE_CAFFEINATE_RECORD": nonMacRecord.path,
                "PATH": "\(root.path):\(originalPath)",
            ]
        )
        XCTAssertEqual(nonMac.status, 0, nonMac.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nonMacRecord.path))
        XCTAssertTrue(nonMac.output.contains("not needed"), nonMac.output)
    }

    func test_runningLocalProfileCancelsOwnedChildrenBeforeReleasingLockAndAssertion() throws {
        let configurations = [
            (disabled: false, mode: "resistant", signals: [SIGTERM, SIGHUP, SIGINT]),
            (disabled: true, mode: "resistant", signals: [SIGTERM, SIGHUP, SIGINT]),
            (disabled: false, mode: "failed-ps", signals: [SIGTERM]),
            (disabled: false, mode: "late-fork", signals: [SIGTERM]),
        ]
        for configuration in configurations {
            for signal in configuration.signals {
                let root = try makeTempDirectory()
                defer { try? FileManager.default.removeItem(at: root) }
                let scripts = root.appendingPathComponent("scripts")
                let bin = root.appendingPathComponent("bin")
                try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
                for name in ["test.sh", "ci-test-with-watchdog.sh"] {
                    try FileManager.default.copyItem(
                        at: repoRoot().appendingPathComponent("scripts/\(name)"),
                        to: scripts.appendingPathComponent(name)
                    )
                }
                let ready = root.appendingPathComponent("ready")
                let record = root.appendingPathComponent("assertion")
                let lock = root.appendingPathComponent("gate.lock")
                // A resistant Swift child proves escalation stops descendants;
                // a natural completion after 30 seconds cannot satisfy this test.
                try writeExecutable(
                    """
                    #!/bin/bash
                    set -uo pipefail
                    if [[ "$CANCELLATION_MODE" == "late-fork" ]]; then
                        trap '' HUP INT
                        trap 'sleep 30 & printf "%s\\n" "$!" > "$CANCELLATION_READY.late"; wait' TERM
                    else
                        trap '' HUP INT TERM
                    fi
                    /bin/ps -p "$$" -o pgid= > "$CANCELLATION_READY.group"
                    test "$(head -n 1 "$MANIFOLD_GATE_LOCK_FILE")" = "$MANIFOLD_GATE_LOCK_OWNER_PID" || exit 65
                    printf '%s\\n' "$$" > "$CANCELLATION_READY"
                    if [[ "$CANCELLATION_MODE" == "late-fork" ]]; then
                        # A foreground command can defer Bash trap dispatch;
                        # readiness must lead straight to the TERM handler.
                        while :; do :; done
                    else
                        while :; do sleep 0.05; done
                    fi
                    """,
                    to: bin.appendingPathComponent("swift")
                )
                let wrongLock = root.appendingPathComponent("wrong.lock")
                try "999\n".write(to: wrongLock, atomically: true, encoding: .utf8)
                for rejectedLock in [wrongLock, root.appendingPathComponent("missing.lock")] {
                    let rejectedReady = root.appendingPathComponent("rejected.ready")
                    let rejected = try run(
                        bin.appendingPathComponent("swift"),
                        environment: [
                            "CANCELLATION_MODE": "resistant",
                            "CANCELLATION_READY": rejectedReady.path,
                            "MANIFOLD_GATE_LOCK_FILE": rejectedLock.path,
                            "MANIFOLD_GATE_LOCK_OWNER_PID": "123",
                        ]
                    )
                    XCTAssertEqual(rejected.status, 65, rejected.output)
                    XCTAssertFalse(FileManager.default.fileExists(atPath: rejectedReady.path), rejected.output)
                }
                if configuration.mode == "failed-ps" {
                    try writeExecutable("#!/bin/bash\nexit 71\n", to: bin.appendingPathComponent("ps"))
                }
                let unrelated = Process()
                unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep")
                unrelated.arguments = ["30"]
                try unrelated.run()
                defer { unrelated.terminate(); unrelated.waitUntilExit() }
                let caffeinate = bin.appendingPathComponent("caffeinate")
                try writeExecutable(
                    """
                    #!/bin/bash
                    set -euo pipefail
                    printf 'started\\n' >> "$CANCELLATION_ASSERTION"
                    trap 'printf "stopped\\n" >> "$CANCELLATION_ASSERTION"; exit 0' HUP INT TERM
                    # Mirror -w cleanup even if timeout recovery KILLs the
                    # owning shell before its EXIT trap can run.
                    while kill -0 "$3" 2>/dev/null; do sleep 0.1; done
                    printf 'stopped\\n' >> "$CANCELLATION_ASSERTION"
                    """,
                    to: caffeinate
                )
                let originalPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
                let launcher = root.appendingPathComponent("signal-launcher.py")
                try """
                import os, signal, sys
                tested = {signal.SIGHUP, signal.SIGINT, signal.SIGTERM}
                inherited_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
                inherited_dispositions = {int(sig): str(signal.getsignal(sig)) for sig in tested}
                print(f"[signal-fixture] inherited-mask={sorted(map(int, inherited_mask))} dispositions={inherited_dispositions}", flush=True)
                # Both ignored dispositions and blocked masks survive exec.
                # Seed both failure modes, then own the tested signal state in
                # this isolated child; never mutate the XCTest worker's state.
                for sig in tested:
                    signal.signal(sig, signal.SIG_IGN)
                signal.pthread_sigmask(signal.SIG_BLOCK, tested)
                for sig in tested:
                    signal.signal(sig, signal.SIG_DFL)
                signal.pthread_sigmask(signal.SIG_UNBLOCK, tested)
                remaining = signal.pthread_sigmask(signal.SIG_BLOCK, set())
                defaults = all(signal.getsignal(sig) == signal.SIG_DFL for sig in tested)
                print(f"[signal-fixture] normalized-tested-blocked={sorted(map(int, remaining & tested))} default-dispositions={defaults}", flush=True)
                os.execv("/bin/bash", ["/bin/bash", *sys.argv[1:]])
                """.write(to: launcher, atomically: true, encoding: .utf8)
                guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else {
                    XCTFail("The isolated signal fixture requires macOS /usr/bin/python3")
                    throw CocoaError(.fileNoSuchFile)
                }
                let result = try run(
                    URL(fileURLWithPath: "/usr/bin/python3"),
                    arguments: [launcher.path, scripts.appendingPathComponent("test.sh").path, "--profile", "local", "--filter", "ManifoldCoreTests"],
                    environment: [
                        "PATH": "\(bin.path):\(originalPath)",
                        "MANIFOLD_GATE_LOCK_FILE": lock.path,
                        "MANIFOLD_GATE_LOCK_OWNER_PID": "",
                        "MANIFOLD_WATCHDOG_ACTIVE": "0",
                        "MANIFOLD_TEST_OUTPUT_FILE": root.appendingPathComponent("output.log").path,
                        "MANIFOLD_DISABLE_LOCAL_WATCHDOG": configuration.disabled ? "1" : "0",
                        "MANIFOLD_SLEEP_ASSERTION_SELFTEST": "1",
                        "MANIFOLD_SLEEP_ASSERTION_SELFTEST_PLATFORM": "Darwin",
                        "MANIFOLD_SLEEP_ASSERTION_SELFTEST_CAFFEINATE_BIN": caffeinate.path,
                        "MANIFOLD_SLEEP_ASSERTION_SELFTEST_CHILD_READY_FILE": record.path,
                        "CANCELLATION_READY": ready.path,
                        "CANCELLATION_MODE": configuration.mode,
                        "CANCELLATION_ASSERTION": record.path,
                        "WATCHDOG_POLL_INTERVAL": "0.1",
                    ],
                    timeout: 3,
                    signalAfterReady: ready,
                    signal: signal,
                    context: "mode=\(configuration.mode) watchdogDisabled=\(configuration.disabled) signal=\(signal)"
                )
                XCTAssertEqual(result.status, 128 + signal, result.output)
                XCTAssertTrue(result.output.contains("normalized-tested-blocked=[] default-dispositions=True"), result.output)
                XCTAssertTrue(unrelated.isRunning, "cancellation must leave unrelated processes alive")
                let groupPID = try XCTUnwrap(Int32(String(contentsOfFile: ready.path + ".group", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
                XCTAssertGreaterThan(groupPID, 0)
                XCTAssertNotEqual(groupPID, Darwin.getpgrp(), "the profile child must own a separate group")
                if configuration.mode == "late-fork" {
                    let latePID = try XCTUnwrap(Int32(String(contentsOfFile: ready.path + ".late", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
                    let lateState = try run(URL(fileURLWithPath: "/bin/ps"), arguments: ["-p", String(latePID), "-o", "stat="])
                    XCTAssertTrue(lateState.status != 0 || lateState.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z"), lateState.output)
                }
                XCTAssertFalse(FileManager.default.fileExists(atPath: lock.path), result.output)
                let lifecycle = try String(contentsOf: record, encoding: .utf8)
                XCTAssertTrue(lifecycle.contains("stopped"), lifecycle)
                let childPID = try XCTUnwrap(Int32(String(contentsOf: ready, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
                // A zombie has already stopped executing, but must never be a
                // live orphan consuming Swift build/test resources after unlock.
                let state = try run(
                    URL(fileURLWithPath: "/bin/ps"),
                    arguments: ["-p", String(childPID), "-o", "stat="]
                )
                XCTAssertTrue(state.status != 0 || state.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z"), state.output)
                XCTAssertTrue(result.output.contains("released macOS idle-sleep assertion"), result.output)
            }
        }
    }

    func test_ciConcurrencySeparatesDraftFromReadyAndPreservesCancellationSemantics() throws {
        let workflow = try String(
            contentsOf: repoRoot().appendingPathComponent(".github/workflows/ci.yml"),
            encoding: .utf8
        )
        let groupLine = try XCTUnwrap(
            workflow.split(separator: "\n").map(String.init)
                .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("group: ci-") }
        )
        XCTAssertTrue(groupLine.contains("github.event.pull_request.draft && 'draft' || 'ready'"), groupLine)
        XCTAssertTrue(workflow.contains("cancel-in-progress: ${{ github.event_name != 'merge_group' }}"))

        func group(event: String, pr: Int? = nil, draft: Bool? = nil, ref: String) -> String {
            if event == "pull_request", let pr, let draft {
                return "ci-CI-\(pr)-\(draft ? "draft" : "ready")"
            }
            return "ci-CI-\(ref)-\(event)"
        }

        let draftOpen = group(event: "pull_request", pr: 42, draft: true, ref: "refs/pull/42/merge")
        let draftSynchronize = group(event: "pull_request", pr: 42, draft: true, ref: "refs/pull/42/merge")
        let ready = group(event: "pull_request", pr: 42, draft: false, ref: "refs/pull/42/merge")
        let readySynchronize = group(event: "pull_request", pr: 42, draft: false, ref: "refs/pull/42/merge")
        XCTAssertEqual(draftOpen, draftSynchronize, "draft bursts should still collapse")
        XCTAssertNotEqual(draftSynchronize, ready, "a late draft run must not cancel the required ready run")
        XCTAssertEqual(ready, readySynchronize, "ready force-push bursts should still collapse")
        XCTAssertEqual(
            group(event: "push", ref: "refs/heads/main"),
            group(event: "push", ref: "refs/heads/main"),
            "main push bursts should still collapse"
        )
        XCTAssertNotEqual(
            group(event: "merge_group", ref: "refs/heads/gh-readonly-queue/main/pr-42-a"),
            group(event: "merge_group", ref: "refs/heads/gh-readonly-queue/main/pr-43-b"),
            "merge-queue batches retain unique ref groups"
        )
    }

    func test_sabotage_oldCIConcurrencyGroupIsDetectedAsDraftReadyCollision() {
        let old = "group: ci-${{ github.workflow }}-${{ github.event.pull_request.number || github.ref }}"
        XCTAssertFalse(old.contains("github.event.pull_request.draft && 'draft' || 'ready'"))
    }
}
