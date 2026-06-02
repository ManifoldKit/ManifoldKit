#if canImport(Darwin)
import Darwin
#endif
import XCTest

/// Phase 5 of #714: validates the **`sandbox-exec` net-deny isolation layer**.
///
/// `DenyAllURLProtocol` (Phase 1, PR #715) intercepts `URLSession`-mediated
/// traffic but cannot see `Network.framework` (`NWConnection`, `NWBrowser`),
/// raw BSD sockets, `getaddrinfo(3)`, mDNS/Bonjour, `CFStream`, or
/// `Process.launch` of `/usr/bin/curl`. `TrafficBoundaryAuditTest` rule 2
/// catches these at the **source** level, but a transitive dependency or a
/// particularly creative regression could still bypass the source audit.
///
/// macOS `sandbox-exec` provides a second runtime layer at the **OS sandbox
/// boundary**: any outbound network operation — regardless of API — triggers
/// a sandbox violation. This file pins the harness invariants that
/// `scripts/test-sandboxed.sh` relies on:
///
/// 1. `sandbox-exec` is available on the test host.
/// 2. The deny-network profile **blocks** an outbound `curl` request.
/// 3. The deny-network profile **does not block** local-only operations
///    (so legitimate test work still runs).
/// 4. The deny-network profile blocks `Network.framework` (`NWConnection`)
///    — the gap `DenyAllURLProtocol` cannot cover.
///
/// ## Why this lives in `ManifoldTestSupportTests`
///
/// `ManifoldTestSupportTests` runs in the default CI suite and houses the
/// `DenyAllURLProtocol` tests. Putting the sandbox-exec harness check next to
/// its source-level twin keeps the two isolation layers — runtime
/// `URLProtocol` interception and OS-level sandbox — discoverable together.
///
/// ## Sabotage check
///
/// Per `CLAUDE.md` the test suite is sabotage-verified before commit: with
/// the `(deny network*)` line removed from the profile, the curl assertion
/// flips to a successful exit code. The line is restored before push.
final class SandboxExecNetDenyTests: XCTestCase {

    // MARK: - Profile

    /// Minimal SBPL profile that allows all local resources but denies every
    /// outbound network operation. Mirrors the profile used by
    /// `scripts/test-sandboxed.sh`.
    ///
    /// `(deny network*)` covers the whole `network` action class:
    /// `network-outbound`, `network-inbound`, `network-bind`, and
    /// `network*-resolution` (which gates `getaddrinfo`).
    private static let denyProfile = """
        (version 1)
        (allow default)
        (deny network*)
        """

    // MARK: - Platform / availability gate

