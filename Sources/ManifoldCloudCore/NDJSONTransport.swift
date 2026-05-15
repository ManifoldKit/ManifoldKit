#if Ollama || CloudSaaS
import Foundation

/// `FramedTransport` over newline-delimited JSON.
///
/// Ollama's streaming API emits one JSON object per line with no `data:`
/// prefix and no `[DONE]` sentinel — the terminal frame is marked by a
/// `"done": true` field inside the JSON. This transport just splits on
/// `\n`, emits each non-empty trimmed line as a `Data` frame, and leaves
/// the per-frame interpretation to the payload handler.
///
/// Bounds:
///   - `maxLineBytes`: per-line cap; defends against an unbounded
///     never-newline upstream. Frames exceeding the cap are dropped
///     and the buffer is reset.
///   - `maxTotalBytes`: cumulative cap; defends against an unbounded
///     stream of small lines. Stream finishes early on breach.
public struct NDJSONTransport: FramedTransport {
    public let maxLineBytes: Int
    public let maxTotalBytes: Int

    /// Defaults are sized for current cloud Ollama payloads (long JSON
    /// per chunk for tool calls and thinking blocks) while still bounding
    /// memory.
    public init(maxLineBytes: Int = 1 << 20, maxTotalBytes: Int = 1 << 27) {
        self.maxLineBytes = maxLineBytes
        self.maxTotalBytes = maxTotalBytes
    }

    public func frames(from bytes: URLSession.AsyncBytes) -> AsyncStream<Data> {
        let maxLineBytes = self.maxLineBytes
        let maxTotalBytes = self.maxTotalBytes
        return AsyncStream<Data> { continuation in
            let task = Task {
                var buffer = Data()
                var total = 0
                do {
                    var iterator = bytes.makeAsyncIterator()
                    while let byte = try await iterator.next() {
                        if Task.isCancelled { break }
                        total += 1
                        if total > maxTotalBytes { break }
                        if byte == UInt8(ascii: "\n") {
                            if !buffer.isEmpty {
                                // Trim trailing CR (some servers ship \r\n).
                                if buffer.last == UInt8(ascii: "\r") {
                                    buffer.removeLast()
                                }
                                if !buffer.isEmpty {
                                    continuation.yield(buffer)
                                }
                                buffer.removeAll(keepingCapacity: true)
                            }
                        } else {
                            buffer.append(byte)
                            if buffer.count > maxLineBytes {
                                // Drop the over-long line; reset and keep
                                // streaming. The payload handler is
                                // resilient to malformed JSON.
                                buffer.removeAll(keepingCapacity: true)
                            }
                        }
                    }
                    // Flush trailing line if no terminator.
                    if !buffer.isEmpty {
                        continuation.yield(buffer)
                    }
                } catch {
                    // Transport error surfaces as stream termination per
                    // the `FramedTransport` contract.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
