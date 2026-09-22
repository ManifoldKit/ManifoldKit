import XCTest
import os

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
        timeout: TimeInterval = 15
    ) throws -> RunResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(
            environment, uniquingKeysWith: { _, new in new }
        )
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let data = OSAllocatedUnfairLock<Data>(initialState: Data())
        let readDone = DispatchSemaphore(value: 0)
        let exitDone = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exitDone.signal() }
        try process.run()
        DispatchQueue.global(qos: .utility).async {
            let captured = pipe.fileHandleForReading.readDataToEndOfFile()
            data.withLock { $0 = captured }
            readDone.signal()
        }

        guard exitDone.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = exitDone.wait(timeout: .now() + 2)
            XCTFail("\(executable.lastPathComponent) did not finish within \(timeout)s")
            throw CocoaError(.coderReadCorrupt)
        }
        _ = readDone.wait(timeout: .now() + 2)
        process.waitUntilExit()
        return RunResult(
            status: process.terminationStatus,
            output: data.withLock { String(data: $0, encoding: .utf8) ?? "" }
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
