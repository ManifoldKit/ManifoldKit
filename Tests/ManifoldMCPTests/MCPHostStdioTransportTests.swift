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
        let consumeTask = Task {
            do {
                for try await _ in transport.incomingMessages {
                    // No messages expected on this fixture — just draining.
                }
            } catch {
                // Either a clean finish or a surfaced close error is an
                // acceptable terminal state; what matters is that iteration
                // ends at all.
            }
            iterationFinished.fulfill()
        }

        // Give the detached read task a moment to actually reach its
        // blocking read before we ask it to stop.
        try await Task.sleep(nanoseconds: 50_000_000)

        await transport.shutdown()

        await fulfillment(of: [iterationFinished], timeout: 5)
        consumeTask.cancel()

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

        try? pipe.fileHandleForWriting.close()
    }

    // MARK: shutdown after the peer already closed (EOF path still works)

    func test_shutdown_afterPeerEOF_stillTerminatesCleanly() async throws {
        let pipe = Pipe()
        let transport = MCPHostStdioTransport(input: pipe.fileHandleForReading)

        let iterationFinished = expectation(description: "iteration terminates on EOF")
        let consumeTask = Task {
            for try await _ in transport.incomingMessages {}
            iterationFinished.fulfill()
        }

        // Closing the write end delivers EOF to the blocked read, which the
        // pre-existing (correct) EOF path already handles.
        try pipe.fileHandleForWriting.close()
        await fulfillment(of: [iterationFinished], timeout: 5)
        consumeTask.cancel()

        // shutdown() after natural EOF must still be safe.
        await transport.shutdown()
    }
}
#endif
