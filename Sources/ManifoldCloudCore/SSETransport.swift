#if Ollama || CloudSaaS
import Foundation
import ManifoldInference

/// `FramedTransport` over Server-Sent Events.
///
/// Wraps the existing `SSEStreamParser` (which already parses `data:` lines
/// against `SSEStreamLimits` for DoS defence) and re-encodes each yielded
/// payload string as UTF-8 `Data` so the framing contract is byte-oriented.
///
/// The `[DONE]` sentinel is consumed inside the parser; downstream handlers
/// see only payload frames. Stream termination from a transport error
/// surfaces as the `AsyncStream` finishing — callers observing transport
/// errors must read them off the underlying `URLSession.AsyncBytes`
/// separately (the parser swallows them into `SSEStreamError`, which we
/// drop on the floor here since `FramedTransport.frames` is non-throwing
/// by contract).
///
/// > Note: Phase 2/B introduces this concrete impl. `SSECloudBackend` does
/// > not yet consume it — the envelope still drives `SSEStreamParser`
/// > directly. Phase 2/B/ii will route the envelope through the adapter's
/// > `framedTransport`.
public struct SSETransport: FramedTransport {
    private let limits: SSEStreamLimits

    public init(limits: SSEStreamLimits = ManifoldConfiguration.shared.sseStreamLimits) {
        self.limits = limits
    }

    public func frames(from bytes: URLSession.AsyncBytes) -> AsyncStream<Data> {
        // Capture limits into the Sendable closure context.
        let limits = self.limits
        return AsyncStream<Data> { continuation in
            let task = Task {
                let parsed = SSEStreamParser.parse(bytes: bytes, limits: limits)
                do {
                    for try await payload in parsed {
                        if Task.isCancelled { break }
                        // UTF-8 encode is total for `String`; force-unwrap is
                        // safe by Swift's invariant that `String` is valid
                        // Unicode.
                        continuation.yield(Data(payload.utf8))
                    }
                } catch {
                    // SSEStreamError surfaces as stream termination per the
                    // `FramedTransport` contract; envelope-level error
                    // observation reads transport errors off the byte stream
                    // separately.
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
#endif