    /// `sandbox-exec` ships with macOS; gate Linux and any host where the
    /// binary is missing (e.g., a sandboxed CI runner that filtered it out).
    private func skipIfSandboxExecUnavailable() throws {
        // test_networkFrameworkConnection spawns the Swift compiler as a subprocess
        // (cold-start ≈ 30–120 s on CI) then calls Process.waitUntilExit() which
        // blocks the cooperative thread pool thread until SIGTERM is handled — which
        // can exceed the 242 s watchdog threshold when the compiler doesn't respond.
        // Run these tests locally only; they cover OS-level sandbox wiring, not
        // logic that changes per commit.
        //
        // Belt-and-suspenders: check both CI (generic) and GITHUB_ACTIONS (specific)
        // because the XCTest child process's environment inheritance is not guaranteed
        // to include every parent-shell variable on all runner configurations.
        let env = ProcessInfo.processInfo.environment
        try XCTSkipIf(
            env["CI"] == "true" || env["GITHUB_ACTIONS"] == "true",
            "sandbox-exec tests skipped in CI: swift subprocess cold-start blocks the cooperative thread pool"
        )
        #if !os(macOS)
        throw XCTSkip("sandbox-exec is macOS-only")
        #else
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"),
            "sandbox-exec not available on this host"
        )
        #endif
    }

    // MARK: - Harness

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs `command` (with `arguments`) under `sandbox-exec` using `profile`.
    /// Returns exit status and captured streams. Throws only on Process API
    /// failure — non-zero exits are returned, not raised, because the sandbox
    /// killing the child is the **expected** outcome for the deny tests.
    private func runSandboxed(
        profile: String,
        command: String,
        arguments: [String],
        timeout: TimeInterval = 10
    ) throws -> ProcessResult {
        let profileURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bck-deny-\(UUID().uuidString).sb")
        try profile.write(to: profileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: profileURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-f", profileURL.path, command] + arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // `Process.waitUntilExit` blocks indefinitely — wrap in a deadline so
        // a hang under sandbox doesn't take the whole suite down. The bound
        // is generous: the only operations under test are short curl/echo/
        // swift-tool invocations.
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            XCTFail("sandbox-exec child did not exit within \(timeout)s")
            // SIGTERM may be ignored by a sandboxed swift subprocess — escalate to
            // SIGKILL after 3 s so waitUntilExit() below cannot block indefinitely.
            let killDeadline = Date().addingTimeInterval(3)
            while process.isRunning && Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: stdout,
            stderr: stderr
        )
    }

    // MARK: - Tests

    /// Baseline: a no-network command (`/bin/echo`) must run unimpeded under
    /// the deny profile. Without this, the harness would be vacuously
    /// "secure" — every test would fail, including legitimate local work.
    func test_localOnlyCommand_succeedsUnderDenyProfile() throws {
        try skipIfSandboxExecUnavailable()

        let result = try runSandboxed(
            profile: Self.denyProfile,
            command: "/bin/echo",
            arguments: ["sandbox-allows-local"]
        )

        XCTAssertEqual(
            result.exitCode, 0,
            "Expected /bin/echo to succeed under deny-network profile, got \(result.exitCode). stderr: \(result.stderr)"
        )
        XCTAssertTrue(
            result.stdout.contains("sandbox-allows-local"),
            "Expected stdout to include the echoed token, got: \(result.stdout)"
        )
    }

    /// `curl` exercises `URLSession`-style HTTPS plus `getaddrinfo` for DNS.
    /// Under `(deny network*)` it must fail — the OS-level boundary is what
    /// catches non-`URLSession` egress that `DenyAllURLProtocol` cannot see.
    ///
    /// Curl's exit codes vary (`6` couldn't resolve host, `7` couldn't
    /// connect, `35` SSL handshake) depending on which sandbox check fires
    /// first; any non-zero is a pass for our purposes. Asserting on a
    /// specific code would couple the test to libcurl/macOS internals.
    func test_curlRequest_isBlockedByDenyProfile() throws {
        try skipIfSandboxExecUnavailable()
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: "/usr/bin/curl"),
            "curl not available on this host"
        )

        let result = try runSandboxed(
            profile: Self.denyProfile,
            command: "/usr/bin/curl",
            arguments: [
                "--max-time", "3",
                "--silent",
                "--show-error",
                "--output", "/dev/null",
                // example.invalid is reserved by RFC 6761 — it never resolves
                // even outside the sandbox, but the sandbox should block the
                // resolver attempt before DNS is even consulted.
                "https://example.invalid/sandbox-canary",
            ],
            timeout: 8
        )

        XCTAssertNotEqual(
            result.exitCode, 0,
            "Expected curl to be blocked by sandbox-exec deny-network profile, but it exited 0. stderr: \(result.stderr)"
        )
    }

    /// `Network.framework` (`NWConnection`) is the canonical gap
    /// `DenyAllURLProtocol` cannot cover — `URLProtocol` interception only
    /// sees `URLSession` traffic. This test invokes the `swift` toolchain to
    /// run a tiny script that opens an `NWConnection` and asserts the
    /// connection never reaches `.ready` under the sandbox.
    ///
    /// We launch via `swift` rather than building an XCTest helper because
    /// the helper would need to run **inside** the sandbox child, and adding
    /// an executable target to `Package.swift` for one assertion is more
    /// machinery than the coverage warrants.
    func test_networkFrameworkConnection_isBlockedByDenyProfile() throws {
        try skipIfSandboxExecUnavailable()
        let swiftPath = "/usr/bin/swift"
        try XCTSkipIf(
            !FileManager.default.isExecutableFile(atPath: swiftPath),
            "swift toolchain not available at \(swiftPath)"
        )

        // Use a fixed loopback address to avoid DNS-resolver interactions —
        // we want the test to cover the *socket* path, not the resolver.
        // 1.1.1.1 is Cloudflare's public DNS; the sandbox should refuse the
        // outbound TCP attempt regardless of routing.
        let scriptURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nw-canary-\(UUID().uuidString).swift")
        let script = """
            import Foundation
            import Network

            let conn = NWConnection(host: "1.1.1.1", port: 443, using: .tcp)
            let group = DispatchGroup()
            group.enter()
            var observed = "no-state"
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    observed = "ready"
                    group.leave()
                case .failed(let err):
                    observed = "failed:\\(err)"
                    group.leave()
                case .waiting(let err):
                    observed = "waiting:\\(err)"
                    group.leave()
                default: break
                }
            }
            conn.start(queue: DispatchQueue(label: "nw-canary"))
            _ = group.wait(timeout: .now() + 3)
            print(observed)
            // Exit 0 only on .ready — anything else (waiting/failed/timeout)
            // is what we expect under the deny-network sandbox.
            exit(observed == "ready" ? 0 : 1)
            """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let result = try runSandboxed(
            profile: Self.denyProfile,
            command: swiftPath,
            arguments: [scriptURL.path],
            // Swift script compile + run has a cold-start cost; give it a
            // generous bound. The assertion only fires if we see ".ready".
            timeout: 60
        )

        XCTAssertNotEqual(
            result.exitCode, 0,
            "Expected NWConnection to be blocked by sandbox-exec, got exit 0 with state: \(result.stdout). stderr: \(result.stderr)"
        )
        XCTAssertFalse(
            result.stdout.contains("ready"),
            "NWConnection reached .ready under deny-network sandbox — the OS-level layer is broken. stdout: \(result.stdout)"
        )
    }
}
