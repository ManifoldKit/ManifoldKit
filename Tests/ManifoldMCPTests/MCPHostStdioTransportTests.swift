#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import XCTest
@testable import ManifoldMCPHost

// MARK: - MCPHostStdioTransportTests
//
// Regression coverage for the shutdown-hang footgun: `MCPHostStdioTransport`
// used to have no way to unblock its detached read loop, which sat blocked
// in `FileHandle.availableData` forever — cancelling the `Task` running
// `MCPHostServer.run(transport:)` never terminated it. `shutdown()` now
// closes the input handle to unblock the read and joins the read task.
final class MCPHostStdioTransportTests: XCTestCase {

    // MARK: shutdown terminates iteration

    func test_shutdown_terminatesIncomingMessagesIteration() async throws {
        let pipe = Pipe()
        let transport = MCPHostStdioTransport(input: pipe.fileHandleForReading)

        // Start consuming before shutdown, mirroring how `MCPHostServer.run`
        // drains `incomingMessages` for the lifetime of the connection.
        let iterationFinished = expectation(description: "iteration terminates")
        let consumeTask = Task { () -> Bool in
            // Returns whether iteration ended by throwing.
            do {
                for try await _ in transport.incomingMessages {
                    // No messages expected on this fixture — just draining.
                }
                iterationFinished.fulfill()
                return false
            } catch {
                iterationFinished.fulfill()
                return true
            }
        }

        // Give the detached read task a moment to actually reach its
        // blocking read before we ask it to stop.
        try await Task.sleep(nanoseconds: 50_000_000)

        await transport.shutdown()

        await fulfillment(of: [iterationFinished], timeout: 5)
        // `shutdown()` cancels the read task before closing the handle, so
        // the unblocked read's error is always observed under
        // `Task.isCancelled == true` — a deterministic clean finish, never a
        // thrown EBADF surfaced to the caller as a spurious transport error.
        let threw = await consumeTask.value
        XCTAssertFalse(threw, "shutdown() must finish incomingMessages cleanly, not by throwing")

        // The write end is still open on our side; close it to avoid leaking
        // the fixture's file descriptor into later tests.
        try? pipe.fileHandleForWriting.close()
    }

    // MARK: shutdown is idempotent

    func test_shutdown_calledTwice_doesNotHang() async throws {
        let pipe = Pipe()
        let transport = MCPHostStdioTransport(input: pipe.fileHandleForReading)

        await transport.shutdown()
        // A second call must be a no-op, not a hang or a crash from
        // double-closing the handle.
        await transport.shutdown()

        // Positive check that the transport actually reached its terminal
        // state: consuming the (already-finished) stream after both calls
        // must complete immediately with no elements and no thrown error.
        var messages: [Data] = []
        for try await message in transport.incomingMessages {
            messages.append(message)
        }
        XCTAssertTrue(messages.isEmpty, "no messages were ever written to the fixture pipe")

        try? pipe.fileHandleForWriting.close()
    }

    // MARK: shutdown after the peer already closed (EOF path still works)

    func test_shutdown_afterPeerEOF_stillTerminatesCleanly() async throws {
        let pipe = Pipe()
        let transport = MCPHostStdioTransport(input: pipe.fileHandleForReading)

        let iterationFinished = expectation(description: "iteration terminates on EOF")
        let consumeTask = Task { () -> Bool in
            do {
                for try await _ in transport.incomingMessages {}
                iterationFinished.fulfill()
                return false
            } catch {
                iterationFinished.fulfill()
                return true
            }
        }

        // Closing the write end delivers EOF to the blocked read, which the
        // pre-existing (correct) EOF path already handles.
        try pipe.fileHandleForWriting.close()
        await fulfillment(of: [iterationFinished], timeout: 5)
        let threw = await consumeTask.value
        XCTAssertFalse(threw, "a natural peer EOF must finish incomingMessages cleanly")

        // shutdown() after natural EOF must still be safe — and idempotently
        // reach the same terminal state rather than hanging or crashing.
        await transport.shutdown()
        var messages: [Data] = []
        for try await message in transport.incomingMessages {
            messages.append(message)
        }
        XCTAssertTrue(messages.isEmpty, "no messages were ever written before EOF")
    }
}
#endif
