#if os(macOS) && !targetEnvironment(macCatalyst)
import Foundation
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

    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let maxMessageBytes: Int
    private let readTask: Task<Void, Never>

    // MARK: Init

    public init(maxMessageBytes: Int = 4 * 1024 * 1024) {
        self.maxMessageBytes = maxMessageBytes
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: Error.self)
        self.incomingMessages = stream
        self.continuation = continuation

        // Capture for the detached read task — captures are strong, which is
        // correct: the read loop must run for the lifetime of the transport.
        let cap = continuation
        let maxBytes = maxMessageBytes
        self.readTask = Task.detached(priority: .utility) {
            MCPHostStdioTransport.readLoop(
                input: FileHandle.standardInput,
                continuation: cap,
                maxMessageBytes: maxBytes
            )
        }
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
    ) {
        var parser = FrameParser()
        do {
            while true {
                // FileHandle.availableData blocks until data arrives.
                // On EOF it returns empty Data.
                let chunk: Data
                chunk = input.availableData
                guard !chunk.isEmpty else { break }

                try parser.append(chunk)
                while let payload = try parser.nextFrame(maxMessageBytes: maxMessageBytes) {
                    continuation.yield(payload)
                }
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
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
