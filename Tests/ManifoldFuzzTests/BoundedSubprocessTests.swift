import XCTest
@testable import ManifoldFuzz

/// Exercises `BoundedSubprocess`, the shared timeout+kill wrapper
/// `HarnessMetadata` and `Replayer` use for their `git`/`swift` metadata
/// shell-outs (previously unbounded `Process.waitUntilExit()` calls — see
/// #2266's fuzz-harness-timeout-hardening PR).
final class BoundedSubprocessTests: XCTestCase {

    /// Happy path: a fast, well-behaved process returns its output before the
    /// timeout and `timedOut` is false.
    func test_run_fastProcess_returnsOutputUntimedOut() {
        let result = BoundedSubprocess.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"],
            timeout: 5
        )
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.output?.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
    }

    /// The core guarantee this type exists for: a hung process (here,
    /// `sleep 30`) is force-killed once the timeout elapses, and `run`
    /// returns promptly rather than blocking for the process's full lifetime.
    func test_run_hungProcess_isBoundedByTimeout() {
        let start = ContinuousClock.now
        let result = BoundedSubprocess.run(
            executableURL: URL(fileURLWithPath: "/bin/sleep"),
            arguments: ["30"],
            timeout: 0.3
        )
        let elapsed = start.duration(to: ContinuousClock.now)

        XCTAssertTrue(result.timedOut)
        XCTAssertNil(result.output, "a killed process's partial output isn't trustworthy for a metadata probe")
        XCTAssertLessThan(
            elapsed,
            .seconds(5),
            "run() must return once the timeout elapses, not wait for the full 30s sleep"
        )
    }

    /// A nonexistent executable fails to launch; `run` reports it as a plain
    /// (non-timeout) failure rather than hanging or crashing.
    func test_run_missingExecutable_failsWithoutTimingOut() {
        let result = BoundedSubprocess.run(
            executableURL: URL(fileURLWithPath: "/no/such/binary-\(UUID().uuidString)"),
            arguments: [],
            timeout: 5
        )
        XCTAssertFalse(result.timedOut)
        XCTAssertNil(result.output)
    }
}
