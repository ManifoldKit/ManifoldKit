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
    /// Resolves the `SSEStreamLimits` to apply for a given `frames(...)` call.
    ///
    /// A closure rather than a stored value is what lets per-instance host
    /// overrides on ``SSECloudBackend/sseStreamLimits`` reach the
    /// adapter-routed path. The legacy path reads `effectiveSSEStreamLimits`
    /// live on every generation; mirroring that here removes the silent
    /// divergence between the two paths.
    private let limitsProvider: @Sendable () -> SSEStreamLimits

    /// Construct a transport that resolves limits live from a host-supplied
    /// provider on each stream. Pass a closure that reads the host's
    /// per-instance override (e.g. `{ [weak backend] in
    /// backend?.effectiveSSEStreamLimits ?? .init() }`) so test overrides
    /// to `SSECloudBackend.sseStreamLimits` flow through to the parser.
    public init(limitsProvider: @escaping @Sendable () -> SSEStreamLimits) {
        self.limitsProvider = limitsProvider
    }

    /// Fixed-limits convenience initializer. Defaults to the
    /// `ManifoldConfiguration.shared.sseStreamLimits` snapshot at construction
    /// time. Use the `limitsProvider:` initializer when the limits source
    /// can change after construction — that's the only shape that lets a
    /// host's per-instance override reach the framed transport.
    public init(limits: SSEStreamLimits = ManifoldConfiguration.shared.sseStreamLimits) {
        self.limitsProvider = { limits }
    }

    public func frames(from bytes: URLSession.AsyncBytes) -> AsyncStream<Data> {
        // Resolve limits once per stream — matches the legacy path's
        // semantics, where `effectiveSSEStreamLimits` is read at the
        // top of each `parseResponseStream` invocation.
        let limits = self.limitsProvider()
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
                    // separately. Log at debug so the diagnostic signal is
                    // preserved without forcing every transport-level hiccup
                    // to bubble up as a top-level error.
                    Log.network.debug("SSETransport: parser terminated with \(error.localizedDescription, privacy: .public)")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
