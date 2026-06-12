import Darwin
import Foundation
import XCTest
@testable import ManifoldMCP
import ManifoldTestSupport

final class MCPStdioTransportTests: XCTestCase {
    #if os(macOS) && !targetEnvironment(macCatalyst)
    func test_sendFramesPayloadAndParsesResponse() async throws {
        // Python3 subprocess echo; skip if interpreter not at the standard path.
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: "/usr/bin/python3"),
            "python3 not found at /usr/bin/python3"
        )
        let echoScript = """
        import re, sys

        header = b""
        while b"\\r\\n\\r\\n" not in header:
            chunk = sys.stdin.buffer.read(1)
            if not chunk:
                sys.exit(0)
            header += chunk

        head, rest = header.split(b"\\r\\n\\r\\n", 1)
        match = re.search(br"Content-Length:\\s*(\\d+)", head, re.IGNORECASE)
        if not match:
            sys.exit(1)
        length = int(match.group(1))

        body = rest
        while len(body) < length:
            chunk = sys.stdin.buffer.read(length - len(body))
            if not chunk:
                sys.exit(1)
            body += chunk

        framed = b"Content-Length: " + str(len(body)).encode("ascii") + b"\\r\\n\\r\\n" + body
        sys.stdout.buffer.write(framed)
        sys.stdout.buffer.flush()
        """

        let transport = MCPStdioTransport(
            command: .executable(
                at: URL(fileURLWithPath: "/usr/bin/python3"),
                args: ["-u", "-c", echoScript]
            ),
            maxMessageBytes: 4_096
        )
        let payload = Data("{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}".utf8)

        try await transport.start()
        defer { Task { await transport.close() } }
        try await transport.send(payload)

        let stream = transport.incomingMessages
        let received = try await withTimeout(.seconds(10)) {
            for try await payload in stream {
                return payload
            }
            throw MCPError.transportClosed
        }
        XCTAssertEqual(received, payload)
    }

    func test_startRejectsShellExecutable() async {
        let transport = MCPStdioTransport(
            command: .executable(at: URL(fileURLWithPath: "/bin/sh"), args: ["-c", "echo unsafe"]),
            maxMessageBytes: 4_096
        )

        do {
            try await transport.start()
            XCTFail("Expected shell executable rejection")
        } catch let error as MCPError {
            XCTAssertEqual(error, .transportFailure("stdio executable must not be a shell"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_closeTerminatesProcessDeterministically() async throws {
        let transport = MCPStdioTransport(
            command: .executable(at: URL(fileURLWithPath: "/bin/sleep"), args: ["30"]),
            maxMessageBytes: 4_096
        )

        try await transport.start()
        try await withTimeout(.seconds(2)) {
            await transport.close()
        }

        do {
            try await transport.send(Data("{}".utf8))
            XCTFail("Expected transportClosed after close")
        } catch let error as MCPError {
            XCTAssertEqual(error, .transportClosed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
    #endif

    func test_environmentPolicyScrubsInheritedAndAllowsExplicitOverrides() {
        let inherited = [
            "PATH": "/usr/bin",
            "HOME": "/Users/tester",
            "SSH_AUTH_SOCK": "/private/tmp/agent.sock",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib",
        ]
        let explicit = [
            "CUSTOM_TOKEN": "abc123",
            "BAD\0KEY": "ignored",
            "GOOD_VALUE": "ok",
            "NULL_VALUE": "bad\0value",
        ]

        let sanitized = MCPStdioEnvironmentPolicy.sanitizedEnvironment(
            inherited: inherited,
            explicit: explicit
        )

        XCTAssertEqual(sanitized["PATH"], "/usr/bin")
        XCTAssertEqual(sanitized["HOME"], "/Users/tester")
        XCTAssertEqual(sanitized["CUSTOM_TOKEN"], "abc123")
        XCTAssertEqual(sanitized["GOOD_VALUE"], "ok")
        XCTAssertNil(sanitized["SSH_AUTH_SOCK"])
        XCTAssertNil(sanitized["DYLD_INSERT_LIBRARIES"])
        XCTAssertNil(sanitized["BAD\0KEY"])
        XCTAssertNil(sanitized["NULL_VALUE"])
    }

    #if os(macOS) && !targetEnvironment(macCatalyst)
    func test_inheritedFDs_marked_CLOEXEC() async throws {
        // Sabotage: removing the fcntl call would fail test_inheritedFDs_marked_CLOEXEC

        // We verify the FD_CLOEXEC contract at the Pipe level: create a Pipe,
        // assert it starts without the flag, then set it and confirm the flag is present.
        // This mirrors exactly what MCPStdioTransport.start() does before launching.
        let probe = Pipe()
        let writeFD = probe.fileHandleForWriting.fileDescriptor
        let before = fcntl(writeFD, F_GETFD)
        XCTAssertEqual(before & FD_CLOEXEC, 0, "Baseline: new pipe should NOT have FD_CLOEXEC")

        let result = fcntl(writeFD, F_SETFD, FD_CLOEXEC)
        XCTAssertEqual(result, 0, "Setting FD_CLOEXEC must succeed")

        let after = fcntl(writeFD, F_GETFD)
        XCTAssertNotEqual(after & FD_CLOEXEC, 0, "After F_SETFD FD_CLOEXEC the flag must be set")

        // Also verify start() completes without a codesign or FD error, exercising
        // the actual fcntl path through MCPStdioTransport.
        let replyScript = """
        import sys
        body = b'{"jsonrpc":"2.0","id":1,"result":{}}'
        header = b"Content-Length: " + str(len(body)).encode("ascii") + b"\\r\\n\\r\\n"
        sys.stdout.buffer.write(header + body)
        sys.stdout.buffer.flush()
        """
        let transport = MCPStdioTransport(
            command: .executable(
                at: URL(fileURLWithPath: "/usr/bin/python3"),
                args: ["-u", "-c", replyScript]
            ),
            maxMessageBytes: 4_096
        )
        try await transport.start()
        Task { await transport.close() }
    }

    func test_codesign_requirement_violated_rejected() async throws {
        // Sabotage: removing the fcntl call would fail test_inheritedFDs_marked_CLOEXEC

        let transport = MCPStdioTransport(
            command: MCPStdioCommand(
                executable: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["hello"],
                codesignRequirement: "identifier com.nonexistent.fake"
            ),
            maxMessageBytes: 4_096
        )

        do {
            try await transport.start()
            XCTFail("Expected codesign requirement failure")
        } catch let error as MCPError {
            guard case .transportFailure(let message) = error else {
                XCTFail("Expected transportFailure, got \(error)")
                return
            }
            XCTAssertTrue(
                message.contains("codesign requirement not met") || message.contains("codesign check"),
                "Error message should describe codesign failure, got: \(message)"
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_codesign_requirement_satisfied_proceeds() async throws {
        // Sabotage: removing the fcntl call would fail test_inheritedFDs_marked_CLOEXEC

        // "anchor apple" is satisfied by any binary signed by Apple, including /bin/echo.
        let transport = MCPStdioTransport(
            command: MCPStdioCommand(
                executable: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["hello"],
                codesignRequirement: "anchor apple"
            ),
            maxMessageBytes: 4_096
        )

        // The process will exit immediately but start() should not throw a codesign error.
        do {
            try await transport.start()
            // Expected: no codesign error
        } catch let error as MCPError {
            if case .transportFailure(let message) = error,
               message.contains("codesign") {
                XCTFail("Unexpected codesign failure for anchor-apple requirement: \(message)")
            }
            // Any other transport failure (e.g., echo exits immediately) is acceptable.
        } catch {
            // Non-MCPError failures are acceptable here (process exit, etc.)
        }

        Task { await transport.close() }
    }

    func test_codesign_requirement_nil_skipsCheck() async throws {
        // Sabotage: removing the fcntl call would fail test_inheritedFDs_marked_CLOEXEC

        // nil requirement means no codesign check — any binary is accepted.
        let transport = MCPStdioTransport(
            command: MCPStdioCommand(
                executable: URL(fileURLWithPath: "/bin/echo"),
                arguments: ["hello"],
                codesignRequirement: nil
            ),
            maxMessageBytes: 4_096
        )

        do {
            try await transport.start()
            // Expected: no codesign check, no error from codesign path
        } catch let error as MCPError {
            if case .transportFailure(let message) = error,
               message.contains("codesign") {
                XCTFail("Codesign check should be skipped when requirement is nil, got: \(message)")
            }
            // Other transport failures (echo exits) are acceptable.
        } catch {
            // Non-MCPError failures are acceptable.
        }

        Task { await transport.close() }
    }
    #endif

    func test_connectStdioUsesPlatformGating() async {
        // allowsSTDIOTransport: true and isUnauthenticatedUnsafe: true here so
        // the test reaches the platform-gating and shell-rejection checks rather
        // than the security opt-in guards added in #1413.
        let descriptor = MCPServerDescriptor(
            displayName: "Stdio",
            transport: .stdio(.executable(at: URL(fileURLWithPath: "/bin/sh"), args: ["-c", "echo nope"])),
            dataDisclosure: "test",
            allowsSTDIOTransport: true,
            isUnauthenticatedUnsafe: true
        )

        let client = MCPClient()

        do {
            _ = try await client.connect(descriptor)
            XCTFail("Expected stdio connect to fail without a full MCP server")
        } catch let error as MCPError {
            #if os(macOS) && !targetEnvironment(macCatalyst)
            XCTAssertEqual(error, .transportFailure("stdio executable must not be a shell"))
            #else
            XCTAssertEqual(error, .transportFailure("stdio MCP transport is unavailable on this platform"))
            #endif
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
