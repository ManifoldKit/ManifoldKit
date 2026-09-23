#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import ManifoldInference
import ManifoldMCP
import os

/// Stdio transport for ``ManifoldMCPHost``.
///
/// Reads newline-delimited JSON-RPC messages from `stdin` and writes
/// responses to `stdout`. This is the transport shape used by Claude Desktop
/// and other local MCP clients that launch the host app as a subprocess.
///
/// Instantiate once and pass to ``ManifoldMCPHost/run(transport:)``:
///
/// ```swift
/// let transport = MCPHostStdioTransport()
/// try await host.run(transport: transport)
/// ```
///
/// ## Limitations
///
/// - macOS only (not available on iOS or Catalyst).
/// - Single-connection by design — a new process is expected per client.
/// - For streamable-HTTP clients that cannot launch the host as a subprocess,
///   use ``MCPHostHTTPTransport`` (the server-side HTTP/SSE transport, #1842).
public actor MCPHostStdioTransport: MCPHostTransport {

    // MARK: MCPHostTransport

    public nonisolated let incomingMessages: AsyncThrowingStream<Data, Error>

    // MARK: Private

    private let input: FileHandle
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let maxMessageBytes: Int
    private var readTask: Task<Void, Never>?
    private var didShutdown = false

    // MARK: Init

    public init(maxMessageBytes: Int = 4 * 1024 * 1024) {
        self.init(input: .standardInput, maxMessageBytes: maxMessageBytes)
    }

    /// Test seam: lets tests substitute a `Pipe`'s read end for real stdin so
    /// shutdown behavior can be exercised without touching the process's
    /// actual standard input.
    init(input: FileHandle, maxMessageBytes: Int = 4 * 1024 * 1024) {
        self.input = input
        self.maxMessageBytes = maxMessageBytes
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
        self.incomingMessages = stream
        self.continuation = continuation

        // Capture for the detached read task — captures are strong, which is
        // correct: the read loop must run until EOF, an error, or `shutdown()`.
        let cap = continuation
        let maxBytes = maxMessageBytes
        let inputFD = input.fileDescriptor
        self.readTask = Task.detached(priority: .utility) {
            await MCPHostStdioTransport.readLoop(
                inputFD: inputFD,
                continuation: cap,
                maxMessageBytes: maxBytes
            )
        }
    }

    // MARK: Lifecycle

    /// Unblocks the read loop and finishes ``incomingMessages``.
    ///
    /// The read loop blocks in a POSIX `read`, which cooperative
    /// `Task` cancellation alone cannot interrupt — there is no suspension
    /// point inside a blocking syscall. Closing the input handle out from
    /// under the blocked read makes it return/throw promptly (mirrors
    /// `ManifoldMCP`'s `InternalMCPTransport.close()`), after which the read
    /// loop observes the closed handle and exits. Awaiting the read task here
    /// makes shutdown deterministic rather than merely requested.
    ///
    /// Cancels the read task **before** closing the handle: the close is what
    /// unblocks the pending read, and the read loop's catch branches on
    /// `Task.isCancelled` to decide whether the resulting error is an
    /// intentional shutdown (finish cleanly) or a real transport failure
    /// (finish throwing). Closing first would race — the read can unblock and
    /// reach the catch before `cancel()` sets the flag, nondeterministically
    /// finishing the stream with a thrown EBADF instead of a clean finish.
    /// Cancelling first makes `Task.isCancelled` reliably true by the time the
    /// close unblocks the read.
    ///
    /// Idempotent — a second call is a no-op.
    public func shutdown() async {
        guard didShutdown == false else { return }
        didShutdown = true

        readTask?.cancel()
        do {
            try input.close()
        } catch {
            Log.inference.error(
                "MCPHostStdioTransport: failed to close input handle during shutdown: \(error.localizedDescription, privacy: .public)"
            )
        }
        await readTask?.value
        readTask = nil
        continuation.finish()
    }

    // MARK: Send

    /// Writes a single newline-delimited response payload to stdout.
    ///
    /// Actor isolation serialises concurrent send calls so stdout writes
    /// never interleave across concurrent MCP responses.
    public func send(_ payload: Data) async throws {
        let framed = MCPStdioFrameCodec.frame(payload)
        do {
            try FileHandle.standardOutput.write(contentsOf: framed)
        } catch {
            throw MCPHostTransportError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: Read loop (static to avoid implicit capture of self)

    private static func readLoop(
        inputFD: Int32,
        continuation: AsyncThrowingStream<Data, Error>.Continuation,
        maxMessageBytes: Int
    ) async {
        var parser = MCPStdioFrameCodec.Parser()
        do {
            while Task.isCancelled == false {
                // A single POSIX read returns as soon as a short JSON line
                // arrives. Closing the handle unblocks it with a catchable error.
                guard let chunk = try MCPStdioPipeReader.readAvailable(from: inputFD) else {
                    break
                }

                try parser.append(chunk, maxMessageBytes: maxMessageBytes)
                while let payload = try parser.nextFrame(maxMessageBytes: maxMessageBytes) {
                    continuation.yield(payload)
                }
            }
            continuation.finish()
        } catch {
            if Task.isCancelled {
                continuation.finish()
            } else if case MCPError.oversizeMessage(let bytes) = error {
                continuation.finish(throwing: MCPHostTransportError.oversizeMessage(bytes))
            } else {
                continuation.finish(throwing: error)
            }
        }
    }

}

// MARK: - MCPHostTransportError

public enum MCPHostTransportError: Error, LocalizedError, Sendable {
    case writeFailed(String)
    case oversizeHeader
    case oversizeMessage(Int)
    case invalidHeader
    case missingContentLength
    case invalidContentLength(String)
    case invalidPort(UInt16)
    case invalidAuthorizationToken
    case listenFailed(String)

    public var errorDescription: String? {
        switch self {
        case .writeFailed(let detail):
            return "Transport write failed: \(detail)"
        case .oversizeHeader:
            return "Incoming frame header exceeded maximum size"
        case .oversizeMessage(let bytes):
            return "Incoming frame body (\(bytes) bytes) exceeds the message size limit"
        case .invalidHeader:
            return "Incoming frame header is not valid UTF-8"
        case .missingContentLength:
            return "Incoming frame is missing the Content-Length header"
        case .invalidContentLength(let raw):
            return "Incoming frame has an invalid Content-Length value: '\(raw)'"
        case .invalidPort(let port):
            return "Invalid TCP port for HTTP transport: \(port)"
        case .invalidAuthorizationToken:
            return "HTTP transport authorization token must be non-empty and contain no whitespace or control characters"
        case .listenFailed(let detail):
            return "HTTP transport failed to start listening: \(detail)"
        }
    }
}

// MARK: - AsyncSequence Conformance

extension MCPHostStdioTransport: AsyncSequence {
    public typealias Element = Data
    public typealias AsyncIterator = AsyncThrowingStream<Data, Error>.AsyncIterator

    /// Returns an iterator over the incoming framed messages on this transport.
    ///
    /// Allows idiomatic iteration with `for try await message in transport { … }`
    /// instead of `for try await message in transport.incomingMessages { … }`.
    public nonisolated func makeAsyncIterator() -> AsyncThrowingStream<Data, Error>.AsyncIterator {
        incomingMessages.makeAsyncIterator()
    }
}
#endif
