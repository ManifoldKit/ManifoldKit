#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
import ManifoldInference
import os

/// Stdio transport for ``ManifoldMCPHost``.
///
/// Reads Content-Length–framed JSON-RPC messages from `stdin` and writes
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
        self.readTask = Task.detached(priority: .utility) {
            await MCPHostStdioTransport.readLoop(
                input: input,
                continuation: cap,
                maxMessageBytes: maxBytes
            )
        }
    }

    // MARK: Lifecycle

    /// Unblocks the read loop and finishes ``incomingMessages``.
    ///
    /// The read loop blocks in `input.read(upToCount:)`, which cooperative
    /// `Task` cancellation alone cannot interrupt — there is no suspension
    /// point inside a blocking syscall. Closing the input handle out from
    /// under the blocked read makes it return/throw promptly (mirrors
    /// `ManifoldMCP`'s `InternalMCPTransport.close()`), after which the read
    /// loop observes the closed handle and exits. Awaiting the read task here
    /// makes shutdown deterministic rather than merely requested.
    ///
    /// Idempotent — a second call is a no-op.
    public func shutdown() async {
        guard didShutdown == false else { return }
        didShutdown = true

        do {
            try input.close()
        } catch {
            Log.inference.error(
                "MCPHostStdioTransport: failed to close input handle during shutdown: \(error.localizedDescription, privacy: .public)"
            )
        }
        readTask?.cancel()
        await readTask?.value
        readTask = nil
        continuation.finish()
    }

    // MARK: Send

    /// Writes a single framed response payload to stdout.
    ///
    /// Actor isolation serialises concurrent send calls so stdout writes
    /// never interleave across concurrent MCP responses.
    public func send(_ payload: Data) async throws {
        let framed = frame(payload)
        do {
            try FileHandle.standardOutput.write(contentsOf: framed)
        } catch {
            throw MCPHostTransportError.writeFailed(error.localizedDescription)
        }
    }

    // MARK: Frame codec

    private func frame(_ payload: Data) -> Data {
        var framed = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
        framed.append(payload)
        return framed
    }

    // MARK: Read loop (static to avoid implicit capture of self)

    private static func readLoop(
        input: FileHandle,
        continuation: AsyncThrowingStream<Data, Error>.Continuation,
        maxMessageBytes: Int
    ) async {
        var parser = FrameParser()
        do {
            while Task.isCancelled == false {
                // `read(upToCount:)` blocks until data arrives, EOF (returns
                // nil/empty), or the handle is closed out from under it (throws)
                // — unlike `.availableData`, a closed-handle read surfaces as a
                // catchable Swift error rather than an uncatchable ObjC
                // exception, which is what makes `shutdown()`'s close-to-unblock
                // safe here.
                guard let chunk = try input.read(upToCount: 4096), chunk.isEmpty == false else {
                    break
                }

                try parser.append(chunk)
                while let payload = try parser.nextFrame(maxMessageBytes: maxMessageBytes) {
                    continuation.yield(payload)
                }
            }
            continuation.finish()
        } catch {
            if Task.isCancelled {
                continuation.finish()
            } else {
                continuation.finish(throwing: error)
            }
        }
    }

    // MARK: - FrameParser

    private struct FrameParser {
        private static let delimiter = Data("\r\n\r\n".utf8)
        private static let maxHeaderBytes = 8 * 1024

        private var buffer = Data()

        mutating func append(_ bytes: Data) throws {
            buffer.append(bytes)
            if buffer.count > Self.maxHeaderBytes && buffer.range(of: Self.delimiter) == nil {
                throw MCPHostTransportError.oversizeHeader
            }
        }

        mutating func nextFrame(maxMessageBytes: Int) throws -> Data? {
            guard let delimiterRange = buffer.range(of: Self.delimiter) else { return nil }
            let headerData = buffer[..<delimiterRange.lowerBound]
            guard let headerString = String(data: headerData, encoding: .utf8) else {
                throw MCPHostTransportError.invalidHeader
            }
            let contentLength = try parseContentLength(headerString)
            if contentLength > maxMessageBytes {
                throw MCPHostTransportError.oversizeMessage(contentLength)
            }

            let frameStart = delimiterRange.upperBound
            let available = buffer.distance(from: frameStart, to: buffer.endIndex)
            guard available >= contentLength else { return nil }

            let payloadEnd = buffer.index(frameStart, offsetBy: contentLength)
            let payload = Data(buffer[frameStart..<payloadEnd])
            buffer.removeSubrange(..<payloadEnd)
            return payload
        }

        private func parseContentLength(_ headers: String) throws -> Int {
            let lines = headers.components(separatedBy: "\r\n")
            guard let lengthHeader = lines.first(where: {
                $0.lowercased().hasPrefix("content-length:")
            }) else {
                throw MCPHostTransportError.missingContentLength
            }

            let value = lengthHeader.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
            guard let length = Int(value), length >= 0 else {
                throw MCPHostTransportError.invalidContentLength(value)
            }
            return length
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
